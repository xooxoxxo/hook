# Install

Hook installs from a prebuilt release: nothing is compiled on your Mac.

## Requirements

- macOS 14+.
- Python 3.9+, for the `relay` command and the MCP server. No third-party dependencies.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash
```

`scripts/get.sh`:

1. Downloads the latest release's `SHA256SUMS` and `Hook-<version>.zip` with curl, and refuses the zip when its SHA-256 doesn't match. No git, no compiler.
2. Puts the release in `~/.local/share/hook/<version>`, links `~/.local/share/hook/current` to it, keeps the version before (for going back) and removes older ones.
3. Runs `current/scripts/install.sh --prebuilt`, with any options you pass after `bash -s --`, for example `| bash -s -- --local`.

`HOOK_VERSION=0.10.0` before `bash` installs that release instead of the newest.

Installer options:

- No flag: keeps the config. A new install gets `{"source":"local"}` (This Mac only).
- `--local`: switches to This Mac only.
- `--mailbox <dir>`: switches to the Pond whose http(s) URL is in `<dir>/mailbox-url`. `<dir>/mailbox-token` must be non-empty; only its path is stored.
- `--uninstall`: see [Uninstall](#uninstall).

A curl download isn't quarantined, so macOS opens Hook even though releases aren't notarized yet. A zip downloaded in a browser is blocked until they are; use the command above.

## What the installer does

1. Checks macOS and Python, and prints the fix for anything missing.
2. Writes `~/.config/relay/config.json` (folder `0700`, file `0600`), keeping existing keys. A config that doesn't parse moves to `config.json.bad-<time>`. A new config, or a kept one when `~/Applications/Hook.app` is new (you deleted the app and installed again), gets `"onboarding": "pending"`, so Hook opens its setup window, filled in from the config.
3. Replaces `~/Applications/Hook.app` with the release's. It quits a running Hook or Relay first (force-quitting one that doesn't quit within 5 s, and stopping if it still runs), and once Hook.app is in place it removes an old `~/Applications/Relay.app`.
4. Links `relay` to `~/.local/bin/relay` unless another `relay` is there, and `hook` (the same command) to `~/.local/bin/hook` unless another `hook` is there, both through `~/.local/share/hook/current`. Prints the `~/.zshrc` line if that folder isn't on your `PATH`.
5. Runs `claude mcp add --scope user relay -- python3 "$HOME/.local/share/hook/current/mcp/relay_mcp.py"`, or prints it when `claude` is missing or the call fails.
6. Links the skill to `~/.claude/skills/instructables` unless something else is there.
7. Writes the login LaunchAgent `~/Library/LaunchAgents/io.github.xooxoxxo.relay.plist` only on a first install or if it exists, so turning it off sticks. Removes the pre-release `dev.instructables.relay` one.
8. Starts Hook, checks that no copy older than the install is still running (one is force-quit and Hook started again, once; then the install fails), and checks `http://127.0.0.1:<port>/health` (port 47823 unless `port` says otherwise).

## Update

Check for Updates… (in the menu-bar menu, or Settings › General › Updates) downloads the new release, checks it against its `SHA256SUMS` and installs it the same way, in the background; Hook restarts. Rerunning the one-line install does the same. Either keeps the config.

Settings › General › Updates shows how this Hook was installed: **Release download**, or **Developer checkout** for a clone you build yourself (see [development.md](development.md#build-from-source)).

An install that fails links `current` back to the version before, so the CLI, MCP server and skill keep working, and prints the command that puts that version's app back. Nothing is removed until a new version installs.

To go back to the version before by hand: `ln -sfn <version> ~/.local/share/hook/current && ~/.local/share/hook/current/scripts/install.sh --prebuilt`.

### Coming from a clone

Hook 0.9.x and earlier ran from a git clone (often `~/relay`, or `~/.local/share/hook` from 0.9.3's `get.sh`). The first prebuilt install, from `get.sh` or from the old Hook's Check for Updates, moves the `relay` and `hook` links, the MCP server and the skill to `~/.local/share/hook/current`. It leaves the clone where it was and prints:

```
The old copy in ~/relay is no longer used; you can delete it.
```

A clone at `~/.local/share/hook` itself moves to `~/.local/share/hook-clone` first. A developer's clone (one with changes, a local branch other than `main`, or one built with `HOOK_DEV=1`, which the config records) is left alone and keeps building from source.

Coming from Relay 0.7.x: the update replaces `Relay.app` with `Hook.app`. The config, token, queue, settings, notification permission, login item and the `relay` command all carry over, because their names and paths stay the same.

## Uninstall

`~/.local/share/hook/current/scripts/install.sh --uninstall` removes the app (and an old Relay.app), LaunchAgent, CLI links, MCP server and skill link. It keeps the config, token and queue, and prints their paths.

To remove everything, also delete `~/.local/share/hook`, `~/Library/Application Support/Relay` and `~/.config/relay`, and run `defaults delete io.github.xooxoxxo.relay` (the uninstaller prints it) to clear the UI state.
