# Install

Hook builds from source with one script.

## Requirements

- macOS 14.5+ to build (the Swift 6 toolchain needs it); the app runs on macOS 14.
- Xcode Command Line Tools 16 with Swift 6+ (`xcode-select -p`, or `xcode-select --install`).
- Python 3.9+. No third-party dependencies.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash
```

`scripts/get.sh` checks for macOS, git, Python and the Command Line Tools (it starts their installer when they are missing; run it again once that finishes). It clones Hook to `~/.local/share/hook` (or `$HOOK_DIR`), or updates the clone `~/.local/bin/relay` already links into, checks out the newest release tag, and runs `./scripts/install.sh`. It never touches a folder that isn't a clone of Hook or that has local changes. Pass installer options after `bash -s --`, for example `| bash -s -- --local`.

Or clone it yourself:

```bash
git clone https://github.com/xooxoxxo/hook.git
cd hook
./scripts/install.sh
```

- No flag: keeps the config. A new install gets `{"source":"local"}` (This Mac only).
- `--local`: switches to This Mac only.
- `--mailbox <dir>`: switches to the Pond whose http(s) URL is in `<dir>/mailbox-url`. `<dir>/mailbox-token` must be non-empty; only its path is stored.
- `--uninstall`: see [Uninstall](#uninstall).

## What the installer does

1. Checks macOS, Swift and Python, and prints the fix for anything missing.
2. Writes `~/.config/relay/config.json` (folder `0700`, file `0600`), keeping existing keys. A config that doesn't parse moves to `config.json.bad-<time>`.
3. Builds `./build/Hook.app` and replaces `~/Applications/Hook.app` only on success. It quits a running Hook or Relay first, and once Hook.app is in place it removes an old `~/Applications/Relay.app`.
4. Links `relay` to `~/.local/bin/relay` unless another `relay` is there, and `hook` (the same command) to `~/.local/bin/hook` unless another `hook` is there. Prints the `~/.zshrc` line if that folder isn't on your `PATH`.
5. Runs `claude mcp add --scope user relay -- python3 "<repo>/mcp/relay_mcp.py"`, or prints it when `claude` is missing or the call fails.
6. Links the skill to `~/.claude/skills/instructables` unless something else is there.
7. Writes the login LaunchAgent `~/Library/LaunchAgents/io.github.xooxoxxo.relay.plist` only on a first install or if it exists, so turning it off sticks. Removes the pre-release `dev.instructables.relay` one.
8. Starts Hook and checks `http://127.0.0.1:<port>/health` (port 47823 unless `port` says otherwise).

## Keep the clone

The `relay` command, MCP server and skill run from the clone. If you move it, rerun `./scripts/install.sh` there.

## Update

Rerun the one-line install, or `git pull && ./scripts/install.sh` in the clone. Either keeps the config.

Coming from Relay 0.7.x: the update replaces `Relay.app` with `Hook.app`. The config, token, queue, settings, notification permission, login item and the `relay` command all carry over, because their names and paths stay the same.

## Uninstall

`./scripts/install.sh --uninstall` removes the app (and an old Relay.app), LaunchAgent, CLI links, MCP server and this repo's skill link. It keeps the config, token and queue, and prints their paths.

To remove everything, also delete the clone, `~/Library/Application Support/Relay` and `~/.config/relay`, and run `defaults delete io.github.xooxoxxo.relay` (the uninstaller prints it) to clear the UI state.
