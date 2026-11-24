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
import { userFromProfile, statusFromFeedItem, stableId, resolveActor, resolvePostRef, buildFacets, twitterList, findList, listViewName } from "./shapes.mjs";

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
  ["GET", /\/1\.1\/statuses\/home_timeline\.json/, async (q) => {
    const r = await atp.view("app.bsky.feed.getTimeline", { params: { limit: clampCount(q.count), cursor: q.max_id_cursor } });
    return (r.feed || []).map(statusFromFeedItem);
  }],
  ["GET", /\/1\.1\/statuses\/user_timeline\.json/, async (q) => {
    const actor = resolveActor(q.screen_name || q.user_id, atp.session.did);
    const r = await atp.view("app.bsky.feed.getAuthorFeed", { params: { actor, limit: clampCount(q.count) } });
    return (r.feed || []).map(statusFromFeedItem);
  }],
  ["GET", /\/1\.1\/statuses\/mentions_timeline\.json/, async (q) => {
    const r = await atp.view("app.bsky.notification.listNotifications", { params: { limit: clampCount(q.count) } });
    return (r.notifications || [])
      .filter((n) => n.reason === "mention" || n.reason === "reply")
      .map((n) => statusFromFeedItem({ post: { ...n, record: n.record, author: n.author, uri: n.uri, cid: n.cid } }));
  }],

  // --- lists = Bluesky saved feeds + lists (Tweetbot's timeline title dropdown) ---
  ["GET", /\/1\.1\/lists\/list\.json/, (q) => loadLists(q.user_id)],
  ["GET", /\/1\.1\/lists\/statuses\.json/, async (q) => {
    const entry = await resolveList(q);
    const isList = entry.kind === "list";
    const r = await atp.view(isList ? "app.bsky.feed.getListFeed" : "app.bsky.feed.getFeed",
      { params: { [isList ? "list" : "feed"]: entry.uri, limit: clampCount(q.count) } });
    return (r.feed || []).map(statusFromFeedItem);
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

  // --- user lookup ---
  ["GET", /\/1\.1\/users\/show\.json/, async (q) => {
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
const json = (obj) => ({ __raw: true, body: JSON.stringify(obj), ct: "application/json" });
const redirect = (location) => ({ __redirect: true, location });

const server = http.createServer(async (req, res) => {
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
      res.writeHead(200, { "content-type": out.ct });
      res.end(out.body);
    } else {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(out));
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
