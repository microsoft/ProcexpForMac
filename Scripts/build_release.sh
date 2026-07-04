#!/usr/bin/env bash
#
# build_release.sh — build a Release ProcexpMac.app and package it as a DMG.
#
# Works today with ad-hoc ("Sign to Run Locally") signing. To produce a
# distributable, notarized build, run Scripts/sign_notarize.sh afterwards with
# a Developer ID identity (see docs/RELEASE.md).
#
# Output:
#   build/DerivedData/Build/Products/Release/ProcexpMac.app
#   build/ProcexpMac.dmg   (with an /Applications symlink for drag-install)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$PRODUCTS/ProcexpMac.app"
DMG="$BUILD_DIR/ProcexpMac.dmg"
STAGE="$BUILD_DIR/dmg-stage"

mkdir -p "$BUILD_DIR"

echo "==> Regenerating Xcode project (xcodegen)…"
xcodegen generate

echo "==> Ensuring app icon assets exist…"
if [[ ! -f "$REPO_ROOT/App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" ]]; then
    bash "$REPO_ROOT/Scripts/make_icon.sh"
fi

echo "==> Building Release (xcodebuild)…"
xcodebuild \
    -project ProcexpMac.xcodeproj \
    -scheme ProcexpMac \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build

if [[ ! -d "$APP" ]]; then
    echo "ERROR: expected app not found at $APP" >&2
    exit 1
fi
echo "==> Built: $APP"

echo "==> Staging DMG contents…"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG at $DMG …"
rm -f "$DMG"
hdiutil create \
    -volname "Process Explorer" \
    -srcfolder "$STAGE" \
    -ov \
    -fs HFS+ \
    -format UDZO \
    "$DMG"

rm -rf "$STAGE"

echo ""
echo "==> DONE"
echo "    App: $APP"
echo "    DMG: $DMG"
echo ""
echo "This build is ad-hoc signed. For distribution, run:"
echo "    DEVELOPER_ID_APP='Developer ID Application: NAME (TEAMID)' \\"
echo "    KEYCHAIN_PROFILE='procexp-notary' \\"
echo "    bash Scripts/sign_notarize.sh"
