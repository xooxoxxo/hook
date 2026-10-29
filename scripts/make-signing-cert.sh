#!/usr/bin/env bash
# Makes a self-signed code-signing certificate for Hook's release builds, and prints the
# two values to store as repository secrets (Settings › Secrets and variables › Actions):
#   MACOS_SIGN_P12       the identity (certificate and private key) as a base64 .p12
#   MACOS_SIGN_PASSWORD  the .p12's password
#   scripts/make-signing-cert.sh [--out <dir>] [--name <certificate name>]
# The files go to <dir> (default ./signing, mode 0700, git-ignored). Keep them somewhere
# safe: a new certificate is a new identity, and macOS then asks once more for Keychain
# access after the next update. This script uploads nothing and touches no keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

die() { echo "make-signing-cert: $*" >&2; exit 1; }

out="$ROOT/signing"
name="Hook Code Signing"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || die "--out needs a folder"; out="$2"; shift ;;
    --name) [ $# -ge 2 ] || die "--name needs a name"; name="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
case "$name" in *[/\\=,]*) die "--name can't hold / \\ = or ," ;; esac

# macOS's LibreSSL writes a .p12 that `security import` reads; OpenSSL 3 needs -legacy for that.
openssl=/usr/bin/openssl
[ -x "$openssl" ] || openssl="$(command -v openssl)" || die "openssl not found"
legacy=()
case "$("$openssl" version)" in "OpenSSL 3"*) legacy=(-legacy) ;; esac

p12="$out/hook-signing.p12"
[ ! -e "$p12" ] || die "$p12 already exists; left alone. Use the identity you have, or pick another --out"
(umask 077; mkdir -p "$out")
chmod 700 "$out"
umask 077

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
"$openssl" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$work/req.cnf" \
  -keyout "$work/key.pem" -out "$out/hook-signing.cer.pem" >/dev/null 2>&1 \
  || die "openssl couldn't make the certificate"
password="$("$openssl" rand -base64 33 | tr -d '/+=\n')"
"$openssl" pkcs12 -export ${legacy[@]+"${legacy[@]}"} -inkey "$work/key.pem" -in "$out/hook-signing.cer.pem" \
  -name "$name" -out "$p12" -passout "pass:$password" </dev/null >/dev/null 2>&1 \
  || die "openssl couldn't write the .p12"
base64 < "$p12" | tr -d '\n' > "$out/MACOS_SIGN_P12.txt"
printf '%s' "$password" > "$out/MACOS_SIGN_PASSWORD.txt"
chmod 600 "$out"/*

fingerprint="$("$openssl" x509 -in "$out/hook-signing.cer.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
echo "Made the code-signing identity \"$name\" (SHA-1 $fingerprint) in $out."
echo
echo "Store these two values as repository secrets (Settings › Secrets and variables › Actions):"
echo
echo "MACOS_SIGN_P12=$(cat "$out/MACOS_SIGN_P12.txt")"
echo
echo "MACOS_SIGN_PASSWORD=$password"
echo
echo "Or with the GitHub CLI, from the files next to the .p12:"
echo "  gh secret set MACOS_SIGN_P12 < \"$out/MACOS_SIGN_P12.txt\""
echo "  gh secret set MACOS_SIGN_PASSWORD < \"$out/MACOS_SIGN_PASSWORD.txt\""
echo
echo "Keep $out safe and out of git. Every release signed with this identity keeps Hook's"
echo "Keychain access across updates; a new identity asks once more."
