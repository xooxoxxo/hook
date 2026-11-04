# Install

Hook installs from a prebuilt release. Nothing is compiled on your Mac.

## Requirements

- macOS 14 or newer.
- Python 3.9 or newer, for the `relay` command and the MCP server. No third-party packages.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash
```

`scripts/get.sh`:

1. Downloads the newest `Hook-<version>.zip` and its `SHA256SUMS` with curl. It refuses a zip that doesn't match.
2. Puts the release in `~/.local/share/hook/<version>` and links `~/.local/share/hook/current` to it. It keeps the version before and removes older ones.
3. Runs `current/scripts/install.sh --prebuilt` with any options you pass after `bash -s --`, as in `| bash -s -- --local`.

Put `HOOK_VERSION=0.10.0` before `bash` to install that release instead of the newest.

Installer options:

- None: keeps your config. A new install gets `{"source":"local"}` (This Mac only).
- `--local`: switches to This Mac only.
- `--mailbox <dir>`: switches to the Pond whose http(s) URL is in `<dir>/mailbox-url`. `<dir>/mailbox-token` must not be empty; only its path is stored.
- `--uninstall`: see [Uninstall](#uninstall).

Releases aren't notarized yet. macOS still opens Hook, because curl downloads aren't quarantined. A zip from a browser stays blocked.

## What the installer does

1. Checks macOS and Python, and prints the fix for anything missing.
2. Writes `~/.config/relay/config.json` (folder `0700`, file `0600`) and keeps existing keys. A config that doesn't parse moves to `config.json.bad-<time>`. A new config, or any config when `~/Applications/Hook.app` is new, gets `"onboarding": "pending"`. Hook then opens its setup window, filled in from the config.
3. Replaces `~/Applications/Hook.app`. It quits a running Hook or Relay first, force-quits one still running after 5 s, and stops if that fails. Then it removes an old `~/Applications/Relay.app`.
4. Links `~/.local/bin/relay` and `~/.local/bin/hook` (the same command) through `~/.local/share/hook/current`, unless another `relay` or `hook` is there. If that folder isn't on your `PATH`, it prints the `~/.zshrc` line.
5. Writes the login LaunchAgent `~/Library/LaunchAgents/io.github.xooxoxxo.relay.plist` only on a first install or when it exists, so turning it off sticks. It removes the pre-release `dev.instructables.relay` agent.
6. Starts Hook and checks `http://127.0.0.1:<port>/health` (port 47823 unless `port` says otherwise). If a copy older than the install still runs, it force-quits it and starts Hook again, once. A second failure fails the install.
7. Sets up the agents it finds, last, so their steps reach the running Hook ([agents.md](agents.md)). A failure here prints the command to run later and never stops the install.

## Update

Choose **Check for Updates…** in the menu or in Settings › General › Updates. Hook downloads the release, checks its `SHA256SUMS`, installs it in the background and restarts. The install command does the same. Both keep your config. A clone you build yourself moves to the release tag and builds again instead.

Settings › General › Updates says **Release download**, or **Developer checkout** for a clone you build yourself ([development.md](development.md#build-from-source)).

Nothing is removed until a new version installs. A failed install links `current` back to the version before, so the CLI, MCP server and skill keep working. It prints the command that restores that app.

To go back by hand:

```bash
ln -sfn <version> ~/.local/share/hook/current && ~/.local/share/hook/current/scripts/install.sh --prebuilt
```

### Move from a clone

Hook 0.9.x and earlier ran from a git clone, often `~/relay`. The first prebuilt install (from `get.sh` or the old Check for Updates) moves the `relay` and `hook` links, the MCP server and the skill to `~/.local/share/hook/current`. It leaves the clone in place and prints:

```
The old copy in ~/relay is no longer used; you can delete it.
```

A clone at `~/.local/share/hook` (from the 0.9.3 `get.sh`) first moves to `~/.local/share/hook-clone`. A developer's clone stays and keeps building from source: one with changes, on a branch other than `main`, or built with `HOOK_DEV=1`.

From Relay 0.7.x, the update replaces `Relay.app` with `Hook.app`. The config, token, queue, settings, notification permission, login item and `relay` command keep their names and paths, so they carry over.

## Uninstall

```bash
~/.local/share/hook/current/scripts/install.sh --uninstall
```

This removes what Hook set up in your agents (`relay integrations remove --all`, see [agents.md](agents.md#removing-hook)). Then it removes the app (and an old Relay.app), the LaunchAgent and the CLI links. It keeps the config, token and queue, and prints their paths.

To remove everything, also delete `~/.local/share/hook`, `~/Library/Application Support/Relay` and `~/.config/relay`. Run `defaults delete io.github.xooxoxxo.relay` to clear the UI state (the uninstaller prints this command).
