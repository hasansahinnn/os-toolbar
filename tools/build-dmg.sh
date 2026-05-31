#!/bin/bash
# Build OSToolbar (Release), sign with the stable self-signed cert so TCC
# permissions persist across rebuilds, and package a distributable DMG with
# the app + an "Applications" symlink for drag-to-install.
# Usage: tools/build-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Build/Products/Release/OSToolbar.app"
CERT="OSToolbar Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ENTITLEMENTS="$ROOT/OSToolbar/OSToolbar.entitlements"
VOLUME_NAME="OSToolbar"
FINAL_DMG="$ROOT/dist/OSToolbar.dmg"

echo "==> Building (Release, signing off)…"
xcodebuild -project OSToolbar.xcodeproj -scheme OSToolbar -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build >/tmp/ostoolbar_build.log 2>&1 \
  || { echo "BUILD FAILED — see /tmp/ostoolbar_build.log"; tail -20 /tmp/ostoolbar_build.log; exit 1; }
grep -q '\*\* BUILD SUCCEEDED \*\*' /tmp/ostoolbar_build.log && echo "    build ok"

echo "==> Signing with stable cert \"$CERT\"…"
codesign --force --sign "$CERT" --entitlements "$ENTITLEMENTS" --keychain "$KEYCHAIN" "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E 'Authority|Identifier='

echo "==> Packaging DMG…"
mkdir -p "$ROOT/dist"
rm -f "$FINAL_DMG"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/OSToolbar.app"
xattr -cr "$STAGE/OSToolbar.app" 2>/dev/null || true
ln -s /Applications "$STAGE/Applications"

# Single-shot compressed DMG. No AppleScript/Finder needed — when the user
# double-clicks the DMG, Finder shows both icons side-by-side and they can
# drag OSToolbar.app onto Applications.
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov \
  -format UDZO -imagekey zlib-level=9 "$FINAL_DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $FINAL_DMG"
ls -lh "$FINAL_DMG"
