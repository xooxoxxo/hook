#!/usr/bin/env bash
# Sandbox test for scripts/get.sh. HOME is a fresh temp folder, the repo it clones is a
# local bare repo (HOOK_REPO_URL) whose scripts/install.sh only prints its arguments,
# and xcode-select is a stand-in, so nothing reaches the network or the real Mac.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
GET="$REPO/scripts/get.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

bash -n "$GET" || fail "get.sh has a syntax error"
[ "$(tail -1 "$GET")" = 'main "$@"' ] || fail "get.sh does not end with main \"\$@\" (a cut download could run part of it)"

H="$T/home"
mkdir -p "$H"
OUT="$T/out.txt"
BARE="$T/hook.git"
FAKE="$T/fakebin"
mkdir -p "$FAKE"
printf '#!/bin/sh\n[ "$1" = "-p" ] && echo /Library/Developer/CommandLineTools\nexit 0\n' > "$FAKE/xcode-select"
chmod +x "$FAKE/xcode-select"

# git that ignores the real ~/.gitconfig and never signs.
g() {
  env HOME="$H" GIT_CONFIG_NOSYSTEM=1 git -c user.name=Test -c user.email=test@example.invalid \
    -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# The source repo: each release's install.sh prints its version and its arguments.
SRC="$T/src"
g init --quiet "$SRC"
mkdir -p "$SRC/scripts" "$SRC/bin"
printf '#!/bin/sh\necho "install-stub $(cat VERSION) args:$*"\n' > "$SRC/scripts/install.sh"
chmod +x "$SRC/scripts/install.sh"
: > "$SRC/bin/relay"
release() {   # release <version> [tag]: commit VERSION, and tag it unless the tag is "-"
  echo "$1" > "$SRC/VERSION"
  g -C "$SRC" add -A
  g -C "$SRC" commit --quiet -m "$1"
  [ "${2:-v$1}" = "-" ] || g -C "$SRC" tag "${2:-v$1}"
}
release 0.9.9
release 0.10.0          # newest by version; "v0.9.9" sorts after it as text
release 1.0.0-rc1 v1.0.0-rc1   # not vX.Y.Z: never chosen
release main-only -     # untagged work on main: never chosen
g clone --quiet --bare "$SRC" "$BARE"

run() {   # run get.sh piped into bash, as the README's one-liner does
  env HOME="$H" HOOK_REPO_URL="$BARE" PATH="$FAKE:$PATH" "$@" >"$OUT" 2>&1
}
head_of() { g -C "$1" describe --tags --exact-match HEAD 2>/dev/null || echo "none"; }
DEFAULT="$H/.local/share/hook"

# 1. A fresh run clones into ~/.local/share/hook, checks out the newest release tag and
#    hands the arguments after `bash -s --` to install.sh.
run bash -s -- --local --mailbox "a b" < "$GET" || { cat "$OUT"; fail "a fresh run exited non-zero"; }
[ "$(head_of "$DEFAULT")" = "v0.10.0" ] || fail "fresh clone is at $(head_of "$DEFAULT"), not v0.10.0"
grep -qx 'install-stub 0.10.0 args:--local --mailbox a b' "$OUT" || { cat "$OUT"; fail "install.sh did not get the arguments"; }
ok "fresh clone checks out the newest tag and passes the arguments"

# 2. No arguments: install.sh runs with none.
run bash < "$GET" || { cat "$OUT"; fail "a run without arguments exited non-zero"; }
grep -qx 'install-stub 0.10.0 args:' "$OUT" || { cat "$OUT"; fail "install.sh got arguments it was not given"; }
ok "no arguments"

# 3. An existing clone is fetched and moved to the new release.
release 0.10.1
g -C "$SRC" push --quiet "$BARE" main v0.10.1
run bash < "$GET" || { cat "$OUT"; fail "an update run exited non-zero"; }
[ "$(head_of "$DEFAULT")" = "v0.10.1" ] || fail "existing clone is at $(head_of "$DEFAULT"), not v0.10.1"
grep -q "get: updating $DEFAULT" "$OUT" || fail "the update was not reported"
grep -qx 'install-stub 0.10.1 args:' "$OUT" || fail "install.sh of the new release did not run"
ok "existing clone updates"

# 4. A clone with local changes is refused and left as it was.
echo "local edit" >> "$DEFAULT/VERSION"
release 0.10.2
g -C "$SRC" push --quiet "$BARE" main v0.10.2
if run bash < "$GET"; then fail "a dirty clone was accepted"; fi
grep -q "has local changes; left alone" "$OUT" || { cat "$OUT"; fail "the refusal does not say why"; }
[ "$(head_of "$DEFAULT")" = "v0.10.1" ] || fail "a dirty clone was moved"
grep -q 'local edit' "$DEFAULT/VERSION" || fail "the local change was lost"
if grep -q 'install-stub' "$OUT"; then fail "install.sh ran from a dirty clone"; fi
g -C "$DEFAULT" checkout --quiet -- VERSION
ok "dirty clone refused"

# 5. A folder that is not a clone of this project is refused: another repo, and a plain folder.
OTHER="$T/other"
g init --quiet "$OTHER"
g -C "$OTHER" remote add origin https://github.com/example/other.git
echo keep > "$OTHER/file"
if run env HOOK_DIR="$OTHER" bash < "$GET"; then fail "another project's clone was accepted"; fi
grep -q "is not a clone of Hook (origin: https://github.com/example/other.git)" "$OUT" || { cat "$OUT"; fail "no refusal for another repo"; }
PLAIN="$T/plain"
mkdir -p "$PLAIN"
echo keep > "$PLAIN/notes.txt"
if run env HOOK_DIR="$PLAIN" bash < "$GET"; then fail "a plain folder was accepted"; fi
grep -q "is not a clone of Hook; left alone" "$OUT" || { cat "$OUT"; fail "no refusal for a plain folder"; }
[ "$(ls -A "$PLAIN")" = "notes.txt" ] || fail "the plain folder was changed"
if grep -q 'install-stub' "$OUT"; then fail "install.sh ran from a folder that isn't ours"; fi
ok "non-project directory refused"

# 6. HOOK_DIR picks the folder when no install exists yet.
rm -rf "$DEFAULT"
CUSTOM="$T/custom/hook"
run env HOOK_DIR="$CUSTOM" bash < "$GET" || { cat "$OUT"; fail "a HOOK_DIR run exited non-zero"; }
[ "$(head_of "$CUSTOM")" = "v0.10.2" ] || fail "HOOK_DIR clone is at $(head_of "$CUSTOM")"
[ ! -e "$DEFAULT" ] || fail "HOOK_DIR was ignored"
ok "HOOK_DIR"

# 7. An existing install wins over HOOK_DIR: the repo ~/.local/bin/relay links into.
mkdir -p "$H/.local/bin"
ln -s "$CUSTOM/bin/relay" "$H/.local/bin/relay"
release 0.10.3
g -C "$SRC" push --quiet "$BARE" main v0.10.3
run env HOOK_DIR="$T/elsewhere" bash < "$GET" || { cat "$OUT"; fail "a run with an existing install exited non-zero"; }
[ "$(head_of "$CUSTOM")" = "v0.10.3" ] || fail "the linked install was not updated"
[ ! -e "$T/elsewhere" ] || fail "a second clone was made next to the existing install"
ok "existing install's repo is used"

# 8. Missing Command Line Tools: the installer is started and the message says to rerun.
printf '#!/bin/sh\necho "$*" >> "%s/xcode-select.log"\nexit 2\n' "$T" > "$FAKE/xcode-select"
if run bash < "$GET"; then fail "a Mac without the Command Line Tools was accepted"; fi
grep -qx -- '--install' "$T/xcode-select.log" || fail "xcode-select --install was not started"
grep -q 'Command Line Tools are missing.*run this command again' "$OUT" || { cat "$OUT"; fail "no rerun message"; }
if grep -q 'install-stub' "$OUT"; then fail "install.sh ran without the Command Line Tools"; fi
ok "missing Command Line Tools"

echo "GET TESTS OK"
