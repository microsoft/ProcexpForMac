#!/usr/bin/env bash
#
# embed_helper.sh — build the privileged root helper (W2) and embed it into an
# existing ProcexpMac.app bundle at the exact production location
# (Contents/Library/LaunchDaemons), alongside its launchd plist.
#
# This is the same layout SMAppService.daemon(plistName:) expects, so the
# in-app "Install Privileged Helper…" button exercises the real code path once
# the bundle is signed. Signing is done separately:
#   • Developer ID release:  Scripts/sign_notarize.sh
#   • Local self-signed test: Scripts/dev_install_helper.sh
#
# Usage: embed_helper.sh /path/to/ProcexpMac.app
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$APP" ]] || fail "usage: embed_helper.sh /path/to/ProcexpMac.app"
[[ -d "$APP" ]] || fail "app bundle not found: $APP"

HELPER_NAME="com.sysinternals.procexpmac.helper"
PLIST_SRC="$REPO_ROOT/Helper/${HELPER_NAME}.plist"
DEST_DIR="$APP/Contents/Library/LaunchDaemons"

[[ -f "$PLIST_SRC" ]] || fail "missing launchd plist: $PLIST_SRC"

SWIFT_ARCH_ARGS=()
for arch in ${HELPER_ARCHS:-}; do
	SWIFT_ARCH_ARGS+=(--arch "$arch")
done

if (( ${#SWIFT_ARCH_ARGS[@]} > 0 )); then
	echo "==> Building Universal helper for: ${HELPER_ARCHS}"
else
	echo "==> Building helper for the native architecture"
fi

( cd "$REPO_ROOT" && swift build -c release --product ProcexpHelper "${SWIFT_ARCH_ARGS[@]}" >/dev/null )

# Resolve the built binary regardless of SwiftPM's arch-specific bin path.
HELPER_BIN="$(cd "$REPO_ROOT" && swift build -c release --product ProcexpHelper "${SWIFT_ARCH_ARGS[@]}" --show-bin-path)/ProcexpHelper"
[[ -f "$HELPER_BIN" ]] || fail "helper binary not found at $HELPER_BIN"

echo "==> Embedding into $DEST_DIR"
mkdir -p "$DEST_DIR"
cp "$HELPER_BIN" "$DEST_DIR/$HELPER_NAME"
cp "$PLIST_SRC" "$DEST_DIR/${HELPER_NAME}.plist"
chmod 755 "$DEST_DIR/$HELPER_NAME"

echo "==> Embedded:"
echo "    $DEST_DIR/$HELPER_NAME"
echo "    $DEST_DIR/${HELPER_NAME}.plist"
