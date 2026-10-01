#!/bin/sh
# Builds Notch for release and packages it as a DMG.
#
#   scripts/release.sh 1.2.0        → build/release/Notch-1.2.0.dmg (+ .sha256)
#
# The app is ad-hoc signed (no paid Apple Developer account), so people opening it for the
# first time need System Settings › Privacy & Security › Open Anyway. See the README.
set -eu

VERSION="${1:?usage: scripts/release.sh <version, e.g. 1.2.0>}"
VERSION="${VERSION#v}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/release-derived"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Notch $VERSION (build $BUILD_NUMBER)"
cd "$ROOT"
xcodegen --quiet

rm -rf "$OUT" "$DERIVED"
mkdir -p "$OUT"

echo "==> Building"
xcodebuild -project Notch.xcodeproj -scheme Notch -configuration Release \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ONLY_ACTIVE_ARCH=NO \
  build | grep -E "error:|warning: |\*\* BUILD" || true

APP="$DERIVED/Build/Products/Release/Notch.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "    $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") · $(lipo -archs "$APP/Contents/MacOS/Notch")"

echo "==> Packaging"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"  # drag-to-install
DMG="$OUT/Notch-$VERSION.dmg"
hdiutil create -volname "Notch $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 "Notch-$VERSION.dmg" > "Notch-$VERSION.dmg.sha256")
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
