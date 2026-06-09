#!/bin/bash
#
# Create a stable, self-signed code-signing certificate so macOS keeps your
# Accessibility grant across rebuilds AND auto-updates. Run this ONCE.
#
#   Scripts/make-signing-cert.sh
#
# Why: macOS ties the Accessibility (TCC) grant to the app's code signature. An
# ad-hoc signature changes on every build, so each upgrade looks like a new app
# and the grant is lost. Signing every build (local + CI) with the SAME cert
# keeps the grant.
#
# After running it:
#   • Local builds:  export MACSANITY_SIGN_IDENTITY="MacSanity Self-Signed"
#                    Scripts/build-app.sh release
#   • CI releases:   add the two GitHub secrets printed at the end, so the builds
#                    your updater downloads carry the same identity.
#
# You only need to grant Accessibility once more after switching to a signed
# build; from then on it persists.

set -euo pipefail

NAME="MacSanity Self-Signed"
PASSWORD="macsanity"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
	echo "An identity named '$NAME' already exists — nothing to do."
	exit 0
fi

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf"

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
	-name "$NAME" -out "$WORK/cert.p12" -passout "pass:$PASSWORD"

echo "==> Importing into your login keychain (lets codesign use it without prompts)"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign -A

echo "==> Trusting it for code signing (you may be asked for your login password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null \
	|| echo "   (trust step skipped — signing still works; you can ignore codesign's chain warning)"

CI_OUT="$HOME/macsanity-signing-cert.b64"
base64 < "$WORK/cert.p12" > "$CI_OUT"

cat <<MSG

Done. Verify the identity exists:
  security find-identity -v -p codesigning   # should list "$NAME"

Local signed builds:
  export MACSANITY_SIGN_IDENTITY="$NAME"
  Scripts/build-app.sh release

CI signing (so released/auto-updated builds keep the grant too):
  gh secret set MACSANITY_CERT_P12 < "$CI_OUT"
  gh secret set MACSANITY_CERT_PASSWORD --body "$PASSWORD"
  rm "$CI_OUT"      # delete the exported key once the secret is set
MSG
