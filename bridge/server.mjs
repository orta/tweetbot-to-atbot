// server.mjs — the fake-Twitter bridge. Tweetbot (via the injected redirector)
// sends Twitter 1.1 API requests here; we answer with Twitter-shaped JSON backed
// by atproto. Dependency-free (node:http + global fetch).
//
// Config via env:
//   BRIDGE_PORT          (default 8080)
//   BRIDGE_HANDLE        e.g. alice.bsky.social
//   BRIDGE_APP_PASSWORD  an app password (Settings -> App Passwords in Bluesky)
//   BRIDGE_PDS           default https://bsky.social
import http from "node:http";
import { AtpClient } from "./atproto.mjs";
import { userFromProfile, statusFromFeedItem, stableId, resolveActor, registerActor, resolvePostRef, cardForId, buildFacets, twitterList, findList, listViewName, numId, snowflakeId, keyHash, tidMs, isoMs, postId, dmEvent, dmEventId, dmOtherDid } from "./shapes.mjs";
import fs from "node:fs";
import { quotedPost, TWITTER_DATE, hlsMasterForTweetbot } from "./shapes.mjs";

const PORT = Number(process.env.BRIDGE_PORT || 8080);
const atp = new AtpClient({ pds: process.env.BRIDGE_PDS || "https://bsky.social" });
let ready = false;

async function boot() {
  const id = process.env.BRIDGE_HANDLE;
  const pw = process.env.BRIDGE_APP_PASSWORD;
  if (!id || !pw) {
    console.warn("[bridge] BRIDGE_HANDLE / BRIDGE_APP_PASSWORD not set — auth endpoints will be stubbed, reads will fail");
    return;
  }
  await atp.login(id, pw);
  ready = true;
  console.log(`[bridge] logged in as ${atp.session.handle} (${atp.session.did})`);
}

// ---- route table: Twitter 1.1 path -> handler -------------------------------
// Each handler returns a JS value (serialized as JSON) or throws for 500.
// Parse oauth_* params out of an OAuth 1.0a Authorization header.
function parseOAuthHeader(req) {
  const h = req.headers["authorization"] || "";
  const out = {};
  for (const m of h.matchAll(/(oauth_[a-z_]+)="([^"]*)"/g)) out[m[1]] = decodeURIComponent(m[2]);
  return out;
}
let pendingCallback = null; // oauth_callback captured from request_token
// Tweetbot keys its in-flight OAuth request by the `uuid` it sent in the
// request_token multipart body. The browser authorize step must bounce back to
// the app with that SAME uuid in the callback URL, or handleOAuthURL can't find
// the in-flight request and its completion block hits a nil key (crash).
let lastOAuthUuid = null;

const routes = [
  // --- debug: current OAuth callback URL (for manual delivery when the browser
  //     blocks the JS redirect). Not part of the Twitter API surface. ---
  ["GET", /\/__callback$/, () => text(
    `atbot:///request_token?oauth_token=bridge-req-token&oauth_verifier=bridgeverifier&uuid=${encodeURIComponent(lastOAuthUuid || "")}`
  )],

  // --- Tweetbot's own fetch of a Bluesky HLS master playlist, sent here by redirect.m:
  //     rewrite it into the shape Tweetbot's m3u8 parser reads (hlsMasterForTweetbot). ---
  ["GET", /\/__hls\/playlist\.m3u8$/, async (q) => {
    const src = new URL(q.url || "", "http://invalid");
    const host = src.hostname.toLowerCase();
    if (src.protocol !== "https:" || !(host === "bsky.app" || host.endsWith(".bsky.app"))) {
      return { __raw: true, status: 400, body: "", ct: "text/plain" };
    }
    const r = await fetch(src);
    if (!r.ok) return { __raw: true, status: r.status, body: "", ct: "text/plain" };
    return text(hlsMasterForTweetbot(await r.text(), src.href), "application/vnd.apple.mpegurl");
  }],

  // --- OAuth 1.0a bootstrap: fake just enough for "Add Account" to complete ---
  ["POST", /\/oauth\/request_token$/, (q, req) => {
    const o = parseOAuthHeader(req);
    pendingCallback = o.oauth_callback || "oob";
    if (req._fields?.uuid) lastOAuthUuid = req._fields.uuid; // remember for the callback
    console.log(`[bridge] request_token: callback=${pendingCallback} uuid=${lastOAuthUuid}`);
    console.log(`[bridge]   authorization: ${req.headers["authorization"] || "(none)"}`);
    // Tapbots proxy (/tweetbot/N/oauth/...) uses its own JSON keys (token/secret),
    // not Twitter's form-encoded oauth_token. Twitter-direct path keeps the form.
    if (req.url.includes("/tweetbot/")) {
      const handle = atp.session?.handle || "orta.io";
      const did = atp.session?.did || "did:bridge";
      // Same id scheme as userFromProfile (stableId of the DID) so the account's
      // user_id matches the one Tweetbot later sees in the timeline/profile.
      const userId = stableId(did);
      return json({
        token: "bridge-req-token", secret: "bridge-req-secret",
        oauth_token: "bridge-req-token", oauth_token_secret: "bridge-req-secret",
        screen_name: handle, username: handle, user_id: userId, id: userId, id_str: userId,
      });
    }
    return text("oauth_token=bridge-req-token&oauth_token_secret=bridge-req-secret&oauth_callback_confirmed=true");
  }],
  ["GET", /\/oauth\/authorize$/, (q) => {
    // The browser authorize step: bounce straight into Tweetbot's URL scheme so
    // handleOAuthURL: fires with a verifier and Tweetbot proceeds to access_token.
    // No oauth_token is in the incoming URL (Tapbots proxy flow), so we supply the
    // one we handed out at request_token. Try a plain tweetbot:// callback first.
    const token = q.oauth_token || "bridge-req-token";
    const verifier = "bridgeverifier";
    const uuid = q.uuid || lastOAuthUuid || "";
    // Our re-identified app registers the atbot:// scheme, so the callback returns
    // to the patched copy (not the original /Applications/Tweetbot.app). The path's
    // first component MUST be `request_token` (PTHTweetbotURLController routes OAuth
    // only then), and the `uuid` MUST match the in-flight request's uuid or the
    // account-creation completion crashes on a nil key.
    const cb = `atbot:///request_token?oauth_token=${encodeURIComponent(token)}` +
      `&oauth_verifier=${verifier}&uuid=${encodeURIComponent(uuid)}`;
    console.log(`[bridge] authorize -> callback ${cb}`);
    // A small HTML page that navigates to the scheme (and shows a manual link).
    return text(
      `<!doctype html><meta charset=utf-8><body style="font:15px -apple-system;padding:2em">` +
      `<script>location.href=${JSON.stringify(cb)}</script>` +
      `<h2>Authorizing…</h2><p>If nothing happens, <a href="${cb}">return to Tweetbot</a>.</p>` +
      `</body>`,
      "text/html"
    );
  }],
  ["POST", /\/oauth\/access_token$/, (q, req) => {
    const did = atp.session?.did || "did:bridge:unknown";
    const handle = atp.session?.handle || "bridge.local";
    // same id scheme as userFromProfile so the stored account id is consistent
    const userId = stableId(did);
    if (req.url.includes("/tweetbot/")) {
      // superset of field-name variants so Tweetbot's account-creation (which reads
      // several keys and crashes on a nil one) finds everything it looks up.
      return json({
        token: "bridge-access-token",
        secret: "bridge-access-secret",
        oauth_token: "bridge-access-token",
        oauth_token_secret: "bridge-access-secret",
        user_id: userId,
        id: userId,
        id_str: userId,
        screen_name: handle,
        username: handle,
        name: "Orta Therox",
      });
    }
    return text(`oauth_token=bridge-access-token&oauth_token_secret=bridge-access-secret&user_id=${userId}&screen_name=${encodeURIComponent(handle)}`);
  }],

  // --- account identity ---
  ["GET", /\/1\.1\/account\/verify_credentials\.json/, async () => {
    const me = await atp.view("app.bsky.actor.getProfile", { params: { actor: atp.session.did } });
    return userFromProfile(me);
  }],
  ["POST", /\/1\.1\/account\/update_profile\.json/, async () => {
    const me = await atp.view("app.bsky.actor.getProfile", { params: { actor: atp.session.did } });
    return userFromProfile(me);
  }],

  // --- writes (post / like / repost / follow / delete) ---
  ["POST", /\/1\.1\/statuses\/update\.json/, async (q, req) => {
    const p = mergedParams(q, req);
    const text = p.status || "";
    const facets = await buildFacets(text, (h) => atp.resolveHandleToDid(h));
    const record = { $type: "app.bsky.feed.post", text, createdAt: new Date().toISOString() };
    if (facets.length) record.facets = facets;
    const parent = resolvePostRef(p.in_reply_to_status_id || p.in_reply_to_status_id_str);
    if (parent) record.reply = { parent: { uri: parent.uri, cid: parent.cid }, root: { uri: parent.rootUri, cid: parent.rootCid } };
    const created = await atp.createRecord("app.bsky.feed.post", record);
    return synthStatus(created.uri, created.cid, record);
  }],
  ["POST", /\/1\.1\/favorites\/create\.json/, async (q, req) => {
    const ref = resolvePostRef(mergedParams(q, req).id);
    if (!ref) throw new Error("unknown status");
    await atp.createRecord("app.bsky.feed.like", { $type: "app.bsky.feed.like", subject: { uri: ref.uri, cid: ref.cid }, createdAt: new Date().toISOString() });
    return statusForUri(ref.uri);
  }],
  ["POST", /\/1\.1\/favorites\/destroy\.json/, async (q, req) => {
    const ref = resolvePostRef(mergedParams(q, req).id);
    const post = ref && (await atp.getPost(ref.uri));
    if (post?.viewer?.like) await atp.deleteAtUri(post.viewer.like);
    return ref ? statusForUri(ref.uri) : {};
  }],
  ["POST", /\/1\.1\/statuses\/retweet\/(\d+)\.json/, async (q, req, m) => {
    const ref = resolvePostRef(m[1]);
    if (!ref) throw new Error("unknown status");
    await atp.createRecord("app.bsky.feed.repost", { $type: "app.bsky.feed.repost", subject: { uri: ref.uri, cid: ref.cid }, createdAt: new Date().toISOString() });
    return statusForUri(ref.uri);
  }],
  ["POST", /\/1\.1\/statuses\/unretweet\/(\d+)\.json/, async (q, req, m) => {
    const ref = resolvePostRef(m[1]);
    const post = ref && (await atp.getPost(ref.uri));
    if (post?.viewer?.repost) await atp.deleteAtUri(post.viewer.repost);
    return ref ? statusForUri(ref.uri) : {};
  }],
  ["POST", /\/1\.1\/statuses\/destroy\/(\d+)\.json/, async (q, req, m) => {
    const ref = resolvePostRef(m[1]);
    if (ref) await atp.deleteAtUri(ref.uri);
    return ref ? statusForUri(ref.uri) : {};
  }],
  ["POST", /\/1\.1\/friendships\/create\.json/, async (q, req) => {
    const p = mergedParams(q, req);
    const actor = resolveActor(p.screen_name || p.user_id, null);
    const prof = actor && (await atp.view("app.bsky.actor.getProfile", { params: { actor } }));
    if (prof?.did) await atp.createRecord("app.bsky.graph.follow", { $type: "app.bsky.graph.follow", subject: prof.did, createdAt: new Date().toISOString() });
    return prof ? userFromProfile(prof) : {};
  }],
  ["POST", /\/1\.1\/friendships\/destroy\.json/, async (q, req) => {
    const p = mergedParams(q, req);
    const actor = resolveActor(p.screen_name || p.user_id, null);
    const prof = actor && (await atp.view("app.bsky.actor.getProfile", { params: { actor } }));
    if (prof?.viewer?.following) await atp.deleteAtUri(prof.viewer.following);
    return prof ? userFromProfile(prof) : {};
  }],

  // --- timelines ---
  ["GET", /\/1\.1\/statuses\/home_timeline\.json/, (q) =>
    pagedFeed("home", q, false, viewFetch("app.bsky.feed.getTimeline", { limit: clampCount(q.count) }))],
  ["GET", /\/1\.1\/statuses\/user_timeline\.json/, async (q) => {
    // Tweetbot's reply-thread loader (_PTHTweetbotStatusPossibleReplyCursor): an
    // author's timeline since <opened post id> - 1, include_rts=0, from which it keeps
    // any reply that isn't the post itself. Hand it the whole reply tree under the
    // post (its result set dedupes across the per-author calls). A plain profile
    // refresh's since_id is a real post id, so since_id + 1 never resolves for it.
    if (cardForId(q.user_id)) return []; // a link card's "author" has no posts
    const openedId = q.include_rts === "0" ? openedIdForSinceId(q.since_id) : null;
    if (openedId) return q.max_id ? [] : threadReplyStatuses(openedId, false);
    const actor = resolveActor(q.screen_name || q.user_id, atp.session.did);
    return pagedFeed(`author:${actor}`, q, false, viewFetch("app.bsky.feed.getAuthorFeed", { actor, limit: clampCount(q.count) }));
  }],
  ["GET", /\/1\.1\/statuses\/mentions_timeline\.json/, async (q) => {
    const r = await atp.view("app.bsky.notification.listNotifications", { params: { limit: clampCount(q.count) } });
    // Notifications carry only the raw record (no embed views / counts): hydrate via
    // getPosts for images, quotes and like/repost/reply counts.
    const ns = (r.notifications || []).filter((n) => n.reason === "mention" || n.reason === "reply");
    const hydrated = await atp.getPostsMap(ns.map((n) => n.uri).filter(Boolean)).catch(() => new Map());
    return statusesInRange(ns.map((n) => statusFromFeedItem({ post: hydrated.get(n.uri) || { ...n, record: n.record, author: n.author, uri: n.uri, cid: n.cid } })), q);
  }],

  // --- search. The detail view's reply lookup (_PTHTweetbotStatusReplySearchCursor):
  // q="to:<author> AND filter:replies", since_id = <post id> - 1; it keeps results whose
  // in_reply_to_status_id is the post. Everything else is a real search (searchStatuses).
  ["GET", /\/1\.1\/search\/tweets\.json/, async (q) => {
    const openedId = String(q.q || "").includes("filter:replies") ? openedIdForSinceId(q.since_id) : null;
    const statuses = openedId ? (q.max_id ? [] : await threadReplyStatuses(openedId, true)) : await searchStatuses(q);
    return { statuses, search_metadata: { count: statuses.length, query: q.q || "", since_id_str: q.since_id || "0" } };
  }],
  ["GET", /\/1\.1\/users\/search\.json/, (q) => searchUsers(q.q)],
  // Trends: one worldwide place (Bluesky's trends aren't per-location).
  ["GET", /\/1\.1\/trends\/(available|closest)\.json/, () => [{
    name: "Worldwide", woeid: 1, parentid: 0, country: "", countryCode: null,
    url: "http://where.yahooapis.com/v1/place/1", placeType: { code: 19, name: "Supername" },
  }]],
  ["GET", /\/1\.1\/trends\/place\.json/, async () => {
    const trends = await loadTrends();
    const now = new Date().toISOString();
    return [{ trends, as_of: now, created_at: now, locations: [{ name: "Worldwide", woeid: 1 }] }];
  }],
  // Saved searches (stored locally, see savedSearchCreate).
  ["GET", /\/1\.1\/saved_searches\/list\.json/, () => readSavedSearches().map(savedSearchJSON)],
  ["POST", /\/1\.1\/saved_searches\/create\.json/, (q, req) => {
    const query = String(mergedParams(q, req).query || "").trim();
    if (!query) throw new Error("missing query");
    return savedSearchCreate(query);
  }],
  ["GET", /\/1\.1\/saved_searches\/show\/(\d+)\.json/, (q, req, m) => savedSearchFind(m[1], false) || notFound()],
  ["POST", /\/1\.1\/saved_searches\/destroy\/(\d+)\.json/, (q, req, m) => savedSearchFind(m[1], true) || notFound()],

  // --- single statuses (detail-view refresh, quoted/linked posts). Tweetbot MERGES
  // the result into its cached status, so an empty {} wiped media/quotes/counts.
  ["GET", /\/1\.1\/statuses\/show(?:\/(\d+))?\.json/, async (q, req, m) => {
    const sid = String(q.id || m[1] || "");
    if (cardForId(sid)) return cardForId(sid); // link cards aren't posts: echo what we served
    const ref = resolvePostRef(sid);
    const post = ref && (await atp.getPost(ref.uri));
    if (!post) return notFound();
    return statusFromFeedItem({ post, ...(ref.reason ? { reason: ref.reason } : {}), _id: sid });
  }],
  // +[PTHTweetbotStatus lookup:result:] (which every search result goes through) POSTs
  // this with map=true and reads only Twitter's map shape, { id: { <id>: status | null } };
  // given an array it "fails to find" them all and the search shows nothing.
  ...["GET", "POST"].map((method) => [method, /\/1\.1\/statuses\/lookup\.json/, async (q, req) => {
    const p = mergedParams(q, req);
    const ids = String(p.id || "").split(",").filter(Boolean);
    const refs = ids.map(resolvePostRef);
    const hydrated = await atp.getPostsMap([...new Set(refs.filter(Boolean).map((r) => r.uri))]);
    const found = ids.map((sid, i) => [sid, cardForId(sid) || (refs[i] && hydrated.has(refs[i].uri)
      ? statusFromFeedItem({ post: hydrated.get(refs[i].uri), ...(refs[i].reason ? { reason: refs[i].reason } : {}), _id: sid }) : null)]);
    if (p.map === "true") return { id: Object.fromEntries(found) };
    return found.map(([, s]) => s).filter(Boolean);
  }]),

  // --- lists = Bluesky saved feeds + lists (Tweetbot's timeline title dropdown) ---
  ["GET", /\/1\.1\/lists\/list\.json/, (q) => loadLists(q.user_id)],
  ["GET", /\/1\.1\/lists\/statuses\.json/, async (q) => {
    const entry = await resolveList(q);
    const isList = entry.kind === "list";
    // List feeds are chronological; feed generators may be ranked (Discover).
    return pagedFeed(entry.uri, q, !isList, viewFetch(isList ? "app.bsky.feed.getListFeed" : "app.bsky.feed.getFeed",
      { [isList ? "list" : "feed"]: entry.uri, limit: clampCount(q.count) }));
  }],
  ["GET", /\/1\.1\/lists\/show\.json/, async (q) => (await resolveList(q)).json],
  ["GET", /\/1\.1\/lists\/(members|subscribers)\.json/, async (q, req) => {
    const entry = await resolveList(q).catch(() => null);
    let users = [];
    // Real members only exist for Bluesky lists; feed generators are algorithms.
    if (entry?.kind === "list" && req.url.includes("/members")) {
      const r = await atp.view("app.bsky.graph.getList", { params: { list: entry.uri, limit: 100 } });
      users = (r.items || []).map((it) => userFromProfile(it.subject));
    }
    return { users, next_cursor: 0, next_cursor_str: "0", previous_cursor: 0, previous_cursor_str: "0" };
  }],

  // --- people: the Likes tab, Followers / Following, relationship, Retweeted by ---
  ["GET", /\/1\.1\/favorites\/list\.json/, (q) => {
    // getActorLikes only answers for the signed-in user: Bluesky likes aren't browsable
    // per profile, so anyone else's Likes tab is empty.
    if (peopleActor(q.screen_name || q.user_id) !== atp.session.did &&
        String(q.screen_name || "").toLowerCase() !== String(atp.session.handle || "").toLowerCase()) return [];
    return pagedFeed("likes", q, false, likesFetch(clampCount(q.count)));
  }],
  ["GET", /\/1\.1\/(followers|friends)\/ids\.json/, (q, req, m) => {
    const actor = peopleActor(q.screen_name || q.user_id);
    if (!actor) return emptyIdsPage();
    return m[1] === "followers"
      ? peopleIdsPage("app.bsky.graph.getFollowers", { actor }, "followers", q.cursor)
      : peopleIdsPage("app.bsky.graph.getFollows", { actor }, "follows", q.cursor);
  }],
  ["GET", /\/1\.1\/statuses\/retweeters\/ids\.json/, (q) => {
    const ref = resolvePostRef(q.id);
    return ref ? peopleIdsPage("app.bsky.feed.getRepostedBy", { uri: ref.uri }, "repostedBy", q.cursor) : emptyIdsPage();
  }],
  ...["GET", "POST"].map((method) => [method, /\/1\.1\/users\/lookup\.json/, (q, req) => {
    const p = mergedParams(q, req);
    return lookupUsers(p.user_id, p.screen_name);
  }]),
  ["GET", /\/1\.1\/friendships\/show\.json/, async (q) => {
    const actor = q.target_screen_name ? resolveActor(q.target_screen_name, null) : peopleActor(q.target_id);
    if (!actor) return notFound();
    return relationshipJSON(await atp.view("app.bsky.actor.getProfile", { params: { actor } }));
  }],

  // --- direct messages (chat.bsky.convo.*), see dmEventsPage ---
  ["GET", /\/1\.1\/direct_messages\/events\/list\.json/, (q) => dmEventsPage(q.cursor, q.count ? clampCount(q.count) : 50)],
  ["GET", /\/1\.1\/direct_messages\/events\/show\.json/, async (q) => {
    const ev = await dmLookupEvent(q.id);
    const c = ev && (dmConvos || []).find((x) => x.id === ev.convoId);
    const m = c && (await dmMessages(c)).find((x) => x.id === ev.messageId);
    return m ? { event: toDMEvent(c, m) } : notFound();
  }],
  // PTHTweetbotDirectMessageDraft post:completion: POSTs JSON { event: { type, message_create:
  // { target: { recipient_id }, message_data: { text[, attachment] } } } } and reads { event }.
  ["POST", /\/1\.1\/direct_messages\/events\/new\.json/, async (q, req) => {
    let body = {};
    try { body = JSON.parse(req._body || "{}"); } catch {}
    const mc = body?.event?.message_create;
    if (!mc?.message_data) throw new Error("malformed direct message");
    if (mc.message_data.attachment) throw new Error("Sending media in DMs isn't supported yet");
    const rid = String(mc.target?.recipient_id ?? "");
    const recipient = async () => {
      const a = rid && rid !== selfUserId() ? resolveActor(rid, null) : null;
      return a ? (a.startsWith("did:") ? a : await atp.resolveHandleToDid(a)) : null;
    };
    let other = await recipient();
    if (!other) { await dmLoadConvos(); other = await recipient(); } // e.g. a thread restored from a previous run
    if (!other) throw new Error("unknown recipient");
    const { convo } = await atp.chat("chat.bsky.convo.getConvoForMembers", { params: { members: [other] } });
    const text = String(mc.message_data.text || "");
    const facets = await buildFacets(text, (h) => atp.resolveHandleToDid(h));
    const sent = await atp.chat("chat.bsky.convo.sendMessage", { method: "POST", body: { convoId: convo.id, message: { text, ...(facets.length ? { facets } : {}) } } });
    return { event: toDMEvent(convo, sent) };
  }],
  // Bluesky only deletes a message for yourself, as Twitter did.
  ["DELETE", /\/1\.1\/direct_messages\/events\/destroy\.json/, async (q) => {
    const ev = await dmLookupEvent(q.id);
    if (!ev) return notFound();
    await atp.chat("chat.bsky.convo.deleteMessageForSelf", { method: "POST", body: { convoId: ev.convoId, messageId: ev.messageId } });
    dmMessageCache.delete(ev.convoId); // refetch without it
    return { __raw: true, status: 204, body: "", ct: "application/json" };
  }],

  // --- user lookup ---
  ["GET", /\/1\.1\/users\/show\.json/, async (q) => {
    if (cardForId(q.user_id)) return cardForId(q.user_id).user;
    const actor = resolveActor(q.screen_name || q.user_id, atp.session.did);
    const me = await atp.view("app.bsky.actor.getProfile", { params: { actor } });
    return userFromProfile(me);
  }],
];

// The user's saved feeds + lists as Twitter lists: pinned first, in the Bluesky
// app's tab order. The "timeline"/following entry is the home timeline, so skip it.
// `accountId` is the numeric id Tweetbot knows the account by (sent as user_id); the
// lists are attributed to that user so Tweetbot treats them as owned.
async function loadLists(accountId) {
  const prefs = await atp.call("app.bsky.actor.getPreferences"); // served by the PDS itself
  const all = prefs.preferences || [];
  let saved = all.find((p) => p.$type === "app.bsky.actor.defs#savedFeedsPrefV2")?.items || [];
  const v1 = all.find((p) => p.$type === "app.bsky.actor.defs#savedFeedsPref");
  if (!saved.length && v1) { // legacy pref: plain uri arrays
    const pinned = v1.pinned || [];
    saved = [...pinned.map((value) => ({ value, pinned: true })),
      ...(v1.saved || []).filter((u) => !pinned.includes(u)).map((value) => ({ value, pinned: false }))];
  }
  const ordered = [...saved.filter((i) => i.pinned), ...saved.filter((i) => !i.pinned)]
    .filter((i) => String(i.value).startsWith("at://"))
    .map((i) => ({ uri: i.value, kind: i.value.includes("/app.bsky.graph.list/") ? "list" : "feed" }));
  const feedUris = ordered.filter((o) => o.kind === "feed").map((o) => o.uri);
  const views = new Map();
  if (feedUris.length) {
    const r = await atp.view("app.bsky.feed.getFeedGenerators", { params: { feeds: feedUris } });
    for (const f of r.feeds || []) views.set(f.uri, f);
  }
  const found = [];
  for (const o of ordered) {
    let view = views.get(o.uri);
    if (!view && o.kind === "list") {
      view = (await atp.view("app.bsky.graph.getList", { params: { list: o.uri, limit: 1 } }).catch(() => null))?.list;
    }
    if (view) found.push({ view, kind: o.kind }); // deleted feeds drop out
  }
  const me = await atp.view("app.bsky.actor.getProfile", { params: { actor: atp.session.did } });
  const owner = userFromProfile(me);
  if (accountId) { owner.id_str = String(accountId); owner.id = Number(accountId); }
  const count = (n) => found.filter((f) => listViewName(f.view) === n).length;
  return found.map(({ view, kind }) => {
    let name = listViewName(view);
    // Two saved feeds can share a name (e.g. two "Mutuals") — tell them apart by creator.
    if (count(name) > 1 && view.creator?.handle) name = `${name} (${view.creator.handle})`;
    return twitterList(view, kind, name, owner);
  });
}
// Tweetbot remembers the selected list across launches, so a registry miss
// reloads the saved feeds before giving up.
async function resolveList(q) {
  let entry = findList(q);
  if (!entry) { await loadLists(q.user_id); entry = findList(q); }
  if (!entry) throw new Error("unknown list");
  return entry;
}

// ---- threads (replies under a post) ----
// Twitter had no "replies to X" endpoint, so when a post's detail view opens Tweetbot
// (PTHTweetbotStatus(ThreadCategory) loadReplyThreads:) fakes one with two requests,
// both carrying since_id = <post id> - 1: search/tweets.json (first-level replies) and
// user_timeline.json include_rts=0 per author (deeper replies, which it chains into
// threads by in_reply_to_status_id). Both are answered from getPostThread.

// The id of the post the reply loaders are asking about: since_id is it minus one.
// Only meaningful if it's in the post registry (a real refresh's since_id + 1 isn't).
function openedIdForSinceId(sinceId) {
  if (!/^\d+$/.test(String(sinceId || ""))) return null;
  const id = (BigInt(sinceId) + 1n).toString();
  return resolvePostRef(id) ? id : null;
}

// Every reply under `uri` as { post, depth } (1 = direct reply). Cached briefly: one
// detail view asks for the same thread several times (search + a timeline per author).
const threadCache = new Map(); // uri -> { at, replies }
async function threadReplies(uri) {
  const hit = threadCache.get(uri);
  if (hit && Date.now() - hit.at < 30_000) return hit.replies;
  const r = await atp.view("app.bsky.feed.getPostThread", { params: { uri, depth: 10, parentHeight: 0 } });
  const replies = [];
  const walk = (node, depth) => {
    for (const child of node?.replies || []) {
      if (!child?.post) continue; // notFoundPost / blockedPost
      replies.push({ post: child.post, depth });
      walk(child, depth + 1);
    }
  };
  walk(r.thread, 1);
  threadCache.set(uri, { at: Date.now(), replies });
  return replies;
}

// Replies under the opened post as Twitter statuses; `directOnly` keeps first-level
// ones. Direct replies point in_reply_to_status_id at `openedId` — the id Tweetbot
// holds for the post — so linkage survives however that id was minted.
async function threadReplyStatuses(openedId, directOnly) {
  const replies = await threadReplies(resolvePostRef(openedId).uri);
  return replies.filter((r) => !directOnly || r.depth === 1).map((r) => {
    const s = statusFromFeedItem({ post: r.post });
    return r.depth === 1 ? { ...s, in_reply_to_status_id: numId(openedId), in_reply_to_status_id_str: openedId } : s;
  });
}

// ---- search (search/tweets, users/search, trends, saved searches) ----
// Tweetbot's search (PTHTweetbotStatusSearchCursor) sends q = "<what you typed>
// -filter:retweets" with result_type=recent&count=100 and pages it by id like any
// timeline (PTHTweetbotTIDCursorPager). app.bsky.feed.searchPosts speaks most of the same
// operators (from: to: mentions: since: until: lang: domain: #tag "phrase") but none of
// Twitter's filter:/min_* ones and no OR, so those come out of the query and run as tests
// on the results instead.

// The post's embed (or, for a quote with media, its media part) has view type `type`.
const postHasEmbed = (p, type) => p?.embed?.$type === type || p?.embed?.media?.$type === type;
const postHasLink = (p) => postHasEmbed(p, "app.bsky.embed.external#view") ||
  (p?.record?.facets || []).some((f) => (f?.features || []).some((x) => x?.$type === "app.bsky.richtext.facet#link"));
const hasImages = (p) => postHasEmbed(p, "app.bsky.embed.images#view");
const hasVideo = (p) => postHasEmbed(p, "app.bsky.embed.video#view");
// Twitter `filter:<name>` -> a test on a post view.
const SEARCH_FILTERS = new Map([
  ["replies", (p) => !!p?.record?.reply],
  ["images", hasImages], ["twimg", hasImages],
  ["videos", hasVideo], ["native_video", hasVideo],
  ["media", (p) => hasImages(p) || hasVideo(p)],
  ["links", postHasLink],
  ["quote", (p) => !!quotedPost(p?.embed)],
]);
const COUNT_OPS = new Map([["min_faves", "likeCount"], ["min_retweets", "repostCount"], ["min_replies", "replyCount"]]);

// Twitter search query -> { bq: searchPosts q, tests: [post => bool] for what Bluesky lacks }.
function blueskySearchQuery(q) {
  const terms = [], tests = [];
  for (const tok of String(q).match(/-?"[^"]*"|\S+/g) || []) {
    if (tok === "AND") continue; // implicit in both
    const neg = tok.length > 1 && tok.startsWith("-");
    const body = neg ? tok.slice(1) : tok;
    const i = body.indexOf(":");
    const op = i >= 0 ? body.slice(0, i).toLowerCase() : null, arg = i >= 0 ? body.slice(i + 1) : "";
    if (op === "filter" || op === "exclude" || op === "include") {
      // Search never returns reposts (so -filter:retweets, which Tweetbot always
      // appends, holds anyway); unsupported filters are dropped, not searched for.
      const t = /retweets$/i.test(arg) || op === "include" ? null : SEARCH_FILTERS.get(arg.toLowerCase());
      if (t) tests.push(neg || op === "exclude" ? (p) => !t(p) : t);
      continue;
    }
    if (COUNT_OPS.has(op)) {
      const key = COUNT_OPS.get(op), n = parseInt(arg, 10) || 0;
      tests.push((p) => ((p?.[key] || 0) >= n) !== neg);
      continue;
    }
    if (op === "url" && arg) { terms.push(`${neg ? "-" : ""}domain:${arg.split("/")[0]}`); continue; } // Bluesky has domain:
    terms.push(tok);
  }
  return { bq: terms.join(" "), tests };
}

// A fetchPage over searchPosts (posts -> feed items) keeping only posts that pass
// `tests`. pagedFeed stops at an empty page, so a page the tests empty out moves on.
const searchFetch = (bq, sort, limit, tests) => async (cursor) => {
  for (let page = 0; ; page++) {
    const r = await atp.view("app.bsky.feed.searchPosts", { params: { q: bq, sort, limit, ...(cursor ? { cursor } : {}) } });
    const posts = r.posts || [];
    const feed = posts.filter((p) => tests.every((t) => t(p))).map((post) => ({ post }));
    if (feed.length || !r.cursor || !posts.length || page === 2) return { feed, cursor: r.cursor || null };
    cursor = r.cursor;
  }
};

// Handle (or DID) -> DID: the actor registry first, else the public resolver.
async function handleToDid(h) {
  if (!h) return null;
  if (h.startsWith("did:")) return h;
  const known = resolveActor(h, null);
  return known?.startsWith("did:") ? known : atp.resolveHandleToDid(h);
}

// Mentions mixes in quotes of your posts (-[PTHTweetbotCurrentUserMentionsCursor
// _loadQuotesSinceTID:maxTID:block:]): it ORs the links of your recent posts (their
// twitterURL, which redirect.m points at bsky.app) into one search and keeps results that
// quote you. Bluesky answers that directly: app.bsky.feed.getQuotes. A query that is
// nothing but bsky.app post links -> their at:// uris (getQuotes wants the DID form);
// null for any other query.
const BSKY_POST_LINK = /^https?:\/\/(?:www\.)?bsky\.app\/profile\/([^/\s]+)\/post\/([^/\s?#]+)\/?$/i;
async function quotedPostUris(bq) {
  const links = [];
  for (const tok of bq.split(/\s+/)) {
    if (!tok || tok === "OR") continue;
    const m = BSKY_POST_LINK.exec(tok);
    if (!m) return null;
    links.push([m[1], m[2]]);
  }
  if (!links.length) return null;
  const uris = [];
  for (const [actor, rkey] of links) {
    const did = await handleToDid(actor);
    if (did) uris.push(`at://${did}/app.bsky.feed.post/${rkey}`);
  }
  return uris;
}
async function quoteStatuses(uris, q) {
  const seen = new Set(), out = [];
  for (const uri of uris) {
    const r = await atp.view("app.bsky.feed.getQuotes", { params: { uri, limit: 50 } }).catch(() => null);
    for (const post of r?.posts || []) {
      if (!post?.uri || seen.has(post.uri)) continue;
      seen.add(post.uri);
      out.push(statusFromFeedItem({ post }));
    }
  }
  return statusesInRange(out, q);
}

// Trends (the search view's trend list) = Bluesky's trending topics. Each is backed by a
// feed (link "/profile/<did>/feed/<rkey>"), and opening a trend searches its `query`
// (Tweetbot urlDecodes it), so the trend's name maps back to that feed here and the
// search is answered from the feed instead of a text search for the headline.
const trendFeeds = new Map(); // normalized name -> feed uri
const trendKey = (s) => String(s).toLowerCase().split(/\s+/).filter(Boolean).join(" ");
// "/profile/<actor>/feed/<rkey>" -> at://<did>/app.bsky.feed.generator/<rkey>
async function feedUriFromLink(link) {
  const parts = String(link).split("/");
  if (parts.length !== 5 || parts[1] !== "profile" || parts[3] !== "feed" || !parts[4]) return null;
  const did = await handleToDid(parts[2]);
  return did ? `at://${did}/app.bsky.feed.generator/${parts[4]}` : null;
}
async function loadTrends() {
  let items = (await atp.view("app.bsky.unspecced.getTrends", { params: { limit: 25 } }).catch(() => null))?.trends;
  // AppViews without getTrends: topics only (no post counts)
  if (!Array.isArray(items)) items = (await atp.view("app.bsky.unspecced.getTrendingTopics", { params: { limit: 25 } })).topics || [];
  const trends = [];
  for (const t of items) {
    const name = String(t?.displayName || "").trim() || String(t?.topic || "").trim();
    if (!name) continue;
    const link = typeof t.link === "string" ? t.link : "";
    let searchQ = name;
    const feed = await feedUriFromLink(link);
    if (feed) trendFeeds.set(trendKey(name), feed);
    else if (link.startsWith("/search?q=")) { try { searchQ = decodeURIComponent(link.slice(10)); } catch {} }
    trends.push({
      name, query: encodeURIComponent(searchQ), url: `https://bsky.app${link}`,
      tweet_volume: typeof t.postCount === "number" ? t.postCount : null, promoted_content: null,
    });
  }
  return trends;
}

// search/tweets for anything but the reply lookup.
async function searchStatuses(q) {
  const { bq, tests } = blueskySearchQuery(q.q || "");
  if (!bq) return []; // nothing left to search for (searchPosts needs a q)
  const quoted = await quotedPostUris(bq);
  if (quoted) return quoteStatuses(quoted, q);
  const limit = clampCount(q.count);
  const trendFeed = trendFeeds.get(trendKey(bq));
  if (trendFeed) return pagedFeed(trendFeed, q, true, viewFetch("app.bsky.feed.getFeed", { feed: trendFeed, limit }));
  // "popular" is ranked: rank ids keep searchPosts' order through Tweetbot's id sort.
  const sort = q.result_type === "popular" ? "top" : "latest";
  return pagedFeed(`search:${sort}:${q.q || ""}`, q, sort === "top", searchFetch(bq, sort, limit, tests));
}

// users/search (PTHTweetbotUserSearchCursor): only `q`, one page, no paging.
// searchActors returns basic profiles without counts, so hydrate via getProfiles.
async function searchUsers(raw) {
  const q = String(raw || "").trim().replace(/^@/, "");
  if (!q) return [];
  const r = await atp.view("app.bsky.actor.searchActors", { params: { q, limit: 50 } });
  const actors = (r.actors || []).filter((a) => a?.did);
  const full = new Map();
  for (let i = 0; i < actors.length; i += 25) {
    const pr = await atp.view("app.bsky.actor.getProfiles", { params: { actors: actors.slice(i, i + 25).map((a) => a.did) } }).catch(() => null);
    for (const p of pr?.profiles || []) if (p?.did) full.set(p.did, p);
  }
  return actors.map((a) => userFromProfile(full.get(a.did) || a));
}

// ---- people (followers / following / reposted by, users/lookup) ----
// Tweetbot loads every list of people the same way (PTHTweetbotFollowersCursor,
// PTHTweetbotFollowingCursor, PTHTweetbotStatusRetweetsCursor, and the account's background
// follower/friend loaders): an `ids` endpoint answering { ids, next_cursor }
// (PTHTweetbotCursorCursorPager: cursor=-1 first, then next_cursor until it is 0), then a
// users/lookup for the ids it hasn't loaded. atproto pages people with opaque string
// cursors, so each one gets an integer stand-in.
const peopleCursors = new Map(); // integer -> atproto cursor
const selfUserId = () => stableId(atp.session?.did || "did:bridge");

// The DID a people request is about. An unknown numeric id stays unknown (never the
// signed-in user's lists in someone else's profile); the account's own id always resolves.
function peopleActor(param) {
  if (param == null || param === "" || String(param) === selfUserId()) return atp.session.did;
  return resolveActor(param, null);
}

const emptyIdsPage = () => ({ ids: [], next_cursor: 0, next_cursor_str: "0", previous_cursor: 0, previous_cursor_str: "0" });

// One page of the profiles in r[listKey] from `nsid`, as Twitter's ids page. Every actor is
// registered so the users/lookup that follows can map its numeric id back to a DID.
async function peopleIdsPage(nsid, params, listKey, cursorParam) {
  const c = String(cursorParam ?? "");
  // unknown (a cursor saved by a previous launch): start over from the top
  const atCursor = c && c !== "-1" && c !== "0" ? peopleCursors.get(c) : undefined;
  const r = await atp.view(nsid, { params: { ...params, limit: 100, ...(atCursor ? { cursor: atCursor } : {}) } });
  const ids = [];
  for (const a of r[listKey] || []) {
    if (!a?.did) continue;
    registerActor(a.did, a.handle);
    ids.push(Number(stableId(a.did)));
  }
  let nextId = "0";
  if (ids.length && r.cursor) {
    nextId = stableId(r.cursor);
    if (nextId === "0") nextId = "1";
    if (peopleCursors.size > 2000) peopleCursors.clear();
    peopleCursors.set(nextId, r.cursor);
  }
  return { ids, next_cursor: Number(nextId), next_cursor_str: nextId, previous_cursor: 0, previous_cursor_str: "0" };
}

// users/lookup (+[PTHTweetbotUser lookup:result:]): a POST of user_id=<id,…> (up to 100)
// for the users an ids page named that it hasn't loaded. It matches the answer array by
// `id` and marks the rest missing, so ids we can't map to a DID are simply left out.
// getProfiles takes 25 actors per call; the chunks run concurrently.
async function lookupUsers(userIds, screenNames) {
  const split = (s) => String(s || "").split(",").map((x) => x.trim()).filter(Boolean);
  const users = [], actors = [], unknown = [];
  for (const s of split(userIds)) {
    const card = cardForId(s); // a link card's synthetic "author"
    if (card) { users.push(card.user); continue; }
    const a = peopleActor(s);
    if (!a) unknown.push(s);
    else if (!actors.includes(a)) actors.push(a);
  }
  // Ids Tweetbot remembers from a previous run (its stored DM threads) aren't in the
  // in-memory registry yet; listing the DM conversations registers everyone in them.
  if (unknown.length && (await dmReloadPartners()))
    for (const s of unknown) { const a = peopleActor(s); if (a && !actors.includes(a)) actors.push(a); }
  for (const s of split(screenNames)) {
    const a = resolveActor(s, null);
    if (a && !actors.includes(a)) actors.push(a);
  }
  const chunks = [];
  for (let i = 0; i < actors.length; i += 25) chunks.push(actors.slice(i, i + 25));
  const pages = await Promise.all(chunks.map((chunk) => atp.view("app.bsky.actor.getProfiles", { params: { actors: chunk } }).catch(() => null)));
  for (const pr of pages) for (const p of pr?.profiles || []) if (p?.did) users.push(userFromProfile(p));
  return users;
}

// friendships/show (-[PTHTweetbotOtherUser updateRelationship:] reads relationship.source):
// the signed-in user's side of the relationship with the profile `prof`, from its viewer state.
function relationshipJSON(prof) {
  const v = prof?.viewer || {};
  const following = typeof v.following === "string", followedBy = typeof v.followedBy === "string";
  const blocked = typeof v.blocking === "string" || v.blockedBy === true;
  // Who may start a Bluesky chat with them: "all", "following" (people they follow, the
  // default) or "none".
  const allow = prof?.associated?.chat?.allowIncoming || "following";
  const canDM = !blocked && (allow === "all" || (allow === "following" && followedBy));
  const sid = selfUserId(), tid = stableId(prof?.did || "");
  return { relationship: {
    source: {
      id: Number(sid), id_str: sid, screen_name: atp.session?.handle || "",
      following, followed_by: followedBy,
      blocking: typeof v.blocking === "string", blocked_by: v.blockedBy === true, muting: v.muted === true,
      can_dm: canDM,
      want_retweets: true, notifications_enabled: false, all_replies: false, marked_spam: false,
      following_received: false, following_requested: false, live_following: false,
    },
    target: {
      id: Number(tid), id_str: tid, screen_name: prof?.handle || "",
      following: followedBy, followed_by: following, following_received: false, following_requested: false,
    },
  } };
}

// ---- direct messages (chat.bsky.convo.*) ----
// Tweetbot polls direct_messages/events/list.json?count=50[&cursor=] and follows next_cursor
// until it meets a message it already holds (a cold start pages through everything). The
// list is a newest-first merge across the 1:1 conversations, built lazily: a conversation
// whose last message is older than the page's last event can't contribute, so a quiet poll
// costs one listConvos. Messages are cached per conversation by its rev. The dylib also
// syncs read state with Tweetbot's own store and gives it a messages.sql it can open; the
// prototype can't (it runs outside the app). Full notes: inject/bridge.m.
let dmConvos = null;
const dmMessageCache = new Map(); // convo id -> { rev, messages }
const dmEvents = new Map();       // event id -> { convoId, messageId }
let dmPartnersAt = 0, dmIndexedAt = 0;
const dmLastId = (c) => (c.lastMessage ? BigInt(dmEventId(c.id, c.lastMessage)) : 0n);
const byBigIdDesc = (a, b) => (b.id > a.id ? 1 : b.id < a.id ? -1 : 0);
// Run fn over items, `n` at a time (be gentle with the chat service).
async function inBatches(items, n, fn) {
  for (let i = 0; i < items.length; i += n) await Promise.all(items.slice(i, i + n).map(fn));
}

// The 1:1 conversations (Twitter DMs have no groups), newest activity first. Members are
// registered so users/lookup and sending can map numeric ids back to DIDs.
async function dmLoadConvos() {
  const out = [];
  let cursor;
  for (let page = 0; page < 5; page++) {
    const r = await atp.chat("chat.bsky.convo.listConvos", { params: { limit: 100, ...(cursor ? { cursor } : {}) } });
    for (const c of r.convos || []) {
      if ((c.members || []).length !== 2 || !c.id || !dmOtherDid(c, atp.session.did)) continue;
      for (const m of c.members) registerActor(m.did, m.handle);
      out.push(c);
    }
    cursor = r.cursor;
    if (!cursor) break;
  }
  out.sort((a, b) => byBigIdDesc({ id: dmLastId(a) }, { id: dmLastId(b) }));
  return (dmConvos = out);
}
async function dmReloadPartners() {
  if (Date.now() - dmPartnersAt < 60_000) return false;
  dmPartnersAt = Date.now();
  return dmLoadConvos().then(() => true, () => false);
}

// A conversation's messages (newest first, deleted ones dropped), cached by its rev.
async function dmMessages(c) {
  const hit = dmMessageCache.get(c.id);
  if (hit && hit.rev === c.rev) return hit.messages;
  const msgs = [];
  let cursor;
  for (let page = 0; page < 10; page++) {
    const r = await atp.chat("chat.bsky.convo.getMessages", { params: { convoId: c.id, limit: 100, ...(cursor ? { cursor } : {}) } });
    const batch = r.messages || [];
    msgs.push(...batch.filter((m) => m?.$type === "chat.bsky.convo.defs#messageView"));
    cursor = r.cursor;
    if (batch.length < 100 || !cursor) break; // a short page is the rest of the history
  }
  dmMessageCache.set(c.id, { rev: c.rev, messages: msgs });
  return msgs;
}

function toDMEvent(c, m) {
  const ev = dmEvent(c, m, atp.session.did);
  if (dmEvents.size > 20000) dmEvents.clear();
  dmEvents.set(ev.id, { convoId: c.id, messageId: m.id });
  return ev;
}

// One page of events/list: newest first, older than `cursor` (the previous page's last id).
async function dmEventsPage(cursor, count) {
  const before = /^\d+$/.test(cursor || "") ? BigInt(cursor) : 0n;
  const convos = !before || !dmConvos ? await dmLoadConvos() : dmConvos;
  // Tweetbot only pages past the first page on a cold start: it's about to want everything.
  if (before) await inBatches(convos, 8, (c) => dmMessages(c).catch(() => null));
  const cands = [];
  let more = false;
  for (const c of convos) {
    if (cands.length >= count) {
      cands.sort(byBigIdDesc);
      // conversations come newest activity first: this one and all after it are older
      if (dmLastId(c) <= cands[count - 1].id) { more = true; break; }
    }
    for (const m of await dmMessages(c).catch(() => [])) {
      const id = BigInt(dmEventId(c.id, m));
      if (!before || id < before) cands.push({ id, c, m });
    }
  }
  cands.sort(byBigIdDesc);
  if (cands.length > count) more = true;
  const events = cands.slice(0, count).map(({ c, m }) => toDMEvent(c, m));
  return { events, apps: {}, ...(more && events.length ? { next_cursor: events.at(-1).id } : {}) };
}

// The { convoId, messageId } behind an event id. A previous run's id isn't registered
// until served again, so a miss re-indexes every conversation (at most once a minute).
async function dmLookupEvent(id) {
  const key = String(id || "");
  if (!dmEvents.has(key) && key && Date.now() - dmIndexedAt > 60_000) {
    dmIndexedAt = Date.now();
    const convos = await dmLoadConvos();
    await inBatches(convos, 8, async (c) => {
      for (const m of await dmMessages(c).catch(() => [])) dmEvents.set(dmEventId(c.id, m), { convoId: c.id, messageId: m.id });
    });
  }
  return dmEvents.get(key) || null;
}

// The Likes tab (PTHTweetbotFavoritesCursor) pages favorites/list by id like any timeline,
// but likes run in the order they were LIKED. Post ids would re-sort them by post date and
// break paging, so each liked post is served under its like record's TID id (viewer.like
// is our own like record when the viewer is the liker).
const likesFetch = (limit) => async (cursor) => {
  const r = await viewFetch("app.bsky.feed.getActorLikes", { actor: atp.session.did, limit })(cursor);
  return { ...r, feed: (r.feed || []).map((it) => {
    const like = it?.post?.viewer?.like;
    return typeof like === "string" && tidMs(rkeyOf(like)) ? { ...it, _id: postId(like) } : it;
  }) };
};

// Saved searches: Bluesky keeps none server-side, so they live locally (the app uses its
// own defaults; the prototype a gitignored JSON file next to this one). Stored as
// { id, query, createdAt }; id = stableId(query), so saving twice is a no-op.
const SAVED_SEARCHES = new URL("./.saved-searches.json", import.meta.url);
function readSavedSearches() {
  try { const a = JSON.parse(fs.readFileSync(SAVED_SEARCHES, "utf8")); return Array.isArray(a) ? a : []; } catch { return []; }
}
const writeSavedSearches = (all) => fs.writeFileSync(SAVED_SEARCHES, JSON.stringify(all, null, 2));
const savedSearchJSON = (s) => ({
  id: Number(s.id), id_str: String(s.id), name: s.query, query: s.query, created_at: TWITTER_DATE(s.createdAt), position: null,
});
function savedSearchCreate(query) {
  const all = readSavedSearches(), id = stableId(query);
  let s = all.find((x) => String(x.id) === id);
  if (!s) { s = { id, query, createdAt: new Date().toISOString() }; all.push(s); writeSavedSearches(all); }
  return savedSearchJSON(s);
}
// Removes the saved search when `destroy`; returns it (null if unknown).
function savedSearchFind(id, destroy) {
  const all = readSavedSearches(), i = all.findIndex((x) => String(x.id) === String(id));
  if (i < 0) return null;
  const s = all[i];
  if (destroy) { all.splice(i, 1); writeSavedSearches(all); }
  return savedSearchJSON(s);
}

// ---- paging (since_id / max_id over atproto cursors) ----
// Tweetbot pages every timeline by id (-[PTHTweetbotTIDCursorPager ...QueryDictionary]):
// refresh = since_id <newest id>, scroll down = max_id <oldest id - 1>, and when a
// refresh returns >= 10 statuses all newer than what it had it opens a "gap" row, filled
// with max_id <gap's newest - 1> + since_id <gap's oldest - 1>. It reads the response's
// first/last status as its newest/oldest, so answers must be newest first, and anything
// outside (since_id, max_id] must be left out or it re-asks forever. atproto pages with
// opaque cursors, so per timeline we remember the cursor that continues after the oldest
// status of each page we hand out: max_id is then "the page after id max_id + 1".
//
// Ranked feeds (Discover) aren't in time order, and Tweetbot re-sorts by id, so a feed
// whose first page isn't chronological gets RANK ids: a refresh is numbered down from
// "now" in feed order (each new batch sits on top in the feed's own order), pages below
// continue downwards, and a post keeps its rank id so a refresh never shows it twice.
const RANK_STEP = 4096n; // 12 low bits of hash per rank; 1024 ranks per ms
const feedStates = new Map(); // key -> { mode, cursors: Map(id -> cursor), ids: Map(itemKey -> id) }
const isRepost = (it) => it.reason?.$type === "app.bsky.feed.defs#reasonRepost";
const rkeyOf = (uri) => String(uri || "").split("/").pop();
const feedItemMs = (it) => isRepost(it)
  ? tidMs(rkeyOf(it.reason.uri)) || isoMs(it.reason.indexedAt)
  : tidMs(rkeyOf(it.post?.uri)) || isoMs(it.post?.record?.createdAt || it.post?.indexedAt);
function looksChronological(items) {
  let bad = 0, prev = Infinity;
  for (const it of items) { const t = feedItemMs(it); if (t > prev) bad++; prev = t; }
  return bad <= Math.max(1, Math.floor(items.length / 10));
}
const feedItemKey = (it) => !isRepost(it) ? it.post.uri : it.reason.uri || `${it.post.uri}#rt:${it.reason.by?.did || ""}`;
const byIdDesc = (a, b) => (BigInt(b.id_str) > BigInt(a.id_str) ? 1 : BigInt(b.id_str) < BigInt(a.id_str) ? -1 : 0);
const viewFetch = (nsid, params) => (cursor) => atp.view(nsid, { params: { ...params, ...(cursor ? { cursor } : {}) } });

// One Tweetbot page of the timeline `key`; `rankable`: a feed generator (maybe ranked).
async function pagedFeed(key, q, rankable, fetchPage) {
  const since = /^\d+$/.test(q.since_id || "") ? BigInt(q.since_id) : 0n;
  const max = /^\d+$/.test(q.max_id || "") ? BigInt(q.max_id) : 0n;
  let st = feedStates.get(key);
  if (!st) feedStates.set(key, (st = { mode: null, cursors: new Map(), ids: new Map() }));
  // No since_id/max_id = Tweetbot holds nothing for this timeline (first load, or it
  // dropped it): forget which posts it was shown, or a ranked feed comes back empty.
  if (!since && !max) st.ids.clear();
  // A max_id we hold no cursor for falls back to walking down from the top.
  let cursor = max ? st.cursors.get((max + 1n).toString()) : undefined;
  let mode = st.mode, next = null, rank = 0n;
  const top = max ? max + 1n : snowflakeId(Date.now(), 0); // rank ids go below this
  const out = [];
  for (let page = 0; page < 5; page++) {
    let r;
    try { r = await fetchPage(cursor); } catch (e) { if (page === 0) throw e; break; }
    const items = (r.feed || []).filter((it) => it?.post);
    next = r.cursor || null;
    if (!mode) {
      // Judge from a real page only: Discover hands back a near-empty page once it has
      // served you most of what it has. Bluesky's own Discover is ranked regardless.
      const discover = key.endsWith("/app.bsky.feed.generator/whats-hot");
      mode = !rankable ? "time" : discover || (items.length >= 3 && !looksChronological(items)) ? "rank" : "time";
      if (discover || !rankable || items.length >= 10) { st.mode = mode; console.log(`[bridge] feed ${key} -> ${mode} ids`); }
    }
    let reachedSince = false;
    for (const it of items) {
      if (mode === "rank") {
        const k = feedItemKey(it);
        if (st.ids.has(k)) continue; // already in this timeline under its rank id
        const rid = top - (rank + 1n) * RANK_STEP + (keyHash(k) & (RANK_STEP - 1n));
        if (since && rid <= since) { reachedSince = true; break; }
        rank++;
        if (st.ids.size > 5000) st.ids.clear();
        st.ids.set(k, rid.toString());
        out.push(statusFromFeedItem({ ...it, _id: rid.toString() }));
      } else {
        const s = statusFromFeedItem(it);
        const sid = BigInt(s.id_str);
        if (max && sid > max) continue;
        if (since && sid <= since) { reachedSince = true; continue; }
        out.push(s);
      }
    }
    if (out.length || reachedSince || !next || !items.length) break;
    cursor = next; // nothing new on this page (all seen / above max_id): keep going
  }
  out.sort(byIdDesc);
  if (out.length && next) {
    if (st.cursors.size > 500) st.cursors.clear();
    st.cursors.set(out[out.length - 1].id_str, next);
  }
  return out;
}

// Keep statuses inside Tweetbot's (since_id, max_id] window, newest first — for sources
// we don't page (notifications).
function statusesInRange(statuses, q) {
  const since = /^\d+$/.test(q.since_id || "") ? BigInt(q.since_id) : 0n;
  const max = /^\d+$/.test(q.max_id || "") ? BigInt(q.max_id) : 0n;
  return statuses.filter((s) => { const id = BigInt(s.id_str); return !(max && id > max) && !(since && id <= since); }).sort(byIdDesc);
}

function clampCount(c) {
  const n = Number(c) || 40;
  return Math.max(1, Math.min(100, n));
}

// Twitter POST params live in the body (form-urlencoded) or query; merge them.
function mergedParams(q, req) {
  const out = { ...q };
  const b = req?._body || "";
  if (b && !b.includes("Content-Disposition")) {
    for (const pair of b.split("&")) {
      const i = pair.indexOf("=");
      if (i < 0) continue;
      try { out[decodeURIComponent(pair.slice(0, i))] = decodeURIComponent(pair.slice(i + 1).replace(/\+/g, " ")); } catch {}
    }
  }
  return out;
}

async function statusForUri(uri) {
  const post = await atp.getPost(uri);
  return post ? statusFromFeedItem({ post }) : {};
}

// Synthesize a status for a just-created post (AppView indexing lags a re-fetch).
async function synthStatus(uri, cid, record) {
  const me = await atp.view("app.bsky.actor.getProfile", { params: { actor: atp.session.did } }).catch(() => null);
  return statusFromFeedItem({ post: {
    uri, cid, record, author: me || { did: atp.session.did, handle: atp.session.handle },
    replyCount: 0, repostCount: 0, likeCount: 0, indexedAt: record.createdAt,
  } });
}

const text = (body, ct = "text/plain") => ({ __raw: true, body, ct });
// Status ids exceed 2^53, so their numeric fields are BigInts (numId): write those as
// exact JSON integers (Tweetbot reads the numeric in_reply_to_status_id).
const toJSON = (v) => JSON.stringify(v, (k, x) => (typeof x === "bigint" ? `\u0001big:${x}` : x)).replace(/"\\u0001big:(\d+)"/g, "$1");
const json = (obj) => ({ __raw: true, body: toJSON(obj), ct: "application/json" });
const notFound = () => ({ __raw: true, status: 404, body: JSON.stringify({ errors: [{ code: 144, message: "No status found with that ID." }] }), ct: "application/json" });
const redirect = (location) => ({ __redirect: true, location });

const server = http.createServer(async (req, res) => {
  // Twitter's token permission: Tweetbot only enables an account's DMs once a response
  // says "read-write-directmessages" (_PTHTweetbotAccountRequestOperation).
  res.setHeader("X-Access-Level", "read-write-directmessages");
  const u = new URL(req.url, "http://127.0.0.1");
  const q = Object.fromEntries(u.searchParams.entries());
  // capture body for POSTs (oauth/proxy protocol discovery)
  if (req.method === "POST") {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    req._body = Buffer.concat(chunks).toString("utf8");
    // Parse multipart form-data fields into a map so handlers can echo them back.
    // Tweetbot matches a response to its in-flight request by the `uuid` field it
    // sent, so the response MUST echo that uuid (and GUID) or account-creation's
    // completion block removes a nil key and crashes.
    req._fields = {};
    for (const m of req._body.matchAll(/name="([^"]+)"\r?\n\r?\n([\s\S]*?)\r?\n--/g)) {
      req._fields[m[1]] = m[2];
    }
    if (u.pathname.includes("oauth") || u.pathname.includes("account")) {
      const shown = Object.entries(req._fields)
        .map(([k, v]) => `${k}=${k === "receipt" ? `<${v.length}b>` : v}`);
      console.log(`[bridge]   FIELDS(${u.pathname}): ${shown.join(" | ")}`);
    }
  }
  const route = routes.find(([m, re]) => m === req.method && re.test(u.pathname));
  const match = route ? route[1].exec(u.pathname) : null; // capture groups (e.g. /retweet/:id)
  const tag = `${req.method} ${u.pathname}`;

  if (!route) {
    // Unknown endpoint: log it (so we learn what Tweetbot wants) and degrade gracefully.
    console.log(`[bridge] UNHANDLED ${tag}`);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(u.pathname.includes("timeline") || u.pathname.endsWith("list.json") ? "[]" : "{}");
    return;
  }

  try {
    const out = await route[2](q, req, match);
    if (out && out.__redirect) {
      res.writeHead(302, { location: out.location });
      res.end();
      console.log(`[bridge] ${tag} -> 302 ${out.location}`);
    } else if (out && out.__raw) {
      res.writeHead(out.status || 200, { "content-type": out.ct });
      res.end(out.body);
    } else {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(toJSON(out));
    }
    console.log(`[bridge] ${tag} -> ok`);
  } catch (e) {
    console.error(`[bridge] ${tag} -> ERROR ${e.message}`);
    res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ errors: [{ code: 131, message: String(e.message) }] }));
  }
});

boot().catch((e) => console.error("[bridge] boot failed:", e.message));
server.listen(PORT, "127.0.0.1", () => console.log(`[bridge] listening on http://127.0.0.1:${PORT}`));
