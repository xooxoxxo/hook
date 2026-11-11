#!/bin/bash
# CI only: import the required Developer ID identity into a disposable keychain.
set -euo pipefail
umask 077
for name in RUNNER_TEMP GITHUB_ENV MACOS_SIGN_P12 MACOS_SIGN_PASSWORD APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_TEAM_ID MACOS_SIGN_SHA1; do
  [ -n "${!name:-}" ] || { echo "Missing required release setting: $name" >&2; exit 1; }
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid Apple team ID' >&2; exit 1; }
[[ "$MACOS_SIGN_SHA1" =~ ^[A-F0-9]{40}$ ]] || { echo 'Invalid signing certificate fingerprint' >&2; exit 1; }
[[ "$APPLE_API_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo 'Invalid Apple API key ID' >&2; exit 1; }
[[ "$APPLE_API_ISSUER_ID" =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo 'Invalid Apple API issuer ID' >&2; exit 1; }
kc="$RUNNER_TEMP/hook-release.keychain-db"
# Publish cleanup paths before creating/importing anything, including partial failures.
printf 'SIGN_KEYCHAIN=%s\n' "$kc" >> "$GITHUB_ENV"
pass=$(openssl rand -hex 24)
security create-keychain -p "$pass" "$kc"
security set-keychain-settings -lut 3600 "$kc"
security unlock-keychain -p "$pass" "$kc"
printf '%s' "$MACOS_SIGN_P12" | base64 --decode > "$RUNNER_TEMP/signing.p12"
security import "$RUNNER_TEMP/signing.p12" -k "$kc" -P "$MACOS_SIGN_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$RUNNER_TEMP/signing.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$kc" >/dev/null
# Make the CI identity visible to the signing service as well as security find-identity.
security list-keychains -d user -s "$kc"
security find-identity -v -p codesigning "$kc" | python3 -c '
import os, re, sys
pattern = r"\s*\d+\) " + re.escape(os.environ["MACOS_SIGN_SHA1"]) + r" \"Developer ID Application: [^\n]+ \(" + re.escape(os.environ["APPLE_TEAM_ID"]) + r"\)\"\s*"
if not any(re.fullmatch(pattern, line) for line in sys.stdin):
    sys.exit("Required valid Developer ID Application identity is unavailable")
'
# Exercise the actual signing operation before spending time on a universal build.
probe=$(mktemp "$RUNNER_TEMP/hook-signing-probe.XXXXXX")
trap 'rm -f "$probe"' EXIT
cp /usr/bin/true "$probe"
codesign --force --sign "$MACOS_SIGN_SHA1" --keychain "$kc" --options runtime --timestamp "$probe"
codesign --verify --strict "$probe"
printf '%s' "$APPLE_API_KEY" | base64 --decode > "$RUNNER_TEMP/notary-key.p8"
{
  printf 'SIGN_IDENTITY=%s\n' "$MACOS_SIGN_SHA1"
  printf 'NOTARY_KEY=%s\n' "$RUNNER_TEMP/notary-key.p8"
  printf 'NOTARY_KEY_ID=%s\n' "$APPLE_API_KEY_ID"
  printf 'NOTARY_ISSUER=%s\n' "$APPLE_API_ISSUER_ID"
  printf 'HARDENED=1\n'
} >> "$GITHUB_ENV"
