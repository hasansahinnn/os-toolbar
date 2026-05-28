#!/bin/bash
# Build OSToolbar (Release), sign with the stable self-signed cert so TCC
# permissions persist across rebuilds, and package a distributable DMG.
# Usage: tools/build-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Build/Products/Release/OSToolbar.app"
CERT="OSToolbar Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ENTITLEMENTS="$ROOT/OSToolbar/OSToolbar.entitlements"

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
rm -f "$ROOT/dist/OSToolbar.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/OSToolbar.app"
xattr -cr "$STAGE/OSToolbar.app" 2>/dev/null || true
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OSToolbar" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/OSToolbar.dmg" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $ROOT/dist/OSToolbar.dmg"
ls -lh "$ROOT/dist/OSToolbar.dmg"
