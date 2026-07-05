#!/usr/bin/env bash
#
# dev_install_helper.sh — build, sign, install, and launch a ProcexpMac.app that
# can use the privileged root helper (the elevation test path).
#
# This is the everyday "build and run the elevated-capable app" loop. It:
#   1. builds ProcexpMac.app (Debug by default — fast),
#   2. embeds the root helper + launchd plist at the production location,
#   3. signs everything inside-out with a stable (non-ad-hoc) identity,
#   4. installs to /Applications (SMAppService ties the helper registration to
#      the app's signature + this location, so reinstalling the same-identity
#      build keeps the helper registered across rebuilds), and
#   5. launches it.
#
# First run: if the default self-signed identity does not exist yet, it is
# created automatically (via Scripts/dev_make_signing_id.sh). Then use the app's
# "Install Privileged Helper…" menu once and approve it in System Settings ▸
# General ▸ Login Items & Extensions. After that, every subsequent run of this
# script rebuilds and relaunches the signed app with the helper already enabled.
#
# NOTE ON HELPER CODE CHANGES: the running root daemon keeps executing the
# already-loaded binary until it is restarted. Changes to the APP are picked up
# on relaunch, but changes to the HELPER's own code require restarting the
# daemon — pass RESTART_HELPER=1 (prompts for sudo) to do that.
#
# Env:
#   CONFIGURATION               Debug (default) or Release
#   DEV_SIGN_IDENTITY           signing identity (default: "ProcexpMac Dev")
#   DEV_SIGN_KEYCHAIN           keychain holding it (default: procexp-dev.keychain-db)
#   DEV_SIGN_KEYCHAIN_PASSWORD  its password (default: "procexp-dev")
#   INSTALL_DIR                 install destination (default: /Applications)
#   RESTART_HELPER              1 to restart the root daemon after install (sudo)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${CONFIGURATION:-Debug}"
IDENTITY="${DEV_SIGN_IDENTITY:-ProcexpMac Dev}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEFAULT_KEYCHAIN="$HOME/Library/Keychains/procexp-dev.keychain-db"
SIGN_KEYCHAIN="${DEV_SIGN_KEYCHAIN:-$DEFAULT_KEYCHAIN}"
SIGN_KEYCHAIN_PASSWORD="${DEV_SIGN_KEYCHAIN_PASSWORD:-procexp-dev}"
RESTART_HELPER="${RESTART_HELPER:-0}"
BUILD_DIR="$REPO_ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
APP_SRC="$DERIVED/Build/Products/$CONFIGURATION/ProcexpMac.app"
APP_DEST="$INSTALL_DIR/ProcexpMac.app"
APP_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpMac.entitlements"
HELPER_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpHelper.entitlements"
HELPER_NAME="com.sysinternals.procexpmac.helper"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Auto-create the default self-signed identity on first use.
# ---------------------------------------------------------------------------
if ! security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    if [[ "$IDENTITY" == "ProcexpMac Dev" ]]; then
        echo "==> Signing identity \"$IDENTITY\" not found — creating it…"
        DEV_SIGN_KEYCHAIN="$SIGN_KEYCHAIN" \
        DEV_SIGN_KEYCHAIN_PASSWORD="$SIGN_KEYCHAIN_PASSWORD" \
        bash "$REPO_ROOT/Scripts/dev_make_signing_id.sh" "$IDENTITY"
    fi
fi

# ---------------------------------------------------------------------------
# Unlock the dedicated signing keychain so codesign can use the private key
# without an interactive prompt.
# ---------------------------------------------------------------------------
if [[ -n "$SIGN_KEYCHAIN" && -f "$SIGN_KEYCHAIN" ]]; then
    if [[ -n "$SIGN_KEYCHAIN_PASSWORD" ]]; then
        security unlock-keychain -p "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
    fi
    # Make sure it's on the search list so find-identity/codesign see it.
    EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g' | tr '\n' ' ')"
    case " $EXISTING " in
        *" $SIGN_KEYCHAIN "*) : ;;
        # shellcheck disable=SC2086
        *) security list-keychains -d user -s "$SIGN_KEYCHAIN" $EXISTING ;;
    esac
fi

# ---------------------------------------------------------------------------
# Verify the identity exists and classify it.
# ---------------------------------------------------------------------------
# NOTE: use the unfiltered list (not `-v`), because a self-signed identity is
# reported CSSMERR_TP_NOT_TRUSTED and excluded from the "valid only" list even
# though codesign can sign with it perfectly well.
security find-identity -p codesigning | grep -qF "$IDENTITY" \
    || fail "signing identity not found in keychain: \"$IDENTITY\"
       Available:
$(security find-identity -p codesigning)"

IS_DEVELOPER_ID=0
if [[ "$IDENTITY" == *"Developer ID"* ]]; then
    IS_DEVELOPER_ID=1
fi

echo "==> Using signing identity: $IDENTITY"
if [[ "$IS_DEVELOPER_ID" -eq 0 ]]; then
    cat <<'NOTE'
    NOTE: this is a self-signed identity. SMAppService will register the daemon
    only after you approve it once in System Settings ▸ General ▸ Login Items &
    Extensions (use the app's "Install Privileged Helper…" menu the first time).
    After approval the registration persists across rebuilds signed with the
    same identity.
NOTE
fi

# ---------------------------------------------------------------------------
# 1. Build the app.
# ---------------------------------------------------------------------------
echo "==> Regenerating Xcode project (xcodegen)…"
xcodegen generate >/dev/null

echo "==> Building $CONFIGURATION app…"
xcodebuild -project ProcexpMac.xcodeproj -scheme ProcexpMac \
    -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" build >/dev/null
[[ -d "$APP_SRC" ]] || fail "expected app not found at $APP_SRC"

# ---------------------------------------------------------------------------
# 2. Embed the helper + plist at the production location.
# ---------------------------------------------------------------------------
bash "$REPO_ROOT/Scripts/embed_helper.sh" "$APP_SRC"
HELPER_PATH="$APP_SRC/Contents/Library/LaunchDaemons/$HELPER_NAME"

# ---------------------------------------------------------------------------
# 3. Inside-out code signing with the chosen identity.
#
# The Hardened Runtime enables *library validation*, which rejects any nested
# Mach-O whose Team ID differs from the main binary's. Self-signed certificates
# have no Team ID, so a hardened self-signed app cannot load its own Debug side
# dylibs (ProcexpMac.debug.dylib) — dyld exits with "different Team IDs". For
# self-signed builds we therefore add the cs.disable-library-validation
# entitlement, which turns library validation off even under the Hardened
# Runtime. Developer ID builds keep validation on (their Team ID matches).
# ---------------------------------------------------------------------------
SIGN=(codesign --force --options runtime --timestamp=none --sign "$IDENTITY")

echo "==> Signing nested frameworks/dylibs…"
if [[ -d "$APP_SRC/Contents/Frameworks" ]]; then
    while IFS= read -r -d '' item; do
        "${SIGN[@]}" "$item"
    done < <(find "$APP_SRC/Contents/Frameworks" -type d -name "*.framework" -print0)
    while IFS= read -r -d '' item; do
        "${SIGN[@]}" "$item"
    done < <(find "$APP_SRC/Contents/Frameworks" -type f -name "*.dylib" -print0)
fi

# Debug builds ship side dylibs (ProcexpMac.debug.dylib, __preview.dylib) in
# Contents/MacOS; sign them with the same identity as the app.
echo "==> Signing nested executables in Contents/MacOS…"
while IFS= read -r -d '' item; do
    "${SIGN[@]}" "$item"
done < <(find "$APP_SRC/Contents/MacOS" -type f -name "*.dylib" -print0)

echo "==> Signing embedded helper (with debugger entitlement)…"
"${SIGN[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$HELPER_PATH"

echo "==> Signing app bundle…"
if [[ "$IS_DEVELOPER_ID" -eq 1 ]]; then
    # Developer ID: the restricted managed-by-launchd entitlement + validation on.
    "${SIGN[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_SRC"
else
    # Self-signed: disable library validation so the Debug side dylibs load, and
    # omit the restricted com.apple.developer.* entitlement (which blocks launch).
    DEV_ENT="$(mktemp -t procexp-dev-ent).plist"
    cat > "$DEV_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST
    "${SIGN[@]}" --entitlements "$DEV_ENT" "$APP_SRC"
    rm -f "$DEV_ENT"
fi

echo "==> Verifying signature…"
codesign --verify --strict --verbose=2 "$APP_SRC" || \
    echo "(verification warnings above are expected for self-signed builds.)"

# ---------------------------------------------------------------------------
# 4. Install to a stable location and launch.
# ---------------------------------------------------------------------------
echo "==> Installing to $APP_DEST"
# Best-effort: quit any running copy, then swap in the new build.
if pgrep -x ProcexpMac >/dev/null; then pkill -x ProcexpMac || true; fi
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Optionally restart the root daemon so it loads the freshly built helper
#    binary (needed only when the HELPER's own code changed).
# ---------------------------------------------------------------------------
if [[ "$RESTART_HELPER" == "1" ]]; then
    if launchctl print "system/$HELPER_NAME" >/dev/null 2>&1; then
        echo "==> Restarting the root helper daemon (sudo)…"
        sudo launchctl kickstart -k "system/$HELPER_NAME" || \
            echo "(could not restart the daemon; it may reload on next connect.)"
    fi
fi

echo "==> Launching $APP_DEST"
open -n "$APP_DEST"

HELPER_STATE="not registered"
if launchctl print "system/$HELPER_NAME" >/dev/null 2>&1; then
    HELPER_STATE="registered (elevated path available)"
fi

cat <<EOF

==> DONE.
    Installed: $APP_DEST
    Config:    $CONFIGURATION
    Identity:  $IDENTITY
    Helper:    $HELPER_STATE

First-time only: choose "Install Privileged Helper…" in the app, then approve it
in System Settings ▸ General ▸ Login Items & Extensions.

If you changed the HELPER's code, reload the daemon with:
  RESTART_HELPER=1 bash Scripts/dev_install_helper.sh

Inspect daemon status:
  launchctl print system/$HELPER_NAME 2>/dev/null || echo "not registered"

Clean up:
  bash Scripts/dev_uninstall_helper.sh
EOF

