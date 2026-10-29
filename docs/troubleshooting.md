# Troubleshooting

Common problems and their fixes.

- **Hook isn't running, or `relay` exits 2.** Run `open -a Hook`, then `relay list` to check that it answers.
- **"Port 47823 is in use by another app".** Set `port` in `~/.config/relay/config.json` to a free port. Hook and the clients follow it.
- **`relay_post` is missing in Claude Code.** Run `claude mcp list` and look for `relay`. If it isn't there, rerun `~/.local/share/hook/current/scripts/install.sh` (or `./scripts/install.sh` in a developer checkout), then restart your Claude Code sessions.
- **No notifications.** Turn them on in System Settings › Notifications › Hook.
- **The shortcut doesn't work.** Another app owns it. Pick a new one in Settings › General.
- **Pond unreachable.** The menu-bar icon dims and the sidebar footer shows `Pond · offline:` and the reason. Check the Pond URL and Pond token file in Settings › Queue, and that the service answers. `relay list` prints the error too.
- **An update failed.** Check for Updates logs to `~/Library/Logs/Relay/update.log`. A release whose zip doesn't match its `SHA256SUMS` is refused and nothing changes; the version before stays in `~/.local/share/hook` (see [Update](install.md#update) to go back).
