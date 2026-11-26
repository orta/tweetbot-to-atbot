// redirect.m — injected into Tweetbot. Rewrites every request aimed at a
// *.twitter.com host to the local bridge (http://127.0.0.1:PORT), so Tweetbot's
// unchanged networking code ends up talking to our atproto translator.
//
// Interception point: NSURLSession's task-creation methods. Tweetbot's PTHCommon
// builds NSMutableURLRequest objects and sends them via NSURLSession, so hooking
// -dataTaskWithRequest:(completionHandler:) / -uploadTask... catches every call at
// a single unambiguous choke point (the request is already fully built there).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "bridge.h"

static int kBridgePort = 8080;

// File logging: NSLog from an ad-hoc-signed binary doesn't reliably reach the
// unified log, so we append to Application Support inside the sandbox container.
// Non-static so the in-process bridge (bridge.m) can log through the same file.
void tblog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *d = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        path = [d.firstObject stringByAppendingPathComponent:@"tweetbot-atproto.log"];
    });
    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [stamped writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    else { [fh seekToEndOfFile]; [fh writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

static BOOL isTwitterHost(NSString *host) {
    host = host.lowercaseString;
    if (!host) return NO;
    // Twitter API hosts...
    if ([host isEqualToString:@"twitter.com"] || [host hasSuffix:@".twitter.com"]) return YES;
    // ...and Tapbots' own API proxy, which is where Tweetbot actually routes OAuth
    // and REST (e.g. push.tapbots.com/tweetbot/5/oauth/request_token). The bridge's
    // path matching tolerates the /tweetbot/N prefix.
    if ([host isEqualToString:@"push.tapbots.com"]) return YES;
    return NO;
}

// Swap a target host's URL for the loopback bridge; pass others through.
static NSURL *rewriteURL(NSURL *url) {
    if (!url || !isTwitterHost(url.host)) return url;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.scheme = @"http";
    c.host = @"127.0.0.1";
    c.port = @(kBridgePort);
    tblog(@"REWRITE %@ -> %@", url, c.URL);
    return c.URL;
}

// Return a request whose twitter URL is swapped for the loopback bridge, keeping
// method, headers (incl. the OAuth Authorization header, which the bridge ignores)
// and body intact. Non-twitter requests pass through untouched.
static NSURLRequest *rewriteRequest(NSURLRequest *req) {
    NSURL *url = req.URL;
    if (!url) return req;
    tblog(@"SEEN %@ %@", req.HTTPMethod ?: @"GET", url);
    if (!isTwitterHost(url.host)) return req;
    NSMutableURLRequest *m = [req mutableCopy];
    m.URL = rewriteURL(url);
    return m;
}

// ---- NSURLSession task hooks ------------------------------------------------
static IMP orig_dataTaskReq;        // -dataTaskWithRequest:
static IMP orig_dataTaskReqCH;      // -dataTaskWithRequest:completionHandler:
static IMP orig_uploadReqData;      // -uploadTaskWithRequest:fromData:
static IMP orig_uploadReqDataCH;    // -uploadTaskWithRequest:fromData:completionHandler:

static id my_dataTaskReq(id self, SEL _cmd, NSURLRequest *req) {
    return ((id(*)(id, SEL, NSURLRequest *))orig_dataTaskReq)(self, _cmd, rewriteRequest(req));
}
static id my_dataTaskReqCH(id self, SEL _cmd, NSURLRequest *req, id ch) {
    return ((id(*)(id, SEL, NSURLRequest *, id))orig_dataTaskReqCH)(self, _cmd, rewriteRequest(req), ch);
}
static id my_uploadReqData(id self, SEL _cmd, NSURLRequest *req, NSData *body) {
    return ((id(*)(id, SEL, NSURLRequest *, NSData *))orig_uploadReqData)(self, _cmd, rewriteRequest(req), body);
}
static id my_uploadReqDataCH(id self, SEL _cmd, NSURLRequest *req, NSData *body, id ch) {
    return ((id(*)(id, SEL, NSURLRequest *, NSData *, id))orig_uploadReqDataCH)(self, _cmd, rewriteRequest(req), body, ch);
}

// ---- NSWorkspace openURL hook: the OAuth "authorize" step normally opens a URL in the
// default browser (Safari). We complete it entirely in-process instead: when we see the
// authorize URL, we ask the bridge for the callback and re-open it via our own atbot://
// scheme, so LaunchServices delivers it straight back to this running app (no browser,
// no blocked JS redirect, no manual step). Other URLs (real links in posts) pass through.
static IMP orig_openURL;
static BOOL my_openURL(id self, SEL _cmd, NSURL *url) {
    tblog(@"OPENURL %@", url);
    if (url && isTwitterHost(url.host) && [url.path containsString:@"/oauth/authorize"]) {
        NSString *cb = bridge_oauth_callback_url();
        if (cb.length) {
            NSURL *cbURL = [NSURL URLWithString:cb];
            tblog(@"authorize intercepted -> delivering callback in-app: %@", cb);
            // atbot:// is handled by this app, so this routes the GetURL event back to us.
            return ((BOOL(*)(id, SEL, NSURL *))orig_openURL)(self, _cmd, cbURL);
        }
        tblog(@"authorize seen but no pending uuid; falling back to browser");
    }
    return ((BOOL(*)(id, SEL, NSURL *))orig_openURL)(self, _cmd, rewriteURL(url));
}

// Instrument -handleOAuthURL: (the OAuth callback entry) to see what URL Tweetbot
// receives from the browser redirect and whether it proceeds. Found by scanning the
// class list for whichever app class implements it.
static IMP orig_handleOAuthURL;
// id-typed objc_msgSend shims for readability.
static inline id msg0(id o, const char *s) { return ((id(*)(id, SEL))objc_msgSend)(o, sel_registerName(s)); }
static inline id msg1(id o, const char *s, id a) { return ((id(*)(id, SEL, id))objc_msgSend)(o, sel_registerName(s), a); }

static id my_handleOAuthURL(id self, SEL _cmd, id url) {
    tblog(@"handleOAuthURL: <%@> arg=%@", NSStringFromClass([self class]), url);
    // Tweetbot keys self->_authDictionary by a CLIENT-SIDE 40-char id (+[NSString uuid]
    // generated in authenticate:completion:), and the response handler looks up
    // _authDictionary[ callbackURL.uuid ][@"block"] to find the stored completion that
    // creates the account. Our OAuth callback carries a different (dashed) uuid, so that
    // lookup misses and no account is created. Fix: rewrite the callback's uuid to the
    // pending entry's real key, matched by oauth_token (which the entry carries from the
    // request_token response). We run in-process, so we can just read the ivar.
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(self), "_authDictionary");
        id authDict = iv ? object_getIvar(self, iv) : nil;
        id q = msg0(url, "queryDictionary");
        id cbUuid = q ? msg1(q, "objectForKeyedSubscript:", @"uuid") : nil;
        id cbToken = q ? msg1(q, "objectForKeyedSubscript:", @"oauth_token") : nil;
        BOOL have = (authDict && cbUuid) ? (msg1(authDict, "objectForKeyedSubscript:", cbUuid) != nil) : NO;
        if (authDict && cbToken && !have) {
            id realKey = nil;
            for (id key in (id)msg0(authDict, "allKeys")) {
                id entry = msg1(authDict, "objectForKeyedSubscript:", key);
                id tok = entry ? msg1(entry, "objectForKeyedSubscript:", @"oauth_token") : nil;
                if (tok && ((BOOL(*)(id, SEL, id))objc_msgSend)(tok, sel_registerName("isEqual:"), cbToken)) { realKey = key; break; }
            }
            if (realKey) {
                NSString *s = [url absoluteString];
                NSString *fixed = cbUuid
                    ? [s stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"uuid=%@", cbUuid]
                                                   withString:[NSString stringWithFormat:@"uuid=%@", realKey]]
                    : [s stringByAppendingFormat:@"&uuid=%@", realKey];
                id fixedURL = [NSURL URLWithString:fixed];
                if (fixedURL) {
                    tblog(@"  rewrote callback uuid %@ -> %@ (matched oauth_token)", cbUuid, realKey);
                    url = fixedURL;
                }
            } else {
                tblog(@"  no _authDictionary entry matched oauth_token=%@", cbToken);
            }
        }
    } @catch (id e) { tblog(@"  (authDict rewrite failed)"); }
    id r = ((id(*)(id, SEL, id))orig_handleOAuthURL)(self, _cmd, url);
    tblog(@"handleOAuthURL: returned %@", r);
    return r;
}
// Probe the raw GetURL apple-event handler to see the URL the app actually receives.
static IMP orig_handleURLEvent;
static void my_handleURLEvent(id self, SEL _cmd, id event, id reply) {
    @try {
        // [[event paramDescriptorForKeyword:keyDirectObject] stringValue]
        id dobj = ((id(*)(id, SEL, unsigned int))objc_msgSend)(event, sel_registerName("paramDescriptorForKeyword:"), '----');
        id s = ((id(*)(id, SEL))objc_msgSend)(dobj, sel_registerName("stringValue"));
        tblog(@"handleURLEvent: <%@> url=%@", NSStringFromClass([self class]), s);
    } @catch (__unused id e) {}
    ((void(*)(id, SEL, id, id))orig_handleURLEvent)(self, _cmd, event, reply);
}

static void swizzleFirstImplementor(SEL sel, IMP repl, IMP *outOrig, const char *label) {
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) {
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(classes[i], &mc);
        BOOL has = NO;
        for (unsigned int j = 0; j < mc; j++) if (method_getName(ms[j]) == sel) { has = YES; break; }
        free(ms);
        if (has) {
            Method m = class_getInstanceMethod(classes[i], sel);
            *outOrig = method_setImplementation(m, repl);
            tblog(@"%s probe on %@", label, NSStringFromClass(classes[i]));
        }
    }
    free(classes);
}

static void installOAuthProbe(void) {
    swizzleFirstImplementor(@selector(handleOAuthURL:), (IMP)my_handleOAuthURL, &orig_handleOAuthURL, "handleOAuthURL");
    swizzleFirstImplementor(@selector(handleURLEvent:withReplyEvent:), (IMP)my_handleURLEvent, &orig_handleURLEvent, "handleURLEvent");
}

// ---- CloudKit neutralization -------------------------------------------------
// We strip the team-scoped iCloud entitlements (icloud-container-identifiers etc.)
// so the ad-hoc-signed app can launch, but that makes CloudKit trap (EXC_BREAKPOINT)
// the moment Tweetbot's iCloud sync touches a CKContainer — which happens when the
// timeline window opens (+[PTHCloudController container] -> CKContainer). Stub the
// container accessor to return nil so the sync layer no-ops instead of trapping.
static id my_cloud_container(__unused id self, __unused SEL _cmd) { return nil; }

static void neutralizeCloudKit(void) {
    Class cc = objc_getClass("PTHCloudController");
    if (!cc) { tblog(@"PTHCloudController not found (no CloudKit stub)"); return; }
    // class method: operate on the metaclass
    Class meta = object_getClass(cc);
    Method m = class_getClassMethod(cc, sel_registerName("container"));
    if (m) {
        method_setImplementation(m, (IMP)my_cloud_container);
        tblog(@"stubbed +[PTHCloudController container] -> nil");
    } else {
        // fall back: add it on the metaclass
        class_addMethod(meta, sel_registerName("container"), (IMP)my_cloud_container, "@@:");
        tblog(@"added +[PTHCloudController container] -> nil");
    }
}

// ---- Web permalinks ----------------------------------------------------------
// -[PTHTweetbotStatus twitterURL] builds "https://twitter.com/<screenName>/status/<id>"
// and -[PTHTweetbotUser twitterURL] "https://twitter.com/<screenName>" (Model.framework);
// they feed Copy Link / Copy Tweet / Open in Browser / share. Point them at bsky.app.
static void hookInstance(Class cls, SEL sel, IMP repl, IMP *outOrig);
static IMP orig_statusTwitterURL;
static IMP orig_userTwitterURL;

static id my_statusTwitterURL(id self, SEL _cmd) {
    @try {
        id user = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("user"));
        NSString *handle = user ? ((id(*)(id, SEL))objc_msgSend)(user, sel_registerName("screenName")) : nil;
        NSNumber *tid = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("originalTIDValue"));
        NSString *s = bridge_post_web_url(tid.stringValue, handle);
        NSURL *u = s ? [NSURL URLWithString:s] : nil;
        if (u) return u;
    } @catch (__unused id e) {}
    return ((id(*)(id, SEL))orig_statusTwitterURL)(self, _cmd);
}

static id my_userTwitterURL(id self, SEL _cmd) {
    @try {
        NSString *handle = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("screenName"));
        NSURL *u = handle.length ? [NSURL URLWithString:bridge_profile_web_url(handle)] : nil;
        if (u) return u;
    } @catch (__unused id e) {}
    return ((id(*)(id, SEL))orig_userTwitterURL)(self, _cmd);
}

static void installWebURLHooks(void) {
    Class st = objc_getClass("PTHTweetbotStatus"), us = objc_getClass("PTHTweetbotUser");
    if (st) hookInstance(st, sel_registerName("twitterURL"), (IMP)my_statusTwitterURL, &orig_statusTwitterURL);
    if (us) hookInstance(us, sel_registerName("twitterURL"), (IMP)my_userTwitterURL, &orig_userTwitterURL);
    tblog(@"web URL hooks: status=%d user=%d", orig_statusTwitterURL != NULL, orig_userTwitterURL != NULL);
}

static void hookInstance(Class cls, SEL sel, IMP repl, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { tblog(@"MISSING -%@", NSStringFromSelector(sel)); return; }
    // If this Method is already our replacement (e.g. the concrete subclass just
    // inherits the public class's now-hooked IMP), don't re-hook — that would
    // capture our own IMP as the "original" and recurse forever.
    if (method_getImplementation(m) == repl) return;
    *outOrig = method_setImplementation(m, repl);
}


// ---- Link cards --------------------------------------------------------------
// The bridge serves a post's link card (app.bsky.embed.external) as a synthetic quoted
// status, since the quote box is the only boxed sub-view Tweetbot has. Clicking a real
// quote opens that status; clicking a card should open the link. Both the timeline row
// (PTHTweetbotStatusView) and the detail header (PTHTweetbotStatusDetailStatusView)
// route the click through -_quoteClicked:.
static IMP orig_rowQuoteClicked;
static IMP orig_detailQuoteClicked;

static BOOL openLinkCard(id view) {
    @try {
        SEL statusSel = sel_registerName("status"), quoteSel = sel_registerName("quotedStatus"),
            tidSel = sel_registerName("originalTIDValue");
        id st = [view respondsToSelector:statusSel] ? ((id(*)(id, SEL))objc_msgSend)(view, statusSel) : nil;
        id q = [st respondsToSelector:quoteSel] ? ((id(*)(id, SEL))objc_msgSend)(st, quoteSel) : nil;
        NSNumber *tid = [q respondsToSelector:tidSel] ? ((id(*)(id, SEL))objc_msgSend)(q, tidSel) : nil;
        NSString *s = tid ? bridge_card_url(tid.stringValue) : nil;
        NSURL *u = s ? [NSURL URLWithString:s] : nil;
        if (!u) return NO;
        id ws = ((id(*)(id, SEL))objc_msgSend)((id)objc_getClass("NSWorkspace"), sel_registerName("sharedWorkspace"));
        ((BOOL(*)(id, SEL, id))objc_msgSend)(ws, sel_registerName("openURL:"), u);
        return YES;
    } @catch (__unused id e) {}
    return NO;
}
static void my_rowQuoteClicked(id self, SEL _cmd, id sender) {
    if (!openLinkCard(self)) ((void(*)(id, SEL, id))orig_rowQuoteClicked)(self, _cmd, sender);
}
static void my_detailQuoteClicked(id self, SEL _cmd, id sender) {
    if (!openLinkCard(self)) ((void(*)(id, SEL, id))orig_detailQuoteClicked)(self, _cmd, sender);
}
static void installLinkCardHooks(void) {
    Class row = objc_getClass("PTHTweetbotStatusView"), detail = objc_getClass("PTHTweetbotStatusDetailStatusView");
    if (row) hookInstance(row, sel_registerName("_quoteClicked:"), (IMP)my_rowQuoteClicked, &orig_rowQuoteClicked);
    if (detail) hookInstance(detail, sel_registerName("_quoteClicked:"), (IMP)my_detailQuoteClicked, &orig_detailQuoteClicked);
    tblog(@"link card hooks: row=%d detail=%d", orig_rowQuoteClicked != NULL, orig_detailQuoteClicked != NULL);
}

// ---- Tab shortcuts from any window -------------------------------------------
// View → Tabs (Timeline ⌘1 … Lists ⌘8) sends a nil-targeted -changeTab: (the item's tag
// picks the tab). Only PTHTweetbotMainViewController implements it, so it's in the
// responder chain only while a main window is key or main: with a compose / drafts /
// media / prefs window in front, or the main window minimised or closed, ⌘1 is disabled
// and does nothing. Give PTHTweetbotAppDelegate (the chain's last stop) a -changeTab: that
// brings the main window forward and hands it the action. The delegate's own
// -validateMenuItem: already answers YES for actions it doesn't special-case.

// The front-most of the delegate's main windows (one per account window), else any.
static id frontMainWindowController(id delegate) {
    NSArray *mwcs = [delegate respondsToSelector:sel_registerName("mainWindowControllers")]
        ? msg0(delegate, "mainWindowControllers") : nil;
    if (!mwcs.count) return nil;
    id app = msg0((id)objc_getClass("NSApplication"), "sharedApplication");
    for (id w in (NSArray *)msg0(app, "orderedWindows")) {
        id wc = msg0(w, "windowController");
        if (wc && [mwcs containsObject:wc]) return wc;
    }
    return mwcs.firstObject;
}

static void my_delegateChangeTab(id self, __unused SEL _cmd, id sender) {
    @try {
        id wc = frontMainWindowController(self);
        if (!wc) {
            // No main window open: same as File → New Window (needs an account).
            NSArray *accounts = msg0((id)objc_getClass("PTHTweetbotAccount"), "accounts");
            if (accounts.count) ((void(*)(id, SEL, id))objc_msgSend)(self, sel_registerName("newMainWindow:"), sender);
            wc = frontMainWindowController(self);
            if (!wc) return;
        }
        id win = msg0(wc, "window");
        if (((BOOL(*)(id, SEL))objc_msgSend)(win, sel_registerName("isMiniaturized")))
            ((void(*)(id, SEL, id))objc_msgSend)(win, sel_registerName("deminiaturize:"), nil);
        ((void(*)(id, SEL, id))objc_msgSend)(win, sel_registerName("makeKeyAndOrderFront:"), nil);
        // Call the main view controller directly (not a nil-targeted resend): the window
        // may not be key yet (deminiaturize animates), which would route back here.
        id vc = msg0(win, "contentViewController");
        if ([vc respondsToSelector:@selector(changeTab:)])
            ((void(*)(id, SEL, id))objc_msgSend)(vc, @selector(changeTab:), sender);
    } @catch (id e) { tblog(@"changeTab fallback failed: %@", e); }
}

static void installTabShortcutFallback(void) {
    Class d = objc_getClass("PTHTweetbotAppDelegate");
    if (!d) { tblog(@"PTHTweetbotAppDelegate not found (no tab-shortcut fallback)"); return; }
    BOOL added = class_addMethod(d, @selector(changeTab:), (IMP)my_delegateChangeTab, "v@:@");
    tblog(@"tab-shortcut fallback on app delegate: %d", added);
}

// ---- DM read state -> Bluesky --------------------------------------------------
// Reading a DM thread ends in -[PTHTweetbotDirectMessageThread setLastReadTID:] (markRead
// passes the newest message). Pass it on so Bluesky's unread state follows. The bridge's
// own Bluesky -> Tweetbot sync writes through the class-level _updateLastReadTID:threadKey:,
// which never calls this setter, so the two can't ping-pong.
static void (*orig_setLastReadTID)(id, SEL, long long);
static void my_setLastReadTID(id self, SEL _cmd, long long tid) {
    orig_setLastReadTID(self, _cmd, tid);
    @try {
        long long other = ((long long (*)(id, SEL))objc_msgSend)(self, sel_registerName("otherUserTID"));
        bridge_dm_mark_read(other, tid);
    } @catch (id e) { tblog(@"dm read hook failed: %@", e); }
}

static void installDMReadHook(void) {
    Class t = objc_getClass("PTHTweetbotDirectMessageThread");
    Method m = t ? class_getInstanceMethod(t, sel_registerName("setLastReadTID:")) : NULL;
    if (!m) { tblog(@"PTHTweetbotDirectMessageThread setLastReadTID: not found (no DM read sync)"); return; }
    orig_setLastReadTID = (void (*)(id, SEL, long long))method_setImplementation(m, (IMP)my_setLastReadTID);
    tblog(@"dm read hook installed");
}

// ---- A home for the DM database ------------------------------------------------
// Tweetbot keeps each account's databases in <App Group container>/Library/Application
// Support/<account id>.accountd (+[PTHTweetbotAccount containerURL]). The App Group is
// Tapbots' (~/Library/Group Containers/9JTH7AWHE6.com.tapbots.Tweetbot3Mac) and we strip
// that entitlement to launch, so the sandbox can't write there: -[PTHTweetbotAccountMessages
// initWithAccount:] can't open messages.sql, the store never finishes loading (_hasLoaded),
// every refresh queues behind it, and the Messages tab spins forever. Give just that init
// the same layout inside our own sandbox container. Everything else kept there (data.sql,
// drafts, filters, the account list) still can't persist: widening this would restore
// cached posts across launches, and the bridge's id registries are in-memory, so those
// posts would stop resolving.
static __thread BOOL tInMessagesInit = NO;
static id (*orig_accountDirectory)(id, SEL);
static id my_accountDirectory(id self, SEL _cmd) {
    id dir = orig_accountDirectory(self, _cmd);
    if (!tInMessagesInit) return dir;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([dir isKindOfClass:NSString.class] && [fm isWritableFileAtPath:dir]) return dir;
    id tid = msg0(self, "tidValue");
    if (![tid respondsToSelector:@selector(stringValue)]) return dir;
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"]
                      stringByAppendingPathComponent:[[tid stringValue] stringByAppendingPathExtension:@"accountd"]];
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
    return path;
}
static id (*orig_messagesInit)(id, SEL, id);
static id my_messagesInit(id self, SEL _cmd, id account) {
    tInMessagesInit = YES;
    tblog(@"messages store at %@", msg0(account, "accountDirectory"));
    id r = orig_messagesInit(self, _cmd, account);
    tInMessagesInit = NO;
    return r;
}

static void installMessagesStoreFallback(void) {
    Class acct = objc_getClass("PTHTweetbotAccount"), msgs = objc_getClass("PTHTweetbotAccountMessages");
    Method dir = acct ? class_getInstanceMethod(acct, sel_registerName("accountDirectory")) : NULL;
    Method init = msgs ? class_getInstanceMethod(msgs, sel_registerName("initWithAccount:")) : NULL;
    if (!dir || !init) { tblog(@"messages store fallback: methods not found"); return; }
    orig_accountDirectory = (id (*)(id, SEL))method_setImplementation(dir, (IMP)my_accountDirectory);
    orig_messagesInit = (id (*)(id, SEL, id))method_setImplementation(init, (IMP)my_messagesInit);
    tblog(@"messages store fallback installed");
}

__attribute__((constructor))
static void tweetbot_atproto_init(void) {
    @autoreleasepool {
        // Start the in-process bridge (no external Node server) and point the
        // redirector at its loopback port. An explicit TWEETBOT_BRIDGE_PORT overrides
        // this (used in dev when running the Node bridge/ prototype standalone).
        const char *p = getenv("TWEETBOT_BRIDGE_PORT");
        if (p) {
            kBridgePort = atoi(p);
            tblog(@"using external bridge port %d (TWEETBOT_BRIDGE_PORT)", kBridgePort);
        } else {
            int port = bridge_start();
            if (port > 0) kBridgePort = port;
            else tblog(@"in-process bridge failed to start; falling back to port %d", kBridgePort);
        }

        // NSURLSession is a class cluster: instances are a private subclass that
        // may carry its own IMPs. Hook both the public class and the concrete class
        // of a real session so we can't be bypassed.
        Class pub = objc_getClass("NSURLSession");
        Class concrete = object_getClass([NSURLSession sharedSession]);
        tblog(@"concrete session class = %@", NSStringFromClass(concrete));

        NSMutableSet *seen = [NSMutableSet set];
        for (Class s in @[pub, concrete]) {
            NSString *cn = NSStringFromClass(s);
            if ([seen containsObject:cn]) continue;
            [seen addObject:cn];
            IMP o1 = NULL, o2 = NULL, o3 = NULL, o4 = NULL;
            hookInstance(s, @selector(dataTaskWithRequest:), (IMP)my_dataTaskReq, &o1);
            hookInstance(s, @selector(dataTaskWithRequest:completionHandler:), (IMP)my_dataTaskReqCH, &o2);
            hookInstance(s, @selector(uploadTaskWithRequest:fromData:), (IMP)my_uploadReqData, &o3);
            hookInstance(s, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)my_uploadReqDataCH, &o4);
            if (o1) orig_dataTaskReq = o1;
            if (o2) orig_dataTaskReqCH = o2;
            if (o3) orig_uploadReqData = o3;
            if (o4) orig_uploadReqDataCH = o4;
        }

        // hook NSWorkspace openURL: so the browser authorize step hits the bridge
        Class ws = objc_getClass("NSWorkspace");
        hookInstance(ws, @selector(openURL:), (IMP)my_openURL, &orig_openURL);

        installOAuthProbe();
        neutralizeCloudKit();
        installWebURLHooks();
        installLinkCardHooks();
        installTabShortcutFallback();
        installDMReadHook();
        installMessagesStoreFallback();

        tblog(@"redirector installed (NSURLSession + openURL hooks), bridge port %d", kBridgePort);
    }
}
