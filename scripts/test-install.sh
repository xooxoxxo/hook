#!/usr/bin/env bash
# Sandbox test for scripts/install.sh. HOME is a fresh temp folder and the test-only
# switches are on, so nothing is built, launched or registered, and the real
# ~/.config, ~/Applications, LaunchAgents, Claude config and running Relay are untouched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
INSTALL="$REPO/scripts/install.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# Running install.sh without the switches would touch the real Mac; refuse early.
grep -q 'RELAY_SKIP_LAUNCH' "$INSTALL" || fail "install.sh has no RELAY_SKIP_* switches yet"
bash -n "$INSTALL" || fail "install.sh has a syntax error"

H="$T/home"
mkdir -p "$H"
CONFIG="$H/.config/relay/config.json"
PLIST="$H/Library/LaunchAgents/io.github.xooxoxxo.relay.plist"
OLD_PLIST="$H/Library/LaunchAgents/dev.instructables.relay.plist"
OUT="$T/out.txt"

run() {   # run install.sh in the sandbox; output goes to $OUT; returns its exit status
  env HOME="$H" RELAY_SKIP_BUILD=1 RELAY_SKIP_LAUNCH=1 RELAY_SKIP_MCP=1 \
    "$INSTALL" "$@" >"$OUT" 2>&1
}
mode_of() { stat -f '%Lp' "$1"; }
config_eq() {   # config_eq '<json>': config.json equals it; "@REPO@" stands for the repo path
  python3 - "$CONFIG" "$REPO" "$1" <<'PY' || fail "config is $(cat "$CONFIG"), expected $1"
import json, sys
path, repo, expected = sys.argv[1:4]
want = json.loads(expected)
if want.get("repoPath") == "@REPO@":
    want["repoPath"] = repo
sys.exit(0 if json.load(open(path, encoding="utf-8")) == want else 1)
PY
}
config_key() {   # config_key <key> '<json value>'
  python3 - "$CONFIG" "$1" "$2" <<'PY' || fail "config key $1 is not $2: $(cat "$CONFIG")"
import json, sys
path, key, value = sys.argv[1:4]
sys.exit(0 if json.load(open(path, encoding="utf-8")).get(key) == json.loads(value) else 1)
PY
}

# 1. Fresh install: {"source":"local"} plus repoPath, 0600 in a 0700 folder.
run || { cat "$OUT"; fail "fresh install exited non-zero"; }
config_eq '{"source": "local", "repoPath": "@REPO@"}'
[ "$(mode_of "$CONFIG")" = "600" ] || fail "config.json is $(mode_of "$CONFIG"), not 600"
[ "$(mode_of "$H/.config/relay")" = "700" ] || fail "~/.config/relay is not 700"
[ "$(mode_of "$H/Library/Application Support/Relay")" = "700" ] || fail "the data folder is not 700"
[ -f "$PLIST" ] || fail "first install did not write the LaunchAgent"
plutil -lint "$PLIST" >/dev/null || fail "LaunchAgent plist does not lint"
[ "$(mode_of "$PLIST")" = "644" ] || fail "LaunchAgent is $(mode_of "$PLIST"), not 644"
[ "$(plutil -extract Label raw "$PLIST")" = "io.github.xooxoxxo.relay" ] || fail "LaunchAgent Label"
[ "$(plutil -extract ProgramArguments.0 raw "$PLIST")" = "/usr/bin/open" ] || fail "LaunchAgent ProgramArguments.0"
[ "$(plutil -extract ProgramArguments.1 raw "$PLIST")" = "-a" ] || fail "LaunchAgent ProgramArguments.1"
[ "$(plutil -extract ProgramArguments.2 raw "$PLIST")" = "$H/Applications/Relay.app" ] || fail "LaunchAgent ProgramArguments.2"
[ "$(plutil -extract RunAtLoad raw "$PLIST")" = "true" ] || fail "LaunchAgent RunAtLoad"
[ "$(plutil -extract KeepAlive raw "$PLIST")" = "false" ] || fail "LaunchAgent KeepAlive"
[ "$(readlink "$H/.local/bin/relay")" = "$REPO/bin/relay" ] || fail "CLI link is wrong"
[ "$(readlink "$H/.claude/skills/instructables")" = "$REPO/skill/instructables" ] || fail "skill link is wrong"
grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$OUT" || fail "no PATH hint although ~/.local/bin is not on PATH"
ok "fresh install"
# RELAY_SKIP_BUILD installs no app; stand one in, so the reruns below aren't first installs.
mkdir -p "$H/Applications/Relay.app/Contents"

# 2. A rerun keeps unknown keys and never turns a removed LaunchAgent back on.
python3 - "$CONFIG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.update({"custom": 7, "hotkey": ""})
open(sys.argv[1], "w").write(json.dumps(d))
PY
rm "$PLIST"
run || { cat "$OUT"; fail "rerun exited non-zero"; }
config_eq '{"source": "local", "repoPath": "@REPO@", "custom": 7, "hotkey": ""}'
[ ! -e "$PLIST" ] || fail "rerun re-created a LaunchAgent the owner had removed"
ok "rerun keeps unknown keys; LaunchAgent stays off"

# 3. A rerun rewrites a LaunchAgent that exists.
echo "old" > "$PLIST"
run || { cat "$OUT"; fail "rerun with LaunchAgent exited non-zero"; }
grep -q "<string>$H/Applications/Relay.app</string>" "$PLIST" || fail "existing LaunchAgent not rewritten"
[ "$(mode_of "$PLIST")" = "644" ] || fail "LaunchAgent is $(mode_of "$PLIST"), not 644"
[ "$(mode_of "$H/Library/LaunchAgents")" != "700" ] || fail "~/Library/LaunchAgents was chmodded to 700"
ok "existing LaunchAgent rewritten"

# 4. --mailbox sets the fields and never prints the token.
CTX="$T/ctx"
mkdir -p "$CTX"
echo "https://mailbox.example.test/" > "$CTX/mailbox-url"
echo "example-mailbox-value" > "$CTX/mailbox-token"
CTX_REAL="$(cd "$CTX" && pwd -P)"
run --mailbox "$CTX" || { cat "$OUT"; fail "--mailbox exited non-zero"; }
config_key source '"mailbox"'
config_key mailboxURL '"https://mailbox.example.test"'
config_key tokenFile "\"$CTX_REAL/mailbox-token\""
config_key custom 7
if grep -q 'example-mailbox-value' "$OUT" "$CONFIG"; then fail "the token value was printed or stored"; fi
ok "--mailbox"

# 5. --mailbox with an empty token file stops before writing anything.
: > "$CTX/mailbox-token"
before="$(shasum "$CONFIG")"
if run --mailbox "$CTX"; then fail "--mailbox accepted an empty token file"; fi
[ "$(shasum "$CONFIG")" = "$before" ] || fail "a refused --mailbox changed the config"
ok "--mailbox refuses an empty token file"

# 6. --local switches back and keeps the mailbox fields (merge).
run --local || { cat "$OUT"; fail "--local exited non-zero"; }
config_key source '"local"'
config_key mailboxURL '"https://mailbox.example.test"'
if run --local --mailbox "$CTX"; then fail "--local with --mailbox was accepted"; fi
ok "--local"

# 7. An unparseable config is moved aside, then replaced.
echo '{"source": "local",' > "$CONFIG"
run || { cat "$OUT"; fail "install over a broken config exited non-zero"; }
ls "$H/.config/relay/" | grep -q '^config\.json\.bad-[0-9]\{8\}-[0-9]\{6\}$' || fail "broken config not moved to .bad-*"
[ "$(cat "$H"/.config/relay/config.json.bad-*)" = '{"source": "local",' ] || fail "moved file lost its content"
config_eq '{"source": "local", "repoPath": "@REPO@"}'
grep -q 'did not parse; moved it to' "$OUT" || fail "the move was not reported"
ok "unparseable config moved aside"

# 8. A skill link that points elsewhere is left alone, by install and uninstall.
rm "$H/.claude/skills/instructables"
ln -s "$T" "$H/.claude/skills/instructables"
run || { cat "$OUT"; fail "install with a foreign skill link exited non-zero"; }
[ "$(readlink "$H/.claude/skills/instructables")" = "$T" ] || fail "a foreign skill link was replaced"
grep -q 'points elsewhere; left alone' "$OUT" || fail "the foreign skill link was not reported"
ok "foreign skill link left alone"

# 9. --uninstall keeps the config and removes the CLI link, app and LaunchAgent.
mkdir -p "$H/Applications/Relay.app/Contents"
run --uninstall || { cat "$OUT"; fail "--uninstall exited non-zero"; }
[ -f "$CONFIG" ] || fail "--uninstall removed the config"
[ ! -e "$H/.local/bin/relay" ] && [ ! -L "$H/.local/bin/relay" ] || fail "--uninstall kept the CLI link"
[ ! -e "$H/Applications/Relay.app" ] || fail "--uninstall kept the app"
[ ! -e "$PLIST" ] || fail "--uninstall kept the LaunchAgent"
[ "$(readlink "$H/.claude/skills/instructables")" = "$T" ] || fail "--uninstall removed a foreign skill link"
grep -q "config: $CONFIG" "$OUT" || fail "--uninstall did not print the kept config path"
[ "$(tail -1 "$OUT")" = "To also remove Relay's UI state: defaults delete io.github.xooxoxxo.relay" ] \
  || fail "--uninstall did not end with the defaults hint"
ok "--uninstall"

# 10. --uninstall removes this repo's own skill link.
rm "$H/.claude/skills/instructables"
run || { cat "$OUT"; fail "reinstall exited non-zero"; }
run --uninstall || { cat "$OUT"; fail "second --uninstall exited non-zero"; }
[ ! -L "$H/.claude/skills/instructables" ] || fail "--uninstall kept this repo's skill link"
ok "--uninstall removes this repo's skill link"

# 11. A config without an app (a first install that failed at the build) is still a
#     first install, so the LaunchAgent is written; with the app it isn't, and the
#     message says so neutrally.
rm -f "$PLIST"
[ ! -d "$H/Applications/Relay.app" ] || fail "test setup: the app should be gone after --uninstall"
run || { cat "$OUT"; fail "install with a config but no app exited non-zero"; }
[ -f "$PLIST" ] || fail "a config without an app was not treated as a first install"
mkdir -p "$H/Applications/Relay.app/Contents"
rm "$PLIST"
run || { cat "$OUT"; fail "rerun with the app exited non-zero"; }
[ ! -e "$PLIST" ] || fail "a rerun with the app re-created the LaunchAgent"
grep -q 'launchagent: not written (not a first install' "$OUT" || fail "the LaunchAgent skip message changed"
if grep -q 'Launch at login is off' "$OUT"; then fail "the skip message claims Launch at login is off"; fi
ok "missing app counts as a first install"

# 12. A config with a UTF-8 BOM is read, not moved aside (a mailbox setup stays a mailbox).
bad_count() { ls "$H/.config/relay/" | grep -c '^config\.json\.bad-' || true; }
bad_before="$(bad_count)"
printf '\xef\xbb\xbf{"source": "mailbox", "mailboxURL": "https://mailbox.example.test", "tokenFile": "/tmp/example-token"}\n' > "$CONFIG"
run || { cat "$OUT"; fail "install over a BOM config exited non-zero"; }
[ "$(bad_count)" = "$bad_before" ] || fail "a BOM config was moved aside"
config_key source '"mailbox"'
config_key mailboxURL '"https://mailbox.example.test"'
ok "BOM config kept"

# 13. Someone else's `relay` command is left alone, by install and uninstall.
rm -f "$H/.local/bin/relay"
ln -s "$T/other-relay" "$H/.local/bin/relay"
run || { cat "$OUT"; fail "install with a foreign CLI link exited non-zero"; }
[ "$(readlink "$H/.local/bin/relay")" = "$T/other-relay" ] || fail "install replaced a foreign relay command"
grep -q 'cli: .* points elsewhere; left alone' "$OUT" || fail "the foreign CLI link was not reported"
grep -qF 'rm ~/.local/bin/relay && ./scripts/install.sh' "$OUT" || fail "the foreign CLI warning does not name the fix"
run --uninstall || { cat "$OUT"; fail "--uninstall with a foreign CLI link exited non-zero"; }
[ "$(readlink "$H/.local/bin/relay")" = "$T/other-relay" ] || fail "--uninstall removed a foreign relay command"
rm "$H/.local/bin/relay"
ok "foreign CLI link left alone"

# 14. A failing `claude mcp add` warns and the install still finishes. Only here is the
#     MCP step on (RELAY_SKIP_MCP unset), with a fake `claude` first on PATH.
FAKE="$T/fakebin"
mkdir -p "$FAKE"
printf '#!/bin/sh\necho "$*" >> "%s/claude.log"\nexit 1\n' "$T" > "$FAKE/claude"
chmod +x "$FAKE/claude"
mkdir -p "$H/Applications/Relay.app/Contents"
env -u RELAY_SKIP_MCP HOME="$H" PATH="$FAKE:$PATH" RELAY_SKIP_BUILD=1 RELAY_SKIP_LAUNCH=1 \
  "$INSTALL" >"$OUT" 2>&1 || { cat "$OUT"; fail "a failing claude mcp add aborted the install"; }
grep -q '^mcp add --scope user relay' "$T/claude.log" || fail "the fake claude was not called"
grep -q "mcp: registration failed; later run: claude mcp add --scope user relay" "$OUT" || fail "no MCP warning with the command"
grep -q '^skill: ' "$OUT" || fail "the skill step did not run after the MCP failure"
grep -q '^launchagent: ' "$OUT" || fail "the LaunchAgent step did not run after the MCP failure"
grep -q '^start: skipped' "$OUT" || fail "the start step was not reached after the MCP failure"
ok "failing claude mcp add is not fatal"

# 15. A LaunchAgent under the old bundle id is removed and replaced by the new one,
#     even on a rerun (launch at login stays on); --uninstall removes an old one too.
#     RELAY_SKIP_LAUNCH=1 keeps launchctl out of it, as everywhere here.
mkdir -p "$H/Applications/Relay.app/Contents"
rm -f "$PLIST"
echo "old" > "$OLD_PLIST"
run || { cat "$OUT"; fail "install with an old LaunchAgent exited non-zero"; }
[ ! -e "$OLD_PLIST" ] || fail "the old LaunchAgent was not removed"
[ -f "$PLIST" ] || fail "the old LaunchAgent was not replaced by the new one"
[ "$(plutil -extract Label raw "$PLIST")" = "io.github.xooxoxxo.relay" ] || fail "new LaunchAgent Label"
[ "$(grep -c 'removed the old dev.instructables.relay LaunchAgent' "$OUT")" = "1" ] || fail "the migration was not reported once"
echo "old" > "$OLD_PLIST"
run --uninstall || { cat "$OUT"; fail "--uninstall with an old LaunchAgent exited non-zero"; }
[ ! -e "$OLD_PLIST" ] && [ ! -e "$PLIST" ] || fail "--uninstall kept a LaunchAgent"
grep -q 'removed the old dev.instructables.relay LaunchAgent' "$OUT" || fail "--uninstall did not report the old LaunchAgent"
ok "old bundle id LaunchAgent migrated"

# 16. When `swift --version` itself fails, its first line and the license hint are shown.
#     The fake swift also makes any build fail, so nothing past the checks can run.
printf '#!/bin/sh\necho "You have not agreed to the Xcode license agreements."\nexit 69\n' > "$FAKE/swift"
printf '#!/bin/sh\necho /Applications/Xcode.app/Contents/Developer\n' > "$FAKE/xcode-select"
chmod +x "$FAKE/swift" "$FAKE/xcode-select"
if env HOME="$H" PATH="$FAKE:$PATH" RELAY_SKIP_LAUNCH=1 RELAY_SKIP_MCP=1 "$INSTALL" >"$OUT" 2>&1; then
  fail "install went on although swift --version failed"
fi
grep -q 'swift --version failed: You have not agreed to the Xcode license' "$OUT" || { cat "$OUT"; fail "swift's own message was not shown"; }
grep -q 'sudo xcodebuild -license accept' "$OUT" || fail "no license hint"
if grep -q 'needs Swift 6' "$OUT"; then fail "a failing swift was reported as too old"; fi
ok "failing swift --version is explained"

echo "INSTALL TESTS OK"
