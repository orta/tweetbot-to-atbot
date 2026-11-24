// atproto.mjs — a tiny XRPC client for a single Bluesky/atproto account.
// Uses app-password auth (com.atproto.server.createSession). No external deps.

export class AtpClient {
  constructor({ pds = "https://bsky.social", appView = "https://public.api.bsky.app" } = {}) {
    this.pds = pds.replace(/\/$/, "");
    this.appView = appView.replace(/\/$/, "");
    this.session = null; // { did, handle, accessJwt, refreshJwt }
  }

  // Resolve a handle/DID to its hosting PDS, so login works on any PDS (not just bsky.social).
  async resolvePds(identifier) {
    let did = identifier;
    if (!identifier.startsWith("did:")) {
      // handle -> DID via the public AppView resolver
      const r = await this.#xrpc("GET", this.appView, "com.atproto.identity.resolveHandle", null, null, {
        handle: identifier.replace(/^@/, ""),
      });
      did = r.did;
    }
    // DID -> DID document -> #atproto_pds service endpoint
    let doc;
    if (did.startsWith("did:plc:")) {
      doc = await (await fetch(`https://plc.directory/${did}`)).json();
    } else if (did.startsWith("did:web:")) {
      const host = did.slice("did:web:".length).replace(/:/g, "/");
      doc = await (await fetch(`https://${host}/.well-known/did.json`)).json();
    } else {
      throw new Error(`unsupported DID method: ${did}`);
    }
    const svc = (doc.service || []).find(
      (s) => s.id === "#atproto_pds" || s.type === "AtprotoPersonalDataServer"
    );
    if (!svc) throw new Error(`no PDS endpoint in DID doc for ${did}`);
    this.pds = svc.serviceEndpoint.replace(/\/$/, "");
    this.did = did;
    return { did, pds: this.pds };
  }

  async login(identifier, password) {
    this._cred = { identifier, password }; // kept in memory for re-login on expiry
    await this.resolvePds(identifier);
    const r = await this.#xrpc("POST", this.pds, "com.atproto.server.createSession", null, {
      identifier,
      password,
    });
    this.session = r;
    return r;
  }

  async refresh() {
    // Prefer the refresh token; if absent/expired, re-login with the stored creds.
    if (this.session?.refreshJwt) {
      const r = await fetch(`${this.pds}/xrpc/com.atproto.server.refreshSession`, {
        method: "POST",
        headers: { authorization: `Bearer ${this.session.refreshJwt}` },
      });
      if (r.ok) { this.session = await r.json(); return this.session; }
    }
    if (this._cred) return this.login(this._cred.identifier, this._cred.password);
    throw new Error("no refresh token and no stored credentials");
  }

  // Authenticated call against the account's PDS.
  async call(nsid, { method = "GET", params, body } = {}) {
    return this.#authed(this.pds, nsid, { method, params, body });
  }

  // Authenticated view (feeds, profiles, graph). Personalized app.bsky.* reads
  // must go through the account's PDS, which proxies to the AppView via the
  // atproto-proxy service header — the public AppView rejects them (AuthMissing).
  async view(nsid, { method = "GET", params, body } = {}) {
    return this.#authed(this.pds, nsid, { method, params, body, proxy: "did:web:api.bsky.app#bsky_appview" });
  }

  // ---- writes (com.atproto.repo.*) ----
  async createRecord(collection, record) {
    return this.call("com.atproto.repo.createRecord", { method: "POST", body: { repo: this.session.did, collection, record } });
  }
  async deleteAtUri(atUri) {
    if (!atUri?.startsWith("at://")) return null;
    const [repo, collection, rkey] = atUri.slice(5).split("/");
    return this.call("com.atproto.repo.deleteRecord", { method: "POST", body: { repo, collection, rkey } });
  }
  async getPost(uri) {
    const r = await this.view("app.bsky.feed.getPosts", { params: { uris: uri } });
    return r.posts?.[0] || null;
  }
  // Hydrate many uris (getPosts caps at 25 per call) -> Map(uri -> post view).
  async getPostsMap(uris) {
    const out = new Map();
    for (let i = 0; i < uris.length; i += 25) {
      const r = await this.view("app.bsky.feed.getPosts", { params: { uris: uris.slice(i, i + 25) } });
      for (const p of r.posts || []) out.set(p.uri, p);
    }
    return out;
  }
  async resolveHandleToDid(handle) {
    try {
      const r = await this.#xrpc("GET", this.appView, "com.atproto.identity.resolveHandle", null, null, { handle });
      return r.did || null;
    } catch { return null; }
  }

  async #authed(base, nsid, opts) {
    const bearer = () => this.session?.accessJwt;
    try {
      return await this.#xrpc(opts.method, base, nsid, bearer(), opts.body, opts.params, opts.proxy);
    } catch (e) {
      if (String(e.message).includes(" 400") || String(e.message).includes(" 401")) {
        await this.refresh();
        return await this.#xrpc(opts.method, base, nsid, bearer(), opts.body, opts.params, opts.proxy);
      }
      throw e;
    }
  }

  async #xrpc(method, base, nsid, token, body, params, proxy) {
    let url = `${base}/xrpc/${nsid}`;
    if (params) {
      const qs = new URLSearchParams();
      for (const [k, v] of Object.entries(params)) {
        if (v == null) continue;
        if (Array.isArray(v)) v.forEach((x) => qs.append(k, x));
        else qs.append(k, String(v));
      }
      url += `?${qs}`;
    }
    const headers = {};
    if (token) headers.authorization = `Bearer ${token}`;
    if (proxy) headers["atproto-proxy"] = proxy;
    if (body) headers["content-type"] = "application/json";
    const r = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await r.text();
    if (!r.ok) throw new Error(`${nsid} ${r.status}: ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : {};
  }
}
