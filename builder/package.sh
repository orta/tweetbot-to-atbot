#!/bin/bash
# package.sh — build the shippable "Make atbot" app into ./dist.
#
# Produces dist/Atbotify.app, a self-contained GUI that transforms a user's installed
# Tweetbot into atbot. It bundles the precompiled universal dylib + the native atbotify
# engine, so an end user needs nothing but macOS (ditto + codesign ship with the OS).
#
# Maintainer deps: clang + swiftc (Xcode CLT). End-user deps: none.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Atbotify.app"
rm -rf "$DIST"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 1. compile universal dylib (redirect.m + bridge.m)"
clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -framework Foundation \
  -install_name "@executable_path/../Frameworks/libtweetbot-atproto.dylib" \
  -o "$APP/Contents/Resources/libtweetbot-atproto.dylib" \
  "$ROOT/inject/redirect.m" "$ROOT/inject/bridge.m"

echo "==> 2. compile the atbotify engine (universal)"
swiftc -O -target arm64-apple-macos11  -o "$DIST/atbotify.arm64" "$ROOT/builder/atbotify.swift"
swiftc -O -target x86_64-apple-macos11 -o "$DIST/atbotify.x86"   "$ROOT/builder/atbotify.swift"
lipo -create "$DIST/atbotify.arm64" "$DIST/atbotify.x86" -output "$APP/Contents/Resources/atbotify"
rm -f "$DIST/atbotify.arm64" "$DIST/atbotify.x86"
chmod +x "$APP/Contents/Resources/atbotify"

echo "==> 3. compile the GUI (universal)"
swiftc -O -target arm64-apple-macos11  -o "$DIST/gui.arm64" "$ROOT/builder/AtbotifyGUI.swift"
swiftc -O -target x86_64-apple-macos11 -o "$DIST/gui.x86"   "$ROOT/builder/AtbotifyGUI.swift"
lipo -create "$DIST/gui.arm64" "$DIST/gui.x86" -output "$APP/Contents/MacOS/Atbotify"
rm -f "$DIST/gui.arm64" "$DIST/gui.x86"

echo "==> 4. Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Atbotify</string>
  <key>CFBundleDisplayName</key><string>Make atbot</string>
  <key>CFBundleIdentifier</key><string>io.orta.atbotify</string>
  <key>CFBundleExecutable</key><string>Atbotify</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

echo "==> 5. sign (ad-hoc; notarize with a Developer ID before release)"
codesign --force -s - "$APP/Contents/Resources/atbotify" 2>/dev/null || true
codesign --force -s - "$APP" 2>/dev/null || true

echo "    OK — $APP"
echo "    (before a public release: sign with a Developer ID and notarize the .app so it"
echo "     opens without a Gatekeeper prompt. The atbot it generates is built locally and"
echo "     carries no quarantine flag, so it launches fine ad-hoc.)"
