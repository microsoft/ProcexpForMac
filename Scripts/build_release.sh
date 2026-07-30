#!/usr/bin/env bash
#
# build_release.sh — build a Release ProcexpMac.app and optionally package a DMG.
#
# Works today with ad-hoc ("Sign to Run Locally") signing. To produce a
# distributable, notarized build, run Scripts/sign_notarize.sh afterwards with
# a Developer ID identity (see docs/RELEASE.md).
#
# Output (default development flavor):
#   build/DerivedData/Build/Products/Release/ProcExp (Dev).app
#   build/ProcExp-Dev.dmg   (unless PACKAGE_DMG=0; local testing only)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
STAGE="$BUILD_DIR/dmg-stage"
PACKAGE_DMG="${PACKAGE_DMG:-1}"
BUILD_FLAVOR="${PROCEXP_BUILD_FLAVOR:-development}"
VERSION="${PROCEXP_VERSION:-0.1}"
BUILD_VERSION="${PROCEXP_BUILD_VERSION:-$VERSION}"
VERSION_PATTERN='^[0-9]+\.[0-9]+(\.[0-9]+)?$'

fail() { echo "ERROR: $*" >&2; exit 1; }

case "$BUILD_FLAVOR" in
    official)
        APP_BUNDLE_ID="com.sysinternals.procexpmac"
        APP_DISPLAY_NAME="Process Explorer"
        APP_WRAPPER_NAME="ProcexpMac.app"
        HELPER_NAME="com.sysinternals.procexpmac.helper"
        HELPER_FLAVOR="official"
        HELPER_CONFIGURATION="release"
        DMG="$BUILD_DIR/ProcExp.dmg"
        DMG_APP_NAME="ProcExp.app"
        DMG_VOLUME_NAME="Process Explorer"
        ;;
    development)
        APP_BUNDLE_ID="com.sysinternals.procexpmac.dev"
        APP_DISPLAY_NAME="Process Explorer (Dev)"
        APP_WRAPPER_NAME="ProcExp (Dev).app"
        HELPER_NAME="com.sysinternals.procexpmac.dev.helper"
        HELPER_FLAVOR="development"
        HELPER_CONFIGURATION="debug"
        DMG="$BUILD_DIR/ProcExp-Dev.dmg"
        DMG_APP_NAME="ProcExp (Dev).app"
        DMG_VOLUME_NAME="Process Explorer Dev"
        ;;
    *) fail "PROCEXP_BUILD_FLAVOR must be development or official" ;;
esac
APP="$PRODUCTS/$APP_WRAPPER_NAME"

[[ "$VERSION" =~ $VERSION_PATTERN ]] || fail \
    "PROCEXP_VERSION must be a dotted numeric version such as 1.0 or 1.0.0 (got '$VERSION')"
[[ "$BUILD_VERSION" =~ $VERSION_PATTERN ]] || fail \
    "PROCEXP_BUILD_VERSION must be a dotted numeric version such as 1.0 or 1.0.0 (got '$BUILD_VERSION')"

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
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
    "PRODUCT_BUNDLE_IDENTIFIER=$APP_BUNDLE_ID" \
    "INFOPLIST_KEY_CFBundleDisplayName=$APP_DISPLAY_NAME" \
    "WRAPPER_NAME=$APP_WRAPPER_NAME" \
    build

if [[ ! -d "$APP" ]]; then
    echo "ERROR: expected app not found at $APP" >&2
    exit 1
fi
APP_INFO_PLIST="$APP/Contents/Info.plist"
ACTUAL_APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c \
    'Print :CFBundleIdentifier' "$APP_INFO_PLIST")"
[[ "$ACTUAL_APP_BUNDLE_ID" == "$APP_BUNDLE_ID" ]] || fail \
    "app bundle id is $ACTUAL_APP_BUNDLE_ID; expected $APP_BUNDLE_ID"
ACTUAL_APP_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c \
    'Print :CFBundleDisplayName' "$APP_INFO_PLIST")"
[[ "$ACTUAL_APP_DISPLAY_NAME" == "$APP_DISPLAY_NAME" ]] || fail \
    "app display name is $ACTUAL_APP_DISPLAY_NAME; expected $APP_DISPLAY_NAME"
echo "==> Built: $APP"

echo "==> Embedding privileged helper (W13)…"
PROCEXP_HELPER_FLAVOR="$HELPER_FLAVOR" \
PROCEXP_APP_BUNDLE_ID="$APP_BUNDLE_ID" \
PROCEXP_HELPER_NAME="$HELPER_NAME" \
HELPER_CONFIGURATION="$HELPER_CONFIGURATION" \
HELPER_ARCHS="${HELPER_ARCHS:-arm64 x86_64}" \
    bash "$REPO_ROOT/Scripts/embed_helper.sh" "$APP"

HELPER_PATH="$APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
echo "==> Applying inside-out ad-hoc transport signatures…"
codesign --force --sign - "$HELPER_PATH"
codesign --force --sign - \
    --requirements "=designated => identifier \"$APP_BUNDLE_ID\"" \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$PACKAGE_DMG" == "0" ]]; then
    echo ""
    echo "==> DONE"
    echo "    App: $APP"
    echo "    DMG packaging skipped (PACKAGE_DMG=0)."
    exit 0
fi

echo "==> Staging DMG contents…"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$DMG_APP_NAME"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating DMG at $DMG …"
rm -f "$DMG"
hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
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
echo "    Flavor: $BUILD_FLAVOR"
echo "    Version: $VERSION ($BUILD_VERSION)"
echo ""
echo "This DMG is for local testing only. For a local Developer ID validation, run:"
echo "    PROCEXP_BUILD_FLAVOR=official PACKAGE_DMG=0 bash Scripts/build_release.sh"
echo "    DEVELOPER_ID_APP='Developer ID Application: NAME (TEAMID)' \\"
echo "    KEYCHAIN_PROFILE='procexp-notary' \\"
echo "    bash Scripts/sign_notarize.sh"
