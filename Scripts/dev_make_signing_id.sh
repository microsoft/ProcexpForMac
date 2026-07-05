#!/usr/bin/env bash
#
# dev_make_signing_id.sh — create a throwaway self-signed code-signing identity
# in a DEDICATED keychain whose password we control, so `codesign` works
# non-interactively without touching your (possibly out-of-sync) login keychain.
#
# This identity is self-signed: it lets you build/sign/launch the app locally
# and drive the real SMAppService flow, but it will NOT let SMAppService
# register the root daemon (that requires a Developer ID Application cert).
#
# Usage:  dev_make_signing_id.sh ["Identity Name"]
# Env:    DEV_SIGN_KEYCHAIN           (default ~/Library/Keychains/procexp-dev.keychain-db)
#         DEV_SIGN_KEYCHAIN_PASSWORD  (default "procexp-dev" — throwaway)
#
set -euo pipefail

NAME="${1:-ProcexpMac Dev}"
KEYCHAIN="${DEV_SIGN_KEYCHAIN:-$HOME/Library/Keychains/procexp-dev.keychain-db}"
KC_PASS="${DEV_SIGN_KEYCHAIN_PASSWORD:-procexp-dev}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code-signing certificate: \"$NAME\""
cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" -passout pass:"$KC_PASS" >/dev/null 2>&1

echo "==> (Re)creating dedicated keychain: $KEYCHAIN"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

echo "==> Importing identity and authorizing codesign…"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$KC_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1

# Prepend to the user search list, preserving existing keychains.
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g' | tr '\n' ' ')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

cat <<EOF

==> DONE. Identity ready: "$NAME"
    Keychain: $KEYCHAIN

Use it:
    DEV_SIGN_IDENTITY="$NAME" \\
    DEV_SIGN_KEYCHAIN="$KEYCHAIN" \\
    DEV_SIGN_KEYCHAIN_PASSWORD="$KC_PASS" \\
    bash Scripts/dev_install_helper.sh

Remove it later:
    security delete-keychain "$KEYCHAIN"
EOF
