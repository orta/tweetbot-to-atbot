#!/usr/bin/env node
// set-github-secrets.mjs — upload the signing + notarization secrets that
// .github/workflows/release.yml needs. Run it yourself in a terminal: it prompts for the
// .p12 password (never echoed, never written to disk, never passed on a command line).
//
//   node scripts/set-github-secrets.mjs <DeveloperID.p12> <AuthKey_XXXXXXXXXX.p8> --issuer <uuid>
//
//   --issuer <uuid>   App Store Connect issuer id (or env APPLE_API_ISSUER)
//   --key-id <id>     API key id; default: taken from the AuthKey_<id>.p8 filename
//   --repo <o/n>      target repository; default: this checkout's GitHub remote
//
// Sets: APPLE_CERTIFICATE, APPLE_CERTIFICATE_PASSWORD, APPLE_API_KEY_P8,
//       APPLE_API_KEY_ID, APPLE_API_ISSUER.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { basename } from "node:path";
import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
const VALUE_FLAGS = ["--issuer", "--key-id", "--repo"];
const opt = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const positional = argv.filter((a, i) => !a.startsWith("--") && !VALUE_FLAGS.includes(argv[i - 1]));
const die = (msg) => {
  console.error(`✗ ${msg}`);
  process.exit(1);
};

const [p12, p8] = positional;
if (!p12 || !p8) die("usage: node scripts/set-github-secrets.mjs <DeveloperID.p12> <AuthKey_XXXXXXXXXX.p8> --issuer <uuid>");
for (const f of [p12, p8]) if (!existsSync(f)) die(`no such file: ${f}`);

const issuer = opt("--issuer") ?? process.env.APPLE_API_ISSUER;
if (!issuer) die("pass --issuer <uuid> (App Store Connect → Users and Access → Integrations, above the keys list)");
if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(issuer)) die(`--issuer doesn't look like a uuid: ${issuer}`);

const keyId = opt("--key-id") ?? process.env.APPLE_API_KEY_ID ?? basename(p8).match(/AuthKey_([A-Z0-9]{10})\.p8$/)?.[1];
if (!keyId) die("can't infer the key id from the .p8 filename — pass --key-id <id>");

const p8Text = readFileSync(p8, "utf8");
if (!p8Text.includes("BEGIN PRIVATE KEY")) die(`${p8} is not a PEM private key`);

const repo =
  opt("--repo") ??
  spawnSync("gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], { encoding: "utf8" }).stdout.trim();
if (!repo) die("no GitHub remote for this checkout — create/push the repo first, or pass --repo owner/name");

/** Prompt without echoing the typed characters. */
function askHidden(question) {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl._writeToOutput = (s) => {
      if (s.includes(question)) process.stdout.write(question);
    };
    rl.question(question, (answer) => {
      rl.close();
      process.stdout.write("\n");
      resolve(answer);
    });
  });
}

if (!process.stdin.isTTY) die("run this in an interactive terminal (it prompts for the .p12 password)");
const password = await askHidden(`Password for ${basename(p12)}: `);

// Check the password opens the .p12 and that it holds the right kind of certificate, so a
// typo fails here rather than as a confusing codesign error on a CI runner. The password
// goes to openssl through the environment, not argv.
const env = { ...process.env, P12_PASSWORD: password };
let certs = spawnSync("openssl", ["pkcs12", "-in", p12, "-nokeys", "-passin", "env:P12_PASSWORD"], { encoding: "utf8", env });
if (certs.status !== 0) {
  // Keychain exports use RC2/3DES, which OpenSSL 3 only reads with -legacy.
  certs = spawnSync("openssl", ["pkcs12", "-legacy", "-in", p12, "-nokeys", "-passin", "env:P12_PASSWORD"], { encoding: "utf8", env });
}
if (certs.status !== 0) die("that password does not open the .p12 (or the file is not a PKCS#12 archive)");
const subject = spawnSync("openssl", ["x509", "-noout", "-subject"], { input: certs.stdout, encoding: "utf8" }).stdout.trim();
if (!/Developer ID Application/.test(subject)) die(`the .p12's certificate is not a Developer ID Application cert:\n  ${subject}`);

console.log(`\nRepository:  ${repo}`);
console.log(`Certificate: ${subject.replace(/^subject= ?/, "")}`);
console.log(`API key:     ${keyId} (issuer ${issuer})\n`);

/** Secret values go over stdin so they never appear in `ps` or shell history. */
function setSecret(name, value) {
  const r = spawnSync("gh", ["secret", "set", name, "-R", repo], { input: value, stdio: ["pipe", "inherit", "inherit"] });
  if (r.status !== 0) die(`failed to set ${name}`);
}
setSecret("APPLE_CERTIFICATE", readFileSync(p12).toString("base64"));
setSecret("APPLE_CERTIFICATE_PASSWORD", password);
setSecret("APPLE_API_KEY_P8", p8Text);
setSecret("APPLE_API_KEY_ID", keyId);
setSecret("APPLE_API_ISSUER", issuer);

console.log("");
spawnSync("gh", ["secret", "list", "-R", repo], { stdio: "inherit" });
