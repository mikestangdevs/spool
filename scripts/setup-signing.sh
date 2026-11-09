#!/bin/bash
# Creates a self-signed code signing identity for local builds, once.
#
# Why: macOS ties the Accessibility permission to an app's signature. An unsigned (ad-hoc)
# build gets a new signature every time, so the permission is lost on every rebuild. Signing
# each build with the same certificate keeps it.
#
# The certificate lives in its own keychain with a fixed password, so nothing here touches
# your login keychain or asks for your password. It is only good for running your own
# builds on this Mac; it is not trusted by anyone else's and cannot be used to distribute.
set -euo pipefail

NAME="Spool Local Signing"
KEYCHAIN="$HOME/Library/Keychains/spool-signing.keychain-db"
PASS="spool-local"

if [ -f "$KEYCHAIN" ] && security unlock-keychain -p "$PASS" "$KEYCHAIN" 2>/dev/null \
    && security find-identity "$KEYCHAIN" | grep -q "$NAME"; then
    exit 0
fi

echo "Creating the local signing identity \"$NAME\" (one time)..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# The system's own openssl: Homebrew's newer one writes a .p12 that `security` cannot read.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$PASS" -name "$NAME"

[ -f "$KEYCHAIN" ] || security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # never lock on a timer
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a "codesign wants to access..." dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

# Add the keychain to the search list, keeping the ones already there.
KEYCHAINS=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"; line="${line%\"}"
    [ -n "$line" ] && [ "$line" != "$KEYCHAIN" ] && KEYCHAINS+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${KEYCHAINS[@]}" "$KEYCHAIN"

echo "Done. Builds will now keep their Accessibility permission."
