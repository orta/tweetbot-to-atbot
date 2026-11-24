// shapes.mjs — translate atproto objects into Twitter 1.1 JSON shapes that
// Tweetbot's parser understands. Only the fields Tweetbot reads are filled;
// the rest are given sane defaults so the model layer never chokes.

// atproto DIDs/handles aren't numeric; Tweetbot expects numeric-ish id_str.
// We derive a stable 53-bit integer from the DID/URI so IDs are consistent.
export function stableId(key) {
  let h = 0n;
  for (const ch of key) h = (h * 131n + BigInt(ch.codePointAt(0))) % 9007199254740881n;
  return h.toString();
}

// Reverse registry: Tweetbot addresses users by the numeric id / screen_name we
// handed out, but atproto needs a DID or handle. Every user we serialize records
// stableId(did)->did and handle->did so users/show & user_timeline can map back.
const actorRegistry = new Map();
export function registerActor(did, handle) {
  if (did) {
    actorRegistry.set(stableId(did), did);
    actorRegistry.set(did, did);
  }
  if (handle) actorRegistry.set(String(handle).toLowerCase(), did || handle);
}
// Resolve a Twitter-style actor param (user_id or screen_name) to an AT identifier.
export function resolveActor(param, fallbackDid) {
  if (param == null || param === "") return fallbackDid;
  const s = String(param);
  if (actorRegistry.has(s)) return actorRegistry.get(s);
  if (actorRegistry.has(s.toLowerCase())) return actorRegistry.get(s.toLowerCase());
  // a bare handle (has a dot, not all digits) is already a valid AT identifier
  if (/[a-z]/i.test(s) && s.includes(".")) return s;
  // an unknown all-numeric id we can't reverse -> fall back to the signed-in user
  if (/^\d+$/.test(s)) return fallbackDid;
  return s;
}

// Post registry: map the numeric id we hand out back to the atproto strong-ref so
// like/repost/reply/delete can recover { uri, cid, rootUri, rootCid }.
const postRegistry = new Map();
export function registerPost(post) {
  if (!post?.uri) return;
  const root = post.record?.reply?.root;
  postRegistry.set(stableId(post.uri), {
    uri: post.uri, cid: post.cid || "",
    rootUri: root?.uri || post.uri, rootCid: root?.cid || post.cid || "",
  });
}
export function resolvePostRef(id) { return id == null ? null : postRegistry.get(String(id)) || null; }

// Build atproto richtext facets (links + @mentions) from plain compose text, with
// UTF-8 byte offsets, so posted links/mentions are tappable. `resolveHandle` maps a
// handle -> DID (async); mentions it can't resolve are skipped.
export async function buildFacets(text, resolveHandle) {
  const facets = [];
  const byteAt = (charIdx) => Buffer.byteLength(text.slice(0, charIdx), "utf8");
  for (const m of text.matchAll(/https?:\/\/[^\s]+/g)) {
    const start = m.index, end = start + m[0].length;
    facets.push({ index: { byteStart: byteAt(start), byteEnd: byteAt(end) }, features: [{ $type: "app.bsky.richtext.facet#link", uri: m[0] }] });
  }
  for (const m of text.matchAll(/@([a-zA-Z0-9][a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})/g)) {
    const did = await resolveHandle?.(m[1]);
    if (!did) continue;
    const start = m.index, end = start + m[0].length;
    facets.push({ index: { byteStart: byteAt(start), byteEnd: byteAt(end) }, features: [{ $type: "app.bsky.richtext.facet#mention", did }] });
  }
  return facets;
}

const TWITTER_DATE = (iso) => {
  // "Wed Oct 10 20:19:24 +0000 2018"
  const d = iso ? new Date(iso) : new Date();
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const mons = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const p = (n) => String(n).padStart(2, "0");
  return `${days[d.getUTCDay()]} ${mons[d.getUTCMonth()]} ${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(
    d.getUTCMinutes()
  )}:${p(d.getUTCSeconds())} +0000 ${d.getUTCFullYear()}`;
};

// atproto profile (app.bsky.actor.defs#profileView*) -> Twitter user object
export function userFromProfile(p) {
  if (!p) return null;
  const id = stableId(p.did);
  registerActor(p.did, p.handle);
  return {
    id_str: id,
    id: Number(id),
    screen_name: p.handle,
    name: p.displayName || p.handle,
    description: p.description || "",
    location: "",
    url: null,
    protected: false,
    verified: false,
    followers_count: p.followersCount ?? 0,
    friends_count: p.followsCount ?? 0,
    statuses_count: p.postsCount ?? 0,
    favourites_count: 0,
    listed_count: 0,
    created_at: TWITTER_DATE(p.createdAt),
    profile_image_url_https: p.avatar || "",
    profile_image_url: p.avatar || "",
    profile_banner_url: p.banner || "",
    following: !!p.viewer?.following,
    follow_request_sent: false,
    // atproto-native handles, stashed so the bridge can map back later.
    _atproto_did: p.did,
    _atproto_handle: p.handle,
  };
}

// atproto feed post (app.bsky.feed.defs#feedViewPost) -> Twitter status object
export function statusFromFeedItem(item) {
  const post = item.post || item;
  const rec = post.record || {};
  registerPost(post);
  const id = stableId(post.uri);
  const rendered = renderPost(rec, post);
  const status = {
    id_str: id,
    id: Number(id),
    full_text: rendered.full_text,
    text: rendered.full_text,
    display_text_range: rendered.display_text_range,
    truncated: false,
    created_at: TWITTER_DATE(rec.createdAt || post.indexedAt),
    user: userFromProfile(post.author),
    retweet_count: post.repostCount ?? 0,
    favorite_count: post.likeCount ?? 0,
    reply_count: post.replyCount ?? 0,
    favorited: !!post.viewer?.like,
    retweeted: !!post.viewer?.repost,
    lang: rec.langs?.[0] || "en",
    source: '<a href="https://bsky.app" rel="nofollow">Bluesky</a>',
    in_reply_to_status_id_str: null,
    in_reply_to_screen_name: null,
    entities: rendered.entities,
    extended_entities: rendered.extended_entities,
    // stash atproto identity for write-backs (like/repost/reply/delete)
    _atproto_uri: post.uri,
    _atproto_cid: post.cid,
  };
  // repost -> Twitter retweet wrapper
  if (item.reason?.$type === "app.bsky.feed.defs#reasonRepost") {
    const by = userFromProfile(item.reason.by);
    const rtText = `RT @${status.user?.screen_name}: ${rendered.full_text}`;
    return {
      id_str: stableId(post.uri + "#rt:" + (item.reason.by?.did || "")),
      id: Number(stableId(post.uri + "#rt:" + (item.reason.by?.did || ""))),
      created_at: TWITTER_DATE(item.reason.indexedAt),
      user: by,
      text: rtText,
      full_text: rtText,
      display_text_range: [0, rtText.length],
      retweeted_status: status,
      retweet_count: status.retweet_count,
      favorite_count: status.favorite_count,
      entities: { hashtags: [], urls: [], user_mentions: [], symbols: [] },
    };
  }
  return status;
}

// Build a lookup from atproto UTF-8 byte offset -> JS (UTF-16) string index, since
// facet ranges are byte offsets but Tweetbot (NSString) indexes by UTF-16 units.
function byteToCharFn(text) {
  const map = new Map([[0, 0]]);
  let byte = 0;
  for (let i = 0; i < text.length; ) {
    const cp = text.codePointAt(i);
    const units = cp > 0xffff ? 2 : 1;
    byte += Buffer.byteLength(String.fromCodePoint(cp), "utf8");
    i += units;
    map.set(byte, i);
  }
  return (b) => {
    if (map.has(b)) return map.get(b);
    let best = 0; // nearest boundary at/below b
    for (const bo of map.keys()) if (bo <= b && bo > best) best = bo;
    return map.get(best) ?? 0;
  };
}

// Pretty display form of a URL: drop scheme + "www.", trim trailing slash, and
// elide very long paths the way Twitter/Tweetbot shows them.
function prettyUrl(uri) {
  let s = String(uri).replace(/^https?:\/\//i, "").replace(/^www\./i, "").replace(/\/$/, "");
  if (s.length > 30) s = s.slice(0, 27) + "…";
  return s;
}

// Render an atproto post record into Twitter-shaped text + entities. Produces real
// `indices` so links/mentions/tags sit in the right place, a `display_text_range`
// that hides the synthetic trailing media URL, and `extended_entities` for photos.
function renderPost(rec, post) {
  const text = rec.text || "";
  const b2c = byteToCharFn(text);
  const urls = [];
  const hashtags = [];
  const user_mentions = [];
  const media = [];

  for (const f of rec.facets || []) {
    const cs = b2c(f.index?.byteStart ?? 0);
    const ce = b2c(f.index?.byteEnd ?? 0);
    const slice = text.substring(cs, ce);
    for (const feat of f.features || []) {
      switch (feat.$type) {
        case "app.bsky.richtext.facet#link":
          urls.push({
            url: feat.uri,            // real target (Tweetbot links here)
            expanded_url: feat.uri,
            display_url: prettyUrl(feat.uri),
            indices: [cs, ce],
          });
          break;
        case "app.bsky.richtext.facet#tag":
          hashtags.push({ text: feat.tag, indices: [cs, ce] });
          break;
        case "app.bsky.richtext.facet#mention": {
          const handle = slice.replace(/^@/, "");
          const mid = stableId(feat.did);
          registerActor(feat.did, handle);
          user_mentions.push({ screen_name: handle, name: handle, id_str: mid, id: Number(mid), indices: [cs, ce] });
          break;
        }
      }
    }
  }

  let full = text;
  const displayEnd = full.length;

  // Photos: Twitter appends a short media URL to the text and flags it non-display
  // via display_text_range, so the client strips it and shows the image instead.
  const imgs = post.embed?.images || post.embed?.media?.images;
  if (Array.isArray(imgs) && imgs.length) {
    const tco = "https://t.co/" + stableId(post.uri).slice(0, 10);
    const start = full.length + 1; // after the joining space
    full = full + " " + tco;
    const end = full.length;
    imgs.forEach((im, i) => {
      const src = im.fullsize || im.thumb;
      const ar = im.aspectRatio || {};
      const sizes = {
        large: { w: ar.width || 1200, h: ar.height || 900, resize: "fit" },
        medium: { w: ar.width || 1200, h: ar.height || 900, resize: "fit" },
        small: { w: 680, h: 510, resize: "fit" },
        thumb: { w: 150, h: 150, resize: "crop" },
      };
      media.push({
        id_str: stableId(post.uri + "#img" + i),
        id: Number(stableId(post.uri + "#img" + i)),
        type: "photo",
        media_url: src,
        media_url_https: src,
        url: tco,
        display_url: "pic.bsky.app/" + stableId(post.uri).slice(0, 6),
        expanded_url: src,
        indices: [start, end],
        sizes,
        ext_alt_text: im.alt || null,
      });
    });
  }

  // External link card (app.bsky.embed.external) whose URL isn't already linked in
  // the text: append it as a trailing url entity so it's tappable.
  const ext = post.embed?.external || post.embed?.media?.external;
  if (ext?.uri && !urls.some((u) => u.expanded_url === ext.uri)) {
    const tag = " " + prettyUrl(ext.uri);
    const start = full.length + 1;
    full = full + tag;
    urls.push({
      url: ext.uri,
      expanded_url: ext.uri,
      display_url: prettyUrl(ext.uri),
      indices: [start, full.length],
    });
  }

  const entities = { hashtags, urls, user_mentions, symbols: [] };
  if (media.length) entities.media = media;
  const out = { full_text: full, display_text_range: [0, displayEnd], entities };
  if (media.length) out.extended_entities = { media };
  return out;
}

// ---- lists: Bluesky saved feeds (feed generators) + lists as Twitter lists ----
// Tweetbot's timeline title is a dropdown of the account's lists.
// Registry: Twitter list id -> { uri, kind: "feed"|"list", json }.
const listRegistry = new Map();
// `ownerUser` is the Twitter user the list is attributed to: Tweetbot's title menu only
// shows lists the account OWNS (list.user.id == account tid), so callers pass the
// signed-in user rather than the feed's creator.
export function twitterList(view, kind, name, ownerUser) {
  const uri = view.uri || "";
  const id = stableId(uri);
  const owner = view.creator?.handle || "";
  const slug = uri.split("/").pop() || "";
  const json = {
    id_str: id, id: Number(id),
    name: name || listViewName(view), slug,
    full_name: `@${owner}/${slug}`,
    uri: `/${owner}/lists/${slug}`,
    description: view.description || "",
    mode: "public", following: true,
    member_count: view.listItemCount || 0,
    subscriber_count: view.likeCount || 0,
    created_at: TWITTER_DATE(view.indexedAt),
    user: ownerUser || userFromProfile(view.creator),
    _atproto_uri: uri, _atproto_kind: kind,
  };
  listRegistry.set(id, { uri, kind, json });
  return json;
}
export const listViewName = (view) => (view.displayName || view.name || String(view.uri).split("/").pop() || "").trim();
export function findList(q) {
  const id = q.list_id || q.id;
  if (id && listRegistry.has(String(id))) return listRegistry.get(String(id));
  if (q.slug) for (const e of listRegistry.values()) if (e.json.slug === q.slug) return e;
  return null;
}
