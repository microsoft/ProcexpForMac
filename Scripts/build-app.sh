#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
APP_NAME="ProcexpMac.app"
SOURCE_APP="$REPO_ROOT/build/DerivedData/Build/Products/Release/$APP_NAME"
OUTPUT_APP="$REPO_ROOT/.build/$APP_NAME"
APP_EXECUTABLE="$OUTPUT_APP/Contents/MacOS/ProcexpMac"
HELPER_NAME="com.sysinternals.procexpmac.helper"
HELPER="$OUTPUT_APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
APP_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpMac.entitlements"
HELPER_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpHelper.entitlements"
REQUIRED_ARCHITECTURES=(arm64 x86_64)

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$CONFIGURATION" == "release" ]] || fail "only the release configuration is supported"
command -v xcodebuild >/dev/null || fail "full Xcode is required"
command -v swift >/dev/null || fail "Swift is required"

if ! command -v xcodegen >/dev/null; then
    command -v brew >/dev/null || fail "xcodegen is required and Homebrew is unavailable"
    echo "==> Installing xcodegen"
    brew install xcodegen
fi

echo "==> Building Universal release app and helper"
PACKAGE_DMG=0 HELPER_ARCHS="${REQUIRED_ARCHITECTURES[*]}" \
    bash "$REPO_ROOT/Scripts/build_release.sh"

[[ -d "$SOURCE_APP" ]] || fail "expected app not found: $SOURCE_APP"
rm -rf "$OUTPUT_APP"
mkdir -p "$REPO_ROOT/.build"
ditto "$SOURCE_APP" "$OUTPUT_APP"

[[ -f "$APP_EXECUTABLE" ]] || fail "app executable not found: $APP_EXECUTABLE"
[[ -f "$HELPER" ]] || fail "embedded helper not found: $HELPER"

verify_architectures() {
    local label="$1"
    local binary="$2"
    local actual
    actual="$(lipo -archs "$binary")"
    echo "$label architectures: $actual"
    for required in "${REQUIRED_ARCHITECTURES[@]}"; do
        [[ " $actual " == *" $required "* ]] || fail "$label is missing $required"
    done
}

verify_entitlement() {
    local label="$1"
    local path="$2"
    local key="$3"
    local plist
    plist="$(mktemp)"
    codesign -d --entitlements :- "$path" >"$plist"
    if ! plutil -lint "$plist" >/dev/null; then
        cat "$plist" >&2
        rm -f "$plist"
        fail "could not extract $label entitlements"
    fi
    local value
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
    if [[ "$value" != "true" ]]; then
        echo "$label entitlements:" >&2
        plutil -p "$plist" >&2
    fi
    rm -f "$plist"
    [[ "$value" == "true" ]] || fail "$label is missing required entitlement $key"
}

verify_architectures "app" "$APP_EXECUTABLE"
verify_architectures "helper" "$HELPER"

echo "==> Applying inside-out ad-hoc transport signatures"
codesign --force --options runtime --sign - \
    --entitlements "$HELPER_ENTITLEMENTS" \
    "$HELPER"
codesign --force --options runtime --sign - \
    --entitlements "$APP_ENTITLEMENTS" \
    "$OUTPUT_APP"

codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
verify_entitlement "app" "$OUTPUT_APP" \
    "com.apple.developer.service-management.managed-by-launchd"
verify_entitlement "helper" "$HELPER" \
    "com.apple.security.cs.debugger"

echo "==> Pipeline app ready: $OUTPUT_APP"
codesign -d --verbose=4 "$OUTPUT_APP" 2>&1 || true
codesign -d --verbose=4 "$HELPER" 2>&1 || true
