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

HELPER_BIN=""
if [[ -n "${HELPER_ARCHS:-}" ]]; then
	command -v lipo >/dev/null || fail "lipo is required for a Universal helper build"
	echo "==> Building Universal helper for: ${HELPER_ARCHS}"

	HELPER_BUILD_ROOT="$REPO_ROOT/.build/procexp-helper"
	UNIVERSAL_HELPER="$HELPER_BUILD_ROOT/universal/$HELPER_NAME"
	HELPER_BINARIES=()
	rm -rf "$HELPER_BUILD_ROOT"

	# SwiftPM's multi-value --arch build is unreliable for executable products.
	# Build each slice in an isolated scratch directory, then combine the final
	# executables explicitly so any architecture-specific error remains visible.
	for arch in ${HELPER_ARCHS}; do
		SCRATCH_PATH="$HELPER_BUILD_ROOT/$arch"
		echo "==> Building helper slice: $arch"
		(
			cd "$REPO_ROOT"
			swift build -c release --product ProcexpHelper \
				--arch "$arch" --scratch-path "$SCRATCH_PATH"
		)
		BIN_PATH="$(
			cd "$REPO_ROOT"
			swift build -c release --product ProcexpHelper \
				--arch "$arch" --scratch-path "$SCRATCH_PATH" \
				--show-bin-path
		)/ProcexpHelper"
		[[ -f "$BIN_PATH" ]] || fail "$arch helper binary not found at $BIN_PATH"
		HELPER_BINARIES+=("$BIN_PATH")
	done

	mkdir -p "$(dirname "$UNIVERSAL_HELPER")"
	if (( ${#HELPER_BINARIES[@]} == 1 )); then
		cp "${HELPER_BINARIES[0]}" "$UNIVERSAL_HELPER"
	else
		lipo -create "${HELPER_BINARIES[@]}" -output "$UNIVERSAL_HELPER"
	fi
	HELPER_BIN="$UNIVERSAL_HELPER"
	echo "==> Universal helper architectures: $(lipo -archs "$HELPER_BIN")"
else
	echo "==> Building helper for the native architecture"
	( cd "$REPO_ROOT" && swift build -c release --product ProcexpHelper )
	HELPER_BIN="$(cd "$REPO_ROOT" && swift build -c release --product ProcexpHelper --show-bin-path)/ProcexpHelper"
	[[ -f "$HELPER_BIN" ]] || fail "helper binary not found at $HELPER_BIN"
fi

echo "==> Embedding into $DEST_DIR"
mkdir -p "$DEST_DIR"
cp "$HELPER_BIN" "$DEST_DIR/$HELPER_NAME"
cp "$PLIST_SRC" "$DEST_DIR/${HELPER_NAME}.plist"
chmod 755 "$DEST_DIR/$HELPER_NAME"

echo "==> Embedded:"
echo "    $DEST_DIR/$HELPER_NAME"
echo "    $DEST_DIR/${HELPER_NAME}.plist"
