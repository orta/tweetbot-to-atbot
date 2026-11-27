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

To test the UI without taking focus or moving the mouse: switch tabs with
`perform action "AXPress" of menu item "<Likes|My Account|…>" of menu 1 of menu item "Tabs" of
menu 1 of menu bar item "View"`, page a list by setting `value of scroll bar 1 of scroll area 1 of
splitter group 1 of window 1` to 1.0, and capture the window even when it's covered with
`screencapture -x -o -l <CGWindowID>` (find the id with JXA `CGWindowListCopyWindowInfo`). To
get a specific post on screen, run a search through the URL scheme:
`open -g -b io.orta.atbot "atbot:///search?q=from%3A<handle>%20<words>"`. The
compact sidebar icons and the profile's Followers/Following counts have no AX action and need a
real click.

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
  Unicode **code points**, Twitter's unit — NOT UTF-16: one emoji before an entity shifts it
  past the end of the text and Tweetbot drops it, showing the raw t.co and no image), set
  `display_text_range` (also code points) to hide a synthetic trailing media URL, clean
  `display_url`, resolve `@handle` mentions, and put photos in `extended_entities.media` — or
  Tweetbot jams the link/`pic.bsky` text into the start of the post.
- **Media URLs**: Tweetbot never loads `media_url_https` verbatim —
  `+[PTHTweetbotMedium twitterMediumURLFromString:sizeName:]` (called from
  `mediumWithEntity:dictionary:` for the main URL and every `sizes` key) turns `x.jpg` into
  `x?format=jpg&name=<size>` and an extension-less path into `x:<size>`. Bluesky CDN paths have no
  extension, so `<cid>:large` 400s → blank image cell. Emit `<fullsize>@jpeg.jpg`, which becomes
  `<cid>@jpeg?format=jpg&name=<size>` (the CDN ignores the query). Image fetches don't go through
  the hooked NSURLSession task methods, so they never show in the log. To test the rewriter
  directly, `dlopen` `/Applications/Tweetbot.app/.../Model` (rpath to its Frameworks) and call it.
  URLs that already have an extension (video `thumbnail.jpg`) get it doubled (`thumbnail.jpg.jpg`)
  so only the copy is stripped.
- **Video / GIF**: Bluesky GIFs are `app.bsky.embed.video` with `presentation: "gif"` (HLS only,
  no mp4). Map to Twitter media `type: "animated_gif"` / `"video"` with
  `video_info.variants: [{content_type: "application/x-mpegURL", url: playlist}]` and the
  thumbnail as `media_url_https`. `mediumWithEntity:` takes the first HLS variant (for `video`
  under 4s it hunts for a `video/mp4` by bitrate, falling back to HLS). Then
  `-[PTHTweetbotMediumMovie loadStreamData:]` fetches that master playlist **itself** and
  parses it with `RESOLUTION=(\d+)x(\d+),.*[\r\n]+(.*)` into best/fastest streams. A
  scheme-less variant URI gets the master URL with its *whole path* replaced. Bluesky puts
  `RESOLUTION` last (no comma after it) and uses relative URIs, so nothing parsed, best/fastest
  were nil and nothing played. `redirect.m` sends Tweetbot's fetch of a `*.bsky.app/…/playlist.m3u8`
  to the bridge's `/__hls/playlist.m3u8?url=`, which serves it with `RESOLUTION` first and
  absolute URIs (`hlsMasterForTweetbot`). The bridge's upstream fetch carries `X-Atbot-Upstream`
  so the hook doesn't loop it back. AVPlayer then pulls the variant playlists from Bluesky
  directly. To check a playlist outside the app, `dlopen` Tweetbot's Model and run
  `loadStreamData:` on a `PTHTweetbotMediumMovie`, then read `bestStream` / `fastestStream`.
- **Link cards (OpenGraph)**: Tweetbot has no link-preview view (`PTHTweetbotCard` only scrapes
  media), so an `app.bsky.embed.external` is served as a synthetic `quoted_status` (`cardStatus`):
  title = user `name` (the bold line), host = `screen_name`, description + link = text, thumb = a
  photo. A real quote wins the box (one per status); with a card the trailing link is no longer
  appended to the post text. Gotchas: Tweetbot **dedupes users by screen name**, so the host gets
  an invisible zero-width suffix unique per card (else cards from one site share a title and a
  host that is a real handle merges with that account); the quote box **prints a media entity's
  `display_url` even outside `display_text_range`** (real quotes with photos show `pic.bsky.app/…`
  too), so the card's link text is itself the media entity. Card ids live in a card registry
  (`statuses/show`, `users/show`, permalinks). `redirect.m` hooks `-_quoteClicked:` on
  `PTHTweetbotStatusView` / `PTHTweetbotStatusDetailStatusView` so clicking a card opens the link.
- **Detail view re-fetch**: opening a post calls `statuses/show/<id>.json` and Tweetbot
  **merges** the response into its cached status — an empty `{}` wipes media, quote and
  counts. Ids resolve through the post registry (repost wrapper ids too, carrying the reason).
  Quotes = `quoted_status` + `is_quote_status` + `quoted_status_permalink` (one level deep).
- **Replies under a post** (`PTHTweetbotStatus(ThreadCategory) loadReplyThreads:`, Model
  framework): Twitter had no replies endpoint, so Tweetbot fakes one with two requests, both
  with `since_id = <post id> - 1`: `search/tweets.json?q=to:<author> AND filter:replies`
  (`_PTHTweetbotStatusReplySearchCursor`, which keeps only results whose `in_reply_to_status_id`
  == the post) and `user_timeline.json?include_rts=0&user_id=<author>`
  (`_PTHTweetbotStatusPossibleReplyCursor`, which keeps any reply ≠ the post and chains them
  into threads). Both are answered from `getPostThread`, keyed by `since_id + 1` in the post
  registry. Tweetbot reads only the **numeric** `in_reply_to_status_id` / `in_reply_to_user_id`
  (never the `_str` forms), so every reply must carry them. Replies are sorted by numeric
  TID (`-[PTHTweetbotObject compare:]`). `to:(null)` in the query means the detail re-fetch
  wiped the author (an empty `statuses/show` answer makes `userWithDictionary:nil`).
- **Search** (`PTHTweetbotStatusSearchCursor`, TID pager): `search/tweets.json` with q = typed
  text + space + `-filter:retweets`, `result_type=recent&count=100`. Served by `searchPosts sort=latest`
  through `pagedFeed`. Bluesky's query has `from: to: mentions: since: until: lang: domain: #tag`
  but no `filter:`/`min_*` and **no OR** (`a OR b` returns 0 hits), so those Twitter operators
  become tests on the results (`blueskySearchQuery`). **Every result goes through
  `+[PTHTweetbotStatus lookup:result:]`**: a POST to `statuses/lookup.json` with `map=true` that
  only accepts `{id: {<id>: status|null}}`. An array answer makes it drop everything and page
  older forever ("No Results"). Mentions' `_loadQuotesSinceTID:` searches
  `<bsky.app post link> OR …` for quotes of your posts → `getQuotes` (wants the DID at-uri; a
  handle at-uri returns nothing). `users/search` (`PTHTweetbotUserSearchCursor`): only `q`, one
  page, no paging → `searchActors` hydrated with `getProfiles` for counts. Trends:
  `trends/place.json` → `[{trends: [{name, query (Tweetbot urlDecodes it), tweet_volume}]}]` from
  `getTrends`. Each trend is a feed generator (`link` `/profile/<did>/feed/<rkey>`), so a search
  for a trend's name is answered from that feed (rank ids). Bluesky has no server-side saved
  searches: they live in the app's defaults (`atbotSavedSearches`; prototype:
  `bridge/.saved-searches.json`).
- **People lists** (Followers / Following, Retweeted by, the account's background loaders): all
  go through `PTHTweetbotCursorCursorPager`. `followers/ids` / `friends/ids` /
  `statuses/retweeters/ids` answer `{ids, next_cursor}` (`cursor=-1` first, then the int64
  `next_cursor` until 0), then Tweetbot POSTs `users/lookup.json` (form `user_id=a,b,…`, ≤100 per
  call, run concurrently; a single id goes to `users/show` instead) and matches the array by `id`,
  marking the rest missing. atproto cursors are strings, so each one gets an integer stand-in
  (`stableId(cursor)`) in a cursor map. An unknown cursor restarts at the top:
  `PTHTweetbotAccountDataTIDLoader` keeps its `next_cursor` in SQLite (`tid_loader_states`) across
  launches. That loader also pulls `blocks/ids`, `mutes/users/ids` and
  `friendships/no_retweets/ids` for the account (not served yet). An unknown numeric user id stays
  unknown here (empty page), never the signed-in user's lists. "Liked by"
  (`PTHTweetbotStatusFavoritesCursor`) only reads the local `interactions` DB and sends no request.
- **Relationship**: `friendships/show.json` → `relationship.source.{following, followed_by,
  blocking, blocked_by, muting, can_dm, want_retweets}` (`-[PTHTweetbotOtherUser
  updateRelationship:]`), filled from `getProfile`'s `viewer`. `can_dm` stays false until DMs exist.
- **Likes tab**: `favorites/list.json` (`PTHTweetbotFavoritesCursor`, TID pager) → `getActorLikes`,
  which only answers for the signed-in user (anyone else's Likes tab gets `[]`). Each liked post is
  served under its **like record's** TID snowflake (`viewer.like`), so the list keeps like order
  and pages cleanly by `max_id`. With post ids it would re-sort by post date and drop items.
- **The App Group container (account directory)**: `+[PTHTweetbotAccount containerURL]` is
  Tapbots' App Group (`~/Library/Group Containers/9JTH7AWHE6.com.tapbots.Tweetbot3Mac`, which
  holds the original Tweetbot's data). It isn't nil, but with that entitlement stripped the
  sandbox can't write there, so nothing per-account under `<tid>.accountd/` persists: `data.sql`
  (follower/friend/block/mute ids, interactions), `messages.sql`, drafts, filters. The
  `PTHTweetbotAccountData*Loader`s and "Liked by" never get a store. Only `messages.sql` is
  redirected so far (`installMessagesStoreFallback` in redirect.m, into our own container,
  while `-[PTHTweetbotAccountMessages initWithAccount:]` runs). Widening it would also restore
  cached posts across launches, which needs the bridge's id registries to survive relaunches
  first.
- **DMs** (`PTHTweetbotAccountMessages`, Model): Twitter's DM events API.
  `direct_messages/events/list.json?count=50[&cursor=]`, following `next_cursor` until it meets
  a message id it already holds, so a cold start pages through everything. Each
  `message_create` event (`id`, `created_timestamp`, `message_create.{sender_id,
  target.recipient_id, message_data.{text, entities, attachment}}`) is filed into a thread
  keyed by the other user's id, then `users/lookup` for the partners. Sending is a **JSON** POST
  to `events/new.json` (`{event: {type, message_create: …}}` → `{event}`), deleting `DELETE
  events/destroy.json?id=` (204), and reloading one message `events/show.json?id=`. Served from
  `chat.bsky.convo.*` through the PDS with `atproto-proxy: did:web:api.bsky.chat#bsky_chat`. The
  app password needs "Allow access to your direct messages" (otherwise "Bad token scope").
  Event ids are snowflakes from the message's TID. The list is a lazy newest-first merge over
  `listConvos` + per-conversation `getMessages` cached by `rev`, so a quiet poll is one
  `listConvos`; a cursor (cold start) fetches the rest concurrently. Only 1:1 conversations; a
  shared post is appended as a twitter.com permalink to its registered id (opens in-app). Ids
  from a previous launch (Tweetbot keeps `messages.sql`) re-index all conversations on a miss,
  and unknown `users/lookup` ids re-list conversations to re-register the partners.
- **The DM gates**: (1) `_PTHTweetbotAccountRequestOperation` only turns on an account's
  `hasDirectMessageAccess` when a response carries `X-Access-Level: read-write-directmessages`
  (Twitter's token permission), so every bridge response sends it. (2) `-[PTHTweetbotAccountMessages
  refresh:]` queues until the store's `_hasLoaded`, which needs `messages.sql` to open (see the
  App Group bullet). Either one alone leaves the Messages tab spinning with no request sent.
- **DM read state**: Tweetbot-local. Each thread has a `lastReadTID` in the account's defaults
  (`MessagesLastRead.<other id>`, thread key `"<account id>.<other id>"`), and received
  messages newer than it are unread. Bluesky → Tweetbot: after each list poll the bridge writes
  "read up to" (from each conversation's `unreadCount`) with
  `+[PTHTweetbotDirectMessageThread _updateLastReadTID:threadKey:]`, which only moves forward.
  Not the public `updateLastReadTID:threadKey:`: its `directMessageThreadForUserTID:` lookup
  **creates and stores** an empty thread for an unknown user. Threads it already holds get
  `_updateCounts`. Tweetbot → Bluesky: redirect.m hooks `-[PTHTweetbotDirectMessageThread
  setLastReadTID:]` (what `markRead` calls) → `bridge_dm_mark_read` →
  `chat.bsky.convo.updateRead`. The sync path never calls that setter, so there's no loop.
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
- **Status ids must be time-ordered (snowflakes)**: every timeline is sorted by numeric tid
  (`-[PTHTweetbotObject compare:]`), and `PTHTweetbotTIDCursorPager` pages by id. Refresh sends
  `since_id=<newest>`, scroll-down sends `max_id=<oldest-1>`, and a refresh that returns ≥10
  statuses all newer than `newestLoadedTID` opens a **gap**, filled with
  `max_id=<gapNewest-1>&since_id=<gapOldest-1>`. It takes the response's first/last item as
  newest/oldest. So hash ids (`stableId`) shuffle timelines and loop the gap loader. Status ids
  are `((ms − 1288834974657) << 22) | hash22`, with `ms` from the post rkey **TID**. That makes
  them a pure function of the at-uri, so `in_reply_to_status_id` works from the parent uri alone.
  Repost wrappers use the repost record's TID. Users, lists and media stay on `stableId`. The
  ids exceed 2^53, so the Node prototype emits them as BigInts (`numId` + `toJSON` in
  `server.mjs`). `pagedFeed` maps since/max onto atproto cursors (`cursor after id X`), answers
  newest-first, and drops anything outside `(since_id, max_id]`.
- **Ranked feeds (Discover)**: time ids would re-sort Discover by date and lose the ranking.
  A feed generator whose first real page isn't chronological (and Bluesky's `whats-hot`
  always) gets **rank ids**: each refresh is numbered down from `snowflake(now)` in feed order,
  pages below continue downwards, and a post keeps its rank id for the session (dedupe, which
  resets when Tweetbot loads with no since/max). The registry maps rank ids too.
  `statuses/show` echoes the requested id (`_id`), and thread loaders force direct replies'
  `in_reply_to` to `since_id+1`. Discover also stops serving posts it has already served you, so
  heavy testing can drain it to 0 items for a while.
- **Query encoding**: build XRPC query strings with `&=+#?` percent-encoded.
  `URLQueryAllowedCharacterSet` leaves `+` alone, the server reads it as a space, and feed
  cursors containing `+` silently re-serve page 1.
- **Tab shortcuts (⌘1–⌘8)**: View → Tabs items send nil-targeted `changeTab:` (tag = tab), which
  only `PTHTweetbotMainViewController` (the main window's `contentViewController`) implements,
  so they die when another window is key or the main window is minimised/closed. `redirect.m`
  adds `-changeTab:` to `PTHTweetbotAppDelegate` (end of the responder chain): bring the
  front-most `mainWindowControllers` window forward (or `newMainWindow:` if none), then call
  the VC's `changeTab:` directly. lldb attaches fine to the running ad-hoc `atbot` for this kind of RE.
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
- `scripts/build-and-inject.sh` — the full pipeline. `scripts/dev.sh` — fast dylib reload
  loop. `patch-receipt.mjs` — anti-tamper. `inject-framework.mjs` — in-place `LC_LOAD_DYLIB`
  injection into PTHCommon (the live one; no LIEF/Python). `modded.entitlements.plist` —
  trimmed entitlements. Legacy/reference only: `insert_dylib_lief.py` (+ `.venv`),
  `insert-dylib.mjs`, `original.entitlements.plist`.
- `builder/atbotify.swift` — native Swift engine (ports receipt-patch + injection, bundles
  the dylib; end users need only macOS). `builder/AtbotifyGUI.swift` — AppKit front-end.
  `builder/package.sh` — assembles `dist/Atbotify.app`.
- `scripts/release.mjs` — Developer ID-sign + notarize + staple `Atbotify.app` →
  `dist/Atbotify-<version>.zip`. `.github/workflows/release.yml` runs it on a `v*` tag and
  publishes the GitHub Release; `ci.yml` compiles the builder on push/PR.
  `scripts/set-github-secrets.mjs` uploads the five `APPLE_*` repo secrets. Details:
  `docs/RELEASING.md`.
- `README.md` — human-facing overview. Memory: `tweetbot-atproto-project` in the auto-memory.

## Done

- **Reads** (home/mentions/user timelines, profiles, users/show), **feeds+lists** in the
  dropdown, **in-app OAuth** (one click, no browser), account **persistence**, and the
  **in-process bridge** (no Node in the shipping app).
- **Write actions**: post (with link/mention facets)/like/repost/follow/delete via
  `com.atproto.repo.*` + `app.bsky.*` (shapes stash `_atproto_uri`/`_cid`/`_did`/`_handle`
  for write-backs; registries `resolvePostRef`/`resolveActor` map numeric ids back). Optimistic
  like/repost echoes; a just-posted skeet is synthesized locally (AppView indexing lags a
  re-fetch). **Web permalinks** (bsky.app) for Copy Link / Open in Browser.
- **Search**: posts (with Twitter operators), people, trends (served from their trending
  feeds), saved searches (local), and quote-posts of yours mixed into Mentions.
- **People**: the Likes tab, Followers / Following lists (+ `users/lookup`), profile relationship
  ("Follows you", blocking, muting) and Retweeted by.
- **DMs**: threads, send, delete-for-yourself, shared posts, read state synced both ways, and
  `can_dm` from the recipient's `allowIncoming` chat setting.
- **Dependency-free injection**: PTHCommon has ~5 KB header padding (the main binary has 16
  bytes), so `inject-framework.mjs` adds the `LC_LOAD_DYLIB` in place — no LIEF, no relocation.
  `DYLD_INSERT_LIBRARIES` is out (the sandboxed/signed binary is "restricted", dyld strips it).
- **Native builder**: `builder/` (Swift engine + AppKit GUI, bundles the precompiled dylib) —
  end users need only macOS (`ditto` + `codesign` ship with the OS). Locally-built apps carry
  no quarantine flag, so the ad-hoc `atbot.app` launches. `Atbotify.app` itself is Developer
  ID-signed + notarized by `scripts/release.mjs` (any new Mach-O in the bundle must be added to
  its signing step or notarization rejects the build).

## Still TODO

- Media upload (posts and DMs), richer notifications. Search: `OR` queries (Bluesky can't),
  and the UI still says "Search Twitter".
- **Per-account persistence**: give the rest of `<tid>.accountd` a writable home (see the App
  Group bullet), after making the bridge's post/actor registries survive relaunches.
- **Sync the Node prototype**: lists + web-permalink helpers were added to `bridge.m` only; the
  `bridge/*.mjs` prototype lacks them. Mirror if you iterate there.

## Conventions

- Prefer Node for tooling/scripts where there's a choice.
- Never commit credentials. Keep them in a gitignored `./atproto.json` (session-only in chat).
- When you change bridge behavior, update **both** `bridge.m` and the `bridge/*.mjs` prototype
  (shipping app = `bridge.m`; the prototype is for fast iteration).
