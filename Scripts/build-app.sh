#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
SOURCE_APP_NAME="ProcexpMac.app"
APP_NAME="ProcExp.app"
APP_BUNDLE_ID="com.sysinternals.procexpmac"
APP_DISPLAY_NAME="Process Explorer"
SOURCE_APP="$REPO_ROOT/build/DerivedData/Build/Products/Release/$SOURCE_APP_NAME"
OUTPUT_APP="$REPO_ROOT/.build/$APP_NAME"
APP_EXECUTABLE="$OUTPUT_APP/Contents/MacOS/ProcexpMac"
HELPER_NAME="com.sysinternals.procexpmac.helper"
HELPER="$OUTPUT_APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
HELPER_PLIST="$OUTPUT_APP/Contents/Library/LaunchDaemons/$HELPER_NAME.plist"
HELPER_ENTITLEMENTS="$REPO_ROOT/Helper/ProcexpHelper.entitlements"
REQUIRED_ARCHITECTURES=(arm64 x86_64)
VERSION="${PROCEXP_VERSION:-0.1}"
BUILD_VERSION="${PROCEXP_BUILD_VERSION:-$VERSION}"
VERSION_PATTERN='^[0-9]+\.[0-9]+(\.[0-9]+)?$'

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$CONFIGURATION" == "release" ]] || fail "only the release configuration is supported"
[[ "$VERSION" =~ $VERSION_PATTERN ]] || fail \
    "PROCEXP_VERSION must be a dotted numeric version such as 1.0 or 1.0.0 (got '$VERSION')"
[[ "$BUILD_VERSION" =~ $VERSION_PATTERN ]] || fail \
    "PROCEXP_BUILD_VERSION must be a dotted numeric version such as 1.0 or 1.0.0 (got '$BUILD_VERSION')"
case "${PROCEXP_REQUIRE_RELEASE_VERSION:-false}" in
    true|True|TRUE|1)
        [[ "$VERSION" != "0.0.0" ]] || fail \
            "replace the 0.0.0 placeholder with the intended release version"
        [[ "$BUILD_VERSION" != "0.0.0" ]] || fail \
            "replace the 0.0.0 build-version placeholder with the intended release version"
        ;;
esac
command -v xcodebuild >/dev/null || fail "full Xcode is required"
command -v swift >/dev/null || fail "Swift is required"

if ! command -v xcodegen >/dev/null; then
    command -v brew >/dev/null || fail "xcodegen is required and Homebrew is unavailable"
    echo "==> Installing xcodegen"
    brew install xcodegen
fi

echo "==> Building Universal release app and helper"
PROCEXP_VERSION="$VERSION" PROCEXP_BUILD_VERSION="$BUILD_VERSION" \
    PROCEXP_BUILD_FLAVOR=official PACKAGE_DMG=0 \
    HELPER_ARCHS="${REQUIRED_ARCHITECTURES[*]}" \
    bash "$REPO_ROOT/Scripts/build_release.sh"

[[ -d "$SOURCE_APP" ]] || fail "expected app not found: $SOURCE_APP"
rm -rf "$OUTPUT_APP"
mkdir -p "$REPO_ROOT/.build"
ditto "$SOURCE_APP" "$OUTPUT_APP"

[[ -f "$APP_EXECUTABLE" ]] || fail "app executable not found: $APP_EXECUTABLE"
[[ -f "$HELPER" ]] || fail "embedded helper not found: $HELPER"
[[ -f "$HELPER_PLIST" ]] || fail "embedded helper plist not found: $HELPER_PLIST"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

verify_value() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    [[ "$actual" == "$expected" ]] || fail \
        "$label is '$actual'; expected '$expected'"
}

APP_INFO_PLIST="$OUTPUT_APP/Contents/Info.plist"
verify_value "app CFBundleIdentifier" \
    "$(plist_value "$APP_INFO_PLIST" CFBundleIdentifier)" "$APP_BUNDLE_ID"
verify_value "app CFBundleDisplayName" \
    "$(plist_value "$APP_INFO_PLIST" CFBundleDisplayName)" "$APP_DISPLAY_NAME"
verify_value "app CFBundleShortVersionString" \
    "$(plist_value "$APP_INFO_PLIST" CFBundleShortVersionString)" "$VERSION"
verify_value "app CFBundleVersion" \
    "$(plist_value "$APP_INFO_PLIST" CFBundleVersion)" "$BUILD_VERSION"

verify_value "helper launchd Label" \
    "$(plist_value "$HELPER_PLIST" Label)" "$HELPER_NAME"
verify_value "helper BundleProgram" \
    "$(plist_value "$HELPER_PLIST" BundleProgram)" \
    "Contents/Library/LaunchDaemons/$HELPER_NAME"
verify_value "helper MachServices name" \
    "$(plist_value "$HELPER_PLIST" "MachServices:$HELPER_NAME")" "true"
verify_value "helper AssociatedBundleIdentifiers" \
    "$(plist_value "$HELPER_PLIST" "AssociatedBundleIdentifiers:0")" "$APP_BUNDLE_ID"
verify_value "helper RunAtLoad" \
    "$(plist_value "$HELPER_PLIST" RunAtLoad)" "false"
verify_value "helper development environment" \
    "$(plist_value "$HELPER_PLIST" "EnvironmentVariables:PROCEXP_HELPER_FLAVOR")" ""

grep -Fq "public static let officialAppBundleID = \"$APP_BUNDLE_ID\"" \
    "$REPO_ROOT/Sources/ProcexpPrivileged/HelperProtocol.swift" || fail \
    "HelperProtocol official app identifier does not match $APP_BUNDLE_ID"
grep -Fq "public static let officialHelperBundleID = \"$HELPER_NAME\"" \
    "$REPO_ROOT/Sources/ProcexpPrivileged/HelperProtocol.swift" || fail \
    "HelperProtocol official helper identifier does not match $HELPER_NAME"
grep -Fq "private static let officialAppIdentifier = HelperConstants.officialAppBundleID" \
    "$REPO_ROOT/Sources/ProcexpHelper/PeerValidation.swift" || fail \
    "release peer requirement does not use the shared official app identifier"

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

verify_entitlement_absent() {
    local label="$1"
    local path="$2"
    local key="$3"
    local plist
    plist="$(mktemp)"
    codesign -d --entitlements :- "$path" >"$plist"
    if [[ ! -s "$plist" ]]; then
        rm -f "$plist"
        return 0
    fi
    local value
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
    rm -f "$plist"
    [[ -z "$value" ]] || fail "$label contains forbidden entitlement $key"
}

verify_signed_identifier() {
    local label="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual="$(codesign -d --verbose=4 "$path" 2>&1 | sed -n 's/^Identifier=//p' | head -1)"
    verify_value "$label signed identifier" "$actual" "$expected"
}

verify_architectures "app" "$APP_EXECUTABLE"
verify_architectures "helper" "$HELPER"

echo "==> Applying inside-out ad-hoc transport signatures"
codesign --force --options runtime --sign - \
    --identifier "$HELPER_NAME" \
    --entitlements "$HELPER_ENTITLEMENTS" \
    "$HELPER"
codesign --force --options runtime --sign - \
    "$OUTPUT_APP"

codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
verify_signed_identifier "app" "$OUTPUT_APP" "$APP_BUNDLE_ID"
verify_signed_identifier "helper" "$HELPER" "$HELPER_NAME"
verify_entitlement_absent "app" "$OUTPUT_APP" \
    "com.apple.developer.service-management.managed-by-launchd"
verify_entitlement "helper" "$HELPER" \
    "com.apple.security.cs.debugger"

echo "==> Pipeline app ready: $OUTPUT_APP"
echo "    bundle id: $APP_BUNDLE_ID"
echo "    version: $VERSION ($BUILD_VERSION)"
codesign -d --verbose=4 "$OUTPUT_APP" 2>&1 || true
codesign -d --verbose=4 "$HELPER" 2>&1 || true
