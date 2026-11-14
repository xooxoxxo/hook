#!/usr/bin/env bash
# Sandbox test for scripts/get.sh. HOME is a fresh temp folder and the releases it
# downloads are fixtures in a temp folder, read over file:// (HOOK_RELEASES_URL) or from
# a local http.server on 127.0.0.1, so nothing reaches the network. Each fixture
# release's install.sh only prints its version, folder and arguments. git, swift and
# xcode-select are stand-ins that log their calls. PATH holds only those stand-ins and the
# system folders, and HOOK_BIN_DIRS and HOOK_APP_DIRS are empty, so the rollback sync of the
# agent integrations (13) finds only a fake claude, never a real harness on this Mac.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
GET="$REPO/scripts/get.sh"
T="$(mktemp -d)"
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

bash -n "$GET" || fail "get.sh has a syntax error"
[ "$(tail -1 "$GET")" = 'main "$@"' ] || fail "get.sh does not end with main \"\$@\" (a cut download could run part of it)"
if grep -vE '^\s*#' "$GET" | grep -Eq 'git clone|git fetch|swift |swiftc|xcodebuild|xcode-select --install'; then
  fail "get.sh clones or compiles"
fi

H="$T/home"
mkdir -p "$H"
OUT="$T/out.txt"
REL="$T/releases"
HH="$H/.local/share/hook"
REAL_GIT="$(command -v git)"
FAKE="$T/fakebin"
mkdir -p "$FAKE"
printf '#!/bin/sh\necho "git $*" >> "%s/calls.log"\nexec "%s" "$@"\n' "$T" "$REAL_GIT" > "$FAKE/git"
printf '#!/bin/sh\necho "swift $*" >> "%s/calls.log"\nexit 1\n' "$T" > "$FAKE/swift"
printf '#!/bin/sh\necho "xcode-select $*" >> "%s/calls.log"\n[ "$1" = "-p" ] && echo /Library/Developer/CommandLineTools\nexit 0\n' "$T" > "$FAKE/xcode-select"
chmod +x "$FAKE/git" "$FAKE/swift" "$FAKE/xcode-select"

# git that ignores the real ~/.gitconfig and never signs.
g() {
  env HOME="$H" GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" -c user.name=Test -c user.email=test@example.invalid \
    -c init.defaultBranch=main -c commit.gpgsign=false "$@"
}

# release <version> [bundle id] [status]: a fixture release under $REL, laid out as GitHub's
# releases/download/v<version>/…; the newest one made is also latest/download/. Its
# install.sh exits with <status> (default 0).
release() {
  local v="$1" id="${2:-io.github.xooxoxxo.relay}" code="${3:-0}" s="$T/stage-$1"
  rm -rf "$s"
  mkdir -p "$s/Hook.app/Contents/MacOS" "$s/support/scripts" "$s/support/bin"
  cat > "$s/Hook.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleShortVersionString</key><string>$v</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\necho "install-stub $(cat "$(dirname "$0")/../VERSION") in:$(cd "$(dirname "$0")/.." && pwd -P) args:$*"\nexit %s\n' \
    "$code" > "$s/support/scripts/install.sh"
  chmod +x "$s/support/scripts/install.sh"
  : > "$s/support/bin/relay"
  echo "$v" > "$s/support/VERSION"
  mkdir -p "$REL/download/v$v" "$REL/latest/download"
  (cd "$s" && ditto -c -k . "$REL/download/v$v/Hook-$v.zip")
  (cd "$REL/download/v$v" && shasum -a 256 "Hook-$v.zip" > SHA256SUMS)
  cp "$REL/download/v$v/"* "$REL/latest/download/"
  rm -f "$REL/latest/download/Hook-"*.zip
  cp "$REL/download/v$v/Hook-$v.zip" "$REL/latest/download/"
}

run() {   # run get.sh piped into bash, as the README's one-liner does
  env HOME="$H" HOOK_RELEASES_URL="file://$REL" PATH="$FAKE:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOOK_BIN_DIRS= HOOK_APP_DIRS= "$@" >"$OUT" 2>&1
}
current() { readlink "$HH/current" 2>/dev/null || echo none; }
versions() { find "$HH" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tr '\n' ' '; }
leftovers() { find "$H/.local/share" -maxdepth 1 -name '.hook-incoming.*' | grep -q .; }

release 0.9.9
release 0.10.0

# 1. A fresh run installs the newest release: the payload and Hook.app in
#    ~/.local/share/hook/<version>, current linking to it, and current's install.sh run with
#    --prebuilt and the arguments after `bash -s --`. No git, no compiler.
run bash -s -- --local --mailbox "a b" < "$GET" || { cat "$OUT"; fail "a fresh run exited non-zero"; }
[ "$(current)" = "0.10.0" ] || fail "current is $(current), not 0.10.0"
[ -f "$HH/0.10.0/Hook.app/Contents/Info.plist" ] || fail "Hook.app is not in the version folder"
[ -f "$HH/0.10.0/scripts/install.sh" ] || fail "the payload is not in the version folder"
grep -qx "install-stub 0.10.0 in:$HH/0.10.0 args:--prebuilt --local --mailbox a b" "$OUT" \
  || { cat "$OUT"; fail "install.sh --prebuilt did not get the arguments"; }
grep -q 'Hook-0.10.0.zip matches SHA256SUMS' "$OUT" || fail "the hash check was not reported"
[ ! -e "$T/calls.log" ] || fail "a fresh install called $(cat "$T/calls.log")"
leftovers && fail "the download folder was left behind"
ok "fresh install of the newest release, no git or compiler"

# 2. HOOK_VERSION picks a release; the version before stays for going back.
run env HOOK_VERSION=0.9.9 bash < "$GET" || { cat "$OUT"; fail "a HOOK_VERSION run exited non-zero"; }
[ "$(current)" = "0.9.9" ] || fail "current is $(current), not 0.9.9"
grep -qx "install-stub 0.9.9 in:$HH/0.9.9 args:--prebuilt" "$OUT" || { cat "$OUT"; fail "0.9.9's install.sh did not run"; }
[ "$(versions)" = "0.10.0 0.9.9 " ] || fail "versions are $(versions)"
ok "HOOK_VERSION"

# 3. An update keeps the version before and removes older ones; anything else stays.
run bash < "$GET" || { cat "$OUT"; fail "back to latest exited non-zero"; }
release 0.10.1
mkdir -p "$HH/notes"
run bash < "$GET" || { cat "$OUT"; fail "an update run exited non-zero"; }
[ "$(current)" = "0.10.1" ] || fail "current is $(current), not 0.10.1"
[ "$(versions)" = "0.10.0 0.10.1 notes " ] || fail "versions are $(versions), expected 0.10.0 0.10.1 notes"
grep -q 'removed Hook 0.9.9' "$OUT" || fail "the old version's removal was not reported"
ok "update keeps the previous version"

# 4. A zip that doesn't match SHA256SUMS is refused with status 3, and nothing changes.
release 0.10.2
printf 'x' >> "$REL/download/v0.10.2/Hook-0.10.2.zip"
cp "$REL/download/v0.10.2/Hook-0.10.2.zip" "$REL/latest/download/"
status=0; run bash < "$GET" || status=$?
[ "$status" = "3" ] || { cat "$OUT"; fail "a mismatched zip exited $status, not 3"; }
grep -q 'Hook-0.10.2.zip does not match SHA256SUMS' "$OUT" || { cat "$OUT"; fail "the refusal does not say why"; }
[ "$(current)" = "0.10.1" ] || fail "a mismatched zip moved current to $(current)"
[ ! -e "$HH/0.10.2" ] || fail "a mismatched zip was unpacked"
if grep -q 'install-stub' "$OUT"; then fail "install.sh ran after a mismatch"; fi
leftovers && fail "the download folder was left behind after a mismatch"
ok "hash mismatch refused"

# 5. A missing release, a SHA256SUMS without the zip, and a zip that isn't Hook: status 3.
status=0; run env HOOK_VERSION=7.7.7 bash < "$GET" || status=$?
[ "$status" = "3" ] && grep -q "couldn't download" "$OUT" || { cat "$OUT"; fail "a missing release: status $status"; }
release 0.10.3
echo "0000000000000000000000000000000000000000000000000000000000000000  Other.zip" > "$REL/download/v0.10.3/SHA256SUMS"
status=0; run env HOOK_VERSION=0.10.3 bash < "$GET" || status=$?
[ "$status" = "3" ] && grep -q 'SHA256SUMS has no line for Hook-0.10.3.zip' "$OUT" || { cat "$OUT"; fail "no zip line: status $status"; }
release 0.10.4 com.example.other
status=0; run bash < "$GET" || status=$?
[ "$status" = "3" ] && grep -q 'holds no Hook.app (bundle id com.example.other)' "$OUT" || { cat "$OUT"; fail "another app: status $status"; }
[ "$(current)" = "0.10.1" ] || fail "a refused release moved current to $(current)"
ok "missing release, missing line and another app refused"

# 6. HOOK_ZIP and HOOK_SUMS (Hook's updater): local files, checked the same way.
release 0.10.5
mkdir -p "$T/dl"
cp "$REL/download/v0.10.5/"* "$T/dl/"
run env HOOK_RELEASES_URL="file://$T/nowhere" HOOK_VERSION=0.10.5 HOOK_ZIP="$T/dl/Hook-0.10.5.zip" \
  HOOK_SUMS="$T/dl/SHA256SUMS" bash < "$GET" || { cat "$OUT"; fail "a local-files run exited non-zero"; }
[ "$(current)" = "0.10.5" ] || fail "current is $(current), not 0.10.5"
printf 'x' >> "$T/dl/Hook-0.10.5.zip"
status=0
run env HOOK_VERSION=0.10.5 HOOK_ZIP="$T/dl/Hook-0.10.5.zip" HOOK_SUMS="$T/dl/SHA256SUMS" bash < "$GET" || status=$?
[ "$status" = "3" ] || { cat "$OUT"; fail "a changed local zip exited $status"; }
status=0; run env HOOK_ZIP="$T/dl/Hook-0.10.5.zip" bash < "$GET" || status=$?
[ "$status" = "1" ] && grep -q 'need each other' "$OUT" || { cat "$OUT"; fail "HOOK_ZIP alone: status $status"; }
ok "HOOK_ZIP and HOOK_SUMS"

# 7. The same version again replaces its folder with a fresh copy.
echo stale > "$HH/0.10.5/stale"
run env HOOK_VERSION=0.10.5 bash < "$GET" || { cat "$OUT"; fail "a reinstall exited non-zero"; }
[ ! -e "$HH/0.10.5/stale" ] || fail "the reinstall kept the old folder's files"
ok "reinstall of the same version"

# 8. Over http, from a local server laid out like GitHub's releases.
python3 -u -m http.server --bind 127.0.0.1 --directory "$REL" 0 >"$T/server.log" 2>&1 &
SERVER_PID=$!
port=""
for _ in $(seq 1 300); do   # 30 s: a cold CI runner takes a while to start Python
  port="$(sed -nE 's/.*port ([0-9]+).*/\1/p' "$T/server.log" | head -1)"
  [ -n "$port" ] && break
  sleep 0.1
done
[ -n "$port" ] || fail "the local http server did not start: $(cat "$T/server.log")"
release 0.10.6
run env HOOK_RELEASES_URL="http://127.0.0.1:$port/" bash < "$GET" || { cat "$OUT"; fail "an http run exited non-zero"; }
[ "$(current)" = "0.10.6" ] || fail "current is $(current) after the http run"
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
ok "download over http"

# 9. 0.9.3's clone at ~/.local/share/hook moves aside to ~/.local/share/hook-clone; a
#    developer clone there is left alone.
rm -rf "$HH"
g init --quiet "$HH"
g -C "$HH" remote add origin https://github.com/xooxoxxo/hook.git
g -C "$HH" commit --quiet --allow-empty -m base
g -C "$HH" checkout --quiet -b feature
g -C "$HH" checkout --quiet main
status=0; run bash < "$GET" || status=$?
[ "$status" = "1" ] && grep -q 'is a developer clone; left alone' "$OUT" || { cat "$OUT"; fail "a developer clone at ~/.local/share/hook: status $status"; }
[ -d "$HH/.git" ] || fail "the developer clone was moved"
g -C "$HH" branch --quiet -D feature
run bash < "$GET" || { cat "$OUT"; fail "a run over the old clone exited non-zero"; }
[ -d "$H/.local/share/hook-clone/.git" ] || fail "the old clone was not moved to hook-clone"
[ "$(current)" = "0.10.6" ] || fail "current is $(current) after moving the clone"
grep -q 'the old copy in ~/.local/share/hook-clone is no longer used; you can delete it' "$OUT" || { cat "$OUT"; fail "no note about the old clone"; }
ok "0.9.3's clone moves aside; a developer clone stays"

# 10. ~/.local/bin/relay linked into a developer clone: refused, nothing downloaded.
DEV="$T/dev-clone"
g init --quiet "$DEV"
mkdir -p "$DEV/bin" "$H/.local/bin"
: > "$DEV/bin/relay"
g -C "$DEV" add -A
g -C "$DEV" commit --quiet -m dev
echo change >> "$DEV/bin/relay"
ln -sfn "$DEV/bin/relay" "$H/.local/bin/relay"
status=0; run bash < "$GET" || status=$?
[ "$status" = "1" ] && grep -q 'links into the developer clone' "$OUT" || { cat "$OUT"; fail "a developer clone's link: status $status"; }
if grep -q 'downloading' "$OUT"; then fail "it downloaded for a developer clone"; fi
g -C "$DEV" checkout --quiet -- bin/relay
run env HOOK_DEV=1 bash < "$GET" && fail "HOOK_DEV=1 did not mark the clone as a developer's"
run bash < "$GET" || { cat "$OUT"; fail "a clean clone's link was refused"; }
rm "$H/.local/bin/relay"
ok "developer clone's link left alone"

# 11. Not a Mac, or an old macOS: refused.
printf '#!/bin/sh\necho Linux\n' > "$FAKE/uname"
chmod +x "$FAKE/uname"
if run bash < "$GET"; then fail "Linux was accepted"; fi
grep -q 'macOS only' "$OUT" || { cat "$OUT"; fail "no macOS message"; }
rm "$FAKE/uname"
printf '#!/bin/sh\necho 13.6\n' > "$FAKE/sw_vers"
chmod +x "$FAKE/sw_vers"
if run bash < "$GET"; then fail "macOS 13 was accepted"; fi
grep -q 'needs macOS 14 or newer (this Mac has 13.6)' "$OUT" || { cat "$OUT"; fail "no macOS version message"; }
rm "$FAKE/sw_vers"
ok "macOS checks"

# 12. A failed install puts current back on the version before and removes nothing; a
#     retry, or a rerun of the same version, keeps that version for going back.
rm -rf "$HH"
release 1.0.0
run bash < "$GET" || { cat "$OUT"; fail "1.0.0 exited non-zero"; }
release 1.0.1
run bash < "$GET" || { cat "$OUT"; fail "1.0.1 exited non-zero"; }
run bash < "$GET" || { cat "$OUT"; fail "a rerun of 1.0.1 exited non-zero"; }
[ "$(versions)" = "1.0.0 1.0.1 " ] || fail "a rerun of the same version left $(versions)"
release 1.0.2 io.github.xooxoxxo.relay 1
status=0; run bash < "$GET" || status=$?
[ "$status" = "1" ] || { cat "$OUT"; fail "a failing install exited $status, not 1"; }
[ "$(current)" = "1.0.1" ] || fail "after a failed install current is $(current), not 1.0.1"
[ "$(versions)" = "1.0.0 1.0.1 1.0.2 " ] || fail "a failed install left $(versions)"
if grep -q 'removed Hook' "$OUT"; then fail "a failed install removed a version"; fi
grep -q 'links to 1.0.1 again' "$OUT" || { cat "$OUT"; fail "the rollback was not reported"; }
grep -qF "run: '$HH/current/scripts/install.sh' --prebuilt" "$OUT" || { cat "$OUT"; fail "the reinstall command is not a full path"; }
status=0; run bash < "$GET" || status=$?
[ "$status" = "1" ] && [ "$(current)" = "1.0.1" ] || { cat "$OUT"; fail "a retry: status $status, current $(current)"; }
[ -d "$HH/1.0.1" ] || fail "a retry removed 1.0.1"
# An install cut short leaves current on the new version; the retry still goes back to 1.0.1.
ln -sfn 1.0.2 "$HH/current"
status=0; run bash < "$GET" || status=$?
[ "$status" = "1" ] && [ "$(current)" = "1.0.1" ] && [ -d "$HH/1.0.1" ] || { cat "$OUT"; fail "a retry from a cut-short install: status $status, current $(current), versions $(versions)"; }
release 1.0.2
run bash < "$GET" || { cat "$OUT"; fail "the fixed 1.0.2 exited non-zero"; }
[ "$(current)" = "1.0.2" ] && [ "$(versions)" = "1.0.1 1.0.2 " ] || fail "after the fixed 1.0.2: current $(current), versions $(versions)"
ok "a failed install rolls back; retries and reruns keep the version before"

# full_release <version> [status]: a fixture release whose support payload is the real one
# (the CLI, clients, MCP server, skill and support/integration, stamped <version>), with the
# stub install.sh that exits <status>.
full_release() {
  local v="$1" code="${2:-0}" s="$T/stage-$1"
  release "$v" io.github.xooxoxxo.relay "$code"
  mkdir -p "$s/support/clients" "$s/support/mcp" "$s/support/skill"
  for f in "$REPO"/clients/*.py; do
    case "${f##*/}" in test_*|answers_fixture.py) continue ;; esac
    cp "$f" "$s/support/clients/"
  done
  cp "$REPO/bin/relay" "$s/support/bin/relay"
  cp "$REPO/mcp/relay_mcp.py" "$s/support/mcp/"
  cp -R "$REPO/skill/instructables" "$s/support/skill/"
  python3 "$REPO/clients/relay_bundle.py" build --version "$v" --out "$s/support/integration" >/dev/null \
    || fail "the fixture bundle for $v did not build"
  rm -f "$REL/download/v$v/Hook-$v.zip"
  (cd "$s" && ditto -c -k . "$REL/download/v$v/Hook-$v.zip")
  (cd "$REL/download/v$v" && shasum -a 256 "Hook-$v.zip" > SHA256SUMS)
  rm -f "$REL/latest/download/"*
  cp "$REL/download/v$v/"* "$REL/latest/download/"
}

# 13. A failed install of a release with agent integrations: once current links to the version
#     before again, that version's relay_integrations.py syncs (--no-asks, link root current),
#     so the rendered plugins match the version that runs. The version cleanup after a
#     successful install keeps the plugins/ folder, which isn't a version.
rm -rf "$HH"
printf '#!/bin/sh\necho "claude $*" >> "%s/claude.log"\nexit 0\n' "$T" > "$FAKE/claude"
chmod +x "$FAKE/claude"
mkdir -p "$H/.claude"
full_release 2.0.0
run bash < "$GET" || { cat "$OUT"; fail "2.0.0 exited non-zero"; }
[ ! -e "$HH/plugins" ] || fail "test setup: the stub install.sh rendered plugins"
full_release 2.0.1 1
status=0; run bash < "$GET" || status=$?
[ "$status" = "1" ] && [ "$(current)" = "2.0.0" ] || { cat "$OUT"; fail "the failing 2.0.1: status $status, current $(current)"; }
grep -qx 'get: syncing the agent integrations with Hook 2.0.0' "$OUT" || { cat "$OUT"; fail "the rollback sync was not reported"; }
[ -f "$HH/plugins/claude/.claude-plugin/plugin.json" ] || { cat "$OUT"; fail "the rollback sync rendered no plugins/"; }
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(0 if m["hookVersion"]=="2.0.0" and m["linkRoot"]=="~/.local/share/hook/current" else 1)' \
  "$H/.config/relay/integrations.json" || fail "the rollback sync did not run as 2.0.0 through current: $(cat "$H/.config/relay/integrations.json")"
grep -q "claude plugin marketplace add $HH/plugins/claude" "$T/claude.log" || fail "the rollback sync did not set up the fake claude"
full_release 2.0.3
run bash < "$GET" || { cat "$OUT"; fail "2.0.3 exited non-zero"; }
[ "$(current)" = "2.0.3" ] || fail "current is $(current), not 2.0.3"
[ -d "$HH/plugins/claude" ] || fail "the version cleanup removed plugins/"
[ "$(versions)" = "2.0.0 2.0.3 plugins " ] || fail "after 2.0.3: versions $(versions)"
if grep -q 'syncing the agent integrations' "$OUT"; then fail "a successful install ran the rollback sync"; fi
ok "a failed install's rollback syncs the integrations; the cleanup keeps plugins/"

# 14. Since the DMG, a release's SHA256SUMS has two lines: the zip's, then the DMG's
#     (package-release.sh --dmg). The newest release's version still comes from the zip's
#     line alone, its hash is the one checked, and HOOK_VERSION and HOOK_ZIP work the same.
#     A DMG line first, or one with a hash that doesn't match anything, changes nothing.
with_dmg() {   # with_dmg <version> [dmg first]: adds a DMG and its line to that release
  local v="$1" d="$REL/download/v$1"
  printf 'not really a disk image\n' > "$d/Hook-$v.dmg"
  if [ -n "${2:-}" ]; then
    (cd "$d" && shasum -a 256 "Hook-$v.dmg" "Hook-$v.zip" > SHA256SUMS)
  else
    (cd "$d" && shasum -a 256 "Hook-$v.zip" "Hook-$v.dmg" > SHA256SUMS)
  fi
  rm -f "$REL/latest/download/"*
  cp "$d/"* "$REL/latest/download/"
}
rm -rf "$HH"
release 3.0.0
with_dmg 3.0.0
[ "$(wc -l < "$REL/download/v3.0.0/SHA256SUMS" | tr -d ' ')" = "2" ] || fail "test setup: SHA256SUMS is not two lines"
run bash < "$GET" || { cat "$OUT"; fail "a two-line SHA256SUMS exited non-zero"; }
[ "$(current)" = "3.0.0" ] || { cat "$OUT"; fail "a two-line SHA256SUMS installed $(current), not 3.0.0"; }
grep -q 'Hook-3.0.0.zip matches SHA256SUMS' "$OUT" || { cat "$OUT"; fail "the zip's line was not the one checked"; }
release 3.0.1
with_dmg 3.0.1 first
run env HOOK_VERSION=3.0.1 bash < "$GET" || { cat "$OUT"; fail "HOOK_VERSION with the DMG's line first exited non-zero"; }
[ "$(current)" = "3.0.1" ] || fail "the DMG's line first installed $(current)"
run bash < "$GET" || { cat "$OUT"; fail "the newest release with the DMG's line first exited non-zero"; }
[ "$(current)" = "3.0.1" ] || fail "the newest release with the DMG's line first installed $(current)"
mkdir -p "$T/dl2"
cp "$REL/download/v3.0.1/"* "$T/dl2/"
run env HOOK_RELEASES_URL="file://$T/nowhere" HOOK_VERSION=3.0.1 HOOK_ZIP="$T/dl2/Hook-3.0.1.zip" \
  HOOK_SUMS="$T/dl2/SHA256SUMS" bash < "$GET" || { cat "$OUT"; fail "HOOK_ZIP with a two-line SHA256SUMS exited non-zero"; }
# A zip that changed still fails with the DMG's line beside it.
release 3.0.2
with_dmg 3.0.2
printf 'x' >> "$REL/download/v3.0.2/Hook-3.0.2.zip"
cp "$REL/download/v3.0.2/Hook-3.0.2.zip" "$REL/latest/download/"
status=0; run bash < "$GET" || status=$?
[ "$status" = "3" ] && grep -q 'Hook-3.0.2.zip does not match SHA256SUMS' "$OUT" || { cat "$OUT"; fail "a changed zip beside a DMG line: status $status"; }
[ "$(current)" = "3.0.1" ] || fail "a refused release moved current to $(current)"
# Two zip lines (never made by package-release.sh) are still refused for the newest release.
(cd "$REL/latest/download" && printf '%s  Hook-9.0.0.zip\n' "$(printf '0%.0s' $(seq 64))" >> SHA256SUMS)
status=0; run bash < "$GET" || status=$?
[ "$status" = "3" ] && grep -q "doesn't name one Hook zip" "$OUT" || { cat "$OUT"; fail "two zip lines: status $status"; }
ok "a SHA256SUMS listing the zip and the DMG"

# 15. HOOK_BUNDLE goes with nothing to download: not with HOOK_ZIP, and only for a folder.
status=0; run env HOOK_BUNDLE="$T/stage-3.0.1/Hook.app" HOOK_VERSION=3.0.1 HOOK_ZIP="$T/dl2/Hook-3.0.1.zip" HOOK_SUMS="$T/dl2/SHA256SUMS" bash < "$GET" || status=$?
[ "$status" = "1" ] && grep -q 'choose one of HOOK_BUNDLE and HOOK_ZIP' "$OUT" || { cat "$OUT"; fail "HOOK_BUNDLE with HOOK_ZIP: status $status"; }
status=0; run env HOOK_BUNDLE="$T/no-such/Hook.app" bash < "$GET" || status=$?
[ "$status" = "1" ] && grep -q 'is not a folder' "$OUT" || { cat "$OUT"; fail "HOOK_BUNDLE without a folder: status $status"; }
# An app that carries its payload installs from it, passing --app and --in-place first.
mkdir -p "$T/dragged"
ditto "$T/stage-3.0.1/Hook.app" "$T/dragged/Hook.app"
ditto "$T/stage-3.0.1/support" "$T/dragged/Hook.app/Contents/Resources/support"
run env HOOK_BUNDLE="$T/dragged/Hook.app" bash < "$GET" -s -- --local || { cat "$OUT"; fail "a HOOK_BUNDLE install exited non-zero"; }
grep -qx "install-stub 3.0.1 in:$HH/3.0.1 args:--prebuilt --app $T/dragged/Hook.app --in-place --local" "$OUT" \
  || { cat "$OUT"; fail "install.sh did not get --app and --in-place"; }
if grep -q 'downloading' "$OUT"; then fail "a HOOK_BUNDLE install downloaded"; fi
ok "HOOK_BUNDLE"

echo "GET TESTS OK"
