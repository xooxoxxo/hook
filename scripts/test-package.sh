#!/usr/bin/env bash
# Sandbox test for scripts/package-release.sh and scripts/release-notes.sh. The app is a
# stand-in folder (an Info.plist and a shell script), so nothing is built or signed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
PACK="$REPO/scripts/package-release.sh"
NOTES="$REPO/scripts/release-notes.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

bash -n "$PACK" || fail "package-release.sh has a syntax error"
bash -n "$NOTES" || fail "release-notes.sh has a syntax error"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$REPO/Resources/Info.plist")"
OUT="$T/out.txt"

fake_app() {   # fake_app <path> [bundle id] [version]
  mkdir -p "$1/Contents/MacOS"
  cat >"$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${2:-io.github.xooxoxxo.relay}</string>
<key>CFBundleShortVersionString</key><string>${3:-$VERSION}</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\nexit 0\n' > "$1/Contents/MacOS/Hook"
  chmod +x "$1/Contents/MacOS/Hook"
}

# 1. The zip holds Hook.app and the support payload, and SHA256SUMS names it with its hash.
fake_app "$T/build/Hook.app"
"$PACK" --app "$T/build/Hook.app" --out "$T/dist" >"$OUT" 2>&1 || { cat "$OUT"; fail "packaging exited non-zero"; }
ZIP="$T/dist/Hook-$VERSION.zip"
[ -f "$ZIP" ] || fail "no $ZIP"
[ "$(cat "$T/dist/SHA256SUMS")" = "$(cd "$T/dist" && shasum -a 256 "Hook-$VERSION.zip")" ] \
  || fail "SHA256SUMS is $(cat "$T/dist/SHA256SUMS")"
mkdir -p "$T/x"
ditto -x -k "$ZIP" "$T/x"
[ "$(ls -A "$T/x" | tr '\n' ' ')" = "Hook.app support " ] || fail "zip top level is $(ls -A "$T/x" | tr '\n' ' ')"
S="$T/x/support"
for f in bin/relay clients/relay_client.py clients/relay_cli.py clients/relay_replies.py clients/relay_wait.py \
         mcp/relay_mcp.py schema/instructable.v1.json skill/instructables/SKILL.md scripts/install.sh \
         scripts/get.sh docs/claude-md-section.md LICENSE THIRD_PARTY_NOTICES.md VERSION; do
  [ -f "$S/$f" ] || fail "support/$f is missing"
done
[ -x "$S/bin/relay" ] && [ -x "$S/scripts/install.sh" ] && [ -x "$S/scripts/get.sh" ] || fail "a script lost its x bit"
[ "$(cat "$S/VERSION")" = "$VERSION" ] || fail "support/VERSION is $(cat "$S/VERSION")"
if find "$S" \( -name 'test_*' -o -name '__pycache__' -o -name '*.pyc' -o -name 'answers_fixture.py' -o -name '.DS_Store' \) | grep -q .; then
  fail "tests or caches in the payload: $(find "$S" -name 'test_*' -o -name '__pycache__' | head -3)"
fi
[ ! -e "$S/scripts/build.sh" ] || fail "build.sh is in the payload (nothing builds there)"
[ -x "$T/x/Hook.app/Contents/MacOS/Hook" ] || fail "the app lost its executable"
ok "zip layout and SHA256SUMS"

# 1b. Relative --app and --out (as the release workflow passes --out dist) resolve
#     against the folder it runs in.
mkdir -p "$T/cwd"
(cd "$T/cwd" && "$PACK" --app ../build/Hook.app --out dist) >"$OUT" 2>&1 || { cat "$OUT"; fail "packaging with a relative --out exited non-zero"; }
[ -f "$T/cwd/dist/Hook-$VERSION.zip" ] || { cat "$OUT"; fail "no dist/Hook-$VERSION.zip under the working folder"; }
[ "$(cat "$T/cwd/dist/SHA256SUMS")" = "$(cd "$T/cwd/dist" && shasum -a 256 "Hook-$VERSION.zip")" ] \
  || fail "a relative --out wrote SHA256SUMS $(cat "$T/cwd/dist/SHA256SUMS")"
ok "relative --app and --out"

# 2. A tag that doesn't match the app's version, and an app that isn't Hook, are refused.
if RELEASE_TAG="v9.9.9" "$PACK" --app "$T/build/Hook.app" --out "$T/dist2" >"$OUT" 2>&1; then fail "a wrong tag was packed"; fi
grep -q "tag v9.9.9 does not match" "$OUT" || { cat "$OUT"; fail "no reason for the wrong tag"; }
RELEASE_TAG="v$VERSION" "$PACK" --app "$T/build/Hook.app" --out "$T/dist3" >"$OUT" 2>&1 || { cat "$OUT"; fail "the matching tag was refused"; }
fake_app "$T/other/Hook.app" com.example.other
if "$PACK" --app "$T/other/Hook.app" --out "$T/dist4" >"$OUT" 2>&1; then fail "another app was packed"; fi
grep -q "not Hook" "$OUT" || { cat "$OUT"; fail "no reason for another app"; }
fake_app "$T/old/Hook.app" io.github.xooxoxxo.relay 0.0.1
if "$PACK" --app "$T/old/Hook.app" --out "$T/dist5" >"$OUT" 2>&1; then fail "an app of another version was packed"; fi
grep -q "is 0.0.1" "$OUT" || { cat "$OUT"; fail "no reason for the version mismatch"; }
ok "wrong tag, another app and another version refused"

# 3. Release notes: the CHANGELOG section, which must carry both Pond markers.
cat > "$T/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-01-02

### Added
- A thing.

<!-- hook:pond=^1.1.0 -->
<!-- hook:mailbox-protocol=5 -->

## [1.2.2] - 2026-01-01

- Older.
EOF
CHANGELOG="$T/CHANGELOG.md" "$NOTES" 1.2.3 >"$OUT" 2>"$T/err.txt" || { cat "$T/err.txt"; fail "notes exited non-zero"; }
grep -q '^- A thing.$' "$OUT" || fail "the section's text is missing"
grep -q 'hook:pond=^1.1.0' "$OUT" || fail "the pond marker is missing"
if grep -q 'Older\|1.2.2\|1.2.3\]' "$OUT"; then fail "the notes run past the section: $(cat "$OUT")"; fi
if CHANGELOG="$T/CHANGELOG.md" "$NOTES" 1.2.2 >"$OUT" 2>"$T/err.txt"; then fail "a section without markers passed"; fi
grep -q 'hook:pond' "$T/err.txt" || { cat "$T/err.txt"; fail "no reason for the missing marker"; }
if CHANGELOG="$T/CHANGELOG.md" "$NOTES" 9.9.9 >"$OUT" 2>"$T/err.txt"; then fail "a missing section passed"; fi
grep -q 'no section' "$T/err.txt" || { cat "$T/err.txt"; fail "no reason for the missing section"; }
ok "release notes"

echo "PACKAGE TESTS OK"
