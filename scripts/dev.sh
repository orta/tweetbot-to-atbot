#!/bin/bash
# dev.sh — fast reload loop for iterating on the injected dylib (redirect.m / bridge.m).
#
# Recompiles just the dylib, swaps it into the EXISTING build/atbot.app, re-signs, and
# relaunches. Skips the full pipeline (ditto / receipt patch / load-command injection)
# because the load command lives in PTHCommon and points at the dylib by path, and your
# baked-in Resources/atproto.json is left untouched — so only the dylib needs rebuilding.
#
# First run (or after changing the pipeline/entitlements) use scripts/build-and-inject.sh;
# after that, use this for a ~2s edit→see loop.
#
#   bash scripts/dev.sh            # recompile + relaunch
#   bash scripts/dev.sh --log      # ...and tail the in-app log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/atbot.app"
BIN="$APP/Contents/MacOS/atbot"
DYLIB="$APP/Contents/Frameworks/libtweetbot-atproto.dylib"
ENT="$ROOT/scripts/modded.entitlements.plist"
INSTALL="@executable_path/../Frameworks/libtweetbot-atproto.dylib"
LOG="$HOME/Library/Containers/io.orta.atbot/Data/Library/Application Support/tweetbot-atproto.log"

[ -d "$APP" ] || { echo "No build/atbot.app yet — run: bash scripts/build-and-inject.sh"; exit 1; }

echo "==> recompile dylib (redirect.m + bridge.m)"
clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -framework Foundation -install_name "$INSTALL" -o "$DYLIB" \
  "$ROOT/inject/redirect.m" "$ROOT/inject/bridge.m"

echo "==> quit, re-sign (inside-out), relaunch"
pkill -f "MacOS/atbot" 2>/dev/null || true
sleep 0.5
codesign --force -s - "$DYLIB"
codesign --force -s - --entitlements "$ENT" "$BIN"
codesign --force -s - --entitlements "$ENT" "$APP"
: > "$LOG" 2>/dev/null || true   # fresh log
open "$APP"
echo "    reloaded → $APP"

if [ "${1:-}" = "--log" ]; then
  echo "==> tailing in-app log (Ctrl-C to stop)"
  sleep 1
  tail -f "$LOG"
fi
