// bridge.m — the fake-Twitter bridge, running IN-PROCESS inside atbot.
//
// This is an Objective-C port of the Node prototype (bridge/*.mjs). It stands up a
// tiny loopback HTTP server on 127.0.0.1:<ephemeral> that the injected redirector
// (redirect.m) points Tweetbot's *.twitter.com / push.tapbots.com traffic at, and
// answers those Twitter 1.1 requests with Twitter-shaped JSON backed by atproto.
//
// No external process, no Node — the whole thing lives in the dylib, so a built
// atbot.app is fully self-contained. Credentials are read from the app bundle
// (Resources/atproto.json, written at build time) or the environment (dev).
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

#import "bridge.h"

// ---- small logging shim (shared with redirect.m) ---------------------------
extern void tblog(NSString *fmt, ...);

// ---- forward declarations (definitions live in the shapes section below) ----
static NSString *stableId(NSString *key);
static NSMutableDictionary<NSString *, NSString *> *gActorRegistry;      // id/handle -> did
static NSMutableDictionary<NSString *, NSDictionary *> *gPostRegistry;   // id -> {uri,cid,...}

#pragma mark - Credentials

static NSString *gHandle = nil;       // login identifier (handle or DID)
static NSString *gAppPassword = nil;  // Bluesky app password
static NSString *gPDSHint = nil;      // optional PDS override

// Loaded/derived session state.
static NSString *gDID = nil;
static NSString *gSessionHandle = nil;
static NSString *gPDS = nil;          // resolved PDS base URL
static NSString *gAccessJwt = nil;
static NSString *gRefreshJwt = nil;

static void loadCredentials(void) {
    // 1) env (developer runs), 2) bundled Resources/atproto.json (shipped atbot).
    NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
    gHandle = env[@"BRIDGE_HANDLE"];
    gAppPassword = env[@"BRIDGE_APP_PASSWORD"];
    gPDSHint = env[@"BRIDGE_PDS"];
    if (gHandle.length && gAppPassword.length) { tblog(@"[bridge] creds from env (%@)", gHandle); return; }

    NSString *path = [[NSBundle mainBundle] pathForResource:@"atproto" ofType:@"json"];
    if (path) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        if ([j isKindOfClass:NSDictionary.class]) {
            gHandle = j[@"handle"] ?: j[@"identifier"];
            gAppPassword = j[@"appPassword"] ?: j[@"password"];
            gPDSHint = j[@"pds"];
            tblog(@"[bridge] creds from bundle atproto.json (%@)", gHandle);
            return;
        }
    }
    tblog(@"[bridge] no credentials (env or Resources/atproto.json) — reads will fail");
}

#pragma mark - Synchronous XRPC helper

// Perform a synchronous HTTP request and return parsed JSON (or raw via out-params).
// Runs on the server's background queue, so blocking is fine. Our own networking is
// to atproto hosts (bsky.social / plc.directory / the PDS), which the redirector
// leaves untouched (only *.twitter.com / push.tapbots.com get rewritten).
static id httpRequestJSON(NSString *method, NSString *urlStr,
                          NSDictionary<NSString *, NSString *> *headers,
                          NSData *body, NSInteger *statusOut, NSString **errOut) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = method;
    for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
    if (body) req.HTTPBody = body;

    __block NSData *outData = nil; __block NSInteger code = 0; __block NSError *netErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            outData = data; netErr = error;
            if ([resp isKindOfClass:NSHTTPURLResponse.class]) code = ((NSHTTPURLResponse *)resp).statusCode;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (statusOut) *statusOut = code;
    if (netErr) { if (errOut) *errOut = netErr.localizedDescription; return nil; }
    if (!outData.length) return @{};
    id json = [NSJSONSerialization JSONObjectWithData:outData options:0 error:NULL];
    if (!json) { // non-JSON body
        if (errOut) *errOut = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"non-json";
        return nil;
    }
    return json;
}

static NSString *qstr(NSDictionary *params) {
    if (!params.count) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    NSCharacterSet *allowed = NSCharacterSet.URLQueryAllowedCharacterSet;
    for (NSString *k in params) {
        id v = params[k];
        if (v == nil || v == NSNull.null) continue;
        // arrays become repeated params (XRPC style: feeds=a&feeds=b)
        for (id item in ([v isKindOfClass:NSArray.class] ? v : @[v])) {
            NSString *vs = [[item description] stringByAddingPercentEncodingWithAllowedCharacters:allowed];
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, vs]];
        }
    }
    return parts.count ? [@"?" stringByAppendingString:[parts componentsJoinedByString:@"&"]] : @"";
}

#pragma mark - atproto client

static NSString *jsonString(id obj, NSString *key) {
    id v = [obj isKindOfClass:NSDictionary.class] ? obj[key] : nil;
    return [v isKindOfClass:NSString.class] ? v : nil;
}

// handle/DID -> hosting PDS (so any PDS works, not just bsky.social).
static BOOL atpResolvePds(NSString *identifier, NSString **errOut) {
    NSString *did = identifier;
    if (![identifier hasPrefix:@"did:"]) {
        NSString *appView = @"https://public.api.bsky.app";
        NSString *url = [NSString stringWithFormat:@"%@/xrpc/com.atproto.identity.resolveHandle%@",
                         appView, qstr(@{ @"handle": [identifier stringByReplacingOccurrencesOfString:@"@" withString:@""] })];
        NSInteger code = 0; id r = httpRequestJSON(@"GET", url, nil, nil, &code, errOut);
        did = jsonString(r, @"did");
        if (!did) { if (errOut && !*errOut) *errOut = @"resolveHandle failed"; return NO; }
    }
    NSDictionary *doc = nil;
    if ([did hasPrefix:@"did:plc:"]) {
        doc = httpRequestJSON(@"GET", [NSString stringWithFormat:@"https://plc.directory/%@", did], nil, nil, NULL, errOut);
    } else if ([did hasPrefix:@"did:web:"]) {
        NSString *host = [[did substringFromIndex:8] stringByReplacingOccurrencesOfString:@":" withString:@"/"];
        doc = httpRequestJSON(@"GET", [NSString stringWithFormat:@"https://%@/.well-known/did.json", host], nil, nil, NULL, errOut);
    } else { if (errOut) *errOut = @"unsupported DID method"; return NO; }

    NSString *endpoint = nil;
    for (NSDictionary *svc in ([doc isKindOfClass:NSDictionary.class] ? doc[@"service"] : nil)) {
        if ([svc[@"id"] isEqual:@"#atproto_pds"] || [svc[@"type"] isEqual:@"AtprotoPersonalDataServer"]) {
            endpoint = svc[@"serviceEndpoint"]; break;
        }
    }
    if (!endpoint.length) { if (errOut) *errOut = @"no PDS endpoint in DID doc"; return NO; }
    gPDS = [endpoint hasSuffix:@"/"] ? [endpoint substringToIndex:endpoint.length - 1] : endpoint;
    gDID = did;
    return YES;
}

static BOOL atpLogin(NSString **errOut) {
    if (!gHandle.length || !gAppPassword.length) { if (errOut) *errOut = @"no credentials"; return NO; }
    if (gPDSHint.length) gPDS = [gPDSHint hasSuffix:@"/"] ? [gPDSHint substringToIndex:gPDSHint.length - 1] : gPDSHint;
    // Always resolve the hosting PDS from the handle/DID (sets gPDS + gDID). Even with
    // a hint we need gDID; resolve is cheap and authoritative.
    if (!atpResolvePds(gHandle, errOut)) { if (gPDSHint.length == 0) return NO; }

    NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"identifier": gHandle, @"password": gAppPassword } options:0 error:NULL];
    NSInteger code = 0;
    id r = httpRequestJSON(@"POST", [NSString stringWithFormat:@"%@/xrpc/com.atproto.server.createSession", gPDS],
                           @{ @"content-type": @"application/json" }, body, &code, errOut);
    if (![r isKindOfClass:NSDictionary.class] || !jsonString(r, @"accessJwt")) {
        if (errOut && !*errOut) *errOut = @"createSession failed";
        return NO;
    }
    gAccessJwt = r[@"accessJwt"]; gRefreshJwt = r[@"refreshJwt"];
    gDID = r[@"did"] ?: gDID; gSessionHandle = r[@"handle"] ?: gHandle;
    tblog(@"[bridge] logged in as %@ (%@)", gSessionHandle, gDID);
    return YES;
}

// Re-login on token expiry (app-password sessions don't always keep a usable refresh).
static BOOL atpRefresh(NSString **errOut) {
    if (gRefreshJwt.length) {
        NSInteger code = 0;
        id r = httpRequestJSON(@"POST", [NSString stringWithFormat:@"%@/xrpc/com.atproto.server.refreshSession", gPDS],
                               @{ @"authorization": [@"Bearer " stringByAppendingString:gRefreshJwt] }, nil, &code, NULL);
        if ([r isKindOfClass:NSDictionary.class] && jsonString(r, @"accessJwt")) {
            gAccessJwt = r[@"accessJwt"]; gRefreshJwt = r[@"refreshJwt"] ?: gRefreshJwt; return YES;
        }
    }
    return atpLogin(errOut);
}

// Authenticated XRPC against the account's PDS. `proxy` routes personalized app.bsky.*
// reads through the PDS to the AppView (the public AppView rejects them: AuthMissing).
// Not logged in yet (e.g. a request arrived during the initial async login, or the
// session was never established)? Log in inline. Serialized so concurrent requests at
// boot don't all hammer createSession. Handlers that read gDID must call this first.
static BOOL atpEnsureSession(NSString **errOut) {
    static NSObject *loginLock; static dispatch_once_t once; dispatch_once(&once, ^{ loginLock = [NSObject new]; });
    @synchronized (loginLock) {
        if (gAccessJwt && gPDS && gDID) return YES;
        return atpLogin(errOut);
    }
}

static id atpAuthed(NSString *method, NSString *nsid, NSDictionary *params, NSData *body, BOOL proxy, NSString **errOut) {
    if (!atpEnsureSession(errOut)) return nil;
    NSString *url = [NSString stringWithFormat:@"%@/xrpc/%@%@", gPDS, nsid, qstr(params)];
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    if (gAccessJwt) h[@"authorization"] = [@"Bearer " stringByAppendingString:gAccessJwt];
    if (proxy) h[@"atproto-proxy"] = @"did:web:api.bsky.app#bsky_appview";
    if (body) h[@"content-type"] = @"application/json";

    NSInteger code = 0; NSString *err = nil;
    id r = httpRequestJSON(method, url, h, body, &code, &err);
    if (code == 400 || code == 401) { // token likely expired -> refresh + retry once
        if (atpRefresh(NULL)) {
            h[@"authorization"] = [@"Bearer " stringByAppendingString:gAccessJwt];
            err = nil; r = httpRequestJSON(method, url, h, body, &code, &err);
        }
    }
    if (code >= 400 || (!r && err)) { if (errOut) *errOut = err ?: [NSString stringWithFormat:@"%@ %ld", nsid, (long)code]; return nil; }
    return r;
}
static id atpView(NSString *nsid, NSDictionary *params, NSString **errOut) { return atpAuthed(@"GET", nsid, params, nil, YES, errOut); }
static id atpCall(NSString *method, NSString *nsid, NSDictionary *params, NSData *body, NSString **errOut) { return atpAuthed(method, nsid, params, body, NO, errOut); }

// ---- writes (com.atproto.repo.*) -------------------------------------------
static NSString *nowISO(void) {
    static NSDateFormatter *f; static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"; f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"]; });
    return [f stringFromDate:[NSDate date]];
}

// Create a record in the user's repo; returns { uri, cid } or nil.
static NSDictionary *atpCreateRecord(NSString *collection, NSDictionary *record, NSString **errOut) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"repo": gDID ?: @"", @"collection": collection, @"record": record } options:0 error:NULL];
    id r = atpCall(@"POST", @"com.atproto.repo.createRecord", nil, body, errOut);
    return [r isKindOfClass:NSDictionary.class] ? r : nil;
}
// Delete a record given its at:// URI (at://did/collection/rkey).
static BOOL atpDeleteAtUri(NSString *atUri, NSString **errOut) {
    if (![atUri hasPrefix:@"at://"]) return NO;
    NSArray *parts = [[atUri substringFromIndex:5] componentsSeparatedByString:@"/"];
    if (parts.count < 3) return NO;
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"repo": parts[0], @"collection": parts[1], @"rkey": parts[2] } options:0 error:NULL];
    id r = atpCall(@"POST", @"com.atproto.repo.deleteRecord", nil, body, errOut);
    return r != nil;
}
// Fetch a single hydrated post (for fresh state + viewer like/repost record uris).
static NSDictionary *atpGetPost(NSString *uri, NSString **errOut) {
    id r = atpView(@"app.bsky.feed.getPosts", @{ @"uris": uri }, errOut);
    NSArray *posts = [r isKindOfClass:NSDictionary.class] ? r[@"posts"] : nil;
    return posts.count ? posts[0] : nil;
}

// Build atproto richtext facets (links + @mentions) from plain compose text, with
// UTF-8 byte offsets, so posted links/mentions are tappable on Bluesky.
static NSArray *buildFacets(NSString *text) {
    NSMutableArray *facets = [NSMutableArray array];
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    // helper: UTF-16 range -> UTF-8 byte range
    NSUInteger (^byteAt)(NSUInteger) = ^NSUInteger(NSUInteger charIdx) {
        return [[text substringToIndex:MIN(charIdx, text.length)] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    };
    // links
    NSDataDetector *det = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
    for (NSTextCheckingResult *m in [det matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSString *uri = m.URL.absoluteString;
        if (!uri) continue;
        [facets addObject:@{ @"index": @{ @"byteStart": @(byteAt(m.range.location)), @"byteEnd": @(byteAt(NSMaxRange(m.range))) },
                             @"features": @[@{ @"$type": @"app.bsky.richtext.facet#link", @"uri": uri }] }];
    }
    // @mentions -> resolve handle to DID
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"@([a-zA-Z0-9][a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,})" options:0 error:NULL];
    for (NSTextCheckingResult *m in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSString *handle = [text substringWithRange:[m rangeAtIndex:1]];
        NSString *did = gActorRegistry[handle.lowercaseString];
        if (!did || [did isEqual:handle]) { // resolve via AppView
            id r = httpRequestJSON(@"GET", [NSString stringWithFormat:@"https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle%@", qstr(@{ @"handle": handle })], nil, nil, NULL, NULL);
            did = jsonString(r, @"did");
        }
        if (!did.length) continue;
        [facets addObject:@{ @"index": @{ @"byteStart": @(byteAt(m.range.location)), @"byteEnd": @(byteAt(NSMaxRange(m.range))) },
                             @"features": @[@{ @"$type": @"app.bsky.richtext.facet#mention", @"did": did }] }];
    }
    (void)utf8;
    return facets;
}

// Resolve a Tweetbot numeric status id -> atproto strong ref { uri, cid, rootUri, rootCid }.
static NSDictionary *resolvePostRef(NSString *statusId) {
    if (!statusId) return nil;
    @synchronized ([NSMutableDictionary class]) { return gPostRegistry[statusId]; }
}

#pragma mark - Shapes (atproto -> Twitter JSON)

// Stable 53-bit id derived from a DID/URI (Tweetbot wants numeric-ish ids).
static NSString *stableId(NSString *key) {
    unsigned long long h = 0;
    const unsigned long long M = 9007199254740881ULL;
    for (NSUInteger i = 0; i < key.length; ) {
        UTF32Char cp = [key characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(cp) && i + 1 < key.length) {
            cp = CFStringGetLongCharacterForSurrogatePair(cp, [key characterAtIndex:i + 1]); i += 2;
        } else i += 1;
        h = (h * 131 + (unsigned long long)cp) % M;
    }
    return [NSString stringWithFormat:@"%llu", h];
}

// Reverse registry: Tweetbot addresses users by the numeric id / handle we hand out;
// atproto needs a DID or handle. Record both so users/show & user_timeline map back.
static NSMutableDictionary<NSString *, NSString *> *gActorRegistry = nil;
static void registerActor(NSString *did, NSString *handle) {
    if (!gActorRegistry) gActorRegistry = [NSMutableDictionary dictionary];
    if (did.length) { gActorRegistry[stableId(did)] = did; gActorRegistry[did] = did; }
    if (handle.length) gActorRegistry[handle.lowercaseString] = did ?: handle;
}
static NSString *resolveActor(NSString *param, NSString *fallbackDid) {
    if (!param.length) return fallbackDid;
    NSString *hit = gActorRegistry[param] ?: gActorRegistry[param.lowercaseString];
    if (hit) return hit;
    BOOL allDigits = [param rangeOfCharacterFromSet:[NSCharacterSet.decimalDigitCharacterSet invertedSet]].location == NSNotFound;
    if (!allDigits && [param containsString:@"."]) return param; // already a handle
    if (allDigits) return fallbackDid;                            // unknown numeric -> self
    return param;
}

// Post registry: Tweetbot acts on a post by the numeric id we handed out, so record
// stableId(uri) -> { uri, cid, rootUri, rootCid } whenever we serialize a post, so
// like/repost/reply/delete can recover the atproto strong-ref.
static NSMutableDictionary<NSString *, NSDictionary *> *gPostRegistry = nil;
static void registerPost(NSDictionary *post) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPostRegistry = [NSMutableDictionary dictionary]; });
    NSString *uri = post[@"uri"]; if (!uri.length) return;
    NSDictionary *replyRoot = post[@"record"][@"reply"][@"root"];
    // locked: redirect.m reads this from the main thread (bridge_post_web_url)
    @synchronized ([NSMutableDictionary class]) {
        gPostRegistry[stableId(uri)] = @{
            @"uri": uri, @"cid": post[@"cid"] ?: @"",
            @"rootUri": replyRoot[@"uri"] ?: uri, @"rootCid": replyRoot[@"cid"] ?: (post[@"cid"] ?: @""),
        };
    }
}

static NSString *twitterDate(NSString *iso) {
    static NSDateFormatter *in; static NSDateFormatter *out; static dispatch_once_t once;
    dispatch_once(&once, ^{
        in = [NSDateFormatter new]; in.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        in.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"; in.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        out = [NSDateFormatter new]; out.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        out.dateFormat = @"EEE MMM dd HH:mm:ss '+0000' yyyy"; out.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    });
    NSDate *d = iso ? [in dateFromString:iso] : nil;
    if (!d && iso) { in.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ"; d = [in dateFromString:iso]; in.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"; }
    return [out stringFromDate:d ?: [NSDate date]];
}

static NSNumber *numId(NSString *s) { return @(strtoull(s.UTF8String, NULL, 10)); }

static NSDictionary *userFromProfile(NSDictionary *p) {
    if (![p isKindOfClass:NSDictionary.class]) return (id)NSNull.null;
    NSString *did = p[@"did"] ?: @"";
    NSString *handle = p[@"handle"] ?: @"";
    registerActor(did, handle);
    NSString *id_ = stableId(did);
    NSString *avatar = p[@"avatar"] ?: @"";
    return @{
        @"id_str": id_, @"id": numId(id_),
        @"screen_name": handle,
        @"name": p[@"displayName"] ?: handle,
        @"description": p[@"description"] ?: @"",
        @"location": @"", @"url": NSNull.null, @"protected": @NO, @"verified": @NO,
        @"followers_count": p[@"followersCount"] ?: @0,
        @"friends_count": p[@"followsCount"] ?: @0,
        @"statuses_count": p[@"postsCount"] ?: @0,
        @"favourites_count": @0, @"listed_count": @0,
        @"created_at": twitterDate(p[@"createdAt"]),
        @"profile_image_url_https": avatar, @"profile_image_url": avatar,
        @"profile_banner_url": p[@"banner"] ?: @"",
        @"following": @([p[@"viewer"][@"following"] isKindOfClass:NSString.class]),
        @"follow_request_sent": @NO,
    };
}

// UTF-8 byte offset (atproto facet index) -> UTF-16 index (NSString/Tweetbot).
static NSUInteger byteToChar(NSString *text, NSUInteger byteOffset) {
    if (byteOffset == 0) return 0;
    NSUInteger bytes = 0; __block NSUInteger result = text.length;
    __block NSUInteger acc = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *sub, NSRange r, NSRange e, BOOL *stop) {
        if (acc >= byteOffset) { result = r.location; *stop = YES; return; }
        acc += [sub lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (acc >= byteOffset) { result = NSMaxRange(r); *stop = YES; }
    }];
    (void)bytes;
    return result;
}

static NSString *prettyUrl(NSString *uri) {
    NSString *s = uri ?: @"";
    for (NSString *pre in @[@"https://", @"http://"]) if ([s.lowercaseString hasPrefix:pre]) { s = [s substringFromIndex:pre.length]; break; }
    if ([s.lowercaseString hasPrefix:@"www."]) s = [s substringFromIndex:4];
    if ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    if (s.length > 30) s = [[s substringToIndex:27] stringByAppendingString:@"…"];
    return s;
}

// Render an atproto post record into Twitter text + entities with real `indices`,
// a `display_text_range` that hides the synthetic trailing media URL, and media.
static NSDictionary *renderPost(NSDictionary *rec, NSDictionary *post) {
    NSString *text = rec[@"text"] ?: @"";
    NSMutableArray *urls = [NSMutableArray array], *hashtags = [NSMutableArray array],
                   *mentions = [NSMutableArray array], *media = [NSMutableArray array];

    for (NSDictionary *f in (rec[@"facets"] ?: @[])) {
        NSDictionary *index = f[@"index"];
        NSUInteger cs = byteToChar(text, [index[@"byteStart"] unsignedIntegerValue]);
        NSUInteger ce = byteToChar(text, [index[@"byteEnd"] unsignedIntegerValue]);
        if (ce > text.length) ce = text.length; if (cs > ce) cs = ce;
        NSString *slice = [text substringWithRange:NSMakeRange(cs, ce - cs)];
        NSArray *idx = @[@(cs), @(ce)];
        for (NSDictionary *feat in (f[@"features"] ?: @[])) {
            NSString *t = feat[@"$type"];
            if ([t isEqual:@"app.bsky.richtext.facet#link"]) {
                NSString *uri = feat[@"uri"] ?: @"";
                [urls addObject:[@{ @"url": uri, @"expanded_url": uri, @"display_url": prettyUrl(uri), @"indices": idx } mutableCopy]];
            } else if ([t isEqual:@"app.bsky.richtext.facet#tag"]) {
                [hashtags addObject:@{ @"text": feat[@"tag"] ?: @"", @"indices": idx }];
            } else if ([t isEqual:@"app.bsky.richtext.facet#mention"]) {
                NSString *handle = [slice hasPrefix:@"@"] ? [slice substringFromIndex:1] : slice;
                NSString *mid = stableId(feat[@"did"] ?: @"");
                registerActor(feat[@"did"], handle);
                [mentions addObject:@{ @"screen_name": handle, @"name": handle, @"id_str": mid, @"id": numId(mid), @"indices": idx }];
            }
        }
    }

    NSMutableString *full = [text mutableCopy];
    NSUInteger displayEnd = full.length;

    NSDictionary *embed = post[@"embed"];
    NSArray *imgs = embed[@"images"] ?: embed[@"media"][@"images"];
    if ([imgs isKindOfClass:NSArray.class] && imgs.count) {
        NSString *tco = [@"https://t.co/" stringByAppendingString:[stableId(post[@"uri"]) substringToIndex:MIN(10, stableId(post[@"uri"]).length)]];
        NSUInteger start = full.length + 1;
        [full appendFormat:@" %@", tco];
        NSUInteger end = full.length;
        [imgs enumerateObjectsUsingBlock:^(NSDictionary *im, NSUInteger i, BOOL *stop) {
            NSString *src = im[@"fullsize"] ?: im[@"thumb"] ?: @"";
            NSDictionary *ar = im[@"aspectRatio"] ?: @{};
            NSNumber *w = ar[@"width"] ?: @1200, *h = ar[@"height"] ?: @900;
            NSString *mid = stableId([NSString stringWithFormat:@"%@#img%lu", post[@"uri"], (unsigned long)i]);
            [media addObject:@{
                @"id_str": mid, @"id": numId(mid), @"type": @"photo",
                @"media_url": src, @"media_url_https": src, @"url": tco,
                @"display_url": [@"pic.bsky.app/" stringByAppendingString:[stableId(post[@"uri"]) substringToIndex:MIN(6, stableId(post[@"uri"]).length)]],
                @"expanded_url": src, @"indices": @[@(start), @(end)],
                @"sizes": @{ @"large": @{@"w": w, @"h": h, @"resize": @"fit"},
                             @"medium": @{@"w": w, @"h": h, @"resize": @"fit"},
                             @"small": @{@"w": @680, @"h": @510, @"resize": @"fit"},
                             @"thumb": @{@"w": @150, @"h": @150, @"resize": @"crop"} },
                @"ext_alt_text": im[@"alt"] ?: NSNull.null,
            }];
        }];
    }

    NSDictionary *ext = embed[@"external"] ?: embed[@"media"][@"external"];
    if ([ext[@"uri"] isKindOfClass:NSString.class]) {
        BOOL already = NO; for (NSDictionary *u in urls) if ([u[@"expanded_url"] isEqual:ext[@"uri"]]) { already = YES; break; }
        if (!already) {
            NSUInteger start = full.length + 1;
            [full appendFormat:@" %@", prettyUrl(ext[@"uri"])];
            [urls addObject:@{ @"url": ext[@"uri"], @"expanded_url": ext[@"uri"], @"display_url": prettyUrl(ext[@"uri"]), @"indices": @[@(start), @(full.length)] }];
        }
    }

    NSMutableDictionary *entities = [@{ @"hashtags": hashtags, @"urls": urls, @"user_mentions": mentions, @"symbols": @[] } mutableCopy];
    if (media.count) entities[@"media"] = media;
    NSMutableDictionary *out = [@{ @"full_text": full, @"display_text_range": @[@0, @(displayEnd)], @"entities": entities } mutableCopy];
    if (media.count) out[@"extended_entities"] = @{ @"media": media };
    return out;
}

static NSDictionary *statusFromFeedItem(NSDictionary *item) {
    NSDictionary *post = item[@"post"] ?: item;
    NSDictionary *rec = post[@"record"] ?: @{};
    registerPost(post);
    NSString *id_ = stableId(post[@"uri"]);
    NSDictionary *rendered = renderPost(rec, post);
    NSMutableDictionary *status = [@{
        @"id_str": id_, @"id": numId(id_),
        @"full_text": rendered[@"full_text"], @"text": rendered[@"full_text"],
        @"display_text_range": rendered[@"display_text_range"],
        @"truncated": @NO,
        @"created_at": twitterDate(rec[@"createdAt"] ?: post[@"indexedAt"]),
        @"user": userFromProfile(post[@"author"]),
        @"retweet_count": post[@"repostCount"] ?: @0,
        @"favorite_count": post[@"likeCount"] ?: @0,
        @"reply_count": post[@"replyCount"] ?: @0,
        @"favorited": @([post[@"viewer"][@"like"] isKindOfClass:NSString.class]),
        @"retweeted": @([post[@"viewer"][@"repost"] isKindOfClass:NSString.class]),
        @"lang": [rec[@"langs"] isKindOfClass:NSArray.class] && [rec[@"langs"] count] ? rec[@"langs"][0] : @"en",
        @"source": @"<a href=\"https://bsky.app\" rel=\"nofollow\">Bluesky</a>",
        @"in_reply_to_status_id_str": NSNull.null, @"in_reply_to_screen_name": NSNull.null,
        @"entities": rendered[@"entities"],
        @"_atproto_uri": post[@"uri"] ?: @"", @"_atproto_cid": post[@"cid"] ?: @"",
    } mutableCopy];
    if (rendered[@"extended_entities"]) status[@"extended_entities"] = rendered[@"extended_entities"];

    NSDictionary *reason = item[@"reason"];
    if ([reason[@"$type"] isEqual:@"app.bsky.feed.defs#reasonRepost"]) {
        NSDictionary *by = userFromProfile(reason[@"by"]);
        NSString *sn = [status[@"user"] isKindOfClass:NSDictionary.class] ? status[@"user"][@"screen_name"] : @"";
        NSString *rtText = [NSString stringWithFormat:@"RT @%@: %@", sn, rendered[@"full_text"]];
        NSString *rtId = stableId([NSString stringWithFormat:@"%@#rt:%@", post[@"uri"], reason[@"by"][@"did"] ?: @""]);
        return @{
            @"id_str": rtId, @"id": numId(rtId),
            @"created_at": twitterDate(reason[@"indexedAt"]),
            @"user": by, @"text": rtText, @"full_text": rtText,
            @"display_text_range": @[@0, @(rtText.length)],
            @"retweeted_status": status,
            @"retweet_count": status[@"retweet_count"], @"favorite_count": status[@"favorite_count"],
            @"entities": @{ @"hashtags": @[], @"urls": @[], @"user_mentions": @[], @"symbols": @[] },
        };
    }
    return status;
}

static NSInteger clampCount(NSString *c) {
    NSInteger n = c ? c.integerValue : 40; if (n <= 0) n = 40;
    return MAX(1, MIN(100, n));
}

static NSArray *mapFeed(id feed) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in ([feed isKindOfClass:NSArray.class] ? feed : @[])) [out addObject:statusFromFeedItem(it)];
    return out;
}

#pragma mark - Lists (Bluesky saved feeds + lists -> Twitter lists)

// Tweetbot's timeline title is a dropdown of the account's Twitter lists. We fill it
// with the user's saved Bluesky feeds (feed generators: Discover, Mutuals, ...) and
// saved lists, in the same order as the tabs in the Bluesky app (pinned first).
// Registry: Twitter list id -> { uri, kind: "feed"|"list", json: <twitter list> }.
static NSMutableDictionary<NSString *, NSDictionary *> *gListRegistry = nil;

static NSString *atUriRkey(NSString *uri) { return uri.lastPathComponent ?: @""; }

// Shape a feed generator view / graph list view as a Twitter list object.
// `owner` is the Twitter user the list is attributed to: Tweetbot's title-menu only
// shows lists the account OWNS (-[PTHTweetbotList isFromCurrentUser]: list.user.id ==
// account tid), so the caller passes the signed-in user, not the feed's creator.
static NSDictionary *twitterList(NSDictionary *view, NSString *kind, NSString *name, NSDictionary *ownerUser) {
    NSString *uri = view[@"uri"] ?: @"";
    NSString *id_ = stableId(uri);
    NSDictionary *creator = view[@"creator"];
    NSString *owner = [creator isKindOfClass:NSDictionary.class] ? (creator[@"handle"] ?: @"") : @"";
    NSString *slug = atUriRkey(uri);
    NSDictionary *json = @{
        @"id_str": id_, @"id": numId(id_),
        @"name": name, @"slug": slug,
        @"full_name": [NSString stringWithFormat:@"@%@/%@", owner, slug],
        @"uri": [NSString stringWithFormat:@"/%@/lists/%@", owner, slug],
        @"description": view[@"description"] ?: @"",
        @"mode": @"public", @"following": @YES,
        @"member_count": view[@"listItemCount"] ?: @0,
        @"subscriber_count": view[@"likeCount"] ?: @0,
        @"created_at": twitterDate(view[@"indexedAt"]),
        @"user": ownerUser ?: userFromProfile(creator),
        @"_atproto_uri": uri, @"_atproto_kind": kind,
    };
    @synchronized ([NSJSONSerialization class]) {
        if (!gListRegistry) gListRegistry = [NSMutableDictionary dictionary];
        gListRegistry[id_] = @{ @"uri": uri, @"kind": kind, @"json": json };
    }
    return json;
}

// The user's saved feeds + lists as Twitter lists (pinned first, app order).
static NSString *listViewName(NSDictionary *view) {
    return [(view[@"displayName"] ?: view[@"name"] ?: atUriRkey(view[@"uri"]))
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// `accountId` is the numeric id Tweetbot knows the account by (it sends it as
// user_id); the lists are attributed to that user so they count as owned.
static NSArray *loadLists(NSString *accountId, NSString **errOut) {
    // Preferences live on the PDS itself (no AppView proxy).
    id prefs = atpCall(@"GET", @"app.bsky.actor.getPreferences", nil, nil, errOut);
    if (![prefs isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray<NSDictionary *> *saved = [NSMutableArray array]; // { type, value, pinned }
    NSDictionary *v1 = nil;
    for (NSDictionary *p in (prefs[@"preferences"] ?: @[])) {
        NSString *t = jsonString(p, @"$type");
        if ([t isEqual:@"app.bsky.actor.defs#savedFeedsPrefV2"]) {
            for (NSDictionary *it in (p[@"items"] ?: @[])) if ([it isKindOfClass:NSDictionary.class]) [saved addObject:it];
        } else if ([t isEqual:@"app.bsky.actor.defs#savedFeedsPref"]) v1 = p;
    }
    if (!saved.count && v1) { // legacy pref: plain uri arrays
        NSArray *pinned = v1[@"pinned"] ?: @[];
        for (NSString *u in pinned) [saved addObject:@{ @"value": u, @"pinned": @YES }];
        for (NSString *u in (v1[@"saved"] ?: @[])) if (![pinned containsObject:u]) [saved addObject:@{ @"value": u, @"pinned": @NO }];
    }

    // Order: pinned (tab order) then the rest. "timeline"/following is the home timeline — skip.
    NSMutableArray<NSDictionary *> *ordered = [NSMutableArray array];
    for (int pass = 0; pass < 2; pass++) for (NSDictionary *it in saved) {
        if ([it[@"pinned"] boolValue] != (pass == 0)) continue;
        NSString *value = jsonString(it, @"value");
        if (![value hasPrefix:@"at://"]) continue;
        NSString *kind = [value containsString:@"/app.bsky.graph.list/"] ? @"list" : @"feed";
        [ordered addObject:@{ @"uri": value, @"kind": kind }];
    }

    // Hydrate feed generators in one call; lists one by one (there are rarely many).
    NSMutableArray *feedUris = [NSMutableArray array];
    for (NSDictionary *o in ordered) if ([o[@"kind"] isEqual:@"feed"]) [feedUris addObject:o[@"uri"]];
    NSMutableDictionary *views = [NSMutableDictionary dictionary];
    if (feedUris.count) {
        id r = atpView(@"app.bsky.feed.getFeedGenerators", @{ @"feeds": feedUris }, errOut);
        for (NSDictionary *f in ([r isKindOfClass:NSDictionary.class] ? r[@"feeds"] : @[])) if (jsonString(f, @"uri")) views[f[@"uri"]] = f;
    }
    NSMutableArray<NSArray *> *found = [NSMutableArray array]; // [view, kind]
    NSCountedSet *names = [NSCountedSet set];
    for (NSDictionary *o in ordered) {
        NSDictionary *view = views[o[@"uri"]];
        if (!view && [o[@"kind"] isEqual:@"list"]) {
            id r = atpView(@"app.bsky.graph.getList", @{ @"list": o[@"uri"], @"limit": @1 }, NULL);
            view = [r isKindOfClass:NSDictionary.class] ? r[@"list"] : nil;
        }
        if (![view isKindOfClass:NSDictionary.class]) continue; // deleted feeds drop out
        [found addObject:@[view, o[@"kind"]]]; [names addObject:listViewName(view)];
    }

    // Owner = the signed-in user, under the id Tweetbot uses for the account.
    NSMutableDictionary *owner = nil;
    id me = atpView(@"app.bsky.actor.getProfile", @{ @"actor": gDID ?: @"" }, NULL);
    if ([me isKindOfClass:NSDictionary.class]) {
        owner = [userFromProfile(me) mutableCopy];
        if (accountId.length) { owner[@"id_str"] = accountId; owner[@"id"] = numId(accountId); }
    }

    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *f in found) {
        NSDictionary *view = f[0];
        NSString *name = listViewName(view);
        // Two saved feeds can share a name (e.g. two "Mutuals") — tell them apart by creator.
        if ([names countForObject:name] > 1 && jsonString(view[@"creator"], @"handle"))
            name = [NSString stringWithFormat:@"%@ (%@)", name, view[@"creator"][@"handle"]];
        [out addObject:twitterList(view, f[1], name, owner)];
    }
    return out;
}

// Twitter list id (or slug) -> registry entry. Tweetbot remembers the selected list
// across launches, so a miss reloads the saved feeds before giving up.
static NSDictionary *resolveList(NSDictionary *query) {
    NSString *lid = query[@"list_id"] ?: query[@"id"];
    NSString *slug = query[@"slug"];
    for (int attempt = 0; attempt < 2; attempt++) {
        @synchronized ([NSJSONSerialization class]) {
            NSDictionary *hit = lid.length ? gListRegistry[lid] : nil;
            if (hit) return hit;
            if (slug.length) for (NSDictionary *e in gListRegistry.allValues) if ([e[@"json"][@"slug"] isEqual:slug]) return e;
        }
        if (attempt == 0) loadLists(query[@"user_id"], NULL);
    }
    return nil;
}

#pragma mark - OAuth state

static NSString *gLastOAuthUuid = nil; // echoed into the callback URL (see redirect.m)

static NSString *selfUserId(void) { return stableId(gDID ?: @"did:bridge"); }

// Exposed for redirect.m: the atbot:// callback for the current in-flight auth, so the
// authorize step can be completed in-app instead of via the external browser.
NSString *bridge_oauth_callback_url(void) {
    if (!gLastOAuthUuid.length) return nil;
    return [NSString stringWithFormat:@"atbot:///request_token?oauth_token=bridge-req-token&oauth_verifier=bridgeverifier&uuid=%@", gLastOAuthUuid];
}

// Exposed for redirect.m: the bsky.app permalink for a status id we handed out
// (stableId(at-uri)), replacing Tweetbot's https://twitter.com/<name>/status/<id>.
// at://<did>/app.bsky.feed.post/<rkey> -> https://bsky.app/profile/<actor>/post/<rkey>.
// Prefers the readable handle; falls back to the DID (always valid) when no handle
// is known, and to the profile page when the post isn't in the registry.
NSString *bridge_post_web_url(NSString *statusId, NSString *handle) {
    NSDictionary *ref = resolvePostRef(statusId);
    NSArray<NSString *> *parts = [ref[@"uri"] hasPrefix:@"at://"] ? [[ref[@"uri"] substringFromIndex:5] componentsSeparatedByString:@"/"] : nil;
    if (parts.count < 3) return handle.length ? bridge_profile_web_url(handle) : nil;
    NSString *actor = handle.length ? handle : parts[0];
    return [NSString stringWithFormat:@"https://bsky.app/profile/%@/post/%@", actor, parts[2]];
}

NSString *bridge_profile_web_url(NSString *handle) {
    return [@"https://bsky.app/profile/" stringByAppendingString:handle ?: @""];
}

// Build the JSON an OAuth proxy call expects.
static NSData *oauthTokenJSON(BOOL access) {
    NSString *uid = selfUserId();
    NSString *tok = access ? @"bridge-access-token" : @"bridge-req-token";
    NSString *sec = access ? @"bridge-access-secret" : @"bridge-req-secret";
    NSDictionary *j = @{
        @"token": tok, @"secret": sec, @"oauth_token": tok, @"oauth_token_secret": sec,
        @"screen_name": gSessionHandle ?: gHandle ?: @"bridge.local",
        @"username": gSessionHandle ?: gHandle ?: @"bridge.local",
        @"user_id": uid, @"id": uid, @"id_str": uid,
        @"name": @"",
    };
    return [NSJSONSerialization dataWithJSONObject:j options:0 error:NULL];
}

#pragma mark - Router

typedef struct { int status; NSString *contentType; NSData *body; } BridgeResp;

static BridgeResp jsonResp(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL] ?: [NSData data];
    return (BridgeResp){ 200, @"application/json", d };
}
static BridgeResp rawResp(NSString *body, NSString *ct) { return (BridgeResp){ 200, ct, [body dataUsingEncoding:NSUTF8StringEncoding] }; }
static BridgeResp errResp(NSString *msg) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{ @"errors": @[@{ @"code": @131, @"message": msg ?: @"error" }] } options:0 error:NULL];
    return (BridgeResp){ 500, @"application/json", d };
}

// Parse multipart form-data field values we care about (uuid) without the receipt blob.
static NSString *multipartField(NSData *body, NSString *name) {
    if (!body.length) return nil;
    NSString *s = [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding];
    NSString *needle = [NSString stringWithFormat:@"name=\"%@\"", name];
    NSRange n = [s rangeOfString:needle];
    if (n.location == NSNotFound) return nil;
    NSRange sep = [s rangeOfString:@"\r\n\r\n" options:0 range:NSMakeRange(NSMaxRange(n), s.length - NSMaxRange(n))];
    if (sep.location == NSNotFound) return nil;
    NSUInteger vstart = NSMaxRange(sep);
    NSRange end = [s rangeOfString:@"\r\n--" options:0 range:NSMakeRange(vstart, s.length - vstart)];
    NSUInteger vend = end.location == NSNotFound ? s.length : end.location;
    return [s substringWithRange:NSMakeRange(vstart, vend - vstart)];
}

// Parse application/x-www-form-urlencoded (Twitter POST params often live in the body).
static NSDictionary *parseForm(NSData *body) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!body.length) return out;
    NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if ([s containsString:@"Content-Disposition"]) return out; // multipart, not form
    for (NSString *pair in [s componentsSeparatedByString:@"&"]) {
        NSArray *kv = [pair componentsSeparatedByString:@"="];
        if (!kv.count || ![kv[0] length]) continue;
        NSString *v = kv.count > 1 ? [[kv subarrayWithRange:NSMakeRange(1, kv.count - 1)] componentsJoinedByString:@"="] : @"";
        v = [v stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        out[kv[0]] = [v stringByRemovingPercentEncoding] ?: v;
    }
    return out;
}

// Build a fresh Twitter status for an atproto uri (echoed back after writes).
static id statusForUri(NSString *uri) {
    NSString *err = nil; NSDictionary *post = atpGetPost(uri, &err);
    return post ? statusFromFeedItem(@{ @"post": post }) : @{};
}
// Optimistically overlay a flag + bump a count on an echoed status (the AppView lags
// a re-fetch, so a freshly liked/reposted post would otherwise echo back un-flagged).
static id statusWithFlag(id status, NSString *flag, BOOL on, NSString *countKey) {
    if (![status isKindOfClass:NSDictionary.class]) return status;
    NSMutableDictionary *m = [status mutableCopy];
    m[flag] = @(on);
    NSInteger c = [m[countKey] integerValue] + (on ? 1 : -1);
    m[countKey] = @(MAX(0, c));
    return m;
}

// Synthesize a Twitter status for a just-created post without waiting for the AppView
// to index it (so a composed skeet shows in Tweetbot immediately). Fills our own author
// profile from getProfile (self).
static id synthStatus(NSString *uri, NSString *cid, NSDictionary *record) {
    NSDictionary *me = atpView(@"app.bsky.actor.getProfile", @{ @"actor": gDID ?: @"" }, NULL);
    NSDictionary *post = @{
        @"uri": uri ?: @"", @"cid": cid ?: @"", @"record": record ?: @{},
        @"author": [me isKindOfClass:NSDictionary.class] ? me : @{ @"did": gDID ?: @"", @"handle": gSessionHandle ?: @"" },
        @"replyCount": @0, @"repostCount": @0, @"likeCount": @0, @"indexedAt": record[@"createdAt"] ?: nowISO(),
    };
    return statusFromFeedItem(@{ @"post": post });
}

static BridgeResp routeRequest(NSString *method, NSString *path, NSDictionary *query, NSData *body) {
    BOOL proxy = [path containsString:@"/tweetbot/"];
    // Merge form-encoded POST params into the query dict so handlers see them uniformly.
    if ([method isEqual:@"POST"] && body.length) {
        NSDictionary *form = parseForm(body);
        if (form.count) { NSMutableDictionary *m = [query mutableCopy]; [m addEntriesFromDictionary:form]; query = m; }
    }

    // ---- writes (post / like / repost / follow / delete) ----
    if ([method isEqual:@"POST"] && [path containsString:@"/statuses/update"]) {
        NSString *text = query[@"status"] ?: @"";
        NSMutableDictionary *rec = [@{ @"$type": @"app.bsky.feed.post", @"text": text, @"createdAt": nowISO() } mutableCopy];
        NSArray *facets = buildFacets(text); if (facets.count) rec[@"facets"] = facets;
        NSDictionary *parent = resolvePostRef(query[@"in_reply_to_status_id"] ?: query[@"in_reply_to_status_id_str"]);
        if (parent) rec[@"reply"] = @{ @"parent": @{ @"uri": parent[@"uri"], @"cid": parent[@"cid"] },
                                       @"root": @{ @"uri": parent[@"rootUri"], @"cid": parent[@"rootCid"] } };
        NSString *err = nil; NSDictionary *created = atpCreateRecord(@"app.bsky.feed.post", rec, &err);
        if (!created) return errResp(err);
        return jsonResp(synthStatus(created[@"uri"], created[@"cid"], rec));
    }
    if ([method isEqual:@"POST"] && [path containsString:@"/favorites/create"]) {
        NSDictionary *ref = resolvePostRef(query[@"id"] ?: query[@"id_str"]);
        if (!ref) return errResp(@"unknown status");
        NSString *err = nil;
        atpCreateRecord(@"app.bsky.feed.like", @{ @"$type": @"app.bsky.feed.like", @"subject": @{ @"uri": ref[@"uri"], @"cid": ref[@"cid"] }, @"createdAt": nowISO() }, &err);
        if (err) return errResp(err);
        return jsonResp(statusWithFlag(statusForUri(ref[@"uri"]), @"favorited", YES, @"favorite_count"));
    }
    if ([method isEqual:@"POST"] && [path containsString:@"/favorites/destroy"]) {
        NSDictionary *ref = resolvePostRef(query[@"id"] ?: query[@"id_str"]);
        NSString *err = nil; NSDictionary *post = ref ? atpGetPost(ref[@"uri"], &err) : nil;
        NSString *likeUri = post[@"viewer"][@"like"];
        if (likeUri) atpDeleteAtUri(likeUri, &err);
        return jsonResp(ref ? statusForUri(ref[@"uri"]) : @{});
    }
    if ([method isEqual:@"POST"] && [path containsString:@"/statuses/retweet/"]) {
        NSString *sid = [[path.lastPathComponent stringByDeletingPathExtension] copy];
        NSDictionary *ref = resolvePostRef(sid);
        if (!ref) return errResp(@"unknown status");
        NSString *err = nil;
        atpCreateRecord(@"app.bsky.feed.repost", @{ @"$type": @"app.bsky.feed.repost", @"subject": @{ @"uri": ref[@"uri"], @"cid": ref[@"cid"] }, @"createdAt": nowISO() }, &err);
        if (err) return errResp(err);
        return jsonResp(statusWithFlag(statusForUri(ref[@"uri"]), @"retweeted", YES, @"retweet_count"));
    }
    if ([method isEqual:@"POST"] && ([path containsString:@"/statuses/unretweet/"] || [path containsString:@"/statuses/destroy/"])) {
        NSString *sid = [[path.lastPathComponent stringByDeletingPathExtension] copy];
        NSDictionary *ref = resolvePostRef(sid);
        NSString *err = nil; NSDictionary *post = ref ? atpGetPost(ref[@"uri"], &err) : nil;
        if ([path containsString:@"/destroy/"]) {           // delete my own post
            if (ref) atpDeleteAtUri(ref[@"uri"], &err);
        } else {                                            // remove my repost
            NSString *rpUri = post[@"viewer"][@"repost"];
            if (rpUri) atpDeleteAtUri(rpUri, &err);
        }
        return jsonResp(ref ? (id)statusForUri(ref[@"uri"]) : (id)@{});
    }
    if ([method isEqual:@"POST"] && [path containsString:@"/friendships/create"]) {
        NSString *actor = resolveActor(query[@"screen_name"] ?: query[@"user_id"], nil);
        NSString *err = nil; id prof = actor ? atpView(@"app.bsky.actor.getProfile", @{ @"actor": actor }, &err) : nil;
        NSString *did = jsonString(prof, @"did");
        if (did) atpCreateRecord(@"app.bsky.graph.follow", @{ @"$type": @"app.bsky.graph.follow", @"subject": did, @"createdAt": nowISO() }, &err);
        return jsonResp(prof ? userFromProfile(prof) : @{});
    }
    if ([method isEqual:@"POST"] && [path containsString:@"/friendships/destroy"]) {
        NSString *actor = resolveActor(query[@"screen_name"] ?: query[@"user_id"], nil);
        NSString *err = nil; id prof = actor ? atpView(@"app.bsky.actor.getProfile", @{ @"actor": actor }, &err) : nil;
        NSString *followUri = [prof isKindOfClass:NSDictionary.class] ? prof[@"viewer"][@"following"] : nil;
        if (followUri) atpDeleteAtUri(followUri, &err);
        return jsonResp(prof ? userFromProfile(prof) : @{});
    }

    // ---- OAuth bootstrap ----
    if ([method isEqual:@"POST"] && [path hasSuffix:@"/oauth/request_token"]) {
        NSString *uuid = multipartField(body, @"uuid"); if (uuid) gLastOAuthUuid = uuid;
        tblog(@"[bridge] request_token uuid=%@", gLastOAuthUuid);
        if (proxy) return (BridgeResp){ 200, @"application/json", oauthTokenJSON(NO) };
        return rawResp(@"oauth_token=bridge-req-token&oauth_token_secret=bridge-req-secret&oauth_callback_confirmed=true", @"text/plain");
    }
    if ([method isEqual:@"GET"] && [path hasSuffix:@"/oauth/authorize"]) {
        NSString *token = query[@"oauth_token"] ?: @"bridge-req-token";
        NSString *uuid = query[@"uuid"] ?: gLastOAuthUuid ?: @"";
        NSString *cb = [NSString stringWithFormat:@"atbot:///request_token?oauth_token=%@&oauth_verifier=bridgeverifier&uuid=%@",
                        token, [uuid stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
        tblog(@"[bridge] authorize -> %@", cb);
        NSString *js = [NSString stringWithFormat:@"\"%@\"", [cb stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
        NSString *html = [NSString stringWithFormat:
            @"<!doctype html><meta charset=utf-8><body style=\"font:15px -apple-system;padding:2em\">"
             "<script>location.href=%@</script><h2>Authorizing…</h2>"
             "<p>If nothing happens, <a href=\"%@\">return to atbot</a>.</p></body>", js, cb];
        return rawResp(html, @"text/html");
    }
    if ([method isEqual:@"POST"] && [path hasSuffix:@"/oauth/access_token"]) {
        if (proxy) return (BridgeResp){ 200, @"application/json", oauthTokenJSON(YES) };
        NSString *uid = selfUserId();
        return rawResp([NSString stringWithFormat:@"oauth_token=bridge-access-token&oauth_token_secret=bridge-access-secret&user_id=%@&screen_name=%@",
                        uid, gSessionHandle ?: gHandle ?: @"bridge.local"], @"text/plain");
    }
    // debug: current callback URL (manual delivery when the browser blocks JS redirect)
    if ([method isEqual:@"GET"] && [path hasSuffix:@"/__callback"]) {
        return rawResp([NSString stringWithFormat:@"atbot:///request_token?oauth_token=bridge-req-token&oauth_verifier=bridgeverifier&uuid=%@", gLastOAuthUuid ?: @""], @"text/plain");
    }

    // Everything below reads gDID, so the session must exist first (requests can
    // arrive before the async boot login finishes).
    if (![path containsString:@"/oauth/"]) atpEnsureSession(NULL);

    // ---- account ----
    if ([path containsString:@"/account/verify_credentials"] || [path containsString:@"/account/update_profile"]) {
        NSString *err = nil; id me = atpView(@"app.bsky.actor.getProfile", @{ @"actor": gDID ?: @"" }, &err);
        if (!me) return errResp(err);
        return jsonResp(userFromProfile(me));
    }
    // ---- timelines ----
    if ([path containsString:@"/statuses/home_timeline"]) {
        NSString *err = nil; id r = atpView(@"app.bsky.feed.getTimeline", @{ @"limit": @(clampCount(query[@"count"])) }, &err);
        if (!r) return errResp(err);
        return jsonResp(mapFeed(r[@"feed"]));
    }
    if ([path containsString:@"/statuses/user_timeline"]) {
        NSString *actor = resolveActor(query[@"screen_name"] ?: query[@"user_id"], gDID);
        NSString *err = nil; id r = atpView(@"app.bsky.feed.getAuthorFeed", @{ @"actor": actor ?: @"", @"limit": @(clampCount(query[@"count"])) }, &err);
        if (!r) return errResp(err);
        return jsonResp(mapFeed(r[@"feed"]));
    }
    if ([path containsString:@"/statuses/mentions_timeline"]) {
        NSString *err = nil; id r = atpView(@"app.bsky.notification.listNotifications", @{ @"limit": @(clampCount(query[@"count"])) }, &err);
        if (!r) return errResp(err);
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *n in (r[@"notifications"] ?: @[])) {
            NSString *reason = n[@"reason"];
            if (![reason isEqual:@"mention"] && ![reason isEqual:@"reply"]) continue;
            [out addObject:statusFromFeedItem(@{ @"post": @{ @"record": n[@"record"] ?: @{}, @"author": n[@"author"] ?: @{}, @"uri": n[@"uri"] ?: @"", @"cid": n[@"cid"] ?: @"", @"indexedAt": n[@"indexedAt"] ?: @"" } })];
        }
        return jsonResp(out);
    }
    // ---- lists = Bluesky saved feeds (the timeline title dropdown) ----
    if ([path containsString:@"/lists/list"]) {
        NSString *err = nil; NSArray *lists = loadLists(query[@"user_id"], &err);
        if (!lists) return errResp(err);
        return jsonResp(lists);
    }
    if ([path containsString:@"/lists/statuses"]) {
        NSDictionary *entry = resolveList(query);
        if (!entry) return errResp(@"unknown list");
        BOOL isList = [entry[@"kind"] isEqual:@"list"];
        NSString *err = nil;
        id r = atpView(isList ? @"app.bsky.feed.getListFeed" : @"app.bsky.feed.getFeed",
                       @{ (isList ? @"list" : @"feed"): entry[@"uri"], @"limit": @(clampCount(query[@"count"])) }, &err);
        if (!r) return errResp(err);
        return jsonResp(mapFeed(r[@"feed"]));
    }
    if ([path containsString:@"/lists/show"]) {
        NSDictionary *entry = resolveList(query);
        if (!entry) return errResp(@"unknown list");
        return jsonResp(entry[@"json"]);
    }
    if ([path containsString:@"/lists/members.json"] || [path containsString:@"/lists/subscribers.json"]) {
        NSDictionary *entry = resolveList(query);
        NSMutableArray *users = [NSMutableArray array];
        // Real members only exist for Bluesky lists; feed generators are algorithms.
        if ([entry[@"kind"] isEqual:@"list"] && [path containsString:@"/members"]) {
            id r = atpView(@"app.bsky.graph.getList", @{ @"list": entry[@"uri"], @"limit": @100 }, NULL);
            for (NSDictionary *it in ([r isKindOfClass:NSDictionary.class] ? r[@"items"] : @[])) [users addObject:userFromProfile(it[@"subject"])];
        }
        return jsonResp(@{ @"users": users, @"next_cursor": @0, @"next_cursor_str": @"0", @"previous_cursor": @0, @"previous_cursor_str": @"0" });
    }

    // ---- user lookup ----
    if ([path containsString:@"/users/show"]) {
        NSString *actor = resolveActor(query[@"screen_name"] ?: query[@"user_id"], gDID);
        NSString *err = nil; id me = atpView(@"app.bsky.actor.getProfile", @{ @"actor": actor ?: @"" }, &err);
        if (!me) return errResp(err);
        return jsonResp(userFromProfile(me));
    }

    // Unknown: degrade gracefully (empty list or object) so Tweetbot doesn't choke.
    tblog(@"[bridge] UNHANDLED %@ %@", method, path);
    BOOL listish = [path containsString:@"timeline"] || [path hasSuffix:@"list.json"];
    return rawResp(listish ? @"[]" : @"{}", @"application/json");
}

#pragma mark - Embedded HTTP server

static void writeAll(int fd, const void *buf, size_t len) {
    const char *p = buf; size_t off = 0;
    while (off < len) { ssize_t n = write(fd, p + off, len - off); if (n <= 0) break; off += (size_t)n; }
}

static void handleConnection(int fd) {
    @autoreleasepool {
        NSMutableData *buf = [NSMutableData data];
        char tmp[8192];
        NSInteger headerEnd = -1, contentLength = 0;
        // read until we have headers
        while (headerEnd < 0) {
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n <= 0) { close(fd); return; }
            [buf appendBytes:tmp length:(NSUInteger)n];
            NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            NSRange r = [buf rangeOfData:sep options:0 range:NSMakeRange(0, buf.length)];
            if (r.location != NSNotFound) headerEnd = (NSInteger)NSMaxRange(r);
            if (buf.length > 1 << 20 && headerEnd < 0) { close(fd); return; }
        }
        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, (NSUInteger)headerEnd)] encoding:NSISOLatin1StringEncoding];
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *reqline = [lines.firstObject componentsSeparatedByString:@" "];
        if (reqline.count < 2) { close(fd); return; }
        NSString *httpMethod = reqline[0];
        NSString *target = reqline[1];
        for (NSString *line in lines) {
            NSRange c = [line rangeOfString:@":"];
            if (c.location == NSNotFound) continue;
            NSString *k = [[line substringToIndex:c.location] lowercaseString];
            if ([k isEqual:@"content-length"]) contentLength = [[line substringFromIndex:c.location + 1] integerValue];
        }
        // read remaining body
        NSUInteger have = buf.length - (NSUInteger)headerEnd;
        while ((NSInteger)have < contentLength) {
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n <= 0) break;
            [buf appendBytes:tmp length:(NSUInteger)n]; have += (NSUInteger)n;
        }
        NSData *body = contentLength > 0 ? [buf subdataWithRange:NSMakeRange((NSUInteger)headerEnd, MIN((NSUInteger)contentLength, buf.length - (NSUInteger)headerEnd))] : nil;

        // split path / query
        NSString *path = target; NSMutableDictionary *query = [NSMutableDictionary dictionary];
        NSRange q = [target rangeOfString:@"?"];
        if (q.location != NSNotFound) {
            path = [target substringToIndex:q.location];
            for (NSString *pair in [[target substringFromIndex:q.location + 1] componentsSeparatedByString:@"&"]) {
                NSArray *kv = [pair componentsSeparatedByString:@"="];
                if (kv.count >= 1 && [kv[0] length]) {
                    NSString *val = kv.count > 1 ? [[kv subarrayWithRange:NSMakeRange(1, kv.count-1)] componentsJoinedByString:@"="] : @"";
                    query[kv[0]] = [val stringByRemovingPercentEncoding] ?: val;
                }
            }
        }

        BridgeResp resp;
        @try { resp = routeRequest(httpMethod, path, query, body); }
        @catch (id e) { resp = errResp([NSString stringWithFormat:@"%@", e]); }

        NSMutableString *out = [NSMutableString stringWithFormat:
            @"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
            resp.status, resp.status == 200 ? @"OK" : @"Error", resp.contentType ?: @"application/json", (unsigned long)resp.body.length];
        NSData *headData = [out dataUsingEncoding:NSUTF8StringEncoding];
        writeAll(fd, headData.bytes, headData.length);
        if (resp.body.length) writeAll(fd, resp.body.bytes, resp.body.length);
        tblog(@"[bridge] %@ %@ -> %d", httpMethod, path, resp.status);
        close(fd);
    }
}

// Start the loopback server; returns the chosen port (0 on failure). Non-blocking:
// the accept loop runs on a background queue.
int bridge_start(void) {
    loadCredentials();
    // log in up front (best-effort; reads will lazily refresh)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *err = nil; if (!atpEnsureSession(&err)) tblog(@"[bridge] initial login failed: %@", err);
    });

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { tblog(@"[bridge] socket() failed"); return 0; }
    int yes = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); addr.sin_port = 0; // ephemeral
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { tblog(@"[bridge] bind() failed"); close(s); return 0; }
    socklen_t al = sizeof(addr); getsockname(s, (struct sockaddr *)&addr, &al);
    int port = ntohs(addr.sin_port);
    if (listen(s, 32) < 0) { tblog(@"[bridge] listen() failed"); close(s); return 0; }
    tblog(@"[bridge] in-process server on 127.0.0.1:%d", port);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (;;) {
            int c = accept(s, NULL, NULL);
            if (c < 0) { if (errno == EINTR) continue; break; }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ handleConnection(c); });
        }
        close(s);
    });
    return port;
}
