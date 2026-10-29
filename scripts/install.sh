#!/usr/bin/env bash
# Hook (formerly Relay) installer. Idempotent: re-run it after `git pull` to rebuild and re-register.
#   scripts/install.sh                  build and install; keep the config (new installs get "This Mac only")
#   scripts/install.sh --local          the same, and set source "local" (This Mac only)
#   scripts/install.sh --mailbox <dir>  the same, and use the mailbox named by <dir>/mailbox-url and <dir>/mailbox-token
#   scripts/install.sh --uninstall      remove the app (Hook.app and an old Relay.app), LaunchAgent,
#                                       this repo's CLI links, MCP server and this repo's skill link (keeps the config, token and queue)
# This script never reads or prints any token.
# Test-only switches, used by scripts/test-install.sh and nothing else:
#   RELAY_SKIP_BUILD=1   no build, no app quit, no copy to ~/Applications
#   RELAY_SKIP_LAUNCH=1  no launchctl, no pkill, no lsregister, no app start
#   RELAY_SKIP_MCP=1     no `claude mcp` calls
#   RELAY_APP_SCOPE=<dir>  only app copies whose bundle is under <dir> count as running
#   RELAY_TEST_STEP=stop   with RELAY_APP_SCOPE: only quit (and force-quit) running copies, then exit
#   RELAY_TEST_STEP=start  with RELAY_APP_SCOPE: only start the app and check no older copy runs,
#                          then exit; the app's executable is run directly, not through `open`
set -euo pipefail

# Copies of the app that started before this moment are old ones.
INSTALL_STARTED="$(date +%s)"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$HOME/Applications/Hook.app"
OLD_APP="$HOME/Applications/Relay.app"   # the app before the rename to Hook
BUNDLE_ID="io.github.xooxoxxo.relay"      # the same for Hook.app and Relay.app
LABEL="io.github.xooxoxxo.relay"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_LABEL="dev.instructables.relay"   # the bundle id of pre-release builds
OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
CONFIG_DIR="$HOME/.config/relay"
CONFIG="$CONFIG_DIR/config.json"
DATA_DIR="$HOME/Library/Application Support/Relay"
CLI_LINK="$HOME/.local/bin/relay"
CLI_ALIAS="$HOME/.local/bin/hook"   # the same CLI under the new name
SKILL_LINK="$HOME/.claude/skills/instructables"
MCP_CMD="claude mcp add --scope user relay -- python3 \"$REPO/mcp/relay_mcp.py\""
GUI="gui/$(id -u)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SKIP_BUILD="${RELAY_SKIP_BUILD:-0}"
SKIP_LAUNCH="${RELAY_SKIP_LAUNCH:-0}"
SKIP_MCP="${RELAY_SKIP_MCP:-0}"
APP_SCOPE="${RELAY_APP_SCOPE:-}"
TEST_STEP="${RELAY_TEST_STEP:-}"

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [--local | --mailbox <dir> | --uninstall | --help]

  (no flag)        Build and install Hook. Keeps an existing config;
                   a new install starts in "This Mac only" mode.
  --local          Also switch the config to "This Mac only" (source "local").
  --mailbox <dir>  Also switch to the Pond named by <dir>/mailbox-url (an http(s) URL)
                   and <dir>/mailbox-token (only its path is stored; it is never read).
  --uninstall      Remove the app, LaunchAgent, CLI links, MCP server and this repo's
                   skill link. Keeps the config, token and queue.
EOF
}

die() { echo "install: $*" >&2; exit 1; }

mode="keep"
mailbox_dir=""
uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --local)
      [ "$mode" = "keep" ] || { echo "install: choose one of --local and --mailbox" >&2; exit 2; }
      mode="local" ;;
    --mailbox)
      [ "$mode" = "keep" ] || { echo "install: choose one of --local and --mailbox" >&2; exit 2; }
      [ $# -ge 2 ] || { echo "install: --mailbox needs a folder" >&2; exit 2; }
      mode="mailbox"; mailbox_dir="$2"; shift ;;
    --uninstall) uninstall=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install: unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

have_claude() { command -v claude >/dev/null 2>&1; }

# Creates a directory with mode 0700, or tightens an existing one to 0700.
private_dir() { (umask 077; mkdir -p "$1"); chmod 700 "$1"; }

# The bundle id of an app folder, or nothing.
bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true; }

# Is this app folder ours (Hook, or Relay from before the rename)? Another app that
# happens to be called Hook is never quit, replaced or removed.
ours() { [ "$(bundle_id "$1")" = "$BUNDLE_ID" ]; }

# PIDs of running copies of this app, by bundle id, whichever name they run under.
# A copy whose bundle is gone (deleted, or replaced by a failed copy) counts only when
# it ran from under $HOME as Hook or Relay; another app called Hook is never ours.
our_pids() {
  for pid in $(pgrep -x Hook 2>/dev/null) $(pgrep -x Relay 2>/dev/null); do
    exe="$(ps -o comm= -p "$pid" 2>/dev/null)" || continue
    case "$exe" in */Contents/MacOS/*) ;; *) continue ;; esac
    bundle="${exe%%/Contents/MacOS/*}"
    if [ -n "$APP_SCOPE" ]; then
      case "$bundle" in "$APP_SCOPE"/*) ;; *) continue ;; esac
    fi
    if [ -d "$bundle" ]; then
      if ours "$bundle"; then echo "$pid"; fi
    else
      case "$bundle" in "$HOME"/*) ;; *) continue ;; esac
      case "${exe##*/}" in Hook|Relay) echo "$pid" ;; esac
    fi
  done
}

# Seconds since a process started (ps's elapsed time, [[dd-]hh:]mm:ss), or nothing.
pid_age() {
  e="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')" || return 0
  [ -n "$e" ] || return 0
  d=0
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  IFS=: read -r a b c <<<"$e"
  if [ -z "$c" ]; then c="$b"; b="$a"; a=0; fi
  echo $(( 10#$d * 86400 + 10#$a * 3600 + 10#$b * 60 + 10#$c ))
}

# PIDs of running copies of this app that started before this install began.
old_pids() {
  since=$(( $(date +%s) - INSTALL_STARTED ))
  for pid in $(our_pids); do
    age="$(pid_age "$pid")"
    if [ -n "$age" ] && [ "$age" -gt "$since" ]; then echo "$pid"; fi
  done
}

# Is a copy of this app still running from Relay.app?
old_app_running() {
  for pid in $(our_pids); do
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in "$OLD_APP"/*) return 0 ;; esac
  done
  return 1
}

# Quits running copies of this app (Hook, and Relay from before the rename), and
# waits up to 5 s for them to go.
quit_apps() {
  pids="$(our_pids)"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(our_pids)" ] || return 0
    sleep 0.5
  done
}

# SIGKILLs the given copies of this app and waits up to 3 s for them to go. A copy that
# hangs on quit would otherwise keep running the old version after the update: `open`
# only brings it forward. Returns 1 when one is still there.
force_quit() {
  [ -n "$1" ] || return 0
  for pid in $1; do
    echo "app: force-quit a Hook that did not quit (pid $pid)"
    kill -9 "$pid" 2>/dev/null || true
  done
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -n "$(our_pids)" ] || return 0
    sleep 0.25
  done
  return 1
}

# Quits running copies of this app; a copy that outlives the quit is force-quit, and one
# that outlives that stops the install before anything is replaced.
stop_apps() {
  quit_apps
  force_quit "$(our_pids)" \
    || die "Hook (pid $(our_pids | tr '\n' ' ' | sed 's/ $//')) is still running after a force-quit; quit it in Activity Monitor and run this again"
}

# Starts the app (`open` brings a running copy forward instead).
start_app() {
  if [ "$TEST_STEP" = "start" ]; then
    # Test only: what `open` does, without LaunchServices.
    [ -n "$(our_pids)" ] || ( "$APP/Contents/MacOS/Hook" >/dev/null 2>&1 & )
  else
    open -g -a "$APP"
  fi
}

# Starts the app and checks that every running copy started after this install began.
# An older copy (one that survived the quit, or came back) is force-quit and the app
# started once more; if an older copy still runs, the install fails.
start_checked() {
  start_app
  old="$(old_pids)"
  [ -n "$old" ] || return 0
  echo "app: an older Hook is still running; starting the new one again"
  force_quit "$old" || true
  start_app
  old="$(old_pids)"
  [ -z "$old" ] || die "an older Hook (pid $(echo $old)) is still running instead of the new one; quit it in Activity Monitor, then open $APP"
}

# Unregisters and removes an app bundle of ours, if it is there.
remove_app() {
  [ -d "$1" ] || return 0
  if ! ours "$1"; then echo "app: $1 is not this app (bundle id $(bundle_id "$1")); left alone"; return 0; fi
  if [ "$SKIP_LAUNCH" != "1" ]; then "$LSREGISTER" -u "$1" 2>/dev/null || true; fi
  rm -rf "$1"
}

# Removes a CLI link only when it points at this repo's bin/relay.
remove_cli_link() {
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$REPO/bin/relay" ]; then
    rm "$1"
  elif [ -e "$1" ] || [ -L "$1" ]; then
    echo "cli: $1 is not this repo's link; left alone"
  fi
}

# Unloads and removes the LaunchAgent written under the old bundle id, if any.
remove_old_agent() {
  [ -e "$OLD_PLIST" ] || return 0
  if [ "$SKIP_LAUNCH" != "1" ]; then launchctl bootout "$GUI/$OLD_LABEL" 2>/dev/null || true; fi
  rm -f "$OLD_PLIST"
  echo "launchagent: removed the old $OLD_LABEL LaunchAgent"
}

# --- test-only single steps (scripts/test-install.sh) -----------------------------

if [ -n "$TEST_STEP" ]; then
  [ -n "$APP_SCOPE" ] || die "RELAY_TEST_STEP needs RELAY_APP_SCOPE, so it never touches a real Hook"
  case "$TEST_STEP" in
    stop) stop_apps ;;
    start) start_checked ;;
    *) die "unknown RELAY_TEST_STEP: $TEST_STEP" ;;
  esac
  exit 0
fi

# --- uninstall -------------------------------------------------------------------

if [ "$uninstall" -eq 1 ]; then
  if [ "$SKIP_LAUNCH" != "1" ]; then
    launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
    stop_apps
  fi
  rm -f "$PLIST"
  remove_old_agent
  remove_app "$APP"
  remove_app "$OLD_APP"
  remove_cli_link "$CLI_LINK"
  remove_cli_link "$CLI_ALIAS"
  if [ "$SKIP_MCP" != "1" ] && have_claude; then claude mcp remove relay --scope user >/dev/null 2>&1 || true; fi
  if [ -L "$SKILL_LINK" ] && [ "$(readlink "$SKILL_LINK")" = "$REPO/skill/instructables" ]; then
    rm "$SKILL_LINK"
  elif [ -e "$SKILL_LINK" ] || [ -L "$SKILL_LINK" ]; then
    echo "skill: $SKILL_LINK is not this repo's link; left alone"
  fi
  echo "Hook uninstalled. Kept:"
  echo "  config: $CONFIG"
  echo "  token:  $CONFIG_DIR/local-token"
  echo "  queue:  $DATA_DIR"
  echo "To also remove Hook's UI state: defaults delete $LABEL"
  exit 0
fi

# --- 1. checks -------------------------------------------------------------------

macos="$(sw_vers -productVersion 2>/dev/null || echo 0)"
[ "${macos%%.*}" -ge 14 ] 2>/dev/null || die "Hook needs macOS 14 or newer (this Mac has $macos)"
command -v python3 >/dev/null 2>&1 || die "python3 not found; install the Command Line Tools: xcode-select --install"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "python3 is older than 3.9; update the Command Line Tools in System Settings › Software Update"
if [ "$SKIP_BUILD" != "1" ]; then
  xcode-select -p >/dev/null 2>&1 || die "the Command Line Tools are missing; run: xcode-select --install"
  swift_out="$(swift --version 2>&1 || true)"
  swift_major="$(printf '%s\n' "$swift_out" | sed -nE 's/.*Swift version ([0-9]+)\..*/\1/p' | head -1)"
  if [ -z "$swift_major" ]; then
    die "swift --version failed: $(printf '%s\n' "$swift_out" | head -1)
If it mentions the Xcode license, run: sudo xcodebuild -license accept"
  fi
  [ "$swift_major" -ge 6 ] \
    || die "Hook needs Swift 6 or newer; update the Command Line Tools in System Settings › Software Update"
fi

mailbox_url=""
token_file=""
if [ "$mode" = "mailbox" ]; then
  [ -d "$mailbox_dir" ] || die "--mailbox: $mailbox_dir is not a folder"
  mailbox_dir="$(cd "$mailbox_dir" && pwd -P)"
  [ -s "$mailbox_dir/mailbox-url" ] || die "--mailbox: $mailbox_dir/mailbox-url is missing or empty"
  test -s "$mailbox_dir/mailbox-token" || die "--mailbox: $mailbox_dir/mailbox-token is missing or empty"
  mailbox_url="$(tr -d '[:space:]' < "$mailbox_dir/mailbox-url")"
  case "$mailbox_url" in
    http://*|https://*) ;;
    *) die "--mailbox: $mailbox_dir/mailbox-url must hold an http(s) URL" ;;
  esac
  mailbox_url="${mailbox_url%/}"
  token_file="$mailbox_dir/mailbox-token"
fi

# --- 2. config, before anything can start the app ---------------------------------

# Whether launch at login was on before this run, under the new or the old bundle id.
had_agent=0
if [ -e "$PLIST" ] || [ -e "$OLD_PLIST" ]; then had_agent=1; fi

private_dir "$CONFIG_DIR"
private_dir "$DATA_DIR"

# A first install: no config yet, or no app yet (an earlier first install that
# failed at the build has already written the config). Relay.app, the app before
# the rename, counts as an app: its owner is updating, not installing.
first_install=0
[ -e "$CONFIG" ] || first_install=1
[ -d "$APP" ] || [ -d "$OLD_APP" ] || first_install=1
# A fresh app install: no app of ours at ~/Applications/Hook.app yet (Relay.app, the app
# before the rename, counts as installed). The setup window then shows again, even over a
# kept config, prefilled from it.
fresh_app=1
if { [ -d "$APP" ] && ours "$APP"; } || { [ -d "$OLD_APP" ] && ours "$OLD_APP"; }; then fresh_app=0; fi
if [ -e "$CONFIG" ]; then
  if ! python3 - "$CONFIG" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8-sig") as f:
        ok = isinstance(json.load(f), dict)
except (OSError, ValueError):
    ok = False
sys.exit(0 if ok else 1)
PY
  then
    bad="$CONFIG.bad-$(date +%Y%m%d-%H%M%S)"
    mv "$CONFIG" "$bad"
    echo "config: $CONFIG did not parse; moved it to $bad"
  fi
fi

python3 - "$CONFIG" "$mode" "$mailbox_url" "$token_file" "$REPO" "$fresh_app" <<'PY'
import json, os, sys
path, mode, url, token_file, repo, fresh_app = sys.argv[1:7]
try:
    with open(path, encoding="utf-8-sig") as f:
        cfg = json.load(f)
    created = False
except FileNotFoundError:
    cfg, created = {}, True
if mode == "local":
    cfg["source"] = "local"
elif mode == "mailbox":
    cfg.update({"source": "mailbox", "mailboxURL": url, "tokenFile": token_file})
elif created:
    cfg["source"] = "local"
if created or fresh_app == "1":
    # The app's setup window shows once for a new config or a new app; it removes the
    # key when done.
    cfg["onboarding"] = "pending"
cfg["repoPath"] = repo
data = (json.dumps(cfg, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
tmp = os.path.join(os.path.dirname(path), ".config.json.%d.tmp" % os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp, path)
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
source = cfg.get("source") or ("mailbox" if "mailboxURL" in cfg else "not set")
print("config: %s %s (source: %s)" % ("wrote" if created else "updated", path, source))
if not created and fresh_app == "1":
    print("config: Hook.app is new here, so setup shows when it starts")
PY

# --- 3. build; only after success, replace the running app ------------------------

if [ "$SKIP_BUILD" != "1" ]; then
  BUILD_ONLY=1 "$REPO/scripts/build.sh"
  [ -d "$REPO/build/Hook.app" ] || die "build.sh did not produce $REPO/build/Hook.app"
  # An update from 0.7.x runs the old app's update job with this script, so Relay
  # is quit here too.
  if [ -d "$APP" ] && ! ours "$APP"; then
    die "$APP is another app (bundle id $(bundle_id "$APP")); move it out of ~/Applications and run this again"
  fi
  if [ "$SKIP_LAUNCH" != "1" ]; then stop_apps; fi
  mkdir -p "$(dirname "$APP")"
  rm -rf "$APP"
  ditto "$REPO/build/Hook.app" "$APP"
  if [ "$SKIP_LAUNCH" != "1" ]; then "$LSREGISTER" -f "$APP"; fi
  echo "app: installed $APP"
else
  echo "app: skipped (RELAY_SKIP_BUILD=1)"
fi

# Only once Hook.app is in place: the app from before the rename goes.
# A Relay that outlived quit_apps keeps its app until the next run.
if [ -d "$APP" ] && ours "$APP" && [ -d "$OLD_APP" ]; then
  if [ "$SKIP_LAUNCH" != "1" ] && old_app_running; then
    echo "app: Relay is still running; $OLD_APP stays until the next install"
  else
    remove_app "$OLD_APP"
    [ -d "$OLD_APP" ] || echo "app: removed $OLD_APP (Relay is now Hook)"
  fi
fi

# Steps 4-6 are optional: a failure warns with the command to run later, and the
# LaunchAgent, start and health check still run.
warn() { echo "$*" >&2; }

# --- 4. CLI; never replace a `relay` command that isn't ours ---------------------------

if [ -L "$CLI_LINK" ] && [ "$(readlink "$CLI_LINK")" = "$REPO/bin/relay" ]; then
  echo "cli: $CLI_LINK already links here"
elif [ -e "$CLI_LINK" ] || [ -L "$CLI_LINK" ]; then
  warn "cli: $CLI_LINK points elsewhere; left alone. To use this clone: rm ~/.local/bin/relay && ./scripts/install.sh"
elif mkdir -p "$(dirname "$CLI_LINK")" && ln -s "$REPO/bin/relay" "$CLI_LINK"; then
  echo "cli: $CLI_LINK -> $REPO/bin/relay"
else
  warn "cli: couldn't link $CLI_LINK; later run: ln -s \"$REPO/bin/relay\" \"$CLI_LINK\""
fi
# The `hook` alias: the same CLI, linked only when the path is free.
if [ -L "$CLI_ALIAS" ] && [ "$(readlink "$CLI_ALIAS")" = "$REPO/bin/relay" ]; then
  echo "cli: $CLI_ALIAS already links here"
elif [ -e "$CLI_ALIAS" ] || [ -L "$CLI_ALIAS" ]; then
  warn "cli: $CLI_ALIAS is something else; left alone. The relay command works the same."
elif mkdir -p "$(dirname "$CLI_ALIAS")" && ln -s "$REPO/bin/relay" "$CLI_ALIAS"; then
  echo "cli: $CLI_ALIAS -> $REPO/bin/relay"
else
  warn "cli: couldn't link $CLI_ALIAS; later run: ln -s \"$REPO/bin/relay\" \"$CLI_ALIAS\""
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "cli: ~/.local/bin is not on PATH; add this line to ~/.zshrc:"
     echo '  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

# --- 5. MCP server, user scope -----------------------------------------------------

if [ "$SKIP_MCP" = "1" ]; then
  echo "mcp: skipped (RELAY_SKIP_MCP=1)"
elif have_claude; then
  claude mcp remove relay --scope user >/dev/null 2>&1 || true
  if claude mcp add --scope user relay -- python3 "$REPO/mcp/relay_mcp.py"; then
    echo "mcp: registered relay (user scope)"
  else
    warn "mcp: registration failed; later run: $MCP_CMD"
  fi
else
  echo "mcp: claude CLI not found; later run: $MCP_CMD"
fi

# --- 6. skill symlink; never replace something that isn't ours ---------------------

if [ -L "$SKILL_LINK" ] && [ "$(readlink "$SKILL_LINK")" = "$REPO/skill/instructables" ]; then
  echo "skill: $SKILL_LINK already links here"
elif [ -e "$SKILL_LINK" ] || [ -L "$SKILL_LINK" ]; then
  echo "skill: $SKILL_LINK points elsewhere; left alone"
elif mkdir -p "$(dirname "$SKILL_LINK")" && ln -s "$REPO/skill/instructables" "$SKILL_LINK"; then
  echo "skill: $SKILL_LINK -> $REPO/skill/instructables"
else
  warn "skill: couldn't link $SKILL_LINK; later run: ln -s \"$REPO/skill/instructables\" \"$SKILL_LINK\""
fi

# --- 7. LaunchAgent: only on a first install, or when it already exists --------------
# Once the owner turns off "Launch at login" in Settings, an update never turns it back on.
# A LaunchAgent under the old bundle id counts as existing; it is replaced by the new one.

remove_old_agent
if [ "$first_install" -eq 1 ] || [ "$had_agent" -eq 1 ]; then
  # ~/Library/LaunchAgents is shared, not private: create it only when missing, never chmod it.
  [ -d "$(dirname "$PLIST")" ] || mkdir -p "$(dirname "$PLIST")"
  (umask 022; cat > "$PLIST.tmp.$$") <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF
  mv "$PLIST.tmp.$$" "$PLIST"
  plutil -lint "$PLIST" >/dev/null
  if [ "$SKIP_LAUNCH" = "1" ]; then
    echo "launchagent: wrote $PLIST (not loaded: RELAY_SKIP_LAUNCH=1)"
  else
    launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
    loaded=0
    for _ in 1 2 3; do   # bootstrap right after bootout can fail with "5: Input/output error"
      if launchctl bootstrap "$GUI" "$PLIST" 2>/dev/null; then loaded=1; break; fi
      sleep 1
    done
    if [ "$loaded" -eq 1 ]; then
      echo "launchagent: loaded $LABEL"
    else
      echo "launchagent: launchctl bootstrap $GUI $PLIST failed; Hook still starts below" >&2
    fi
  fi
else
  echo "launchagent: not written (not a first install, and there is no LaunchAgent to update)"
fi

# --- 8. start and check /health ------------------------------------------------------

if [ "$SKIP_LAUNCH" = "1" ]; then
  echo "start: skipped (RELAY_SKIP_LAUNCH=1)"
  exit 0
fi
port="$(python3 - "$CONFIG" <<'PY'
import json, sys
try:
    port = json.load(open(sys.argv[1], encoding="utf-8-sig")).get("port", 47823)
except (OSError, ValueError, AttributeError):
    port = 47823
print(port if isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535 else 47823)
PY
)"
start_checked
for _ in $(seq 1 20); do
  health="$(curl -q --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null || true)"
  src="$(printf '%s' "$health" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = {}
print(d.get("source", "?") if isinstance(d, dict) and d.get("app") == "relay" else "")' 2>/dev/null || true)"
  if [ -n "$src" ]; then
    echo "hook: running on 127.0.0.1:$port (source: $src)"
    echo "Done. Settings: right-click the menu-bar icon. Config: $CONFIG"
    exit 0
  fi
  sleep 0.5
done
echo "warning: Hook did not answer on 127.0.0.1:$port/health. It may still be starting: check the menu bar, or open $APP by hand" >&2
exit 1
