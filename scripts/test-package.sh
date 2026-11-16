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
  # The support payload, sealed into the app as build.sh does.
  mkdir -p "$1/Contents/Resources"
  "$REPO/scripts/bundle-support.sh" "$1/Contents/Resources/support" --version "${3:-$VERSION}" \
    || fail "bundle-support.sh failed for $1"
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
for f in bin/relay clients/relay_client.py clients/relay_cli.py clients/relay_lint.py clients/relay_replies.py clients/relay_wait.py \
         mcp/relay_mcp.py schema/instructable.v1.json skill/instructables/SKILL.md scripts/install.sh \
         scripts/get.sh LICENSE THIRD_PARTY_NOTICES.md VERSION; do
  [ -f "$S/$f" ] || fail "support/$f is missing"
done
# 0.13: the pasted CLAUDE.md section is gone; the bundle's instructions/hook.md replaces it.
[ ! -e "$S/docs" ] || fail "support/docs is in the payload: $(ls -A "$S/docs" | tr '\n' ' ')"
[ -x "$S/bin/relay" ] && [ -x "$S/scripts/install.sh" ] && [ -x "$S/scripts/get.sh" ] || fail "a script lost its x bit"
[ "$(cat "$S/VERSION")" = "$VERSION" ] || fail "support/VERSION is $(cat "$S/VERSION")"
if find "$S" \( -name 'test_*' -o -name '__pycache__' -o -name '*.pyc' -o -name 'answers_fixture.py' -o -name '.DS_Store' \) | grep -q .; then
  fail "tests or caches in the payload: $(find "$S" -name 'test_*' -o -name '__pycache__' | head -3)"
fi
[ ! -e "$S/scripts/build.sh" ] || fail "build.sh is in the payload (nothing builds there)"
[ -x "$T/x/Hook.app/Contents/MacOS/Hook" ] || fail "the app lost its executable"
# The app carries the same payload inside (Contents/Resources/support), signed with it.
diff -r "$S" "$T/x/Hook.app/Contents/Resources/support" >/dev/null || fail "support/ differs from the app's bundled payload"
[ -x "$T/x/Hook.app/Contents/Resources/support/scripts/install.sh" ] || fail "the bundled install.sh lost its x bit"
if find "$T/x/Hook.app/Contents/Resources/support" -type l | grep -q .; then fail "symlinks in the bundled payload"; fi
if find "$T/x/Hook.app/Contents/Resources/support" -type f -exec file -b {} + | grep -q 'Mach-O'; then
  fail "a Mach-O file in the bundled payload (it would need its own signature)"
fi
# Without --dmg, SHA256SUMS lists the zip alone.
[ "$(wc -l < "$T/dist/SHA256SUMS" | tr -d ' ')" = "1" ] || fail "SHA256SUMS without --dmg has $(wc -l < "$T/dist/SHA256SUMS") lines"
ok "zip layout and SHA256SUMS"

# 1c. An app without the bundled payload (or with another version's) is refused.
mkdir -p "$T/bare/Hook.app"
ditto "$T/build/Hook.app" "$T/bare/Hook.app"
rm -rf "$T/bare/Hook.app/Contents/Resources/support"
if "$PACK" --app "$T/bare/Hook.app" --out "$T/dist-bare" >"$OUT" 2>&1; then fail "an app without support was packed"; fi
grep -q "has no support payload" "$OUT" || { cat "$OUT"; fail "no reason for the missing payload"; }
"$REPO/scripts/bundle-support.sh" "$T/bare/Hook.app/Contents/Resources/support" --version 0.0.1 >/dev/null
if "$PACK" --app "$T/bare/Hook.app" --out "$T/dist-bare" >"$OUT" 2>&1; then fail "an app with another version's payload was packed"; fi
grep -q "support payload is 0.0.1" "$OUT" || { cat "$OUT"; fail "no reason for the payload's version"; }
if "$REPO/scripts/bundle-support.sh" "$T/bare/Hook.app/Contents/Resources/support" >"$OUT" 2>&1; then fail "bundle-support.sh overwrote a folder"; fi
ok "an app without its payload refused"

# 1d. --dmg: Hook-<version>.dmg holds Hook.app (with its payload) and a link to /Applications,
#     and SHA256SUMS lists the zip, then the DMG. --sums rewrites it for the files there.
#     Only where hdiutil can make and mount an image (it can't in some sandboxes).
DMG="$T/dist-dmg/Hook-$VERSION.dmg"
if command -v hdiutil >/dev/null 2>&1 && hdiutil info >/dev/null 2>&1; then
  "$PACK" --app "$T/build/Hook.app" --out "$T/dist-dmg" --dmg >"$OUT" 2>&1 || { cat "$OUT"; fail "packaging with --dmg exited non-zero"; }
  [ -f "$DMG" ] && [ -f "$T/dist-dmg/Hook-$VERSION.zip" ] || fail "no DMG and zip in dist-dmg: $(ls "$T/dist-dmg")"
  want="$(cd "$T/dist-dmg" && shasum -a 256 "Hook-$VERSION.zip" "Hook-$VERSION.dmg")"
  [ "$(cat "$T/dist-dmg/SHA256SUMS")" = "$want" ] || fail "SHA256SUMS with --dmg is $(cat "$T/dist-dmg/SHA256SUMS")"
  [ "$(sed -n 1p "$T/dist-dmg/SHA256SUMS" | cut -c67-)" = "Hook-$VERSION.zip" ] || fail "the zip is not SHA256SUMS's first line"
  MNT="$T/mnt"
  mkdir -p "$MNT"
  hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" || fail "the DMG does not mount"
  layout="$(ls -A "$MNT" | grep -v '^\.' | tr '\n' ' ')"
  link="$(readlink "$MNT/Applications" || true)"
  app_id="$(plutil -extract CFBundleIdentifier raw "$MNT/Hook.app/Contents/Info.plist" 2>/dev/null || true)"
  payload="$(cat "$MNT/Hook.app/Contents/Resources/support/VERSION" 2>/dev/null || true)"
  hdiutil detach -quiet "$MNT" || hdiutil detach -quiet -force "$MNT" || true
  [ "$layout" = "Applications Hook.app " ] || fail "the DMG holds $layout"
  [ "$link" = "/Applications" ] || fail "the DMG's Applications links to ${link:-nothing}"
  [ "$app_id" = "io.github.xooxoxxo.relay" ] || fail "the DMG's Hook.app is ${app_id:-not an app}"
  [ "$payload" = "$VERSION" ] || fail "the DMG's Hook.app has payload ${payload:-none}"
  # The workflow signs and staples the DMG, which changes its bytes; --sums lists the new ones.
  printf 'x' >> "$DMG"
  "$PACK" --sums --out "$T/dist-dmg" >"$OUT" 2>&1 || { cat "$OUT"; fail "--sums exited non-zero"; }
  [ "$(cat "$T/dist-dmg/SHA256SUMS")" = "$(cd "$T/dist-dmg" && shasum -a 256 "Hook-$VERSION.zip" "Hook-$VERSION.dmg")" ] \
    || fail "--sums wrote $(cat "$T/dist-dmg/SHA256SUMS")"
  ok "DMG layout and a two-line SHA256SUMS"
else
  echo "skip - DMG layout (hdiutil can't run here)"
fi
mkdir -p "$T/empty"
if "$PACK" --sums --out "$T/empty" >"$OUT" 2>&1; then fail "--sums without a zip passed"; fi
grep -q "no $T/empty/Hook-$VERSION.zip" "$OUT" || { cat "$OUT"; fail "no reason for --sums without a zip"; }
ok "--sums needs the zip"

# 1a. The integration bundle: built for this version, its files match bundle.json.
I="$S/integration"
for f in bundle.json harnesses.json instructions/hook.md skills/instructables/SKILL.md \
         plugins/claude/.claude-plugin/plugin.json; do
  [ -f "$I/$f" ] || fail "support/integration/$f is missing"
done
[ "$(head -n 1 "$I/instructions/hook.md")" = "<!-- hook:instructions v=1 app=$VERSION -->" ] \
  || fail "instructions/hook.md starts with $(head -n 1 "$I/instructions/hook.md")"
grep -qx "  version: \"$VERSION\"" "$I/skills/instructables/SKILL.md" || fail "the skill has no metadata.version $VERSION"
for f in instructions/hook.md skills/instructables/SKILL.md plugins/claude/.claude-plugin/plugin.json; do
  want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"][sys.argv[2]])' "$I/bundle.json" "$f")" \
    || fail "bundle.json does not list $f"
  [ "$(shasum -a 256 "$I/$f" | cut -d' ' -f1)" = "$want" ] || fail "$f does not match its sha in bundle.json"
done
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$I/bundle.json")" = "$VERSION" ] \
  || fail "bundle.json names another version"
if find "$I" -type l | grep -q .; then fail "symlinks in the bundle: $(find "$I" -type l | head -3)"; fi
if ls "$S/clients" | grep -q '^test_.*\.py$'; then fail "tests in support/clients: $(ls "$S/clients" | grep '^test_' | head -3)"; fi
[ -f "$S/clients/relay_bundle.py" ] || fail "support/clients/relay_bundle.py is missing"
ok "integration bundle"

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
