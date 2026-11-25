# Releasing Atbotify

A release is one file: `Atbotify-<version>.zip`, containing `Atbotify.app` signed with a
Developer ID, notarized by Apple, and stapled, so it opens on any Mac without a Gatekeeper
warning. Only the builder is signed and notarized. The `atbot.app` it produces is ad-hoc
signed on the user's own Mac and never leaves it.

## Cutting a release

```sh
git tag v1.0.0
git push origin v1.0.0
```

The [Release workflow](../.github/workflows/release.yml) builds, signs, notarizes, staples,
and publishes a GitHub Release with the zip and its `.sha256`. A tag with a hyphen
(`v1.0.0-beta.1`) is published as a prerelease. Notarization usually takes a few minutes.

To exercise the whole pipeline without publishing, run the workflow manually
(Actions → Release → Run workflow). The zip is attached to the run as an artifact and no
GitHub Release is created.

## One-time setup: repository secrets

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE` | base64 of a `.p12` holding the **Developer ID Application** certificate and its private key |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12`; leave unset if it has none |
| `APPLE_API_KEY_P8` | the App Store Connect API key (`AuthKey_XXXXXXXXXX.p8`), as its PEM text |
| `APPLE_API_KEY_ID` | that key's ID (the `XXXXXXXXXX` in the filename) |
| `APPLE_API_ISSUER` | the issuer UUID shown above the keys list |

**Certificate.** In Keychain Access, find "Developer ID Application: …" under My
Certificates, expand it to check the private key is there, then right-click → Export as
`.p12` with a strong password.

**API key.** In App Store Connect → Users and Access → Integrations → App Store Connect
API, create a team key with the **Developer** role. The `.p8` can be downloaded once.

Then upload all five in one go. The script prompts for the `.p12` password, checks that it
opens the file and that the certificate is a Developer ID Application one, and sends every
value to `gh` over stdin:

```sh
node scripts/set-github-secrets.mjs ~/Desktop/DeveloperID.p12 ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
  --issuer <issuer-uuid>
```

Whoever's certificate this is becomes the developer name Gatekeeper shows for Atbotify, and
their Apple account is the one accountable for it.

## Releasing from your own Mac

The same script runs locally, using the Developer ID identity already in your keychain:

```sh
# once: save notary credentials in the keychain under a profile name
xcrun notarytool store-credentials atbot-notary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>

NOTARY_PROFILE=atbot-notary node scripts/release.mjs --version 1.0.0
gh release create v1.0.0 dist/Atbotify-1.0.0.zip dist/Atbotify-1.0.0.zip.sha256 --generate-notes
```

`node scripts/release.mjs --skip-notarize` signs without contacting the notary service,
which is a quick way to check the signing setup. `CODESIGN_IDENTITY` picks a specific
identity if the keychain holds more than one Developer ID.

## What the script does

[`scripts/release.mjs`](../scripts/release.mjs):

1. Runs `builder/package.sh` with the version from the tag (the build number is the commit
   count).
2. Signs inside-out with a secure timestamp: the bundled dylib, then the `atbotify` engine
   and the app itself with the hardened runtime. No entitlements are needed.
3. Zips with `ditto`, submits to `notarytool` and waits. On rejection it prints Apple's
   log, which names the offending file.
4. Staples the ticket to the app, re-zips (the uploaded zip predates the staple), and
   checks the result with `spctl`.

## If notarization fails

- **"The signature does not include a secure timestamp" / "not signed with a valid
  Developer ID"** — a new Mach-O was added to the bundle without being signed. Add it to
  the signing step in `release.mjs`, innermost first.
- **"The executable does not have the hardened runtime enabled"** — a new executable needs
  `--options runtime`.
- **HTTP 401/403 from notarytool** — the API key was revoked, or a new Apple agreement is
  waiting to be accepted at developer.apple.com.
