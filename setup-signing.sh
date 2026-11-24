#!/bin/bash
# Creates a local, self-signed code-signing identity in its own keychain.
# With a stable signature macOS keeps the permissions you grant MemBar
# (Files, Accessibility, Automation) across rebuilds instead of asking again.
# Nothing is added to your login keychain and the key never leaves this Mac.
set -e
KC="$HOME/Library/Keychains/membar-signing.keychain-db"
NAME="MemBar Local Signing"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "Signing identity already exists."; exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:membar

rm -f "$KC"
security create-keychain -p "" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "" "$KC"
security import "$TMP/id.p12" -k "$KC" -P membar -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null 2>&1 || true
echo "Created signing identity: $NAME"
