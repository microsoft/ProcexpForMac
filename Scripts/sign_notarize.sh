#!/usr/bin/env bash
#
# sign_notarize.sh — Developer ID sign, notarize, package, and staple a Release build.
#
# This does NOT run under the current ad-hoc signing setup — it requires a real
# "Developer ID Application" certificate in the login keychain and a stored
# notarytool credential profile. It is authored to be correct and ready to run
# once those are supplied. See docs/RELEASE.md for the full walkthrough.
#
# Required environment variables:
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Jane Doe (AB12CD34EF)"
#   KEYCHAIN_PROFILE   the `xcrun notarytool store-credentials` profile name
#
# Steps:
#   1. codesign the embedded helper (if present) with the debugger entitlement
#      + Hardened Runtime.
#   2. codesign the app with the managed-by-launchd entitlement + Hardened
#      Runtime without replacing the helper's nested signature.
#   3. notarize and staple the app.
#   4. package that exact app into a DMG.
#   5. sign, notarize, and staple the DMG.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
APP="$BUILD_DIR/DerivedData/Build/Products/Release/ProcexpMac.app"
APP_ARCHIVE="$BUILD_DIR/ProcExp-app-notarization.zip"
DMG="$BUILD_DIR/ProcExp.dmg"
STAGE="$BUILD_DIR/dmg-stage-signed"
APP_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpMac.entitlements"
HELPER_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpHelper.entitlements"
APP_BUNDLE_ID="com.sysinternals.procexpmac"
HELPER_NAME="com.sysinternals.procexpmac.helper"
HELPER_PATH="$APP/Contents/Library/LaunchDaemons/$HELPER_NAME"

# ---------------------------------------------------------------------------
# Guard: required inputs.
# ---------------------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${DEVELOPER_ID_APP:-}" ]] || fail \
    "DEVELOPER_ID_APP is not set. Export it, e.g.:\n" \
    "  export DEVELOPER_ID_APP='Developer ID Application: NAME (TEAMID)'"
[[ -n "${KEYCHAIN_PROFILE:-}" ]] || fail \
    "KEYCHAIN_PROFILE is not set. Create one with:\n" \
    "  xcrun notarytool store-credentials procexp-notary \\\n" \
    "    --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PW\n" \
    "  then: export KEYCHAIN_PROFILE='procexp-notary'"

[[ -d "$APP" ]] || fail \
    "official app not found at $APP; run PROCEXP_BUILD_FLAVOR=official PACKAGE_DMG=0 bash Scripts/build_release.sh first"
[[ -f "$APP_ENTITLEMENTS" ]] || fail "missing $APP_ENTITLEMENTS"
ACTUAL_APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c \
    'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$ACTUAL_APP_BUNDLE_ID" == "$APP_BUNDLE_ID" ]] || fail \
    "refusing to sign bundle id $ACTUAL_APP_BUNDLE_ID; expected $APP_BUNDLE_ID"
HELPER_PLIST="$APP/Contents/Library/LaunchDaemons/${HELPER_NAME}.plist"
[[ -f "$HELPER_PLIST" ]] || fail "official helper plist not found at $HELPER_PLIST"
ACTUAL_ASSOCIATED_ID="$(/usr/libexec/PlistBuddy -c \
    'Print :AssociatedBundleIdentifiers:0' "$HELPER_PLIST")"
[[ "$ACTUAL_ASSOCIATED_ID" == "$APP_BUNDLE_ID" ]] || fail \
    "helper is associated with $ACTUAL_ASSOCIATED_ID; expected $APP_BUNDLE_ID"

CODESIGN_COMMON=(--force --timestamp --options runtime --sign "$DEVELOPER_ID_APP")

# ---------------------------------------------------------------------------
# 1. Sign the embedded privileged helper first (inside-out signing order).
# ---------------------------------------------------------------------------
[[ -f "$HELPER_PATH" ]] || fail "embedded helper not found at $HELPER_PATH"
echo "==> Signing embedded helper: $HELPER_PATH"
[[ -f "$HELPER_ENTITLEMENTS" ]] || fail "missing $HELPER_ENTITLEMENTS"
codesign "${CODESIGN_COMMON[@]}" \
    --identifier "$HELPER_NAME" \
    --entitlements "$HELPER_ENTITLEMENTS" \
    "$HELPER_PATH"

# ---------------------------------------------------------------------------
# 2. Sign the app. Nested code is signed explicitly first; signing-time --deep
#    can replace nested signatures and their distinct entitlements.
# ---------------------------------------------------------------------------
echo "==> Signing app: $APP"
codesign "${CODESIGN_COMMON[@]}" \
    --entitlements "$APP_ENTITLEMENTS" \
    "$APP"

echo "==> Verifying app signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || \
    echo "(spctl assessment will pass only after notarization + stapling.)"

# ---------------------------------------------------------------------------
# 3. Notarize and staple the signed app before it enters the DMG.
# ---------------------------------------------------------------------------
echo "==> Packaging app for notarization: $APP_ARCHIVE"
rm -f "$APP_ARCHIVE"
ditto -c -k --keepParent "$APP" "$APP_ARCHIVE"

echo "==> Submitting app to the notary service…"
xcrun notarytool submit "$APP_ARCHIVE" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> Stapling ticket to the app…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# ---------------------------------------------------------------------------
# 4. Create the DMG from the signed, notarized, stapled app.
# ---------------------------------------------------------------------------
echo "==> Creating DMG from the notarized app: $DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ProcExp.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create \
    -volname "Process Explorer" \
    -srcfolder "$STAGE" \
    -ov \
    -fs HFS+ \
    -format UDZO \
    "$DMG"
rm -rf "$STAGE"

# ---------------------------------------------------------------------------
# 5. Sign, notarize, staple, and verify the DMG.
# ---------------------------------------------------------------------------
echo "==> Signing DMG: $DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"

echo "==> Submitting DMG to the notary service…"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> Stapling ticket to the DMG…"
xcrun stapler staple "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
xcrun stapler validate "$DMG"

echo ""
echo "==> DONE — notarized & stapled:"
echo "    $DMG"
echo "Verify on a clean machine with: spctl --assess --type open --context context:primary-signature -v \"$DMG\""
