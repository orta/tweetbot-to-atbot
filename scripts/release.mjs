#!/usr/bin/env node
// release.mjs — build, Developer ID-sign, notarize and staple the Atbotify builder app.
//
//   node scripts/release.mjs                    # full release build -> dist/Atbotify-<version>.zip
//   node scripts/release.mjs --skip-notarize    # sign only (checks the signing setup, no Apple round-trip)
//   node scripts/release.mjs --version 1.2.0    # override the version (default: git tag, else 0.0.0-dev)
//
// Environment:
//   CODESIGN_IDENTITY   "Developer ID Application: …" name or SHA-1. Default: the first
//                       Developer ID Application identity in the keychain search list.
//   Notary credentials — either
//     NOTARY_PROFILE    a profile saved with `xcrun notarytool store-credentials`
//   or an App Store Connect API key (what CI uses):
//     APPLE_API_KEY_PATH   path to AuthKey_XXXX.p8
//     APPLE_API_KEY_ID     the key id
//     APPLE_API_ISSUER_ID  the issuer uuid
//
// Only Atbotify.app is signed/notarized. The atbot.app it generates on the user's Mac is
// still ad-hoc signed there — it is built locally, so it never carries a quarantine flag.
// Dependency-free: node + the Xcode command-line tools.
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");
const APP = join(DIST, "Atbotify.app");

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const opt = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : undefined;
};
const skipNotarize = flag("skip-notarize");

const step = (msg) => console.log(`\n==> ${msg}`);
const die = (msg) => {
  console.error(`\n✗ ${msg}`);
  process.exit(1);
};
/** Run a command, streaming its output; throws on a non-zero exit. */
const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: "inherit", cwd: ROOT, ...opts });
/** Run a command and return its stdout ("" if it fails). */
const capture = (cmd, args) => {
  const r = spawnSync(cmd, args, { cwd: ROOT, encoding: "utf8" });
  return r.status === 0 ? r.stdout.trim() : "";
};

// ---- version ------------------------------------------------------------------
// Tag `v1.2.0` -> 1.2.0. Off a tag we still build, as 0.0.0-dev, so the pipeline can be
// exercised without cutting a release.
function resolveVersion() {
  const explicit = opt("version") ?? process.env.VERSION;
  if (explicit) return explicit.replace(/^v/, "");
  const tag = capture("git", ["describe", "--tags", "--exact-match", "--match", "v*"]);
  return tag ? tag.replace(/^v/, "") : "0.0.0-dev";
}
const version = resolveVersion();
const buildNumber = process.env.BUILD_NUMBER ?? (capture("git", ["rev-list", "--count", "HEAD"]) || "1");

// ---- signing identity -----------------------------------------------------------
function resolveIdentity() {
  if (process.env.CODESIGN_IDENTITY) return process.env.CODESIGN_IDENTITY;
  const out = capture("security", ["find-identity", "-v", "-p", "codesigning"]);
  const m = out.match(/^\s*\d+\)\s+([0-9A-F]{40})\s+"Developer ID Application: [^"]+"/m);
  if (!m) die('No "Developer ID Application" identity in the keychain. Set CODESIGN_IDENTITY, or install the certificate.');
  return m[1];
}

// ---- notary credentials -----------------------------------------------------------
function notaryAuthArgs() {
  const { NOTARY_PROFILE, APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID } = process.env;
  if (NOTARY_PROFILE) return ["--keychain-profile", NOTARY_PROFILE];
  if (APPLE_API_KEY_PATH && APPLE_API_KEY_ID && APPLE_API_ISSUER_ID) {
    if (!existsSync(APPLE_API_KEY_PATH)) die(`APPLE_API_KEY_PATH does not exist: ${APPLE_API_KEY_PATH}`);
    return ["--key", APPLE_API_KEY_PATH, "--key-id", APPLE_API_KEY_ID, "--issuer", APPLE_API_ISSUER_ID];
  }
  die(
    "No notary credentials. Set NOTARY_PROFILE (from `xcrun notarytool store-credentials`), or\n" +
      "  APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER_ID. Use --skip-notarize to sign only.",
  );
}

// Resolve everything that can fail on configuration before spending time compiling.
const identity = resolveIdentity();
const notaryAuth = skipNotarize ? null : notaryAuthArgs();

// ---- 1. build -------------------------------------------------------------------
step(`build Atbotify.app ${version} (${buildNumber})`);
run("bash", [join(ROOT, "builder/package.sh")], { env: { ...process.env, VERSION: version, BUILD_NUMBER: buildNumber } });

// ---- 2. sign ----------------------------------------------------------------------
// Inside-out. Notarization requires every Mach-O in the bundle — including the helper and
// the dylib that live in Resources — to carry a Developer ID signature with a secure
// timestamp, and every executable to opt into the hardened runtime. Neither needs
// entitlements: the builder only runs /usr/bin/ditto and /usr/bin/codesign.
step("sign with Developer ID (hardened runtime + secure timestamp)");
const sign = (path, extra = []) => run("codesign", ["--force", "--timestamp", "--sign", identity, ...extra, path]);
sign(join(APP, "Contents/Resources/libtweetbot-atproto.dylib"), ["--identifier", "io.orta.atbot.dylib"]);
sign(join(APP, "Contents/Resources/atbotify"), ["--options", "runtime", "--identifier", "io.orta.atbotify.engine"]);
sign(APP, ["--options", "runtime"]);
run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", APP]);

// ---- 3. notarize + staple -----------------------------------------------------------
const zip = join(DIST, `Atbotify-${version}.zip`);
const makeZip = () => {
  rmSync(zip, { force: true });
  run("ditto", ["-c", "-k", "--keepParent", APP, zip]);
};
makeZip();

if (skipNotarize) {
  console.log("\n(skipping notarization — this build will be blocked by Gatekeeper on other Macs)");
} else {
  step("notarize (uploads to Apple and waits; usually a few minutes)");
  const work = mkdtempSync(join(tmpdir(), "atbotify-notary-"));
  const resultPath = join(work, "submit.json");
  const r = spawnSync("xcrun", ["notarytool", "submit", zip, ...notaryAuth, "--wait", "--output-format", "json"], {
    cwd: ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  });
  writeFileSync(resultPath, r.stdout ?? "");
  let result = {};
  try {
    result = JSON.parse(r.stdout);
  } catch {
    die(`notarytool gave no parseable result (exit ${r.status}):\n${r.stdout}`);
  }
  console.log(`    submission ${result.id}: ${result.status}`);
  if (result.status !== "Accepted") {
    // The log names the exact file + reason for a rejection — always print it.
    if (result.id) spawnSync("xcrun", ["notarytool", "log", result.id, ...notaryAuth], { cwd: ROOT, stdio: "inherit" });
    die(`notarization failed: ${result.status ?? result.message ?? "unknown"}`);
  }
  rmSync(work, { recursive: true, force: true });

  step("staple the ticket + re-zip");
  run("xcrun", ["stapler", "staple", APP]);
  run("xcrun", ["stapler", "validate", APP]);
  makeZip(); // the uploaded zip predates the staple; ship the stapled app
  run("spctl", ["--assess", "--type", "execute", "--verbose=2", APP]);
}

// ---- 4. report ------------------------------------------------------------------------
const sha256 = createHash("sha256").update(readFileSync(zip)).digest("hex");
writeFileSync(`${zip}.sha256`, `${sha256}  Atbotify-${version}.zip\n`);
console.log(`\n✓ ${zip}\n  sha256 ${sha256}${skipNotarize ? "\n  (signed, NOT notarized)" : "\n  (signed, notarized, stapled)"}`);

// Hand the artifact to the calling GitHub Actions job.
if (process.env.GITHUB_OUTPUT) {
  appendFileSync(process.env.GITHUB_OUTPUT, `zip=${zip}\nsha256_file=${zip}.sha256\nversion=${version}\n`);
}
