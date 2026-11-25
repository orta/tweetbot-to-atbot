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
static NSString *resolveActor(NSString *param, NSString *fallbackDid);
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
    // URLQueryAllowedCharacterSet keeps & = + # as-is, but they're delimiters inside a
    // value (servers decode '+' as a space): feed cursors like "M0Gv…+…" broke paging.
    static NSCharacterSet *allowed; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *s = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
        [s removeCharactersInString:@"&=+#?"];
        allowed = s;
    });
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

// Hydrate many post uris at once (getPosts caps at 25 per call). uri -> post view.
static NSDictionary<NSString *, NSDictionary *> *atpGetPostsMap(NSArray<NSString *> *uris) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < uris.count; i += 25) {
        NSArray *chunk = [uris subarrayWithRange:NSMakeRange(i, MIN(25, uris.count - i))];
        id r = atpView(@"app.bsky.feed.getPosts", @{ @"uris": chunk }, NULL);
        for (NSDictionary *p in ([r isKindOfClass:NSDictionary.class] ? r[@"posts"] : @[])) if (p[@"uri"]) out[p[@"uri"]] = p;
    }
    return out;
}

// Handle (or DID) -> DID: the actor registry first, else the public resolver. nil if unknown.
static NSString *resolveHandleToDid(NSString *handle) {
    if (!handle.length) return nil;
    if ([handle hasPrefix:@"did:"]) return handle;
    NSString *did = resolveActor(handle, nil);
    if ([did hasPrefix:@"did:"]) return did;
    id r = httpRequestJSON(@"GET", [NSString stringWithFormat:@"https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle%@", qstr(@{ @"handle": handle })], nil, nil, NULL, NULL);
    did = jsonString(r, @"did");
    return did.length ? did : nil;
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
        NSString *did = resolveHandleToDid([text substringWithRange:[m rangeAtIndex:1]]);
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

#pragma mark - Status ids (time-ordered, like Twitter snowflakes)

// Tweetbot orders EVERY timeline by numeric id (-[PTHTweetbotObject compare:] compares
// tids) and pages with since_id/max_id taken from the first/last item, so a status id
// must grow with time exactly like a Twitter snowflake: ((ms - Twitter epoch) << 22) |
// 22 low bits. A hash id (stableId) shuffles the timeline. The time comes from the
// post's rkey — a TID, so the id is a pure function of the at:// uri: a reply's
// in_reply_to_status_id is computable from its parent's uri alone. User, list and media
// ids stay on stableId (nothing orders them).
static const long long kTwitterEpochMs = 1288834974657LL;

static long long nowMs(void) { return (long long)(NSDate.date.timeIntervalSince1970 * 1000.0); }
static BOOL plausibleMs(long long ms) { return ms > kTwitterEpochMs && ms < nowMs() + 86400000LL; }
static unsigned long long keyHash(NSString *key) { return strtoull(stableId(key ?: @"").UTF8String, NULL, 10); }
static long long snowflakeId(long long ms, unsigned long long low) {
    return ((ms - kTwitterEpochMs) << 22) | (long long)(low & 0x3FFFFF);
}

// ms since 1970 encoded in a TID record key (base32-sortable: 53 bits of µs + 10-bit
// clock id); 0 if `rkey` isn't a plausible TID.
static long long tidMs(NSString *rkey) {
    static const char *alphabet = "234567abcdefghijklmnopqrstuvwxyz";
    if (![rkey isKindOfClass:NSString.class] || rkey.length != 13) return 0;
    unsigned long long v = 0;
    for (NSUInteger i = 0; i < 13; i++) {
        unichar c = [rkey characterAtIndex:i];
        const char *p = (c > 0 && c < 128) ? strchr(alphabet, (char)c) : NULL;
        if (!p) return 0;
        v = (v << 5) | (unsigned long long)(p - alphabet);
    }
    long long ms = (long long)((v >> 10) / 1000);
    return plausibleMs(ms) ? ms : 0;
}

// ms since 1970 for an atproto datetime (any fractional precision); 0 if unparseable.
static long long isoMs(NSString *iso) {
    if (![iso isKindOfClass:NSString.class] || !iso.length) return 0;
    static NSISO8601DateFormatter *frac, *plain; static dispatch_once_t once;
    dispatch_once(&once, ^{
        frac = [NSISO8601DateFormatter new];
        frac.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
    });
    NSDate *d = [frac dateFromString:iso] ?: [plain dateFromString:iso];
    if (!d) { // e.g. microsecond precision: drop the fraction
        NSString *s = [iso stringByReplacingOccurrencesOfString:@"\\.[0-9]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, iso.length)];
        d = [plain dateFromString:s];
    }
    long long ms = d ? (long long)(d.timeIntervalSince1970 * 1000.0) : 0;
    return plausibleMs(ms) ? ms : 0;
}

// Status id for a post uri: its rkey TID time, else `iso` (createdAt/indexedAt), else a
// hash (sorts as ancient — only for non-TID rkeys with no date).
static NSString *postIdWithDate(NSString *uri, NSString *iso) {
    uri = [uri isKindOfClass:NSString.class] ? uri : @"";
    long long ms = tidMs(uri.lastPathComponent) ?: isoMs(iso);
    if (!ms) return stableId(uri);
    return [NSString stringWithFormat:@"%lld", snowflakeId(ms, keyHash(uri))];
}
static NSString *postId(NSString *uri) { return postIdWithDate(uri, nil); }
static NSString *postIdForPost(NSDictionary *post) {
    NSDictionary *rec = [post[@"record"] isKindOfClass:NSDictionary.class] ? post[@"record"] : nil;
    return postIdWithDate(post[@"uri"], rec[@"createdAt"] ?: post[@"indexedAt"]);
}
// A repost wrapper sorts by when it was reposted: the repost record's own TID, else
// the reason's indexedAt.
static NSString *repostId(NSDictionary *post, NSDictionary *reason) {
    NSString *rtUri = [reason[@"uri"] isKindOfClass:NSString.class] ? reason[@"uri"] : nil;
    if (tidMs(rtUri.lastPathComponent)) return postId(rtUri);
    NSString *key = [NSString stringWithFormat:@"%@#rt:%@", post[@"uri"], reason[@"by"][@"did"] ?: @""];
    long long ms = isoMs(reason[@"indexedAt"]);
    return ms ? [NSString stringWithFormat:@"%lld", snowflakeId(ms, keyHash(key))] : stableId(key);
}

// Reverse registry: Tweetbot addresses users by the numeric id / handle we hand out;
// atproto needs a DID or handle. Record both so users/show & user_timeline map back.
static NSMutableDictionary<NSString *, NSString *> *gActorRegistry = nil;
// Requests are served concurrently (opening a post fires the reply search and the
// reply-thread timeline at once), so the actor registry needs a lock.
static NSObject *actorLock(void) {
    static NSObject *lock; static dispatch_once_t once; dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static void registerActor(NSString *did, NSString *handle) {
    @synchronized (actorLock()) {
        if (!gActorRegistry) gActorRegistry = [NSMutableDictionary dictionary];
        if (did.length) { gActorRegistry[stableId(did)] = did; gActorRegistry[did] = did; }
        if (handle.length) gActorRegistry[handle.lowercaseString] = did ?: handle;
    }
}
static NSString *resolveActor(NSString *param, NSString *fallbackDid) {
    if (!param.length) return fallbackDid;
    NSString *hit;
    @synchronized (actorLock()) { hit = gActorRegistry[param] ?: gActorRegistry[param.lowercaseString]; }
    if (hit) return hit;
    BOOL allDigits = [param rangeOfCharacterFromSet:[NSCharacterSet.decimalDigitCharacterSet invertedSet]].location == NSNotFound;
    if (!allDigits && [param containsString:@"."]) return param; // already a handle
    if (allDigits) return fallbackDid;                            // unknown numeric -> self
    return param;
}

// Post registry: Tweetbot acts on a post by the numeric id we handed out, so record
// id -> { uri, cid, rootUri, rootCid[, reason] } whenever we serialize a post, so
// like/repost/reply/delete/statuses/show can recover the atproto strong-ref. A post can
// be known under several ids (its postId, a repost wrapper id, a ranked-feed id).
static NSMutableDictionary<NSString *, NSDictionary *> *gPostRegistry = nil;
static void registerPostId(NSString *sid, NSDictionary *post, NSDictionary *reason) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPostRegistry = [NSMutableDictionary dictionary]; });
    NSString *uri = post[@"uri"]; if (![uri isKindOfClass:NSString.class] || !uri.length || !sid.length) return;
    NSDictionary *replyRoot = post[@"record"][@"reply"][@"root"];
    NSMutableDictionary *ref = [@{
        @"uri": uri, @"cid": post[@"cid"] ?: @"",
        @"rootUri": replyRoot[@"uri"] ?: uri, @"rootCid": replyRoot[@"cid"] ?: (post[@"cid"] ?: @""),
    } mutableCopy];
    if (reason) ref[@"reason"] = reason;
    // locked: redirect.m reads this from the main thread (bridge_post_web_url)
    @synchronized ([NSMutableDictionary class]) { gPostRegistry[sid] = ref; }
}
static void registerPost(NSDictionary *post) { registerPostId(postIdForPost(post), post, nil); }

// A repost wrapper's id (repostId) maps to the original post plus the repost reason,
// so statuses/show on a retweet id re-emits the same wrapper.
static void registerRepost(NSString *rtId, NSDictionary *post, NSDictionary *reason) {
    registerPostId(rtId, post, reason);
}

// A reply's parent may never have been serialized itself, but Tweetbot will
// statuses/show it by the in_reply_to_status_id we hand out (the conversation above
// a reply). Record its strong-ref so that id resolves; a full registerPost wins.
static void registerReplyParent(NSDictionary *reply) {
    NSDictionary *parent = reply[@"parent"], *root = reply[@"root"];
    NSString *uri = [parent isKindOfClass:NSDictionary.class] ? parent[@"uri"] : nil;
    if (![uri isKindOfClass:NSString.class] || !uri.length) return;
    if (![root isKindOfClass:NSDictionary.class]) root = parent;
    NSString *pid = postId(uri);
    @synchronized ([NSMutableDictionary class]) {
        if (!gPostRegistry || gPostRegistry[pid]) return;
        gPostRegistry[pid] = @{
            @"uri": uri, @"cid": parent[@"cid"] ?: @"",
            @"rootUri": root[@"uri"] ?: uri, @"rootCid": root[@"cid"] ?: (parent[@"cid"] ?: @""),
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

// Twitter entity `indices` / display_text_range count Unicode CODE POINTS (not UTF-16
// units): Tweetbot converts them itself, so an emoji before an entity shifts it by one
// and can push it past the end of the text (entity dropped -> raw t.co shown, no media).
static NSUInteger cpCount(NSString *s) {
    NSUInteger n = 0, len = s.length;
    for (NSUInteger i = 0; i < len; i++) if (!CFStringIsSurrogateLowCharacter([s characterAtIndex:i])) n++;
    return n;
}
static NSUInteger cpAt(NSString *s, NSUInteger utf16Index) {
    return cpCount([s substringToIndex:MIN(utf16Index, s.length)]);
}

static NSString *prettyUrl(NSString *uri) {
    NSString *s = uri ?: @"";
    for (NSString *pre in @[@"https://", @"http://"]) if ([s.lowercaseString hasPrefix:pre]) { s = [s substringFromIndex:pre.length]; break; }
    if ([s.lowercaseString hasPrefix:@"www."]) s = [s substringFromIndex:4];
    if ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    if (s.length > 30) s = [[s substringToIndex:27] stringByAppendingString:@"…"];
    return s;
}

// Tweetbot never loads media_url_https as-is: +[PTHTweetbotMedium
// twitterMediumURLFromString:sizeName:] rewrites it per size — "x.jpg" -> "x?format=jpg&name=large",
// and an extension-less path -> "x:large". Bluesky CDN paths have no extension, so
// "<cid>:large" 400s and the image cell stays blank. "<cid>@jpeg.jpg" becomes
// "<cid>@jpeg?format=jpg&name=large", which the CDN serves as JPEG (it ignores the query).
// A URL that already has an extension (video thumbnail.jpg) gets it doubled, so the
// rewriter strips only the copy: "thumbnail.jpg.jpg" -> "thumbnail.jpg?format=jpg&...".
static NSString *tweetbotMediaURL(NSString *src) {
    if (!src.length) return @"";
    NSString *ext = src.lastPathComponent.pathExtension;
    if (ext.length) return [src stringByAppendingFormat:@".%@", ext];
    return [src stringByAppendingString:[src hasSuffix:@"@jpeg"] ? @".jpg" : @"@jpeg.jpg"];
}
// Twitter "sizes" entry scaled to fit `box` (keeps the real aspect ratio).
static NSDictionary *fitSize(double w, double h, double box, NSString *resize) {
    double k = MIN(1.0, box / MAX(w, h));
    return @{ @"w": @(lround(w * k)), @"h": @(lround(h * k)), @"resize": resize };
}

// Render an atproto post record into Twitter text + entities with real `indices`,
// a `display_text_range` that hides the synthetic trailing media URL, and media.
// `linkCard`: the post's external embed is shown as a card (see cardStatus), so the
// trailing link isn't appended to the text.
static NSDictionary *renderPost(NSDictionary *rec, NSDictionary *post, BOOL linkCard) {
    NSString *text = rec[@"text"] ?: @"";
    NSMutableArray *urls = [NSMutableArray array], *hashtags = [NSMutableArray array],
                   *mentions = [NSMutableArray array], *media = [NSMutableArray array];

    for (NSDictionary *f in (rec[@"facets"] ?: @[])) {
        NSDictionary *index = f[@"index"];
        NSUInteger cs = byteToChar(text, [index[@"byteStart"] unsignedIntegerValue]);
        NSUInteger ce = byteToChar(text, [index[@"byteEnd"] unsignedIntegerValue]);
        if (ce > text.length) ce = text.length; if (cs > ce) cs = ce;
        NSString *slice = [text substringWithRange:NSMakeRange(cs, ce - cs)];
        NSArray *idx = @[@(cpAt(text, cs)), @(cpAt(text, ce))];
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
    NSUInteger displayEnd = cpCount(full);

    NSDictionary *embed = post[@"embed"];
    NSArray *imgs = embed[@"images"] ?: embed[@"media"][@"images"];
    if ([imgs isKindOfClass:NSArray.class] && imgs.count) {
        NSString *tco = [@"https://t.co/" stringByAppendingString:[stableId(post[@"uri"]) substringToIndex:MIN(10, stableId(post[@"uri"]).length)]];
        NSUInteger start = cpCount(full) + 1;
        [full appendFormat:@" %@", tco];
        NSUInteger end = cpCount(full);
        [imgs enumerateObjectsUsingBlock:^(NSDictionary *im, NSUInteger i, BOOL *stop) {
            NSString *src = im[@"fullsize"] ?: im[@"thumb"] ?: @"";
            NSString *mediaUrl = tweetbotMediaURL(src);
            NSDictionary *ar = im[@"aspectRatio"] ?: @{};
            double w = [ar[@"width"] doubleValue] ?: 1200, h = [ar[@"height"] doubleValue] ?: 900;
            NSString *mid = stableId([NSString stringWithFormat:@"%@#img%lu", post[@"uri"], (unsigned long)i]);
            [media addObject:@{
                @"id_str": mid, @"id": numId(mid), @"type": @"photo",
                @"media_url": mediaUrl, @"media_url_https": mediaUrl, @"url": tco,
                @"display_url": [@"pic.bsky.app/" stringByAppendingString:[stableId(post[@"uri"]) substringToIndex:MIN(6, stableId(post[@"uri"]).length)]],
                @"expanded_url": src, @"indices": @[@(start), @(end)],
                @"sizes": @{ @"large": fitSize(w, h, 2048, @"fit"),
                             @"medium": fitSize(w, h, 1200, @"fit"),
                             @"small": fitSize(w, h, 680, @"fit"),
                             @"thumb": @{@"w": @150, @"h": @150, @"resize": @"crop"} },
                @"ext_alt_text": im[@"alt"] ?: NSNull.null,
            }];
        }];
    }

    // Video (app.bsky.embed.video, also as recordWithMedia's media). Bluesky GIFs are
    // short videos with presentation "gif". Tweetbot's mediumWithEntity: takes the first
    // `application/x-mpegURL` variant for video/animated_gif (falling back to it when no
    // mp4 exists), so the HLS playlist alone is enough; AVPlayer streams it.
    // media_url_https is the poster frame and goes through the same URL rewriter as photos.
    NSDictionary *vid = [embed[@"$type"] isEqual:@"app.bsky.embed.video#view"] ? embed
                      : [embed[@"media"][@"$type"] isEqual:@"app.bsky.embed.video#view"] ? embed[@"media"] : nil;
    if ([vid[@"playlist"] isKindOfClass:NSString.class]) {
        NSString *sid = stableId(post[@"uri"] ?: @"");
        NSString *tco = [@"https://t.co/" stringByAppendingString:[sid substringToIndex:MIN(10, sid.length)]];
        NSUInteger start = cpCount(full) + 1;
        [full appendFormat:@" %@", tco];
        NSUInteger end = cpCount(full);
        NSDictionary *ar = vid[@"aspectRatio"] ?: @{};
        double w = [ar[@"width"] doubleValue] ?: 1280, h = [ar[@"height"] doubleValue] ?: 720;
        BOOL gif = [vid[@"presentation"] isEqual:@"gif"];
        NSString *poster = tweetbotMediaURL(vid[@"thumbnail"]);
        NSArray *atParts = [post[@"uri"] hasPrefix:@"at://"] ? [[post[@"uri"] substringFromIndex:5] componentsSeparatedByString:@"/"] : nil;
        NSString *web = atParts.count >= 3 ? [NSString stringWithFormat:@"https://bsky.app/profile/%@/post/%@", atParts[0], atParts[2]] : vid[@"playlist"];
        NSString *mid = stableId([post[@"uri"] ?: @"" stringByAppendingString:@"#video"]);
        [media addObject:@{
            @"id_str": mid, @"id": numId(mid), @"type": gif ? @"animated_gif" : @"video",
            @"media_url": poster, @"media_url_https": poster, @"url": tco,
            @"display_url": [@"pic.bsky.app/" stringByAppendingString:[sid substringToIndex:MIN(6, sid.length)]],
            @"expanded_url": web, @"indices": @[@(start), @(end)],
            @"sizes": @{ @"large": fitSize(w, h, 2048, @"fit"),
                         @"medium": fitSize(w, h, 1200, @"fit"),
                         @"small": fitSize(w, h, 680, @"fit"),
                         @"thumb": @{@"w": @150, @"h": @150, @"resize": @"crop"} },
            @"video_info": @{
                @"aspect_ratio": @[@(lround(w)), @(lround(h))],
                @"variants": @[ @{ @"content_type": @"application/x-mpegURL", @"url": vid[@"playlist"] } ],
            },
            @"ext_alt_text": vid[@"alt"] ?: NSNull.null,
        }];
    }

    NSDictionary *ext = embed[@"external"] ?: embed[@"media"][@"external"];
    if (!linkCard && [ext[@"uri"] isKindOfClass:NSString.class]) {
        BOOL already = NO; for (NSDictionary *u in urls) if ([u[@"expanded_url"] isEqual:ext[@"uri"]]) { already = YES; break; }
        if (!already) {
            NSUInteger start = cpCount(full) + 1;
            [full appendFormat:@" %@", prettyUrl(ext[@"uri"])];
            [urls addObject:@{ @"url": ext[@"uri"], @"expanded_url": ext[@"uri"], @"display_url": prettyUrl(ext[@"uri"]), @"indices": @[@(start), @(cpCount(full))] }];
        }
    }

    NSMutableDictionary *entities = [@{ @"hashtags": hashtags, @"urls": urls, @"user_mentions": mentions, @"symbols": @[] } mutableCopy];
    if (media.count) entities[@"media"] = media;
    NSMutableDictionary *out = [@{ @"full_text": full, @"display_text_range": @[@0, @(displayEnd)], @"entities": entities } mutableCopy];
    if (media.count) out[@"extended_entities"] = @{ @"media": media };
    return out;
}

#pragma mark - Link cards (app.bsky.embed.external)

// Tweetbot has no link-preview view; the only boxed sub-view a status has is the quoted
// tweet. So an external embed is served as a synthetic `quoted_status`: the page title
// is the "user" name (the bold line), the site host the screen name, the description
// plus the link the text, and the thumbnail a photo. Card ids aren't posts, so they
// live in their own registry (status id and user id -> the JSON we handed out).
static NSMutableDictionary<NSString *, NSDictionary *> *gCardRegistry = nil;
static NSObject *cardLock(void) {
    static NSObject *lock; static dispatch_once_t once; dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSDictionary *cardForId(NSString *sid) {
    if (![sid isKindOfClass:NSString.class] || !sid.length) return nil;
    @synchronized (cardLock()) { return gCardRegistry[sid]; }
}
static NSString *trimmed(id v) {
    return [v isKindOfClass:NSString.class] ? [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}
// The post's external embed, if it has anything worth a card (else the bare link stays
// in the text).
static NSDictionary *cardEmbed(NSDictionary *post) {
    NSDictionary *embed = post[@"embed"];
    if (![embed isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *ext = embed[@"external"];
    if (![ext isKindOfClass:NSDictionary.class] || ![ext[@"uri"] isKindOfClass:NSString.class] || ![ext[@"uri"] length]) return nil;
    if (!trimmed(ext[@"title"]).length && !trimmed(ext[@"description"]).length && !trimmed(ext[@"thumb"]).length) return nil;
    return ext;
}
static NSDictionary *cardStatus(NSDictionary *post, NSDictionary *ext) {
    NSString *uri = ext[@"uri"];
    NSString *host = [NSURL URLWithString:uri].host ?: prettyUrl(uri);
    if ([host.lowercaseString hasPrefix:@"www."]) host = [host substringFromIndex:4];
    NSString *title = trimmed(ext[@"title"]), *desc = trimmed(ext[@"description"]), *thumb = trimmed(ext[@"thumb"]);
    // GIF picker embeds (Tenor / Klipy) carry a stock title and "ALT: ..." as the description
    if ([host isEqual:@"media.tenor.com"] || [host isEqual:@"static.klipy.com"]) {
        title = @"GIF";
        if ([desc.lowercaseString hasPrefix:@"alt:"]) desc = trimmed([desc substringFromIndex:4]);
    }
    if (desc.length > 200) desc = [[desc substringToIndex:[desc rangeOfComposedCharacterSequenceAtIndex:199].location] stringByAppendingString:@"…"];

    NSString *key = [post[@"uri"] ?: @"" stringByAppendingString:@"#card"];
    NSString *sid = stableId(key), *uid = stableId([key stringByAppendingString:@"-site"]);

    // The text is the description plus the link. With a thumbnail the link IS the media
    // entity: the quote box prints a media entity's display_url even when it lies outside
    // display_text_range, so a separate hidden t.co would show up as a second URL.
    // Tweetbot dedupes users by screen name, so cards sharing a host would share one
    // "user" (and so one title), and a host that is also a real handle (theguardian.com)
    // would merge with that account. Make the screen name unique per card with an
    // invisible suffix: 20 bits of the card id as zero-width space / non-joiner.
    NSMutableString *screenName = [host mutableCopy];
    unsigned long long bits = strtoull(uid.UTF8String, NULL, 10);
    for (int i = 0; i < 20; i++) [screenName appendString:((bits >> i) & 1) ? @"\u200c" : @"\u200b"];

    NSMutableString *full = [desc mutableCopy];
    if (full.length) [full appendString:@"\n"];
    NSArray *linkIdx = @[@(cpCount(full)), @(cpCount(full) + cpCount(prettyUrl(uri)))];
    [full appendString:prettyUrl(uri)];
    NSUInteger displayEnd = cpCount(full);

    NSMutableDictionary *entities = [@{ @"hashtags": @[], @"urls": @[], @"user_mentions": @[], @"symbols": @[] } mutableCopy];
    NSArray *media = nil;
    if (thumb.length) {
        NSString *mediaUrl = tweetbotMediaURL(thumb);
        NSString *mid = stableId([key stringByAppendingString:@"-thumb"]);
        // og:image has no recorded size; 1.91:1 is the usual card shape
        media = @[@{
            @"id_str": mid, @"id": numId(mid), @"type": @"photo",
            @"media_url": mediaUrl, @"media_url_https": mediaUrl, @"url": uri,
            @"display_url": prettyUrl(uri), @"expanded_url": uri, @"indices": linkIdx,
            @"sizes": @{ @"large": fitSize(1200, 630, 2048, @"fit"), @"medium": fitSize(1200, 630, 1200, @"fit"),
                         @"small": fitSize(1200, 630, 680, @"fit"), @"thumb": @{@"w": @150, @"h": @150, @"resize": @"crop"} },
            @"ext_alt_text": NSNull.null,
        }];
        entities[@"media"] = media;
    } else {
        entities[@"urls"] = @[@{ @"url": uri, @"expanded_url": uri, @"display_url": prettyUrl(uri), @"indices": linkIdx }];
    }

    NSString *created = twitterDate(post[@"record"][@"createdAt"] ?: post[@"indexedAt"]);
    NSDictionary *user = @{
        @"id_str": uid, @"id": numId(uid),
        @"screen_name": screenName, @"name": title.length ? title : host,
        @"description": desc, @"location": @"", @"url": uri, @"protected": @NO, @"verified": @NO,
        @"followers_count": @0, @"friends_count": @0, @"statuses_count": @0,
        @"favourites_count": @0, @"listed_count": @0, @"created_at": created,
        @"profile_image_url_https": @"", @"profile_image_url": @"", @"profile_banner_url": @"",
        @"following": @NO, @"follow_request_sent": @NO,
    };
    NSMutableDictionary *status = [@{
        @"id_str": sid, @"id": numId(sid),
        @"full_text": full, @"text": full, @"display_text_range": @[@0, @(displayEnd)],
        @"truncated": @NO, @"created_at": created, @"user": user,
        @"retweet_count": @0, @"favorite_count": @0, @"reply_count": @0, @"quote_count": @0,
        @"is_quote_status": @NO, @"favorited": @NO, @"retweeted": @NO, @"lang": @"en",
        @"source": @"<a href=\"https://bsky.app\" rel=\"nofollow\">Bluesky</a>",
        @"in_reply_to_status_id_str": NSNull.null, @"in_reply_to_screen_name": NSNull.null,
        @"entities": entities, @"_card_url": uri,
    } mutableCopy];
    if (media) status[@"extended_entities"] = @{ @"media": media };
    @synchronized (cardLock()) {
        if (!gCardRegistry) gCardRegistry = [NSMutableDictionary dictionary];
        gCardRegistry[sid] = status; gCardRegistry[uid] = status;
    }
    return status;
}

// The quoted post inside an embed (app.bsky.embed.record / recordWithMedia), as a
// post-shaped dict (viewRecord carries the record under `value` and media under
// `embeds`). nil for blocked / deleted / non-post (feed, list, starter pack) embeds.
static NSDictionary *quotedPost(NSDictionary *embed) {
    if (![embed isKindOfClass:NSDictionary.class]) return nil;
    NSString *t = embed[@"$type"];
    NSDictionary *r = [t isEqual:@"app.bsky.embed.record#view"] ? embed[@"record"]
                    : [t isEqual:@"app.bsky.embed.recordWithMedia#view"] ? embed[@"record"][@"record"] : nil;
    if (![r isKindOfClass:NSDictionary.class] || ![r[@"$type"] isEqual:@"app.bsky.embed.record#viewRecord"]) return nil;
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"uri", @"cid", @"author", @"indexedAt", @"likeCount", @"repostCount", @"replyCount", @"quoteCount"]) if (r[k]) p[k] = r[k];
    p[@"record"] = r[@"value"] ?: @{};
    NSArray *embeds = r[@"embeds"];
    if ([embeds isKindOfClass:NSArray.class] && embeds.count) p[@"embed"] = embeds[0];
    return p;
}

static NSDictionary *statusFromPost(NSDictionary *post, BOOL allowQuote);
static NSDictionary *retweetWrapper(NSDictionary *status, NSDictionary *rendered, NSDictionary *post, NSDictionary *reason);

// `item[@"_id"]` (optional) forces the top-level status id: a ranked feed's position id,
// or the id statuses/show was asked for (Tweetbot merges the reply into the status it
// holds under that id, so it must come back under the same one).
static NSDictionary *statusFromFeedItem(NSDictionary *item) {
    NSDictionary *post = item[@"post"] ?: item;
    NSString *forcedId = [item[@"_id"] isKindOfClass:NSString.class] && [item[@"_id"] length] ? item[@"_id"] : nil;
    NSDictionary *status = statusFromPost(post, YES);
    NSDictionary *reason = item[@"reason"];
    // status carries full_text, so it doubles as the rendered text for the RT wrapper
    if ([reason[@"$type"] isEqual:@"app.bsky.feed.defs#reasonRepost"]) {
        NSDictionary *rt = retweetWrapper(status, status, post, reason);
        if (!forcedId || [rt[@"id_str"] isEqual:forcedId]) return rt;
        NSMutableDictionary *m = [rt mutableCopy];
        m[@"id_str"] = forcedId; m[@"id"] = numId(forcedId);
        registerPostId(forcedId, post, reason);
        return m;
    }
    if (!forcedId || [status[@"id_str"] isEqual:forcedId]) return status;
    NSMutableDictionary *m = [status mutableCopy];
    m[@"id_str"] = forcedId; m[@"id"] = numId(forcedId);
    registerPostId(forcedId, post, nil);
    return m;
}

// Twitter status for one hydrated post view. `allowQuote`: attach the embedded quoted
// post as `quoted_status` (one level only, like Twitter).
static NSDictionary *statusFromPost(NSDictionary *post, BOOL allowQuote) {
    NSDictionary *rec = post[@"record"] ?: @{};
    registerPost(post);
    NSString *id_ = postIdForPost(post);
    NSDictionary *q = allowQuote ? quotedPost(post[@"embed"]) : nil;
    // A link card takes the quote box when there is no real quote (one box per status).
    NSDictionary *card = allowQuote && !q[@"uri"] ? cardEmbed(post) : nil;
    NSDictionary *rendered = renderPost(rec, post, card != nil);
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
        @"quote_count": post[@"quoteCount"] ?: @0,
        @"is_quote_status": @NO,
        @"favorited": @([post[@"viewer"][@"like"] isKindOfClass:NSString.class]),
        @"retweeted": @([post[@"viewer"][@"repost"] isKindOfClass:NSString.class]),
        @"lang": [rec[@"langs"] isKindOfClass:NSArray.class] && [rec[@"langs"] count] ? rec[@"langs"][0] : @"en",
        @"source": @"<a href=\"https://bsky.app\" rel=\"nofollow\">Bluesky</a>",
        @"in_reply_to_status_id_str": NSNull.null, @"in_reply_to_screen_name": NSNull.null,
        @"entities": rendered[@"entities"],
        @"_atproto_uri": post[@"uri"] ?: @"", @"_atproto_cid": post[@"cid"] ?: @"",
    } mutableCopy];
    if (rendered[@"extended_entities"]) status[@"extended_entities"] = rendered[@"extended_entities"];

    // Replies. Tweetbot threads purely on the NUMERIC in_reply_to_status_id /
    // in_reply_to_user_id (-[PTHTweetbotStatus _updateFromDictionary:] ignores the _str
    // forms), and its reply loaders keep only results whose in_reply_to_status_id is
    // the opened post — without these no post ever has replies.
    NSDictionary *reply = [rec[@"reply"] isKindOfClass:NSDictionary.class] ? rec[@"reply"] : nil;
    NSString *parentUri = [reply[@"parent"] isKindOfClass:NSDictionary.class] ? reply[@"parent"][@"uri"] : nil;
    if ([parentUri isKindOfClass:NSString.class] && [parentUri hasPrefix:@"at://"]) {
        registerReplyParent(reply);
        NSString *pid = postId(parentUri);
        NSString *puid = stableId([[parentUri substringFromIndex:5] componentsSeparatedByString:@"/"].firstObject ?: @"");
        status[@"in_reply_to_status_id"] = numId(pid); status[@"in_reply_to_status_id_str"] = pid;
        status[@"in_reply_to_user_id"] = numId(puid); status[@"in_reply_to_user_id_str"] = puid;
    }

    if (q[@"uri"] || card) {
        NSDictionary *qs = card ? cardStatus(post, card) : statusFromPost(q, NO);
        NSString *qsn = [qs[@"user"] isKindOfClass:NSDictionary.class] ? qs[@"user"][@"screen_name"] : @"";
        NSString *permalink = [NSString stringWithFormat:@"https://twitter.com/%@/status/%@", qsn, qs[@"id_str"]];
        status[@"is_quote_status"] = @YES;
        status[@"quoted_status_id_str"] = qs[@"id_str"];
        status[@"quoted_status_id"] = qs[@"id"];
        status[@"quoted_status"] = qs;
        status[@"quoted_status_permalink"] = @{ @"url": permalink, @"expanded": permalink, @"display": prettyUrl(permalink) };
    }
    return status;
}

static NSDictionary *retweetWrapper(NSDictionary *status, NSDictionary *rendered, NSDictionary *post, NSDictionary *reason) {
    {
        NSDictionary *by = userFromProfile(reason[@"by"]);
        NSString *sn = [status[@"user"] isKindOfClass:NSDictionary.class] ? status[@"user"][@"screen_name"] : @"";
        NSString *rtText = [NSString stringWithFormat:@"RT @%@: %@", sn, rendered[@"full_text"]];
        NSString *rtId = repostId(post, reason);
        registerRepost(rtId, post, reason);
        return @{
            @"id_str": rtId, @"id": numId(rtId),
            @"created_at": twitterDate(reason[@"indexedAt"]),
            @"user": by, @"text": rtText, @"full_text": rtText,
            @"display_text_range": @[@0, @(cpCount(rtText))],
            @"retweeted_status": status,
            @"retweet_count": status[@"retweet_count"], @"favorite_count": status[@"favorite_count"],
            @"entities": @{ @"hashtags": @[], @"urls": @[], @"user_mentions": @[], @"symbols": @[] },
        };
    }
}

static NSInteger clampCount(NSString *c) {
    NSInteger n = c ? c.integerValue : 40; if (n <= 0) n = 40;
    return MAX(1, MIN(100, n));
}

#pragma mark - Paging (since_id / max_id over atproto cursors)

// Tweetbot pages every timeline by id (-[PTHTweetbotTIDCursorPager ...QueryDictionary]):
// refresh = since_id <newest id>, scroll down = max_id <oldest id - 1>, and when a
// refresh returns >= 10 statuses that are all newer than what it had it opens a "gap"
// row, filled with max_id <gap's newest - 1> + since_id <gap's oldest - 1>. It reads
// the response's first/last status as its newest/oldest, so answers must be newest
// first, and anything outside (since_id, max_id] must be left out or it re-asks forever.
// atproto pages with opaque cursors instead, so per timeline we remember the cursor that
// continues after the oldest status of each page we hand out: a max_id request is
// "the page after id max_id + 1".
//
// Ranked feeds (Discover) aren't in time order, and Tweetbot always re-sorts by id, so
// time ids would scramble the ranking. A feed whose first page isn't chronological gets
// RANK ids instead: a refresh is numbered down from "now" in feed order (so each new
// batch sits on top, in the feed's own order), pages below it continue downwards, and a
// post keeps its rank id for the session so a refresh never shows it twice.

typedef NSDictionary *(^FeedFetch)(NSString *cursor, NSString **errOut); // -> { feed, cursor }

static const long long kRankStep = 4096; // 12 low bits of hash per rank; 1024 ranks per ms

static NSObject *feedLock(void) {
    static NSObject *lock; static dispatch_once_t once; dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
// key -> { mode: "time"|"rank", cursors: { id -> cursor }, ids: { item key -> rank id } }
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gFeedStates = nil;

static long long queryId(NSString *s) { return [s isKindOfClass:NSString.class] && s.length ? strtoll(s.UTF8String, NULL, 10) : 0; }
static long long statusIdOf(NSDictionary *status) { return queryId(status[@"id_str"]); }

// When an item entered the timeline: repost time for reposts, else the post's TID time.
static long long feedItemMs(NSDictionary *it) {
    NSDictionary *reason = it[@"reason"], *post = it[@"post"];
    if ([reason[@"$type"] isEqual:@"app.bsky.feed.defs#reasonRepost"])
        return tidMs([reason[@"uri"] isKindOfClass:NSString.class] ? [reason[@"uri"] lastPathComponent] : nil) ?: isoMs(reason[@"indexedAt"]);
    return tidMs([post[@"uri"] isKindOfClass:NSString.class] ? [post[@"uri"] lastPathComponent] : nil)
        ?: isoMs(post[@"record"][@"createdAt"] ?: post[@"indexedAt"]);
}
// Chronological feeds (Following, Mutuals, lists) come back newest-first, give or take
// a client clock; Discover is ~50% out of order.
static BOOL looksChronological(NSArray *items) {
    NSUInteger bad = 0; long long prev = LLONG_MAX;
    for (NSDictionary *it in items) { long long t = feedItemMs(it); if (t > prev) bad++; prev = t; }
    return bad <= MAX((NSUInteger)1, items.count / 10);
}
// Identity of a feed item for rank-id dedupe (a repost is its own item).
static NSString *feedItemKey(NSDictionary *it) {
    NSDictionary *reason = it[@"reason"];
    NSString *uri = [it[@"post"][@"uri"] isKindOfClass:NSString.class] ? it[@"post"][@"uri"] : @"";
    if (![reason[@"$type"] isEqual:@"app.bsky.feed.defs#reasonRepost"]) return uri;
    return [reason[@"uri"] isKindOfClass:NSString.class] ? reason[@"uri"] : [NSString stringWithFormat:@"%@#rt:%@", uri, reason[@"by"][@"did"] ?: @""];
}

// One Tweetbot page of the timeline `key` (since_id / max_id / count in `query`).
// `rankable`: a feed generator, which may be ranked rather than chronological.
static NSArray *pagedFeed(NSString *key, NSDictionary *query, BOOL rankable, FeedFetch fetch, NSString **errOut) {
    long long since = queryId(query[@"since_id"]), max = queryId(query[@"max_id"]);
    NSMutableDictionary *st; NSString *mode, *cursor = nil;
    @synchronized (feedLock()) {
        if (!gFeedStates) gFeedStates = [NSMutableDictionary dictionary];
        st = gFeedStates[key];
        if (!st) gFeedStates[key] = st = [@{ @"cursors": [NSMutableDictionary dictionary], @"ids": [NSMutableDictionary dictionary] } mutableCopy];
        // No since_id/max_id = Tweetbot holds nothing for this timeline (first load, or
        // it dropped it): forget which posts it was shown, or a ranked feed comes back empty.
        if (!since && !max) [st[@"ids"] removeAllObjects];
        mode = st[@"mode"];
        if (max) cursor = st[@"cursors"][[NSString stringWithFormat:@"%lld", max + 1]];
    }
    // A max_id we hold no cursor for (shouldn't happen in-process) falls back to walking
    // down from the top until the pages reach it.
    NSMutableArray *out = [NSMutableArray array];
    NSString *next = nil;
    long long top = max ? max + 1 : snowflakeId(nowMs(), 0); // rank ids are allocated below this
    NSUInteger rank = 0;
    for (int page = 0; page < 5; page++) {
        NSString *pageErr = nil;
        NSDictionary *r = fetch(cursor, &pageErr);
        if (![r isKindOfClass:NSDictionary.class]) {
            if (page == 0) { if (errOut) *errOut = pageErr ?: @"feed request failed"; return nil; }
            break;
        }
        NSArray *items = [r[@"feed"] isKindOfClass:NSArray.class] ? r[@"feed"] : @[];
        next = [r[@"cursor"] isKindOfClass:NSString.class] && [r[@"cursor"] length] ? r[@"cursor"] : nil;
        if (!mode) {
            // Judge from a real page only: Discover hands back a near-empty page once it
            // has served you most of what it has, which would read as "chronological".
            // Bluesky's own Discover is ranked whatever this page looks like.
            BOOL discover = [key hasSuffix:@"/app.bsky.feed.generator/whats-hot"];
            BOOL settled = discover || !rankable || items.count >= 10;
            mode = !rankable ? @"time"
                 : (discover || (items.count >= 3 && !looksChronological(items))) ? @"rank" : @"time";
            if (settled) {
                @synchronized (feedLock()) { st[@"mode"] = mode; }
                tblog(@"[bridge] feed %@ -> %@ ids", key, mode);
            }
        }
        BOOL reachedSince = NO;
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:NSDictionary.class] || ![it[@"post"] isKindOfClass:NSDictionary.class]) continue;
            if ([mode isEqual:@"rank"]) {
                NSString *k = feedItemKey(it); NSString *known;
                @synchronized (feedLock()) { known = st[@"ids"][k]; }
                if (known) continue; // already in this timeline under its rank id
                long long rid = top - (long long)(rank + 1) * kRankStep + (long long)(keyHash(k) & (kRankStep - 1));
                if (since && rid <= since) { reachedSince = YES; break; }
                rank++;
                NSString *ridStr = [NSString stringWithFormat:@"%lld", rid];
                @synchronized (feedLock()) {
                    if ([st[@"ids"] count] > 5000) [st[@"ids"] removeAllObjects];
                    st[@"ids"][k] = ridStr;
                }
                NSMutableDictionary *m = [it mutableCopy]; m[@"_id"] = ridStr;
                [out addObject:statusFromFeedItem(m)];
            } else {
                NSDictionary *s = statusFromFeedItem(it);
                long long sid = statusIdOf(s);
                if (max && sid > max) continue;
                if (since && sid <= since) { reachedSince = YES; continue; }
                [out addObject:s];
            }
        }
        if (out.count || reachedSince || !next || !items.count) break;
        cursor = next; // nothing new on this page (all seen / above max_id): keep going
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        long long x = statusIdOf(a), y = statusIdOf(b);
        return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
    }];
    if (out.count && next) @synchronized (feedLock()) {
        if ([st[@"cursors"] count] > 500) [st[@"cursors"] removeAllObjects];
        st[@"cursors"][[out.lastObject[@"id_str"] description]] = next;
    }
    return out;
}

// Keep statuses inside Tweetbot's (since_id, max_id] window, newest first — for
// sources we don't page (notifications).
static NSArray *statusesInRange(NSArray *statuses, NSDictionary *query) {
    long long since = queryId(query[@"since_id"]), max = queryId(query[@"max_id"]);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in statuses) {
        long long sid = statusIdOf(s);
        if ((max && sid > max) || (since && sid <= since)) continue;
        [out addObject:s];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        long long x = statusIdOf(a), y = statusIdOf(b);
        return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
    }];
    return out;
}

// A FeedFetch for an app.bsky.* view returning { feed, cursor }.
static FeedFetch viewFetch(NSString *nsid, NSDictionary *params) {
    return ^NSDictionary *(NSString *cursor, NSString **errOut) {
        NSMutableDictionary *p = [params mutableCopy];
        if (cursor) p[@"cursor"] = cursor;
        id r = atpView(nsid, p, errOut);
        return [r isKindOfClass:NSDictionary.class] ? r : nil;
    };
}

#pragma mark - Threads (replies under a post)

// Twitter had no "replies to X" endpoint, so when a post's detail view opens Tweetbot
// (PTHTweetbotStatus(ThreadCategory) loadReplyThreads:) fakes one with two requests,
// both carrying since_id = <post id> - 1:
//   search/tweets.json   q="to:<author> AND filter:replies"  -> first-level replies
//   user_timeline.json   include_rts=0 (per author)          -> deeper replies, which
//                        it chains into threads by in_reply_to_status_id
// We answer both from app.bsky.feed.getPostThread.

static void collectReplies(id node, NSUInteger depth, NSMutableArray *out) {
    if (![node isKindOfClass:NSDictionary.class]) return;
    for (NSDictionary *child in ([node[@"replies"] isKindOfClass:NSArray.class] ? node[@"replies"] : @[])) {
        // notFoundPost / blockedPost carry no `post`
        if (![child isKindOfClass:NSDictionary.class] || ![child[@"post"] isKindOfClass:NSDictionary.class]) continue;
        [out addObject:@{ @"post": child[@"post"], @"depth": @(depth) }];
        collectReplies(child, depth + 1, out);
    }
}

// Every reply under `uri` as { post, depth } (1 = direct reply). Cached briefly: one
// detail view asks for the same thread several times (search + a timeline per author).
static NSArray<NSDictionary *> *atpThreadReplies(NSString *uri, NSString **errOut) {
    static NSMutableDictionary<NSString *, NSArray *> *cache; // uri -> @[date, replies]
    @synchronized ([NSDate class]) {
        if (!cache) cache = [NSMutableDictionary dictionary];
        NSArray *hit = cache[uri];
        if (hit && -[hit[0] timeIntervalSinceNow] < 30) return hit[1];
    }
    id r = atpView(@"app.bsky.feed.getPostThread", @{ @"uri": uri, @"depth": @10, @"parentHeight": @0 }, errOut);
    if (![r isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    collectReplies(r[@"thread"], 1, out);
    @synchronized ([NSDate class]) { cache[uri] = @[[NSDate date], out]; }
    return out;
}

// The id of the post the reply loaders are asking about: since_id is it minus one.
// Only meaningful if it's in the post registry (a real refresh's since_id + 1 isn't).
static NSString *openedIdForSinceId(NSString *sinceId) {
    unsigned long long v = sinceId.length ? strtoull(sinceId.UTF8String, NULL, 10) : 0;
    return v && resolvePostRef([NSString stringWithFormat:@"%llu", v + 1]) ? [NSString stringWithFormat:@"%llu", v + 1] : nil;
}

// Replies under the opened post as Twitter statuses; `directOnly` keeps first-level
// ones. Direct replies point in_reply_to_status_id at `openedId` — the id Tweetbot
// holds for the post — so linkage survives however that id was minted.
static NSArray *threadReplyStatuses(NSString *openedId, BOOL directOnly, NSString **errOut) {
    NSArray *replies = atpThreadReplies(resolvePostRef(openedId)[@"uri"], errOut);
    if (!replies) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in replies) {
        BOOL direct = [r[@"depth"] integerValue] == 1;
        if (directOnly && !direct) continue;
        NSDictionary *s = statusFromFeedItem(@{ @"post": r[@"post"] });
        if (direct) {
            NSMutableDictionary *m = [s mutableCopy];
            m[@"in_reply_to_status_id"] = numId(openedId); m[@"in_reply_to_status_id_str"] = openedId;
            s = m;
        }
        [out addObject:s];
    }
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

#pragma mark - Search (search/tweets, users/search, trends, saved searches)

// Tweetbot's search (PTHTweetbotStatusSearchCursor) sends q = "<what you typed>
// -filter:retweets" with result_type=recent&count=100 and pages it by id like any
// timeline (PTHTweetbotTIDCursorPager). app.bsky.feed.searchPosts speaks most of the same
// operators (from: to: mentions: since: until: lang: domain: #tag "phrase") but none of
// Twitter's filter:/min_* ones and no OR, so those come out of the query and run as tests
// on the results instead.

typedef BOOL (^PostTest)(NSDictionary *post);

// The post's embed (or, for a quote with media, its media part) has view type `type`.
static BOOL postHasEmbed(NSDictionary *post, NSString *type) {
    NSDictionary *e = post[@"embed"];
    if (![e isKindOfClass:NSDictionary.class]) return NO;
    if ([e[@"$type"] isEqual:type]) return YES;
    NSDictionary *m = e[@"media"];
    return [m isKindOfClass:NSDictionary.class] && [m[@"$type"] isEqual:type];
}
static BOOL postHasLink(NSDictionary *post) {
    if (postHasEmbed(post, @"app.bsky.embed.external#view")) return YES;
    NSArray *facets = [post[@"record"] isKindOfClass:NSDictionary.class] ? post[@"record"][@"facets"] : nil;
    for (NSDictionary *f in ([facets isKindOfClass:NSArray.class] ? facets : @[])) {
        NSArray *features = [f isKindOfClass:NSDictionary.class] ? f[@"features"] : nil;
        for (NSDictionary *feat in ([features isKindOfClass:NSArray.class] ? features : @[]))
            if ([feat isKindOfClass:NSDictionary.class] && [feat[@"$type"] isEqual:@"app.bsky.richtext.facet#link"]) return YES;
    }
    return NO;
}
// Twitter `filter:<name>` -> a test on a post view (nil = unsupported).
static PostTest searchFilter(NSString *name) {
    static NSDictionary<NSString *, PostTest> *tests; static dispatch_once_t once;
    dispatch_once(&once, ^{
        PostTest images = ^BOOL(NSDictionary *p) { return postHasEmbed(p, @"app.bsky.embed.images#view"); };
        PostTest videos = ^BOOL(NSDictionary *p) { return postHasEmbed(p, @"app.bsky.embed.video#view"); };
        tests = @{
            @"replies": ^BOOL(NSDictionary *p) { return [p[@"record"] isKindOfClass:NSDictionary.class] && [p[@"record"][@"reply"] isKindOfClass:NSDictionary.class]; },
            @"images": images, @"twimg": images,
            @"videos": videos, @"native_video": videos,
            @"media": [^BOOL(NSDictionary *p) { return images(p) || videos(p); } copy],
            @"links": ^BOOL(NSDictionary *p) { return postHasLink(p); },
            @"quote": ^BOOL(NSDictionary *p) { return quotedPost(p[@"embed"]) != nil; },
        };
    });
    return name ? tests[name.lowercaseString] : nil;
}

// Twitter search query -> searchPosts `q`, adding the operators Bluesky lacks to `tests`.
static NSString *blueskySearchQuery(NSString *q, NSMutableArray<PostTest> *tests) {
    static NSRegularExpression *tokenRe; static dispatch_once_t once;
    dispatch_once(&once, ^{ tokenRe = [NSRegularExpression regularExpressionWithPattern:@"-?\"[^\"]*\"|\\S+" options:0 error:NULL]; });
    NSMutableArray *terms = [NSMutableArray array];
    for (NSTextCheckingResult *m in [tokenRe matchesInString:q options:0 range:NSMakeRange(0, q.length)]) {
        NSString *tok = [q substringWithRange:m.range];
        if ([tok isEqual:@"AND"]) continue; // implicit in both
        BOOL neg = tok.length > 1 && [tok hasPrefix:@"-"];
        NSString *body = neg ? [tok substringFromIndex:1] : tok;
        NSRange colon = [body rangeOfString:@":"];
        NSString *op = colon.location != NSNotFound ? [body substringToIndex:colon.location].lowercaseString : nil;
        NSString *arg = colon.location != NSNotFound ? [body substringFromIndex:colon.location + 1] : @"";
        if ([op isEqual:@"filter"] || [op isEqual:@"exclude"] || [op isEqual:@"include"]) {
            // Search never returns reposts (so -filter:retweets, which Tweetbot always
            // appends, holds anyway); unsupported filters are dropped, not searched for.
            PostTest t = [arg.lowercaseString hasSuffix:@"retweets"] || [op isEqual:@"include"] ? nil : searchFilter(arg);
            if (!t) continue;
            PostTest test = (neg || [op isEqual:@"exclude"]) ? ^BOOL(NSDictionary *p) { return !t(p); } : t;
            [tests addObject:[test copy]];
            continue;
        }
        NSString *countKey = op ? @{ @"min_faves": @"likeCount", @"min_retweets": @"repostCount", @"min_replies": @"replyCount" }[op] : nil;
        if (countKey) {
            NSInteger n = arg.integerValue;
            PostTest test = ^BOOL(NSDictionary *p) { BOOL ok = [p[countKey] integerValue] >= n; return neg ? !ok : ok; };
            [tests addObject:[test copy]];
            continue;
        }
        if ([op isEqual:@"url"] && arg.length) { // Twitter matches URL text; Bluesky has domain:
            NSString *host = [arg componentsSeparatedByString:@"/"].firstObject;
            [terms addObject:[(neg ? @"-domain:" : @"domain:") stringByAppendingString:host]];
            continue;
        }
        [terms addObject:tok];
    }
    return [terms componentsJoinedByString:@" "];
}

// A FeedFetch over searchPosts (posts -> feed items) keeping only posts that pass
// `tests`. pagedFeed stops at an empty page, so a page the tests empty out moves on.
static FeedFetch searchFetch(NSString *bq, NSString *sort, NSInteger limit, NSArray<PostTest> *tests) {
    return ^NSDictionary *(NSString *cursor, NSString **errOut) {
        for (int page = 0; page < 3; page++) {
            NSMutableDictionary *p = [@{ @"q": bq, @"sort": sort, @"limit": @(limit) } mutableCopy];
            if (cursor) p[@"cursor"] = cursor;
            id r = atpView(@"app.bsky.feed.searchPosts", p, errOut);
            if (![r isKindOfClass:NSDictionary.class]) return nil;
            NSArray *posts = [r[@"posts"] isKindOfClass:NSArray.class] ? r[@"posts"] : @[];
            NSMutableArray *feed = [NSMutableArray array];
            for (NSDictionary *post in posts) {
                if (![post isKindOfClass:NSDictionary.class]) continue;
                BOOL ok = YES; for (PostTest t in tests) if (!t(post)) { ok = NO; break; }
                if (ok) [feed addObject:@{ @"post": post }];
            }
            NSString *next = [r[@"cursor"] isKindOfClass:NSString.class] && [r[@"cursor"] length] ? r[@"cursor"] : nil;
            if (feed.count || !next || !posts.count || page == 2) return next ? @{ @"feed": feed, @"cursor": next } : @{ @"feed": feed };
            cursor = next;
        }
        return @{ @"feed": @[] };
    };
}

// Mentions mixes in quotes of your posts (-[PTHTweetbotCurrentUserMentionsCursor
// _loadQuotesSinceTID:maxTID:block:]): it ORs the links of your recent posts (their
// twitterURL, which redirect.m points at bsky.app) into one search and keeps results that
// quote you. Bluesky answers that directly: app.bsky.feed.getQuotes. A query that is
// nothing but bsky.app post links -> their at:// uris (getQuotes wants the DID form);
// nil for any other query.
static NSArray<NSString *> *quotedPostUris(NSString *bq) {
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^https?://(?:www\\.)?bsky\\.app/profile/([^/\\s]+)/post/([^/\\s?#]+)/?$" options:NSRegularExpressionCaseInsensitive error:NULL]; });
    NSMutableArray<NSArray *> *links = [NSMutableArray array]; // [actor, rkey]
    for (NSString *tok in [bq componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (!tok.length || [tok isEqual:@"OR"]) continue;
        NSTextCheckingResult *m = [re firstMatchInString:tok options:0 range:NSMakeRange(0, tok.length)];
        if (!m) return nil;
        [links addObject:@[[tok substringWithRange:[m rangeAtIndex:1]], [tok substringWithRange:[m rangeAtIndex:2]]]];
    }
    NSMutableArray *uris = [NSMutableArray array];
    for (NSArray *l in links) {
        NSString *did = resolveHandleToDid(l[0]);
        if (did) [uris addObject:[NSString stringWithFormat:@"at://%@/app.bsky.feed.post/%@", did, l[1]]];
    }
    return links.count ? uris : nil;
}
static NSArray *quoteStatuses(NSArray<NSString *> *uris, NSDictionary *query) {
    NSMutableArray *out = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSString *uri in uris) {
        id r = atpView(@"app.bsky.feed.getQuotes", @{ @"uri": uri, @"limit": @50 }, NULL);
        NSArray *posts = [r isKindOfClass:NSDictionary.class] && [r[@"posts"] isKindOfClass:NSArray.class] ? r[@"posts"] : @[];
        for (NSDictionary *post in posts) {
            if (![post isKindOfClass:NSDictionary.class] || ![post[@"uri"] isKindOfClass:NSString.class] || [seen containsObject:post[@"uri"]]) continue;
            [seen addObject:post[@"uri"]];
            [out addObject:statusFromFeedItem(@{ @"post": post })];
        }
    }
    return statusesInRange(out, query);
}

// Trends (the search view's trend list) = Bluesky's trending topics. Each is backed by a
// feed (link "/profile/<did>/feed/<rkey>"), and opening a trend searches its `query`
// (Tweetbot urlDecodes it), so the trend's name maps back to that feed here and the
// search is answered from the feed instead of a text search for the headline.
static NSMutableDictionary<NSString *, NSString *> *gTrendFeeds = nil; // normalized name -> feed uri
static NSObject *trendLock(void) {
    static NSObject *lock; static dispatch_once_t once; dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSString *trendKey(NSString *s) {
    NSArray *words = [s.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}
static NSString *trendFeedForQuery(NSString *bq) {
    @synchronized (trendLock()) { return gTrendFeeds[trendKey(bq)]; }
}
// "/profile/<actor>/feed/<rkey>" -> at://<did>/app.bsky.feed.generator/<rkey>
static NSString *feedUriFromLink(NSString *link) {
    NSArray<NSString *> *parts = [link componentsSeparatedByString:@"/"];
    if (parts.count != 5 || ![parts[1] isEqual:@"profile"] || ![parts[3] isEqual:@"feed"] || !parts[4].length) return nil;
    NSString *did = resolveHandleToDid(parts[2]);
    return did ? [NSString stringWithFormat:@"at://%@/app.bsky.feed.generator/%@", did, parts[4]] : nil;
}
static NSArray *loadTrends(NSString **errOut) {
    id r = atpView(@"app.bsky.unspecced.getTrends", @{ @"limit": @25 }, NULL);
    NSArray *items = [r isKindOfClass:NSDictionary.class] && [r[@"trends"] isKindOfClass:NSArray.class] ? r[@"trends"] : nil;
    if (!items) { // AppViews without getTrends: topics only (no post counts)
        r = atpView(@"app.bsky.unspecced.getTrendingTopics", @{ @"limit": @25 }, errOut);
        items = [r isKindOfClass:NSDictionary.class] && [r[@"topics"] isKindOfClass:NSArray.class] ? r[@"topics"] : nil;
    }
    if (!items) return nil;
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableArray *trends = [NSMutableArray array];
    for (NSDictionary *t in items) {
        if (![t isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [jsonString(t, @"displayName") stringByTrimmingCharactersInSet:ws];
        if (!name.length) name = [jsonString(t, @"topic") stringByTrimmingCharactersInSet:ws];
        if (!name.length) continue;
        NSString *link = jsonString(t, @"link") ?: @"", *searchQ = name;
        NSString *feed = feedUriFromLink(link);
        if (feed) @synchronized (trendLock()) {
            if (!gTrendFeeds) gTrendFeeds = [NSMutableDictionary dictionary];
            gTrendFeeds[trendKey(name)] = feed;
        } else if ([link hasPrefix:@"/search?q="]) {
            searchQ = [[link substringFromIndex:10] stringByRemovingPercentEncoding] ?: name;
        }
        [trends addObject:@{
            @"name": name,
            @"query": [searchQ stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: name,
            @"url": [@"https://bsky.app" stringByAppendingString:link],
            @"tweet_volume": [t[@"postCount"] isKindOfClass:NSNumber.class] ? t[@"postCount"] : NSNull.null,
            @"promoted_content": NSNull.null,
        }];
    }
    return trends;
}

// search/tweets for anything but the reply lookup.
static NSArray *searchStatuses(NSString *q, NSDictionary *query, NSString **errOut) {
    NSMutableArray<PostTest> *tests = [NSMutableArray array];
    NSString *bq = blueskySearchQuery(q, tests);
    if (!bq.length) return @[]; // nothing left to search for (searchPosts needs a q)
    NSArray *quoted = quotedPostUris(bq);
    if (quoted) return quoteStatuses(quoted, query);
    NSInteger limit = clampCount(query[@"count"]);
    NSString *trendFeed = trendFeedForQuery(bq);
    if (trendFeed) return pagedFeed(trendFeed, query, YES, viewFetch(@"app.bsky.feed.getFeed", @{ @"feed": trendFeed, @"limit": @(limit) }), errOut);
    // "popular" is ranked: rank ids keep searchPosts' order through Tweetbot's id sort.
    NSString *sort = [query[@"result_type"] isEqual:@"popular"] ? @"top" : @"latest";
    return pagedFeed([NSString stringWithFormat:@"search:%@:%@", sort, q], query, [sort isEqual:@"top"],
                     searchFetch(bq, sort, limit, tests), errOut);
}

// users/search (PTHTweetbotUserSearchCursor): only `q`, one page, no paging.
// searchActors returns basic profiles without counts, so hydrate via getProfiles.
static NSArray *searchUsers(NSString *q, NSString **errOut) {
    q = [q stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([q hasPrefix:@"@"]) q = [q substringFromIndex:1];
    if (!q.length) return @[];
    id r = atpView(@"app.bsky.actor.searchActors", @{ @"q": q, @"limit": @50 }, errOut);
    if (![r isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray *actors = [NSMutableArray array], *dids = [NSMutableArray array];
    for (NSDictionary *a in ([r[@"actors"] isKindOfClass:NSArray.class] ? r[@"actors"] : @[]))
        if (jsonString(a, @"did")) { [actors addObject:a]; [dids addObject:a[@"did"]]; }
    NSMutableDictionary *full = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < dids.count; i += 25) {
        id pr = atpView(@"app.bsky.actor.getProfiles", @{ @"actors": [dids subarrayWithRange:NSMakeRange(i, MIN(25, dids.count - i))] }, NULL);
        for (NSDictionary *p in ([pr isKindOfClass:NSDictionary.class] && [pr[@"profiles"] isKindOfClass:NSArray.class] ? pr[@"profiles"] : @[]))
            if (jsonString(p, @"did")) full[p[@"did"]] = p;
    }
    NSMutableArray *users = [NSMutableArray array];
    for (NSDictionary *a in actors) [users addObject:userFromProfile(full[a[@"did"]] ?: a)];
    return users;
}

// Saved searches: Bluesky keeps none server-side, so they live in the app's own
// defaults (the sandbox container, so they survive relaunches and dylib reloads).
// Stored as { id, query, createdAt }; id = stableId(query), so saving twice is a no-op.
static NSString *const kSavedSearchesKey = @"atbotSavedSearches";
static NSObject *savedSearchLock(void) {
    static NSObject *lock; static dispatch_once_t once; dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSArray<NSDictionary *> *savedSearches(void) {
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:kSavedSearchesKey];
    return [a isKindOfClass:NSArray.class] ? a : @[];
}
static NSDictionary *savedSearchJSON(NSDictionary *s) {
    NSString *sid = [s[@"id"] description] ?: @"0";
    return @{ @"id": numId(sid), @"id_str": sid, @"name": s[@"query"] ?: @"", @"query": s[@"query"] ?: @"",
              @"created_at": twitterDate(s[@"createdAt"]), @"position": NSNull.null };
}
static NSDictionary *savedSearchCreate(NSString *q) {
    @synchronized (savedSearchLock()) {
        NSString *sid = stableId(q);
        NSMutableArray *all = [savedSearches() mutableCopy];
        for (NSDictionary *s in all) if ([[s[@"id"] description] isEqual:sid]) return savedSearchJSON(s);
        NSDictionary *s = @{ @"id": sid, @"query": q, @"createdAt": nowISO() };
        [all addObject:s];
        [NSUserDefaults.standardUserDefaults setObject:all forKey:kSavedSearchesKey];
        return savedSearchJSON(s);
    }
}
// Removes the saved search when `destroy`; returns it (nil if unknown).
static NSDictionary *savedSearchFind(NSString *sid, BOOL destroy) {
    @synchronized (savedSearchLock()) {
        NSMutableArray *all = [savedSearches() mutableCopy];
        for (NSUInteger i = 0; i < all.count; i++) {
            if (![[all[i][@"id"] description] isEqual:sid]) continue;
            NSDictionary *s = all[i];
            if (destroy) { [all removeObjectAtIndex:i]; [NSUserDefaults.standardUserDefaults setObject:all forKey:kSavedSearchesKey]; }
            return savedSearchJSON(s);
        }
        return nil;
    }
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
// (postId(at-uri), or a repost/ranked-feed id), replacing Tweetbot's https://twitter.com/<name>/status/<id>.
// at://<did>/app.bsky.feed.post/<rkey> -> https://bsky.app/profile/<actor>/post/<rkey>.
// Prefers the readable handle; falls back to the DID (always valid) when no handle
// is known, and to the profile page when the post isn't in the registry.
NSString *bridge_post_web_url(NSString *statusId, NSString *handle) {
    NSString *cardUrl = bridge_card_url(statusId);
    if (cardUrl) return cardUrl;
    NSDictionary *ref = resolvePostRef(statusId);
    NSArray<NSString *> *parts = [ref[@"uri"] hasPrefix:@"at://"] ? [[ref[@"uri"] substringFromIndex:5] componentsSeparatedByString:@"/"] : nil;
    if (parts.count < 3) return handle.length ? bridge_profile_web_url(handle) : nil;
    NSString *actor = handle.length ? handle : parts[0];
    return [NSString stringWithFormat:@"https://bsky.app/profile/%@/post/%@", actor, parts[2]];
}

// The link behind a link card's synthetic status id (nil for anything else).
NSString *bridge_card_url(NSString *statusId) {
    return cardForId(statusId)[@"_card_url"];
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

static BridgeResp notFoundResp(void) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{ @"errors": @[@{ @"code": @144, @"message": @"No status found with that ID." }] } options:0 error:NULL];
    return (BridgeResp){ 404, @"application/json", d };
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
        NSString *err = nil;
        NSArray *out = pagedFeed(@"home", query, NO, viewFetch(@"app.bsky.feed.getTimeline", @{ @"limit": @(clampCount(query[@"count"])) }), &err);
        if (!out) return errResp(err);
        return jsonResp(out);
    }
    if ([path containsString:@"/statuses/user_timeline"]) {
        // Tweetbot's reply-thread loader (_PTHTweetbotStatusPossibleReplyCursor): an
        // author's timeline since <opened post id> - 1, include_rts=0, from which it keeps
        // any reply that isn't the post itself. Hand it the whole reply tree under the
        // post (its result set dedupes across the per-author calls). A plain profile
        // refresh's since_id is a real post id, so since_id + 1 never resolves for it.
        if (cardForId(query[@"user_id"])) return jsonResp(@[]); // a link card's "author" has no posts
        NSString *openedId = [query[@"include_rts"] isEqual:@"0"] ? openedIdForSinceId(query[@"since_id"]) : nil;
        if (openedId) {
            if (query[@"max_id"]) return jsonResp(@[]); // everything came on the first page
            NSString *err = nil; NSArray *replies = threadReplyStatuses(openedId, NO, &err);
            if (!replies) return errResp(err);
            return jsonResp(replies);
        }
        NSString *actor = resolveActor(query[@"screen_name"] ?: query[@"user_id"], gDID);
        NSString *err = nil;
        NSArray *out = pagedFeed([@"author:" stringByAppendingString:actor ?: @""], query, NO,
                                 viewFetch(@"app.bsky.feed.getAuthorFeed", @{ @"actor": actor ?: @"", @"limit": @(clampCount(query[@"count"])) }), &err);
        if (!out) return errResp(err);
        return jsonResp(out);
    }
    if ([path containsString:@"/statuses/mentions_timeline"]) {
        NSString *err = nil; id r = atpView(@"app.bsky.notification.listNotifications", @{ @"limit": @(clampCount(query[@"count"])) }, &err);
        if (!r) return errResp(err);
        NSMutableArray *out = [NSMutableArray array];
        // Notifications carry only the raw record (no embed views / counts), so hydrate
        // them via getPosts for images, quotes and like/repost/reply counts.
        NSMutableArray *uris = [NSMutableArray array];
        for (NSDictionary *n in (r[@"notifications"] ?: @[]))
            if (([n[@"reason"] isEqual:@"mention"] || [n[@"reason"] isEqual:@"reply"]) && n[@"uri"]) [uris addObject:n[@"uri"]];
        NSDictionary *hydrated = atpGetPostsMap(uris);
        for (NSDictionary *n in (r[@"notifications"] ?: @[])) {
            NSString *reason = n[@"reason"];
            if (![reason isEqual:@"mention"] && ![reason isEqual:@"reply"]) continue;
            NSDictionary *hp = n[@"uri"] ? hydrated[n[@"uri"]] : nil;
            if (hp) { [out addObject:statusFromFeedItem(@{ @"post": hp })]; continue; }
            [out addObject:statusFromFeedItem(@{ @"post": @{ @"record": n[@"record"] ?: @{}, @"author": n[@"author"] ?: @{}, @"uri": n[@"uri"] ?: @"", @"cid": n[@"cid"] ?: @"", @"indexedAt": n[@"indexedAt"] ?: @"" } })];
        }
        return jsonResp(statusesInRange(out, query));
    }
    // ---- search ----
    if ([path containsString:@"/search/tweets"]) {
        NSString *q = query[@"q"] ?: @"";
        NSArray *statuses = nil; NSString *err = nil;
        // The detail view's reply lookup (_PTHTweetbotStatusReplySearchCursor):
        // q="to:<author> AND filter:replies", since_id = <post id> - 1; it keeps results
        // whose in_reply_to_status_id is the post. Everything else is a real search.
        NSString *openedId = [q containsString:@"filter:replies"] ? openedIdForSinceId(query[@"since_id"]) : nil;
        if (openedId) statuses = query[@"max_id"] ? @[] : threadReplyStatuses(openedId, YES, &err);
        else statuses = searchStatuses(q, query, &err);
        if (!statuses) return errResp(err);
        return jsonResp(@{ @"statuses": statuses,
                           @"search_metadata": @{ @"count": @(statuses.count), @"query": q, @"since_id_str": query[@"since_id"] ?: @"0" } });
    }
    if ([path containsString:@"/users/search"]) {
        NSString *err = nil; NSArray *users = searchUsers(query[@"q"] ?: @"", &err);
        if (!users) return errResp(err);
        return jsonResp(users);
    }
    // Trends: one worldwide place (Bluesky's trends aren't per-location).
    if ([path containsString:@"/trends/available"] || [path containsString:@"/trends/closest"]) {
        return jsonResp(@[@{ @"name": @"Worldwide", @"woeid": @1, @"parentid": @0, @"country": @"", @"countryCode": NSNull.null,
                             @"url": @"http://where.yahooapis.com/v1/place/1", @"placeType": @{ @"code": @19, @"name": @"Supername" } }]);
    }
    if ([path containsString:@"/trends/place"]) {
        NSString *err = nil; NSArray *trends = loadTrends(&err);
        if (!trends) return errResp(err);
        NSString *now = nowISO();
        return jsonResp(@[@{ @"trends": trends, @"as_of": now, @"created_at": now,
                             @"locations": @[@{ @"name": @"Worldwide", @"woeid": @1 }] }]);
    }
    // Saved searches (stored locally, see savedSearchCreate).
    if ([path containsString:@"/saved_searches/"]) {
        if ([path containsString:@"/saved_searches/list"]) {
            NSMutableArray *out = [NSMutableArray array];
            for (NSDictionary *s in savedSearches()) [out addObject:savedSearchJSON(s)];
            return jsonResp(out);
        }
        if ([path containsString:@"/saved_searches/create"]) {
            NSString *q = [query[@"query"] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!q.length) return errResp(@"missing query");
            return jsonResp(savedSearchCreate(q));
        }
        NSString *sid = [path.lastPathComponent stringByDeletingPathExtension];
        NSDictionary *s = savedSearchFind(sid, [path containsString:@"/saved_searches/destroy/"]);
        return s ? jsonResp(s) : notFoundResp();
    }
    // ---- single statuses (detail view refresh, quoted/linked posts) ----
    // Tweetbot re-fetches a post when its detail view opens and MERGES the result, so an
    // empty {} here wiped media, quotes and counts. Ids are ones we handed out.
    if ([method isEqual:@"GET"] && [path containsString:@"/statuses/show"]) {
        NSString *sid = query[@"id"] ?: [path.lastPathComponent stringByDeletingPathExtension];
        NSDictionary *card = cardForId(sid); // link cards aren't posts: echo what we served
        if (card) return jsonResp(card);
        NSDictionary *ref = resolvePostRef(sid);
        if (!ref) return notFoundResp();
        NSString *err = nil; NSDictionary *post = atpGetPost(ref[@"uri"], &err);
        if (!post) return err ? errResp(err) : notFoundResp();
        return jsonResp(statusFromFeedItem(ref[@"reason"] ? @{ @"post": post, @"reason": ref[@"reason"], @"_id": sid } : @{ @"post": post, @"_id": sid }));
    }
    if ([path containsString:@"/statuses/lookup"]) {
        NSArray *ids = [query[@"id"] ?: @"" componentsSeparatedByString:@","];
        NSMutableArray *uris = [NSMutableArray array];
        for (NSString *sid in ids) { NSDictionary *ref = resolvePostRef(sid); if (ref[@"uri"] && ![uris containsObject:ref[@"uri"]]) [uris addObject:ref[@"uri"]]; }
        NSDictionary *hydrated = atpGetPostsMap(uris);
        NSMutableArray *out = [NSMutableArray array];
        NSMutableDictionary *byId = [NSMutableDictionary dictionary];
        for (NSString *sid in ids) {
            if (!sid.length) continue;
            NSDictionary *s = cardForId(sid);
            if (!s) {
                NSDictionary *ref = resolvePostRef(sid); NSDictionary *post = ref[@"uri"] ? hydrated[ref[@"uri"]] : nil;
                if (post) s = statusFromFeedItem(ref[@"reason"] ? @{ @"post": post, @"reason": ref[@"reason"], @"_id": sid } : @{ @"post": post, @"_id": sid });
            }
            if (s) [out addObject:s];
            byId[sid] = s ?: NSNull.null;
        }
        // +[PTHTweetbotStatus lookup:result:] (which every search result goes through)
        // sends map=true and reads only Twitter's map shape, { id: { <id>: status | null } };
        // given an array it "fails to find" them all and the search shows nothing.
        if ([query[@"map"] isEqual:@"true"]) return jsonResp(@{ @"id": byId });
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
        // List feeds are chronological; feed generators may be ranked (Discover).
        NSArray *out = pagedFeed(entry[@"uri"], query, !isList,
                                 viewFetch(isList ? @"app.bsky.feed.getListFeed" : @"app.bsky.feed.getFeed",
                                           @{ (isList ? @"list" : @"feed"): entry[@"uri"], @"limit": @(clampCount(query[@"count"])) }), &err);
        if (!out) return errResp(err);
        return jsonResp(out);
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
        NSDictionary *card = cardForId(query[@"user_id"]);
        if (card) return jsonResp(card[@"user"]);
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
