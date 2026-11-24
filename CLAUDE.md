# CLAUDE.md

Working notes for Claude (and humans) hacking on **atbot** — modding Mac App Store
**Tweetbot 3.5.8** into a Bluesky/atproto client by code injection, not a rebuild.

## Goal

Make `/Applications/Tweetbot.app` (bundle id `com.tapbots.Tweetbot3Mac`, universal
ObjC/Cocoa, final MAS build — there will never be another) talk to Bluesky instead of the
dead Twitter API. Ship it as a transform of the user's own Tweetbot copy.

## Architecture: loopback bridge, not UI surgery

Tweetbot hardcodes `https://api.twitter.com/...` and routes OAuth + REST through
`push.tapbots.com/tweetbot/5/...`. We don't touch its UI/model. Instead:

1. **`inject/redirect.m`** — injected dylib. Swizzles `NSURLSession`
   `-dataTaskWithRequest:(completionHandler:)` / `-uploadTask...` (hooking the concrete
   class `__NSURLSessionLocal` too — it's a class cluster; guard against re-hooking an
   inherited IMP) and rewrites `*.twitter.com` + `push.tapbots.com` requests to
   `http://127.0.0.1:<port>`. Also hooks `NSWorkspace openURL:` (browser authorize step),
   `handleOAuthURL:` and the GetURL Apple-event handler. Owns `tblog()` (file logging,
   non-static so `bridge.m` shares it).
2. **`inject/bridge.m`** — the fake-Twitter bridge, **in-process**. An embedded loopback
   HTTP server (BSD sockets + GCD, ephemeral port) that emulates the ~Twitter-1.1 endpoints
   Tweetbot calls, backed by an ObjC atproto XRPC client + shape translators. `redirect.m`'s
   constructor calls `bridge_start()` and points `kBridgePort` at it. No Node, no external
   process — a built app is self-contained.
3. **`bridge/*.mjs`** — the original dependency-free **Node prototype** of the same logic
   (`server.mjs` routes, `atproto.mjs` client, `shapes.mjs` translation). Kept as the
   reference / for iterating on translation without rebuilding the app. `bridge.m` is a
   faithful port of these — **keep them in sync** when changing behavior.

Interception is at the `NSURLSession` task level (PTHCommon builds `NSMutableURLRequest`s and
sends them via `NSURLSession`; `__NSURLSessionLocal` is the concrete class). Hooking
`NSURLRequest`/`setURL:` did NOT fire — session-level is the reliable choke point.

## Build & run

```sh
# in-process build (default SRC=inject/redirect.m, which pulls in bridge.m):
bash scripts/build-and-inject.sh            # -> build/atbot.app

# bake creds (shipping path; dylib reads Contents/Resources/atproto.json):
cat > build/atbot.app/Contents/Resources/atproto.json <<'JSON'
{ "handle": "orta.io", "appPassword": "xxxx-xxxx-xxxx-xxxx", "pds": "https://npmx.social" }
JSON
codesign --force -s - --entitlements scripts/modded.entitlements.plist build/atbot.app
open build/atbot.app
```

`build-and-inject.sh` does: `ditto` Tweetbot → rename to **atbot** (CFBundleName/executable
`atbot`, id `io.orta.atbot`, own `atbot://` URL scheme) → `patch-receipt.mjs` → compile the
universal dylib (`redirect.m` + `bridge.m`) → inject `LC_LOAD_DYLIB` **into
PTHCommon.framework in place** (`inject-framework.mjs`; no LIEF/Python — see the padding note
below) → if `./atproto.json` exists, copy it into `Resources/` → re-sign ad-hoc inside-out
with `scripts/modded.entitlements.plist`.

Creds also load from env (`BRIDGE_HANDLE` / `BRIDGE_APP_PASSWORD` / `BRIDGE_PDS`) for dev.
`TWEETBOT_BRIDGE_PORT` makes the dylib use an external Node bridge instead of the in-process
one (launch the binary directly so the env reaches it — `open` won't pass it). Credentials are
**session-only in chat and never committed** — keep them in a gitignored `./atproto.json`
(the build bakes it in; `.gitignore` already covers `**/atproto.json`).

### Dev loop

- **Dylib code (`redirect.m` / `bridge.m`)** — after one `build-and-inject.sh`, use
  **`bash scripts/dev.sh`** (`--log` to tail): recompiles just the dylib, swaps it into the
  existing `build/atbot.app`, re-signs, relaunches (~1.6s). It skips ditto/patch/inject (the
  load command is in PTHCommon and references the dylib by path) and leaves `Resources/` alone,
  so the account + creds survive every reload.
- **Full `build-and-inject.sh`** — only when you change the pipeline, entitlements, Info.plist,
  bundle identity, or `patch-receipt.mjs` / `inject-framework.mjs`.
- **Translation logic, fastest** — iterate in the `bridge/*.mjs` Node prototype (external
  server + `TWEETBOT_BRIDGE_PORT`), then port to `bridge.m`.
- **Builder** — `bash builder/package.sh` → `dist/Atbotify.app`.
- Debug output: `tblog(@"…")` (non-static, shared by both dylib files) appends to
  `~/Library/Containers/io.orta.atbot/Data/Library/Application Support/tweetbot-atproto.log`
  (NSLog is swallowed for ad-hoc binaries).

### OAuth now completes in-app (no browser)

`my_openURL` in `redirect.m` intercepts the authorize-step `openURL:` and, instead of opening
Safari, re-opens the `atbot://` callback (from `bridge_oauth_callback_url()`), which
LaunchServices routes straight back to the running app's GetURL handler. So **clicking the
welcome Authorize button adds the account in one shot** — no browser, no manual callback
delivery. (For a from-scratch manual drive you can still `open -b io.orta.atbot
"$(curl -s http://127.0.0.1:<port>/__callback)"`.) Testing taps via `System Events` need
`tell application "atbot" to activate` first; the macOS restore dialog's button is `"Don’t
Reopen"` (curly apostrophe) and is a self-inflicted artifact of force-killing — quit cleanly to
avoid it. Timeline window: File → New Window. A persisted account auto-reauthorizes on launch.

## Reverse-engineering findings (the hard-won bits)

- **Injection**: arm64 slice has only 16 bytes of header padding, so a from-scratch Node
  patcher can't append a load command — use **LIEF** (`scripts/insert_dylib_lief.py`), which
  relocates. `scripts/insert-dylib.mjs` is a readable Node reference only.
  `DYLD_INSERT_LIBRARIES` does **not** work (the sandboxed/signed binary is "restricted", dyld
  strips it) — tested and rejected.
- **Launch**: must drop hardened runtime and strip team-scoped entitlements
  (`application-identifier`, `team-identifier`, `aps-environment`, `icloud-*`,
  `application-groups`, `keychain-access-groups`) or launch fails POSIX 153. Keep plain
  `app-sandbox` (+ `network.client/server`, `files.*`) so the container/data persists. See
  `scripts/modded.entitlements.plist`.
- **Anti-tamper** (`scripts/patch-receipt.mjs`, run on the pristine binary before injection):
  (1) MAS receipt gate in `main()` `cmp x23,#3; b.ne exit173` at vmaddr `0x100001ed4` → NOP;
  (2) FOUR dispatch-timer watchdog stubs (signature `stp x29,x30,[sp,#-0x10]!; mov x29,sp;
  mov w0,#0; bl _exit`) → RET. Without all 5 the app `exit()`s ~22–36s after launch. JS
  bitwise needs `>>>0` for `0x8xxxxxxx` compares. Offsets are permanent (no future Tweetbot).
- **Tapbots OAuth proxy protocol**: request_token/access_token are **multipart form-data**
  POSTs to `push.tapbots.com/tweetbot/5/oauth/*` (fields incl. the binary MAS receipt); the
  responses must be **JSON** (`{token,secret,oauth_token,screen_name,user_id,...}`) — form
  encoding gives "Invalid Data". The browser authorize page must redirect to
  `atbot:///request_token?...` — `PTHTweetbotURLController.handleURLEvent:` routes to OAuth
  **only when the first path component is `request_token`**.
- **The account-creation fix (uuid correlation)**: `PTHOAuthHandler` methods live at IMPs
  `init`/`authenticate:completion:`/`handleOAuthURL:`/`.cxx_destruct` =
  `0x10000fd54`/`fdc4`/`0x100010860`/`0x100010b94`. `handleOAuthURL:` does
  `[url queryDictionary]` → `+[PTHTweetbotAccount createAccessRequest:mode:completion:]`
  (Model+0x6990c); the access_token **response handler** (block invoke `0x1000109bc`, the one
  that was crashing at +0x10b58) looks up `self->_authDictionary[ queryDict[@"uuid"] ][@"block"]`
  — the completion stored at `authenticate:` time — and only creates the account if that block
  is found. `_authDictionary` (PTHOAuthHandler ivar @ offset 8) is keyed by a **client-side
  40-char hex id** (`+[NSString uuid]`), NOT the dashed UUID in the request_token multipart
  `uuid` field. **Fix lives in the dylib** (`my_handleOAuthURL`): it reads `_authDictionary`
  via `object_getIvar` and **rewrites the callback URL's `uuid` to the pending entry's real
  key**, matched by `oauth_token` (the entry carries the request_token response fields). The
  original crash was `-[__NSDictionaryM removeObjectForKey:] key cannot be nil` when that uuid
  was absent.
- **CloudKit crash**: because we strip iCloud entitlements, `+[PTHCloudController container]`
  → `CKContainer` **traps (EXC_BREAKPOINT)** when a timeline window opens (via
  `PTHTweetbotSyncPositionController`/`SyncCloudController init`) — this is the "unexpectedly
  quit while reopening windows" dialog. **Fix**: `neutralizeCloudKit()` stubs
  `+[PTHCloudController container]` → nil so position-sync no-ops.
- **atproto routing**: custom-domain handles are on non-bsky PDSes — resolve handle→DID
  (`resolveHandle` on public AppView) → DID doc (`plc.directory` for did:plc, `.well-known`
  for did:web) → `#atproto_pds` endpoint → `createSession` there. Personalized reads
  (`getTimeline`, `getAuthorFeed`, `getProfile`, `listNotifications`) go through the user's PDS
  with header `atproto-proxy: did:web:api.bsky.app#bsky_appview` (public AppView rejects them:
  AuthMissing). App-password sessions may lack a usable refresh token → on 400/401 re-login
  with stored creds.
- **Id consistency**: Tweetbot addresses the account by the numeric `user_id` returned at
  OAuth. Unify it on `stableId(did)` (same as `userFromProfile`), and keep a reverse registry
  (`registerActor` / `resolveActor`) so `users/show` & `user_timeline` map a numeric id /
  handle back to a DID (unknown all-numeric → the signed-in user).
- **Entity rendering**: give every facet real `indices` (convert atproto UTF-8 byteStart/End →
  UTF-16 for NSString), set `display_text_range` to hide a synthetic trailing media URL, clean
  `display_url`, resolve `@handle` mentions, and put photos in `extended_entities.media` — or
  Tweetbot jams the link/`pic.bsky` text into the start of the post.
- **Feeds = Twitter lists**: Tweetbot's timeline-title dropdown is filled from `lists/list.json`.
  We answer it with the user's saved feeds (`getPreferences` → `savedFeedsPrefV2`, pinned first,
  skipping the `timeline`/following entry; hydrated via `getFeedGenerators` / `getList`), and
  `lists/statuses.json?list_id=` maps back through a list registry (`stableId(uri)`) to `getFeed` /
  `getListFeed`. `getPreferences` is served by the PDS itself (no AppView proxy). Tweetbot
  remembers the selected list across launches, so a registry miss reloads the saved feeds.
  **The title menu only shows OWNED lists**: `_loadTimelineMenu:account:` (atbot `0x100058074`)
  enumerates `[[account.currentUser listsCursor] ownedLists]`, and
  `-[PTHTweetbotList isFromCurrentUser]` is `list.userTID == account.currentUser.tid`. So each
  list's `user` must be the signed-in user under the id Tweetbot sends as `user_id` on the
  request (NOT the feed's creator, or the lists load as "subscribed" and the menu stays empty).
  Tweetbot sorts the menu alphabetically; same-named feeds get a `(creator.handle)` suffix.
- **Testing dialog gotcha**: the macOS "unexpectedly quit… Reopen?" loop during testing is a
  self-inflicted artifact of force-killing atbot. Quit cleanly
  (`osascript -e 'tell application "atbot" to quit'`), and/or
  `defaults write io.orta.atbot ApplePersistenceIgnoreState -bool yes` + delete
  `Containers/io.orta.atbot/Data/Library/Saved Application State/io.orta.atbot.savedState`.

## File map

- `inject/redirect.m` — injected dylib: NSURLSession/openURL/OAuth hooks, CloudKit stub,
  starts the in-process bridge. `inject/bridge.{m,h}` — in-process server + atproto client +
  shapes. `inject/poc.m` — load-proof POC. `inject/test_hook.m` — deterministic unit test.
- `bridge/{server,atproto,shapes}.mjs` — Node prototype of the bridge (reference; keep in
  sync with `bridge.m`).
- `scripts/build-and-inject.sh` — the pipeline. `patch-receipt.mjs` — anti-tamper.
  `insert_dylib_lief.py` (+ `.venv`) — injection. `modded.entitlements.plist` — trimmed
  entitlements. `insert-dylib.mjs` / `original.entitlements.plist` — reference.
- `README.md` — human-facing overview. Memory: `tweetbot-atproto-project` in the auto-memory.

## Remaining work

- **Write actions**: post/like/repost/follow/delete via `com.atproto.repo.*` + `app.bsky.*`
  (shapes already stash `_atproto_uri`/`_cid`/`_did`/`_handle` for write-backs). Then DMs,
  search quality, media upload.
- **Builder app**: a notarized Mac app on GitHub Releases that transforms the user's installed
  Tweetbot (prompt for creds → run the pipeline → emit `atbot.app`). Locally-built apps avoid
  the quarantine flag so the ad-hoc output launches. Blocker to solve: **drop the Python/LIEF
  dependency** — either bundle a frozen injector or port LIEF's load-command relocation to
  native code (the arm64 header has no room, so a real Mach-O rebuild is required;
  `DYLD_INSERT` is out). `codesign` is always present on macOS; `clang` can be avoided by
  shipping the precompiled dylib.

## Conventions

- Prefer Node for tooling/scripts where there's a choice.
- Never commit credentials (`atproto.json`, app passwords). They're session-only.
- When you change bridge behavior, update **both** `bridge.m` and the `bridge/*.mjs` prototype.
