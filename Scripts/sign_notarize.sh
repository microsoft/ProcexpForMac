#!/usr/bin/env bash
#
# sign_notarize.sh — Developer ID sign, notarize, and staple the Release build.
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
#   3. codesign the DMG.
#   4. notarytool submit --wait, then stapler staple the DMG (and the app).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
APP="$BUILD_DIR/DerivedData/Build/Products/Release/ProcexpMac.app"
DMG="$BUILD_DIR/ProcexpMac.dmg"
APP_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpMac.entitlements"
HELPER_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpHelper.entitlements"
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

[[ -d "$APP" ]] || fail "app not found at $APP — run Scripts/build_release.sh first."
[[ -f "$DMG" ]] || fail "dmg not found at $DMG — run Scripts/build_release.sh first."
[[ -f "$APP_ENTITLEMENTS" ]] || fail "missing $APP_ENTITLEMENTS"

CODESIGN_COMMON=(--force --timestamp --options runtime --sign "$DEVELOPER_ID_APP")

# ---------------------------------------------------------------------------
# 1. Sign the embedded privileged helper first (inside-out signing order).
# ---------------------------------------------------------------------------
[[ -f "$HELPER_PATH" ]] || fail "embedded helper not found at $HELPER_PATH"
echo "==> Signing embedded helper: $HELPER_PATH"
[[ -f "$HELPER_ENTITLEMENTS" ]] || fail "missing $HELPER_ENTITLEMENTS"
codesign "${CODESIGN_COMMON[@]}" \
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
# 3. Sign the DMG.
# ---------------------------------------------------------------------------
echo "==> Signing DMG: $DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"

# ---------------------------------------------------------------------------
# 4. Notarize + staple.
# ---------------------------------------------------------------------------
echo "==> Submitting to notary service (this waits for the result)…"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> Stapling ticket to the DMG…"
xcrun stapler staple "$DMG"

echo "==> Stapling ticket to the app…"
xcrun stapler staple "$APP" || \
    echo "(app staple is optional; the DMG staple is what matters for distribution.)"

echo ""
echo "==> DONE — notarized & stapled:"
echo "    $DMG"
echo "Verify on a clean machine with: spctl --assess --type open --context context:primary-signature -v \"$DMG\""
