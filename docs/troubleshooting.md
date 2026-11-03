# Troubleshooting

Common problems and their fixes.

- **Hook isn't running, or `relay` exits 2.** Run `open -a Hook`, then `relay list` to check that it answers.
- **"Port 47823 is in use by another app".** Set `port` in `~/.config/relay/config.json` to a free port. Hook and the clients follow it.
- **`relay_post` is missing in Claude Code.** Run `claude mcp list` and look for `relay`. If it isn't there, rerun `~/.local/share/hook/current/scripts/install.sh` (or `./scripts/install.sh` in a developer checkout), then restart your Claude Code sessions.
- **No notifications.** Turn them on in System Settings › Notifications › Hook.
- **The shortcut doesn't work.** Another app owns it. Pick a new one in Settings › General.
- **Pond unreachable.** The menu-bar icon dims and the status bar at the bottom of the panel says **Offline**; click it for the reason. Check the Pond URL and Pond token file in Settings › Queue, and that the service answers. `relay list` prints the error too.
- **An update failed.** Check for Updates logs to `~/Library/Logs/Hook/update.log`. A release whose zip doesn't match its `SHA256SUMS` is refused and nothing changes; the version before stays in `~/.local/share/hook` (see [Update](install.md#update) to go back).
- **Hook quit or crashed.** At the next launch a bar at the bottom of the panel offers **Review…**, which opens **Send a Crash Report**. Send it from there, to GitHub or your own Pond (see [Privacy](privacy.md)). If you said Not Now, or crash reports are Off, you can still send one by hand: the macOS crash file is the newest `Hook-*.ips` in `~/Library/Logs/DiagnosticReports/` (open it in Console), and Hook's own log is below. Look the file over before you attach it anywhere: unlike Hook's report, it isn't redacted.
- **Logs.** Hook's activity log is `~/Library/Logs/Hook/hook.log` (with `hook.1.log`, the one before it); Settings › General › Privacy › Activity log shows it in Finder. It records events and redacted errors, never ask contents, and each line also reaches the system log: `log show --predicate 'subsystem == "Hook"' --last 1h`. The updater's log is `~/Library/Logs/Hook/update.log` (before 0.12, `~/Library/Logs/Relay/update.log`; Hook moves it once).
