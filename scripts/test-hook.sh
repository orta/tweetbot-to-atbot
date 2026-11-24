#!/bin/bash
# test-hook.sh — deterministic end-to-end test of the redirector + bridge, WITHOUT
# Tweetbot. Builds the dylib + a tiny client that links it, then makes a real
# NSURLSession request to api.twitter.com. If interception works it is redirected
# to the bridge and returns the atproto-backed Twitter JSON.
#
# Prereq: the bridge must be running:
#   BRIDGE_HANDLE=you.example BRIDGE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx node bridge/server.mjs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/tweetbot-atproto-test"
mkdir -p "$OUT"
LOG="$HOME/Library/Application Support/tweetbot-atproto.log"

clang -dynamiclib -fobjc-arc -arch arm64 -framework Foundation \
  -install_name @rpath/libtweetbot-atproto.dylib \
  -o "$OUT/libtweetbot-atproto.dylib" "$ROOT/inject/redirect.m"
clang -fobjc-arc -arch arm64 -framework Foundation \
  -o "$OUT/test_hook" "$ROOT/inject/test_hook.m" \
  -L"$OUT" -ltweetbot-atproto -Wl,-rpath,"$OUT"

rm -f "$LOG"
echo "== verify_credentials =="
TWEETBOT_BRIDGE_PORT="${BRIDGE_PORT:-8080}" "$OUT/test_hook" \
  "https://api.twitter.com/1.1/account/verify_credentials.json"
echo; echo "== redirector log =="; cat "$LOG" 2>/dev/null || true
