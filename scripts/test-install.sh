#!/usr/bin/env bash
# Sandbox test for scripts/install.sh. HOME is a fresh temp folder and the test-only
# switches are on, so nothing is built, launched or registered, and the real
# ~/.config, ~/Applications, LaunchAgents, Claude config and running app are untouched.
# The quit and start tests run fake app processes inside the temp folder, fenced to it
# with RELAY_APP_SCOPE. Runs that set up agent integrations see only fake harness CLIs
# (clients/fixtures/fakecli.py as claude and codex) and the system folders on PATH, with
# HOOK_BIN_DIRS and HOOK_APP_DIRS empty, so no real harness CLI or app is ever found.
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

# This checkout builds from source as a developer's clone would; without this, a clean
# clone (as CI checks out) would hand over to the release download.
export HOOK_DEV=1

# Running install.sh without the switches would touch the real Mac; refuse early.
grep -q 'RELAY_SKIP_LAUNCH' "$INSTALL" || fail "install.sh has no RELAY_SKIP_* switches yet"
bash -n "$INSTALL" || fail "install.sh has a syntax error"

H="$T/home"
mkdir -p "$H"
# Runs from this checkout skip the integrations, so they never build a bundle into it.
REPO_BUNDLE_BEFORE=0
[ ! -e "$REPO/build/integration" ] || REPO_BUNDLE_BEFORE=1
CONFIG="$H/.config/relay/config.json"
PLIST="$H/Library/LaunchAgents/io.github.xooxoxxo.relay.plist"
OLD_PLIST="$H/Library/LaunchAgents/dev.instructables.relay.plist"
OUT="$T/out.txt"

run() {   # run install.sh in the sandbox; output goes to $OUT; returns its exit status
  env HOME="$H" RELAY_SKIP_BUILD=1 RELAY_SKIP_LAUNCH=1 RELAY_SKIP_MCP=1 HOOK_BIN_DIRS= HOOK_APP_DIRS= \
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
config_eq '{"source": "local", "repoPath": "@REPO@", "onboarding": "pending", "updateMode": "developer"}'
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
[ ! -e "$H/.claude/skills/instructables" ] && [ ! -L "$H/.claude/skills/instructables" ] \
  || fail "install linked a skill into ~/.claude/skills (the Claude Code plugin carries it now)"
grep -qx 'integrations: skipped (RELAY_SKIP_INTEGRATIONS=1)' "$OUT" || { cat "$OUT"; fail "RELAY_SKIP_MCP=1 did not skip the integrations"; }
[ ! -e "$REPO/build/integration" ] || [ "$REPO_BUNDLE_BEFORE" = "1" ] || fail "a skipped integrations run built a bundle in the repo"
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
config_eq '{"source": "local", "repoPath": "@REPO@", "custom": 7, "hotkey": "", "updateMode": "developer"}'
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
config_eq '{"source": "local", "repoPath": "@REPO@", "onboarding": "pending", "updateMode": "developer"}'
grep -q 'did not parse; moved it to' "$OUT" || fail "the move was not reported"
ok "unparseable config moved aside"

# 8. A skill link that points elsewhere is left alone, by install and uninstall. (With the
#    integrations on, sync reports it as foreign: see 33.)
mkdir -p "$H/.claude/skills"
ln -s "$T" "$H/.claude/skills/instructables"
run || { cat "$OUT"; fail "install with a foreign skill link exited non-zero"; }
[ "$(readlink "$H/.claude/skills/instructables")" = "$T" ] || fail "a foreign skill link was replaced"
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

# 10. Without an integrations manifest, --uninstall still removes the skill link an older
#     install made into this repo (the legacy cleanup).
rm "$H/.claude/skills/instructables"
run || { cat "$OUT"; fail "reinstall exited non-zero"; }
ln -s "$REPO/skill/instructables" "$H/.claude/skills/instructables"
[ ! -e "$H/.config/relay/integrations.json" ] || fail "test setup: a skipped install wrote a manifest"
run --uninstall || { cat "$OUT"; fail "second --uninstall exited non-zero"; }
[ ! -L "$H/.claude/skills/instructables" ] || fail "--uninstall kept this repo's skill link"
grep -qx 'integrations: skipped (RELAY_SKIP_INTEGRATIONS=1)' "$OUT" || { cat "$OUT"; fail "a skipped --uninstall ran the integrations"; }
ok "--uninstall removes an older install's skill link when there is no manifest"

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

# 14. (A failing integrations sync: see 34.)
FAKE="$T/fakebin"
mkdir -p "$FAKE"
fake_app "$H/Applications/Hook.app"

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

# --- prebuilt releases (scripts/get.sh, then install.sh --prebuilt) -----------------
# A fixture release packed by package-release.sh from this checkout, with a stand-in
# app, served over file://. Its install.sh is this checkout's.
VERSION="$(plutil -extract CFBundleShortVersionString raw "$REPO/Resources/Info.plist")"
REL="$T/releases"
mkdir -p "$T/fixture-app/Hook.app/Contents/MacOS" "$REL/download/v$VERSION" "$REL/latest/download"
cat > "$T/fixture-app/Hook.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.xooxoxxo.relay</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$T/fixture-app/Hook.app/Contents/MacOS/Hook"
chmod +x "$T/fixture-app/Hook.app/Contents/MacOS/Hook"
"$REPO/scripts/package-release.sh" --app "$T/fixture-app/Hook.app" --out "$REL/download/v$VERSION" >/dev/null
cp "$REL/download/v$VERSION/"* "$REL/latest/download/"

# Fake harness CLIs: clients/fixtures/fakecli.py as claude and codex. Their MCP commands
# write and remove the key a real CLI would (~ is the HOME they run with); every call is a
# JSON line in $FAKE_LOG. PATH holds only them and the system folders, and HOOK_BIN_DIRS and
# HOOK_APP_DIRS are empty, so the integrations find no real harness on this Mac.
PFAKE="$T/prebuilt-fakebin"
mkdir -p "$PFAKE"
PY="$(python3 -c 'import sys; print(sys.executable)')"   # the interpreter itself, not a shim script
for prog in claude codex; do
  { echo "#!$PY"; cat "$REPO/clients/fixtures/fakecli.py"; } > "$PFAKE/$prog"
done
printf '#!/bin/sh\necho "swift $*" >> "%s/compiler.log"\nexit 1\n' "$T" > "$PFAKE/swift"
chmod +x "$PFAKE/claude" "$PFAKE/codex" "$PFAKE/swift"
FAKE_LOG="$T/fakecli.log"
FAKE_RULES="$T/fakecli.json"
cat > "$FAKE_RULES" <<'JSON'
{"rules": [
  {"prog": "claude", "prefix": ["mcp", "add-json", "--scope", "user", "relay"], "action": "set",
   "writes": {"path": "~/.claude.json", "format": "json", "key": ["mcpServers", "relay"]}},
  {"prog": "claude", "prefix": ["mcp", "remove", "relay"], "action": "delete",
   "writes": {"path": "~/.claude.json", "format": "json", "key": ["mcpServers", "relay"]}},
  {"prog": "codex", "prefix": ["mcp", "add", "relay"], "action": "set",
   "writes": {"path": "~/.codex/config.toml", "format": "toml", "key": ["mcp_servers", "relay"]}},
  {"prog": "codex", "prefix": ["mcp", "remove", "relay"], "action": "delete",
   "writes": {"path": "~/.codex/config.toml", "format": "toml", "key": ["mcp_servers", "relay"]}}
]}
JSON
FAIL_RULES="$T/fakecli-fail.json"
echo '{"fail": ["claude"]}' > "$FAIL_RULES"
SAFE_PATH="$PFAKE:/usr/bin:/bin:/usr/sbin:/sbin"
prun() {   # prun <home> <command…>: a sandboxed run with the fixture releases and the fake CLIs
  local home="$1"; shift
  env -u HOOK_DEV -u RELAY_SKIP_MCP -u RELAY_SKIP_INTEGRATIONS HOME="$home" PATH="$SAFE_PATH" \
    HOOK_BIN_DIRS= HOOK_APP_DIRS= HOOK_RELEASES_URL="file://$REL" \
    FAKECLI_LOG="$FAKE_LOG" FAKECLI_CONFIG="${FAKE_CONFIG:-$FAKE_RULES}" FAKECLI_STATE="$home.fakecli-state.json" \
    FAKECLI_CLIENTS="$REPO/clients" RELAY_SKIP_BUILD=1 RELAY_SKIP_LAUNCH=1 "$@" >"$OUT" 2>&1
}
called() {   # called <prog> <arg…>: the fake <prog> ran with exactly these arguments
  python3 - "$FAKE_LOG" "$@" <<'PY'
import json, sys
log, prog, args = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    lines = open(log, encoding="utf-8").read().splitlines()
except OSError:
    lines = []
sys.exit(0 if any(d.get("prog") == prog and d.get("argv") == args for d in map(json.loads, lines)) else 1)
PY
}
calls() {   # calls: the fake CLI calls so far, one per line, for failure messages
  python3 -c 'import json,sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if "argv" in d: print(d["prog"], *d["argv"])' "$FAKE_LOG" 2>/dev/null || true
}
mcp_json() {   # mcp_json <link root>: the JSON Hook passes to claude mcp add-json
  printf '{"type": "stdio", "command": "python3", "args": ["%s/mcp/relay_mcp.py"]}' "$1"
}
manifest_key() {   # manifest_key <home> <key>: a top-level value of the integrations manifest
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' \
    "$1/.config/relay/integrations.json" "$2" 2>/dev/null || echo "(no manifest)"
}
g() {   # git that ignores the real ~/.gitconfig and never signs
  env GIT_CONFIG_NOSYSTEM=1 HOME="$T" git -c user.name=Test -c user.email=test@example.invalid \
    -c init.defaultBranch=main -c commit.gpgsign=false "$@"
}
old_clone() {   # old_clone <dir>: a clean clone of Hook as an older install left it, on main only
  mkdir -p "$1"
  (cd "$REPO" && tar -cf - Resources/Info.plist bin/relay mcp/relay_mcp.py scripts/install.sh scripts/get.sh \
    scripts/build.sh skill/instructables docs/claude-md-section.md) | (cd "$1" && tar -xf -)
  g init --quiet "$1"
  g -C "$1" add -A
  g -C "$1" commit --quiet -m release
}

# 24. A fresh install from the release: the app comes from the release (nothing is built),
#     the CLI, alias and repoPath go through ~/.local/share/hook/current, and the
#     integrations sync sets up the agents it finds (here Claude Code and Codex, fakes):
#     without the app running, with --no-asks, and on a first install with --include-new.
P="$T/p-home"
mkdir -p "$P/.claude"
printf '{\n  "theme": "dark",\n  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}\n}\n' \
  > "$P/.claude/settings.json"
SETTINGS_BEFORE="$(shasum "$P/.claude/settings.json")"
HC="$P/.local/share/hook/current"
prun "$P" bash "$REPO/scripts/get.sh" --local || { cat "$OUT"; fail "a prebuilt install exited non-zero"; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$P/Applications/Hook.app/Contents/Info.plist")" = "io.github.xooxoxxo.relay" ] \
  || fail "the release's Hook.app was not copied to ~/Applications"
grep -q "app: installed $P/Applications/Hook.app" "$OUT" || { cat "$OUT"; fail "the app copy was not reported"; }
[ "$(readlink "$P/.local/bin/relay")" = "$HC/bin/relay" ] || fail "CLI link is $(readlink "$P/.local/bin/relay")"
[ "$(readlink "$P/.local/bin/hook")" = "$HC/bin/relay" ] || fail "hook alias is $(readlink "$P/.local/bin/hook")"
[ ! -e "$P/.claude/skills/instructables" ] || fail "install linked a skill into ~/.claude/skills"
grep -qx 'integrations: sync --include-new --no-asks' "$OUT" || { cat "$OUT"; fail "the integrations sync did not run with --include-new --no-asks"; }
[ -f "$P/.config/relay/integrations.json" ] || { cat "$OUT"; fail "the sync wrote no manifest"; }
[ "$(manifest_key "$P" linkRoot)" = "~/.local/share/hook/current" ] || fail "manifest linkRoot is $(manifest_key "$P" linkRoot)"
[ -f "$P/.local/share/hook/plugins/claude/.claude-plugin/marketplace.json" ] \
  || { find "$P/.local/share/hook" -maxdepth 4; fail "the Claude Code plugin was not rendered"; }
called claude plugin marketplace add "$P/.local/share/hook/plugins/claude" || { calls; fail "no claude plugin marketplace add"; }
called claude mcp add-json --scope user relay "$(mcp_json "$HC")" || { calls; fail "no claude mcp add-json through current"; }
called codex mcp add relay -- python3 "$HC/mcp/relay_mcp.py" || { calls; fail "no codex mcp add through current"; }
[ -f "$P/.claude/rules/hook.md" ] && [ -f "$P/.codex/AGENTS.md" ] || fail "the instructions were not installed"
if grep -rq '/\.local/share/hook/[0-9]' "$P/.claude.json" "$P/.codex" "$P/.local/share/hook/plugins"; then
  fail "a harness config names a versioned folder"
fi
grep -q 'integrations:' "$OUT" && ! grep -q '^integrations: failed\|weren.t set up' "$OUT" || { cat "$OUT"; fail "the integrations sync warned"; }
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c["repoPath"]==sys.argv[2] and c["source"]=="local" else 1)' \
  "$P/.config/relay/config.json" "$HC" || fail "config: $(cat "$P/.config/relay/config.json")"
[ -f "$P/Library/LaunchAgents/io.github.xooxoxxo.relay.plist" ] || fail "a first prebuilt install wrote no LaunchAgent"
[ ! -e "$T/compiler.log" ] || fail "a prebuilt install ran $(cat "$T/compiler.log")"
"$P/.local/bin/relay" --version >/dev/null 2>&1 || fail "the linked CLI doesn't run"
ok "prebuilt install through current"

# 25. --uninstall from the release runs `integrations remove --all` (so the agents lose
#     exactly what Hook wrote, and ~/.claude/settings.json is as it was before the install),
#     then removes its own links and the app.
prun "$P" "$HC/scripts/install.sh" --uninstall || { cat "$OUT"; fail "a prebuilt --uninstall exited non-zero"; }
grep -qx 'integrations: remove --all' "$OUT" || { cat "$OUT"; fail "--uninstall did not run integrations remove --all"; }
for l in "$P/.local/bin/relay" "$P/.local/bin/hook"; do
  [ ! -e "$l" ] && [ ! -L "$l" ] || fail "--uninstall kept $l"
done
[ ! -e "$P/Applications/Hook.app" ] || fail "--uninstall kept Hook.app"
[ "$(shasum "$P/.claude/settings.json")" = "$SETTINGS_BEFORE" ] || { cat "$P/.claude/settings.json"; fail "~/.claude/settings.json changed"; }
called claude mcp remove relay --scope user || { calls; fail "no claude mcp remove"; }
called claude plugin uninstall hook@hook --scope user || { calls; fail "no claude plugin uninstall"; }
called codex mcp remove relay || { calls; fail "no codex mcp remove"; }
if python3 -c 'import json,sys; sys.exit(0 if "relay" in json.load(open(sys.argv[1])).get("mcpServers", {}) else 1)' "$P/.claude.json" 2>/dev/null; then
  fail "~/.claude.json still has Hook's MCP server"
fi
[ ! -e "$P/.claude/rules/hook.md" ] && [ ! -e "$P/.codex/AGENTS.md" ] && [ ! -e "$P/.agents/skills/instructables" ] \
  || fail "--uninstall left Hook's instructions or skill"
[ ! -e "$P/.local/share/hook/plugins" ] || fail "--uninstall kept the rendered plugins"
[ "$(manifest_key "$P" harnesses)" = "{}" ] || fail "the manifest still has harnesses: $(manifest_key "$P" harnesses)"
grep -q "config: $P/.config/relay/config.json" "$OUT" || fail "--uninstall did not list the kept config"
ok "prebuilt --uninstall removes the integrations first"

# 26. --prebuilt refuses a clone, and a payload that current doesn't link to.
prun "$P" "$INSTALL" --prebuilt && fail "--prebuilt ran from a clone"
grep -q 'is a clone' "$OUT" || { cat "$OUT"; fail "no reason for refusing a clone"; }
cp -R "$(cd "$HC" && pwd -P)" "$T/stray-$VERSION"
prun "$P" "$T/stray-$VERSION/scripts/install.sh" --prebuilt && fail "--prebuilt ran from a folder current doesn't link to"
grep -q 'does not link to' "$OUT" || { cat "$OUT"; fail "no reason for refusing a stray payload"; }
ok "--prebuilt needs current"

# 27. Migration: an install from an older clone (~/relay) moves its links, MCP server and
#     repoPath to current, and the clone stays, named as no longer used.
M="$T/m-home"
mkdir -p "$M/.local/bin" "$M/.claude/skills" "$M/Applications" "$M/.config/relay"
old_clone "$M/relay"
ln -s "$M/relay/bin/relay" "$M/.local/bin/relay"
ln -s "$M/relay/bin/relay" "$M/.local/bin/hook"
ln -s "$M/relay/skill/instructables" "$M/.claude/skills/instructables"
cp -R "$T/fixture-app/Hook.app" "$M/Applications/Hook.app"
printf '{"source": "local", "repoPath": "%s"}\n' "$M/relay" > "$M/.config/relay/config.json"
: > "$FAKE_LOG"
prun "$M" bash "$REPO/scripts/get.sh" || { cat "$OUT"; fail "a migrating install exited non-zero"; }
MC="$M/.local/share/hook/current"
[ "$(readlink "$M/.local/bin/relay")" = "$MC/bin/relay" ] || fail "the CLI link stayed on the clone"
[ "$(readlink "$M/.local/bin/hook")" = "$MC/bin/relay" ] || fail "the hook link stayed on the clone"
# The update syncs without --include-new (the manifest's autoSetup decides), and the Claude
# Code migration removes the old skill link: the plugin carries the skill.
grep -qx 'integrations: sync --no-asks' "$OUT" || { cat "$OUT"; fail "an update did not sync without --include-new"; }
[ ! -e "$M/.claude/skills/instructables" ] && [ ! -L "$M/.claude/skills/instructables" ] || fail "the old skill link into the clone stayed"
called claude mcp add-json --scope user relay "$(mcp_json "$MC")" || { calls; fail "MCP still on the clone"; }
grep -q "\"repoPath\": \"$MC\"" "$M/.config/relay/config.json" || fail "repoPath: $(cat "$M/.config/relay/config.json")"
grep -qx 'The old copy in ~/relay is no longer used; you can delete it.' "$OUT" || { cat "$OUT"; fail "no note about the old clone"; }
[ -d "$M/relay/.git" ] && [ -f "$M/relay/bin/relay" ] || fail "the old clone was changed"
ok "a clone install moves to current; the clone stays"

# 28. A developer's clone keeps its links when a release is installed by hand.
D="$T/d-home"
mkdir -p "$D/.local/bin"
old_clone "$D/dev"
g -C "$D/dev" branch feature
ln -s "$D/dev/bin/relay" "$D/.local/bin/relay"
mkdir -p "$D/.local/share/hook"
cp -R "$(cd "$HC" && pwd -P)" "$D/.local/share/hook/$VERSION"
ln -s "$VERSION" "$D/.local/share/hook/current"
prun "$D" "$D/.local/share/hook/current/scripts/install.sh" --prebuilt || { cat "$OUT"; fail "a prebuilt install next to a dev clone exited non-zero"; }
[ "$(readlink "$D/.local/bin/relay")" = "$D/dev/bin/relay" ] || fail "a developer clone's link was taken over"
grep -q 'links into the developer clone ~/dev; left alone' "$OUT" || { cat "$OUT"; fail "the developer clone was not reported"; }
if grep -q 'old copy in ~/dev' "$OUT"; then fail "a developer clone was called unused"; fi
ok "a developer clone keeps its links"

# 29. install.sh in a clone that isn't a developer's (as an older Hook's updater runs it
#     after moving the clone to the new tag) installs the release download instead.
U="$T/u-home"
mkdir -p "$U/.local/bin" "$U/Applications"
old_clone "$U/relay"
ln -s "$U/relay/bin/relay" "$U/.local/bin/relay"
cp -R "$T/fixture-app/Hook.app" "$U/Applications/Hook.app"
prun "$U" "$U/relay/scripts/install.sh" --local || { cat "$OUT"; fail "the clone's hand-over exited non-zero"; }
grep -q "installing the Hook $VERSION release download instead" "$OUT" || { cat "$OUT"; fail "the hand-over was not reported"; }
[ "$(readlink "$U/.local/bin/relay")" = "$U/.local/share/hook/current/bin/relay" ] || fail "the hand-over left the CLI on the clone"
grep -qx 'The old copy in ~/relay is no longer used; you can delete it.' "$OUT" || { cat "$OUT"; fail "no note about the clone"; }
[ ! -e "$T/compiler.log" ] || fail "the hand-over built from source"
ok "a clone that isn't a developer's installs the release"

# 30. When the release can't be downloaded, that clone builds from source as before.
rm -rf "$U/.local/share/hook" "$U/.local/bin/relay"
ln -s "$U/relay/bin/relay" "$U/.local/bin/relay"
prun "$U" env HOOK_RELEASES_URL="file://$T/no-releases" "$U/relay/scripts/install.sh" \
  || { cat "$OUT"; fail "the fallback exited non-zero"; }
grep -q 'the release download failed; building from source' "$OUT" || { cat "$OUT"; fail "the fallback was not reported"; }
[ "$(readlink "$U/.local/bin/relay")" = "$U/relay/bin/relay" ] || fail "the fallback moved the CLI link"
if grep -q '"updateMode"' "$U/.config/relay/config.json"; then fail "the fallback build was recorded as a developer's"; fi
ok "a failed download falls back to the source build"

# 31. A clone built with HOOK_DEV=1 (clean, on main only) is recorded as a developer's, so
#     the next run there without HOOK_DEV (as Hook's updater starts it) builds from source
#     again and keeps its links, and get.sh leaves it alone. HOOK_DEV=0 moves it to the release.
V="$T/v-home"
mkdir -p "$V/.local/bin"
old_clone "$V/dev"
ln -s "$V/dev/bin/relay" "$V/.local/bin/relay"
VCONF="$V/.config/relay/config.json"
prun "$V" env HOOK_DEV=1 "$V/dev/scripts/install.sh" || { cat "$OUT"; fail "a HOOK_DEV=1 install exited non-zero"; }
grep -q '"updateMode": "developer"' "$VCONF" || fail "HOOK_DEV=1 was not recorded: $(cat "$VCONF")"
prun "$V" "$V/dev/scripts/install.sh" || { cat "$OUT"; fail "the rerun without HOOK_DEV exited non-zero"; }
if grep -q 'release download instead' "$OUT"; then cat "$OUT"; fail "the recorded developer clone handed over to the release"; fi
grep -q 'is a developer'"'"'s clone; building from source here' "$OUT" || { cat "$OUT"; fail "the rerun did not say it builds from source"; }
[ "$(readlink "$V/.local/bin/relay")" = "$V/dev/bin/relay" ] || fail "the rerun moved the CLI link off the developer clone"
grep -q "\"repoPath\": \"$V/dev\"" "$VCONF" && grep -q '"updateMode": "developer"' "$VCONF" || fail "the rerun changed the config: $(cat "$VCONF")"
[ ! -e "$V/.local/share/hook" ] || fail "the rerun downloaded the release"
status=0; prun "$V" bash "$REPO/scripts/get.sh" || status=$?
[ "$status" = "1" ] && grep -q 'links into the developer clone' "$OUT" || { cat "$OUT"; fail "get.sh over a recorded developer clone: status $status"; }
prun "$V" env HOOK_DEV=0 "$V/dev/scripts/install.sh" || { cat "$OUT"; fail "HOOK_DEV=0 exited non-zero"; }
[ "$(readlink "$V/.local/bin/relay")" = "$V/.local/share/hook/current/bin/relay" ] || fail "HOOK_DEV=0 left the CLI on the clone"
if grep -q '"updateMode"' "$VCONF"; then fail "the release install kept updateMode: $(cat "$VCONF")"; fi
ok "a HOOK_DEV=1 clone stays a developer's on later runs; HOOK_DEV=0 moves it to the release"

# --- agent integrations (relay_integrations.py, run at the end of every install) -----------

dev_copy() {   # dev_copy <dir>: this checkout's working tree (what an install reads) as a git clone
  mkdir -p "$1"
  (cd "$REPO" && tar --exclude __pycache__ --exclude clients/fixtures -cf - Resources/Info.plist bin clients mcp \
    integration skill schema scripts docs/claude-md-section.md) | (cd "$1" && tar -xf -)
  g init --quiet "$1"
  g -C "$1" add -A
  g -C "$1" commit --quiet -m dev
}

# 32. A developer's clone builds its own bundle (build/integration, stamped with the version in
#     Resources/Info.plist) before the CLI links, and syncs with the clone as the link root.
DV="$T/dv-home"
mkdir -p "$DV/.claude"
dev_copy "$DV/dev"
: > "$FAKE_LOG"
prun "$DV" env HOOK_DEV=1 "$DV/dev/scripts/install.sh" || { cat "$OUT"; fail "a developer clone's install exited non-zero"; }
[ -f "$DV/dev/build/integration/bundle.json" ] || { cat "$OUT"; fail "the developer clone built no build/integration/bundle.json"; }
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["version"] == sys.argv[2] else 1)' \
  "$DV/dev/build/integration/bundle.json" "$VERSION" || fail "the clone's bundle is not stamped $VERSION"
grep -qx 'integrations: sync --include-new --no-asks' "$OUT" || { cat "$OUT"; fail "the developer clone did not sync"; }
[ "$(manifest_key "$DV" linkRoot)" = "~/dev" ] || fail "manifest linkRoot is $(manifest_key "$DV" linkRoot), not the clone"
called claude mcp add-json --scope user relay "$(mcp_json "$DV/dev")" || { calls; fail "the MCP server does not run from the clone"; }
[ -f "$DV/.local/share/hook/plugins/claude/.claude-plugin/plugin.json" ] || fail "the clone's install rendered no plugin"
ok "a developer clone builds its bundle and syncs with itself as the link root"

# 33. A bundle that won't build warns, skips the integrations, and the install still finishes.
DB="$T/db-home"
mkdir -p "$DB"
dev_copy "$DB/dev"
echo '{' > "$DB/dev/integration/harnesses.json"
: > "$FAKE_LOG"
prun "$DB" env HOOK_DEV=1 "$DB/dev/scripts/install.sh" || { cat "$OUT"; fail "a failed bundle build aborted the install"; }
grep -q "^integrations: couldn't build the bundle" "$OUT" || { cat "$OUT"; fail "the failed bundle build was not reported"; }
grep -qx 'integrations: skipped (RELAY_SKIP_INTEGRATIONS=1)' "$OUT" || { cat "$OUT"; fail "the integrations ran without a bundle"; }
[ ! -s "$FAKE_LOG" ] || { calls; fail "a harness CLI ran without a bundle"; }
grep -q '^launchagent: ' "$OUT" && grep -q '^start: skipped' "$OUT" || { cat "$OUT"; fail "the install stopped after the bundle failure"; }
ok "a bundle that won't build is not fatal"

# 34. A failing sync (claude exits 1) warns with the command to look at, and the install
#     still finishes with status 0.
F="$T/f-home"
mkdir -p "$F/.claude"
status=0; FAKE_CONFIG="$FAIL_RULES" prun "$F" bash "$REPO/scripts/get.sh" || status=$?
[ "$status" = "0" ] || { cat "$OUT"; fail "a failing integrations sync made the install exit $status"; }
grep -qx "integrations: some agents weren't set up; see: relay integrations status" "$OUT" || { cat "$OUT"; fail "no integrations warning"; }
grep -q '^launchagent: ' "$OUT" && grep -q '^start: skipped' "$OUT" || { cat "$OUT"; fail "the install stopped after the failing sync"; }
ok "a failing integrations sync is not fatal"

# 35. RELAY_SKIP_INTEGRATIONS=1, and its old name RELAY_SKIP_MCP=1, skip the integrations.
for switch in RELAY_SKIP_INTEGRATIONS RELAY_SKIP_MCP; do
  K="$T/k-home-$switch"
  mkdir -p "$K/.claude"
  : > "$FAKE_LOG"
  prun "$K" env "$switch=1" bash "$REPO/scripts/get.sh" || { cat "$OUT"; fail "$switch=1: the install exited non-zero"; }
  grep -qx 'integrations: skipped (RELAY_SKIP_INTEGRATIONS=1)' "$OUT" || { cat "$OUT"; fail "$switch=1 did not skip"; }
  [ ! -s "$FAKE_LOG" ] || { calls; fail "$switch=1: a harness CLI ran"; }
  [ ! -e "$K/.config/relay/integrations.json" ] || fail "$switch=1 wrote a manifest"
done
ok "RELAY_SKIP_INTEGRATIONS=1 and RELAY_SKIP_MCP=1 skip"

# 36. A skill link in ~/.claude/skills that isn't Hook's: sync reports it as foreign and leaves it.
G="$T/g-home"
mkdir -p "$G/.claude/skills" "$T/someone-elses-skill"
ln -s "$T/someone-elses-skill" "$G/.claude/skills/instructables"
prun "$G" bash "$REPO/scripts/get.sh" || { cat "$OUT"; fail "an install with a foreign skill link exited non-zero"; }
[ "$(readlink "$G/.claude/skills/instructables")" = "$T/someone-elses-skill" ] || fail "sync replaced a foreign skill link"
grep -q 'foreign.*~/.claude/skills/instructables\|~/.claude/skills/instructables.*foreign' "$OUT" \
  || { cat "$OUT"; fail "sync did not report the foreign skill link"; }
prun "$G" "$G/.local/share/hook/current/scripts/install.sh" --uninstall || { cat "$OUT"; fail "--uninstall exited non-zero"; }
[ "$(readlink "$G/.claude/skills/instructables")" = "$T/someone-elses-skill" ] || fail "--uninstall removed a foreign skill link"
ok "a foreign skill link is reported by sync and left alone"

# 37. --uninstall without a manifest (an install from before 0.13) keeps the legacy cleanup:
#     claude mcp remove, and the old skill link into this install.
L="$T/l-home"
mkdir -p "$L/.claude"
prun "$L" env RELAY_SKIP_INTEGRATIONS=1 bash "$REPO/scripts/get.sh" || { cat "$OUT"; fail "the legacy fixture install exited non-zero"; }
LC="$L/.local/share/hook/current"
mkdir -p "$L/.claude/skills"
ln -s "$LC/skill/instructables" "$L/.claude/skills/instructables"
: > "$FAKE_LOG"
prun "$L" "$LC/scripts/install.sh" --uninstall || { cat "$OUT"; fail "a legacy --uninstall exited non-zero"; }
called claude mcp remove relay --scope user || { calls; fail "a legacy --uninstall did not remove the claude mcp server"; }
[ ! -L "$L/.claude/skills/instructables" ] || fail "a legacy --uninstall kept the old skill link"
if grep -q '^integrations: remove' "$OUT"; then fail "--uninstall ran integrations remove without a manifest"; fi
ok "--uninstall without a manifest keeps the legacy cleanup"

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
