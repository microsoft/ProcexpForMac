#!/usr/bin/env bash
#
# dev_uninstall_helper.sh — undo Scripts/dev_install_helper.sh.
#
# Removes the installed app, and best-effort unregisters/boots out the helper
# daemon whether it was registered via SMAppService or loaded manually.
#
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_DEST="$INSTALL_DIR/ProcexpMac.app"
HELPER_NAME="com.sysinternals.procexpmac.helper"

echo "==> Quitting the app if running…"
pkill -x ProcexpMac 2>/dev/null || true

echo "==> Attempting to boot out the daemon (needs sudo; ignore if absent)…"
sudo launchctl bootout "system/$HELPER_NAME" 2>/dev/null \
    && echo "    booted out system/$HELPER_NAME" \
    || echo "    system/$HELPER_NAME was not loaded"

# Remove a manually-installed LaunchDaemon plist, if any.
if [[ -f "/Library/LaunchDaemons/${HELPER_NAME}.plist" ]]; then
    echo "==> Removing /Library/LaunchDaemons/${HELPER_NAME}.plist"
    sudo rm -f "/Library/LaunchDaemons/${HELPER_NAME}.plist"
fi
if [[ -f "/Library/PrivilegedHelperTools/${HELPER_NAME}" ]]; then
    echo "==> Removing /Library/PrivilegedHelperTools/${HELPER_NAME}"
    sudo rm -f "/Library/PrivilegedHelperTools/${HELPER_NAME}"
fi

echo "==> Removing $APP_DEST"
rm -rf "$APP_DEST"

cat <<EOF

==> DONE.
If the daemon was registered via SMAppService, macOS may still list it under
System Settings ▸ General ▸ Login Items & Extensions until you remove it there
(or until the registering app calls SMAppService.unregister()).
EOF
