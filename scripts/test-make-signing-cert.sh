#!/usr/bin/env bash
# Sandbox test for scripts/make-signing-cert.sh: it runs in a temp folder with gh, curl
# and security replaced by stand-ins that record any call, so nothing is uploaded and no
# keychain is touched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
MAKE="$REPO/scripts/make-signing-cert.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

bash -n "$MAKE" || fail "make-signing-cert.sh has a syntax error"
FAKE="$T/fakebin"
mkdir -p "$FAKE"
for tool in gh curl security; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 1\n' "$tool" "$T" > "$FAKE/$tool"
  chmod +x "$FAKE/$tool"
done
OUT="$T/out.txt"
run() { env PATH="$FAKE:$PATH" "$MAKE" "$@" >"$OUT" 2>&1; }
OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=openssl

# 1. It writes a code-signing identity and prints the two secret values.
run --out "$T/cert" || { cat "$OUT"; fail "make-signing-cert.sh exited non-zero"; }
p12_b64="$(sed -n 's/^MACOS_SIGN_P12=//p' "$OUT")"
password="$(sed -n 's/^MACOS_SIGN_PASSWORD=//p' "$OUT")"
[ -n "$p12_b64" ] || { cat "$OUT"; fail "no MACOS_SIGN_P12 line"; }
[ "${#password}" -ge 24 ] || fail "the password is too short (${#password})"
printf '%s' "$p12_b64" | base64 --decode > "$T/decoded.p12"
cmp -s "$T/decoded.p12" "$T/cert/hook-signing.p12" || fail "the printed value is not the .p12 file"
"$OPENSSL" pkcs12 -in "$T/decoded.p12" -passin "pass:$password" -nokeys -clcerts 2>/dev/null > "$T/cert.pem" \
  || fail "the .p12 does not open with the printed password"
"$OPENSSL" pkcs12 -in "$T/decoded.p12" -passin "pass:$password" -nocerts -nodes 2>/dev/null | grep -q 'PRIVATE KEY' \
  || fail "the .p12 holds no private key"
text="$("$OPENSSL" x509 -in "$T/cert.pem" -noout -text)"
printf '%s' "$text" | grep -q 'Code Signing' || fail "the certificate is not for code signing"
printf '%s' "$text" | grep -q 'CN *= *Hook Code Signing\|CN=Hook Code Signing' || fail "the certificate is not named Hook Code Signing"
"$OPENSSL" x509 -in "$T/cert.pem" -noout -checkend $((5 * 365 * 86400)) >/dev/null || fail "the certificate expires within 5 years"
[ "$(stat -f '%Lp' "$T/cert")" = "700" ] || fail "the folder is not 700"
for f in "$T/cert"/*; do [ "$(stat -f '%Lp' "$f")" = "600" ] || fail "$f is not 600"; done
[ ! -e "$T/cert/key.pem" ] || fail "the unencrypted key was left behind"
grep -q 'gh secret set MACOS_SIGN_P12' "$OUT" || fail "no hint for storing the secrets"
[ ! -e "$T/calls.log" ] || fail "it called $(cat "$T/calls.log")"
ok "a code-signing identity and the two secret values; nothing uploaded"

# 2. An existing identity is never overwritten.
before="$(shasum "$T/cert/hook-signing.p12")"
if run --out "$T/cert"; then fail "an existing identity was overwritten"; fi
grep -q 'already' "$OUT" || { cat "$OUT"; fail "no reason for refusing"; }
[ "$(shasum "$T/cert/hook-signing.p12")" = "$before" ] || fail "the .p12 changed"
ok "existing identity kept"

# 3. --name names the certificate.
run --out "$T/cert2" --name "Example Signing" || { cat "$OUT"; fail "--name exited non-zero"; }
password="$(sed -n 's/^MACOS_SIGN_PASSWORD=//p' "$OUT")"
"$OPENSSL" pkcs12 -in "$T/cert2/hook-signing.p12" -passin "pass:$password" -nokeys -clcerts 2>/dev/null \
  | "$OPENSSL" x509 -noout -subject | grep -q 'Example Signing' || fail "--name was ignored"
ok "--name"

echo "SIGNING CERT TESTS OK"
