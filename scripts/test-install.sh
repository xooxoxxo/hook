#!/usr/bin/env bash
# Sandbox test for scripts/install.sh. HOME is a fresh temp folder and the test-only
# switches are on, so nothing is built, launched or registered, and the real
# ~/.config, ~/Applications, LaunchAgents, Claude config and running app are untouched.
# The quit and start tests run fake app processes inside the temp folder, fenced to it
# with RELAY_APP_SCOPE.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
INSTALL="$REPO/scripts/install.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"   # ps names processes by their real path

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
fake_app() {   # fake_app <path> [bundle id]: an app folder holding only an Info.plist
  mkdir -p "$1/Contents"
  cat >"$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${2:-io.github.xooxoxxo.relay}</string></dict></plist>
PLIST
}

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

# 1. Fresh install: {"source":"local"} plus repoPath and onboarding "pending" (the app's
#    setup window shows once), 0600 in a 0700 folder.
run || { cat "$OUT"; fail "fresh install exited non-zero"; }
config_eq '{"source": "local", "repoPath": "@REPO@", "onboarding": "pending"}'
[ "$(mode_of "$CONFIG")" = "600" ] || fail "config.json is $(mode_of "$CONFIG"), not 600"
[ "$(mode_of "$H/.config/relay")" = "700" ] || fail "~/.config/relay is not 700"
[ "$(mode_of "$H/Library/Application Support/Relay")" = "700" ] || fail "the data folder is not 700"
[ -f "$PLIST" ] || fail "first install did not write the LaunchAgent"
plutil -lint "$PLIST" >/dev/null || fail "LaunchAgent plist does not lint"
[ "$(mode_of "$PLIST")" = "644" ] || fail "LaunchAgent is $(mode_of "$PLIST"), not 644"
[ "$(plutil -extract Label raw "$PLIST")" = "io.github.xooxoxxo.relay" ] || fail "LaunchAgent Label"
[ "$(plutil -extract ProgramArguments.0 raw "$PLIST")" = "/usr/bin/open" ] || fail "LaunchAgent ProgramArguments.0"
[ "$(plutil -extract ProgramArguments.1 raw "$PLIST")" = "-a" ] || fail "LaunchAgent ProgramArguments.1"
[ "$(plutil -extract ProgramArguments.2 raw "$PLIST")" = "$H/Applications/Hook.app" ] || fail "LaunchAgent ProgramArguments.2"
[ "$(plutil -extract RunAtLoad raw "$PLIST")" = "true" ] || fail "LaunchAgent RunAtLoad"
[ "$(plutil -extract KeepAlive raw "$PLIST")" = "false" ] || fail "LaunchAgent KeepAlive"
[ "$(readlink "$H/.local/bin/relay")" = "$REPO/bin/relay" ] || fail "CLI link is wrong"
[ "$(readlink "$H/.local/bin/hook")" = "$REPO/bin/relay" ] || fail "hook CLI alias is wrong"
[ "$(readlink "$H/.claude/skills/instructables")" = "$REPO/skill/instructables" ] || fail "skill link is wrong"
grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$OUT" || fail "no PATH hint although ~/.local/bin is not on PATH"
ok "fresh install"
# RELAY_SKIP_BUILD installs no app; stand one in, so the reruns below aren't first installs.
fake_app "$H/Applications/Hook.app"

# 2. A rerun keeps unknown keys, never writes onboarding into a config it didn't create
#    (the app removed it after setup), and never turns a removed LaunchAgent back on.
python3 - "$CONFIG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("onboarding")
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
grep -q "<string>$H/Applications/Hook.app</string>" "$PLIST" || fail "existing LaunchAgent not rewritten"
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
config_eq '{"source": "local", "repoPath": "@REPO@", "onboarding": "pending"}'
grep -q 'did not parse; moved it to' "$OUT" || fail "the move was not reported"
ok "unparseable config moved aside"

# 8. A skill link that points elsewhere is left alone, by install and uninstall.
rm "$H/.claude/skills/instructables"
ln -s "$T" "$H/.claude/skills/instructables"
run || { cat "$OUT"; fail "install with a foreign skill link exited non-zero"; }
[ "$(readlink "$H/.claude/skills/instructables")" = "$T" ] || fail "a foreign skill link was replaced"
grep -q 'points elsewhere; left alone' "$OUT" || fail "the foreign skill link was not reported"
ok "foreign skill link left alone"

# 9. --uninstall keeps the config and removes the CLI links, both apps and LaunchAgent.
fake_app "$H/Applications/Hook.app"; fake_app "$H/Applications/Relay.app"
run --uninstall || { cat "$OUT"; fail "--uninstall exited non-zero"; }
[ -f "$CONFIG" ] || fail "--uninstall removed the config"
[ ! -e "$H/.local/bin/relay" ] && [ ! -L "$H/.local/bin/relay" ] || fail "--uninstall kept the CLI link"
[ ! -e "$H/.local/bin/hook" ] && [ ! -L "$H/.local/bin/hook" ] || fail "--uninstall kept the hook CLI alias"
[ ! -e "$H/Applications/Hook.app" ] || fail "--uninstall kept the app"
[ ! -e "$H/Applications/Relay.app" ] || fail "--uninstall kept the old Relay.app"
[ ! -e "$PLIST" ] || fail "--uninstall kept the LaunchAgent"
[ "$(readlink "$H/.claude/skills/instructables")" = "$T" ] || fail "--uninstall removed a foreign skill link"
grep -q "config: $CONFIG" "$OUT" || fail "--uninstall did not print the kept config path"
[ "$(tail -1 "$OUT")" = "To also remove Hook's UI state: defaults delete io.github.xooxoxxo.relay" ] \
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
[ ! -d "$H/Applications/Hook.app" ] || fail "test setup: the app should be gone after --uninstall"
run || { cat "$OUT"; fail "install with a config but no app exited non-zero"; }
[ -f "$PLIST" ] || fail "a config without an app was not treated as a first install"
fake_app "$H/Applications/Hook.app"
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
config_key onboarding 'null'
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
fake_app "$H/Applications/Hook.app"
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
fake_app "$H/Applications/Hook.app"
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

# 17. An existing Relay.app (from before the rename) means an update, not a first
#     install: a LaunchAgent the owner removed stays off. Relay.app is removed only
#     once Hook.app is in place.
rm -rf "$H/Applications/Hook.app" "$H/Applications/Relay.app"
rm -f "$PLIST" "$OLD_PLIST"
fake_app "$H/Applications/Relay.app"
run || { cat "$OUT"; fail "install over a Relay.app exited non-zero"; }
[ ! -e "$PLIST" ] || fail "an existing Relay.app was treated as a first install"
[ -d "$H/Applications/Relay.app" ] || fail "Relay.app was removed before Hook.app was in place"
fake_app "$H/Applications/Hook.app"
run || { cat "$OUT"; fail "install with Hook.app and Relay.app exited non-zero"; }
[ ! -e "$H/Applications/Relay.app" ] || fail "Relay.app was kept next to Hook.app"
[ -d "$H/Applications/Hook.app" ] || fail "Hook.app went missing"
grep -q "app: removed $H/Applications/Relay.app" "$OUT" || fail "the Relay.app removal was not reported"
ok "Relay.app counts as installed and goes once Hook.app is in place"

# 18. Someone else's `hook` command is left alone, by install and uninstall.
rm -f "$H/.local/bin/hook"
ln -s "$T/other-hook" "$H/.local/bin/hook"
run || { cat "$OUT"; fail "install with a foreign hook command exited non-zero"; }
[ "$(readlink "$H/.local/bin/hook")" = "$T/other-hook" ] || fail "install replaced a foreign hook command"
grep -q 'cli: .*hook is something else; left alone' "$OUT" || fail "the foreign hook command was not reported"
run --uninstall || { cat "$OUT"; fail "--uninstall with a foreign hook command exited non-zero"; }
[ "$(readlink "$H/.local/bin/hook")" = "$T/other-hook" ] || fail "--uninstall removed a foreign hook command"
rm "$H/.local/bin/hook"
ok "foreign hook command left alone"

# 19. Another app called Hook (another bundle id) is never treated as this app: an
#     old Relay.app stays next to it, and --uninstall leaves it in place.
rm -rf "$H/Applications/Hook.app" "$H/Applications/Relay.app"
fake_app "$H/Applications/Hook.app" com.example.other-hook
fake_app "$H/Applications/Relay.app"
run || { cat "$OUT"; fail "install next to a foreign Hook.app exited non-zero"; }
[ -d "$H/Applications/Relay.app" ] || fail "Relay.app was removed although Hook.app is another app"
run --uninstall || { cat "$OUT"; fail "--uninstall next to a foreign Hook.app exited non-zero"; }
[ -d "$H/Applications/Hook.app" ] || fail "--uninstall removed another app called Hook"
grep -q "Hook.app is not this app" "$OUT" || fail "the foreign Hook.app was not reported"
[ ! -e "$H/Applications/Relay.app" ] || fail "--uninstall kept the old Relay.app"
ok "another app called Hook is left alone"

# 20. A fresh app install over a kept config (Hook.app deleted, then reinstalled) sets
#     onboarding "pending", so the setup window shows; an update over our bundle doesn't.
rm -rf "$H/Applications/Hook.app" "$H/Applications/Relay.app"
printf '{"source": "local", "custom": 1}\n' > "$CONFIG"
run || { cat "$OUT"; fail "a fresh app install over a kept config exited non-zero"; }
config_key onboarding '"pending"'
config_key custom 1
grep -q 'Hook.app is new here, so setup shows when it starts' "$OUT" || fail "the fresh app install was not reported"
fake_app "$H/Applications/Hook.app"
printf '{"source": "local", "custom": 1}\n' > "$CONFIG"
run || { cat "$OUT"; fail "an update over our bundle exited non-zero"; }
config_key onboarding 'null'
if grep -q 'Hook.app is new here' "$OUT"; then fail "an update was reported as a fresh app install"; fi
rm -rf "$H/Applications/Hook.app"
fake_app "$H/Applications/Relay.app"
run || { cat "$OUT"; fail "an update from Relay.app exited non-zero"; }
config_key onboarding 'null'
rm -rf "$H/Applications/Relay.app"
fake_app "$H/Applications/Hook.app" com.example.other-hook
run || { cat "$OUT"; fail "an install next to a foreign Hook.app exited non-zero"; }
config_key onboarding '"pending"'
rm -rf "$H/Applications/Hook.app"
ok "a fresh app install shows setup again; an update doesn't"

# 21. A Hook that ignores SIGTERM is force-quit before its bundle is replaced; another app
#     called Hook is never touched; a copy whose bundle is gone counts as ours only from
#     under HOME. RELAY_APP_SCOPE fences every step to the sandbox ($T, which holds the
#     sandbox HOME and a folder outside it), so a real Hook running on this Mac is never seen. The fake app is a tiny C program, so its
#     process name is Hook.
command -v cc >/dev/null 2>&1 || fail "cc is needed for the fake app (install the Command Line Tools)"
printf '#include <signal.h>\n#include <unistd.h>\nint main(void) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }\n' > "$T/stubborn.c"
cc -o "$T/stubborn" "$T/stubborn.c" || fail "couldn't build the fake app"
PIDS="$T/pids"
: > "$PIDS"
trap 'while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$PIDS"; rm -rf "$T"' EXIT
fake_running() {   # fake_running <app> [bundle id]: a bundle whose Hook ignores SIGTERM, started; prints its pid
  fake_app "$1" "${2:-io.github.xooxoxxo.relay}"
  mkdir -p "$1/Contents/MacOS"
  cp "$T/stubborn" "$1/Contents/MacOS/Hook"
  ( "$1/Contents/MacOS/Hook" >/dev/null 2>&1 & echo $! > "$T/last.pid" )
  cat "$T/last.pid" >> "$PIDS"
  cat "$T/last.pid"
}
alive() { kill -0 "$1" 2>/dev/null; }
step() {   # step <stop|start>: one install.sh step, fenced to the sandbox
  env HOME="$H" RELAY_APP_SCOPE="$T" RELAY_TEST_STEP="$1" "$INSTALL" >"$OUT" 2>&1
}
rm -rf "$H/Applications/Hook.app" "$H/Applications/Relay.app"
ours_pid="$(fake_running "$H/Applications/Hook.app")"
other_pid="$(fake_running "$H/Other/Hook.app" com.example.other-hook)"
gone_pid="$(fake_running "$H/Gone/Hook.app")"
outside="$T/outside-home/Hook.app"
outside_pid="$(fake_running "$outside")"
sleep 0.5   # let them load before their bundles go
rm -rf "$H/Gone/Hook.app" "$outside"
for p in "$ours_pid" "$other_pid" "$gone_pid" "$outside_pid"; do alive "$p" || fail "a fake app didn't start (pid $p)"; done
step stop || { cat "$OUT"; fail "the stop step exited non-zero"; }
! alive "$ours_pid" || fail "a Hook that ignores SIGTERM is still running"
! alive "$gone_pid" || fail "a Hook whose bundle is gone (under HOME) is still running"
alive "$other_pid" || fail "another app called Hook was killed"
grep -qx "app: force-quit a Hook that did not quit (pid $ours_pid)" "$OUT" || { cat "$OUT"; fail "the force-quit was not reported"; }
grep -qx "app: force-quit a Hook that did not quit (pid $gone_pid)" "$OUT" || { cat "$OUT"; fail "the gone bundle's force-quit was not reported"; }
if grep -q "pid $other_pid" "$OUT"; then fail "another app called Hook was reported"; fi
alive "$outside_pid" || fail "a Hook whose bundle is gone, outside HOME, was killed"
ok "a Hook that ignores SIGTERM is force-quit; another app called Hook is left alone"
kill -9 "$outside_pid" "$other_pid" 2>/dev/null || true

# 22. After the start, a copy older than the install (open only brought it forward) is
#     force-quit and the app started again; the new copy is left running.
old_pid="$(fake_running "$H/Applications/Hook.app")"
sleep 2   # older than the install by whole seconds
step start || { cat "$OUT"; fail "the start step exited non-zero"; }
! alive "$old_pid" || fail "the older Hook is still running after the start"
grep -qx "app: an older Hook is still running; starting the new one again" "$OUT" || { cat "$OUT"; fail "the restart was not reported"; }
grep -qx "app: force-quit a Hook that did not quit (pid $old_pid)" "$OUT" || { cat "$OUT"; fail "the older copy's force-quit was not reported"; }
new_pid="$(pgrep -f "^$H/Applications/Hook.app/Contents/MacOS/Hook" || true)"
[ -n "$new_pid" ] || fail "the new Hook was not started again"
echo "$new_pid" >> "$PIDS"
alive "$new_pid" || fail "the new Hook is not running"
kill -9 $new_pid 2>/dev/null || true
ok "an older copy found after the start is replaced by the new one"

# 23. The single steps refuse to run without the sandbox fence.
if env HOME="$H" RELAY_TEST_STEP=stop "$INSTALL" >"$OUT" 2>&1; then fail "RELAY_TEST_STEP ran without RELAY_APP_SCOPE"; fi
grep -q 'RELAY_TEST_STEP needs RELAY_APP_SCOPE' "$OUT" || fail "no reason for the refusal"
ok "single steps need the fence"

echo "INSTALL TESTS OK"
