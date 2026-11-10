# Troubleshooting

## Hook and agents

- **Hook isn't running, or `relay` exits 2.** Run `open -a Hook`, then `relay list` to check that Hook answers.
- **"Port 47823 is in use by another app".** Set `port` in `~/.config/relay/config.json` to a free port. Hook and the clients follow it.
- **An agent has no `relay_post`.** `relay integrations status` lists each agent and the state of each piece. `relay integrations sync` (or Settings › Agents › Reinstall All) sets up what's missing; then start a new session. In Claude Code, `claude mcp list` should show `relay`.
- **A piece says Edited by you.** Something changed a file Hook wrote, or another file sits where Hook's goes, so Hook leaves it alone. Its Fix… menu in Settings › Agents offers Keep Mine, Show Difference and Use Hook's (which saves a `.bak` first). Commands: [Edited files](agents.md#edited-files).
- **An agent says Needs you.** A step only you can do waits in your queue (Show Ask opens it), or a file is `blocked`. A blocked file doesn't parse, and Hook never rewrites it. `relay integrations status` names the file; fix it, then run `relay integrations sync`.
- **Codex shows no Hook lines.** Codex runs a new hook only after you trust it. Run `codex`, type `/hooks`, select the hook that runs `relay hook replies` and choose Trust. Once is enough.
- **Cursor doesn't list `relay_post`.** Cursor loads a local plugin only when a window loads. After Hook adds or updates its plugin, run Developer: Reload Window from the Command Palette (Command-Shift-P).

## The app

- **No notifications.** Turn them on in System Settings › Notifications › Hook.
- **The shortcut doesn't work.** Another app owns it. Pick a new one in Settings › General.
- **The Pond is unreachable.** The menu-bar icon dims and the status bar says **Offline**; click it for the reason. Check the Pond URL and token file in Settings › Queue, and that the Pond answers. `relay list` prints the error too.
- **An update failed.** Read `~/Library/Logs/Hook/update.log`. A zip that doesn't match its `SHA256SUMS` is refused and nothing changes. The version before stays in `~/.local/share/hook` ([go back](install.md#update)).

## Crashes and logs

- **Hook crashed.** At the next launch, the panel's **Review…** bar opens **Send a Crash Report**, which sends to GitHub or your Pond ([Privacy](privacy.md)). After Not Now, or with crash reports Off, send the macOS crash file by hand: the newest `Hook-*.ips` in `~/Library/Logs/DiagnosticReports/` (open it in Console). Read it first: unlike Hook's report, it isn't redacted.
- **Hook quits and you can't tell why.** Each quit in `hook.log` names its cause: `quit clean=true cause=signal sig=TERM pid=1 from="launchd"`. A quit you didn't ask for shows the crash bar at the next launch. Settings › Privacy › **Save Diagnostics…** saves the rest in one redacted file for an issue ([Privacy](privacy.md#save-diagnostics)).
- **Where the logs are.** The activity log is `~/Library/Logs/Hook/hook.log` (and `hook.1.log` before it); Settings › Privacy › Activity log shows it in Finder. It holds events and redacted errors, never ask contents. Each line also goes to the system log: `log show --predicate 'subsystem == "Hook"' --last 1h`. The updater writes `~/Library/Logs/Hook/update.log` (before 0.12, `~/Library/Logs/Relay/update.log`; Hook moves it once).
