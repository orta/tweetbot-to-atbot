#!/bin/bash
# build-and-inject.sh — produce "atbot": a distinct, re-identified copy of Tweetbot
# with the atproto redirector injected, anti-tamper neutralized, and re-signed so it
# launches. Given a unique bundle id + URL scheme so LaunchServices never confuses it
# with the original /Applications/Tweetbot.app (important for the OAuth callback).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_APP="${SRC_APP:-/Applications/Tweetbot.app}"
APP="$ROOT/build/atbot.app"
BIN="$APP/Contents/MacOS/atbot"              # executable renamed to atbot too
FRAMEWORKS="$APP/Contents/Frameworks"
PLIST="$APP/Contents/Info.plist"
DYLIB_NAME="libtweetbot-atproto.dylib"
DYLIB_OUT="$FRAMEWORKS/$DYLIB_NAME"
INSTALL_PATH="@executable_path/../Frameworks/$DYLIB_NAME"
SRC="${SRC:-$ROOT/inject/redirect.m}"

NEW_NAME="atbot"
NEW_ID="io.orta.atbot"
NEW_SCHEME="atbot"
PB=/usr/libexec/PlistBuddy

echo "==> copy pristine app -> $APP"
rm -rf "$APP"
ditto "$SRC_APP" "$APP"

echo "==> re-identify as '$NEW_NAME' ($NEW_ID), add '$NEW_SCHEME://' scheme"
# rename the main executable too, so the process + menu bar read "atbot"
mv "$APP/Contents/MacOS/Tweetbot" "$BIN"
$PB -c "Set :CFBundleExecutable $NEW_NAME" "$PLIST"
$PB -c "Set :CFBundleName $NEW_NAME" "$PLIST"
$PB -c "Set :CFBundleDisplayName $NEW_NAME" "$PLIST" 2>/dev/null || $PB -c "Add :CFBundleDisplayName string $NEW_NAME" "$PLIST"
$PB -c "Set :CFBundleIdentifier $NEW_ID" "$PLIST"
# add a dedicated URL type so the OAuth callback (atbot://) returns to THIS app
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLName string $NEW_ID" "$PLIST" 2>/dev/null || true
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $NEW_SCHEME" "$PLIST" 2>/dev/null || true

echo "==> 0. neutralize MAS receipt check + watchdog timers (on pristine binary)"
node "$ROOT/scripts/patch-receipt.mjs" "$BIN"

echo "==> 1. compile injected dylib (universal) from $(basename "$SRC") + bridge.m"
# redirect.m pulls in the in-process bridge (bridge.m) so the built app needs no
# external Node server. The POC source (poc.m) builds standalone.
EXTRA_SRC=""
if grep -q 'bridge.h' "$SRC" 2>/dev/null; then EXTRA_SRC="$ROOT/inject/bridge.m"; fi
clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -framework Foundation -install_name "$INSTALL_PATH" -o "$DYLIB_OUT" "$SRC" $EXTRA_SRC

echo "==> 2. inject LC_LOAD_DYLIB into PTHCommon.framework (in-place, no LIEF/Python)"
# The main executable has only 16 bytes of header padding, but PTHCommon has ~5 KB and
# is loaded at launch, so our dylib's constructor runs. In-place injection there needs
# no relocation — pure Node, so the whole pipeline is dependency-free.
PTHBIN="$FRAMEWORKS/PTHCommon.framework/Versions/A/PTHCommon"
[ -f "$PTHBIN" ] || PTHBIN="$FRAMEWORKS/PTHCommon.framework/PTHCommon"
node "$ROOT/scripts/inject-framework.mjs" "$PTHBIN" "$INSTALL_PATH"

# bake in credentials from a local gitignored file (so full rebuilds keep them)
if [ -f "$ROOT/atproto.json" ]; then
  echo "==> 2b. bake in credentials from ./atproto.json"
  cp "$ROOT/atproto.json" "$APP/Contents/Resources/atproto.json"
fi

echo "==> 3. re-sign ad-hoc, inside-out (trimmed entitlements, no hardened runtime)"
ENT="$ROOT/scripts/modded.entitlements.plist"
codesign --force -s - "$DYLIB_OUT"
codesign --force -s - "$FRAMEWORKS/Model.framework" 2>/dev/null || true
codesign --force -s - "$FRAMEWORKS/PTHCommon.framework" 2>/dev/null || true
for appex in "$APP"/Contents/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  codesign --force -s - --entitlements "$ENT" "$appex"
done
codesign --force -s - --entitlements "$ENT" "$BIN"
codesign --force -s - --entitlements "$ENT" "$APP"

echo "==> 4. verify"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|flags|Format" || true
otool -arch arm64 -L "$PTHBIN" | grep -i atproto >/dev/null || { echo "ERROR: load command missing in PTHCommon"; exit 1; }
echo "    OK — $APP ($NEW_ID)"
