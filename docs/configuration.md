# Configuration

Hook reads `~/.config/relay/config.json`, and Settings edits the same file.

`$RELAY_CONFIG` overrides the path; `local-token` and `replies-cursor.json` live next to whichever file is used. The config never contains a token.

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `source` | `"local"` \| `"mailbox"` | `"mailbox"` when `mailboxURL` is set | Where asks live: `local` keeps them in `~/Library/Application Support/Relay/queue.json`, served on `127.0.0.1`. Switch it in Settings › Queue or with `install.sh --local` / `--mailbox`. `"mailbox"` is the Pond (formerly called the mailbox); the value keeps its old name |
| `mailboxURL` | http(s) string | none | Pond mode: the Pond's base URL (the Pond URL) |
| `tokenFile` | path | none | Pond mode: the Pond token file, holding the bearer token |
| `context` | string | `"personal"` | Pond mode: sent with every post |
| `port` | 1–65535 | 47823 | The `127.0.0.1` listener |
| `pollSeconds` | int ≥ 1 | 15 | Pond mode: how often to check |
| `hotkey` | string | `"ctrl+opt+cmd+r"` | Shows or hides the panel; `""` turns it off |
| `keepDays` | 1–365 | 14 | This Mac only: how long finished asks are kept |
| `showCount` | bool | true | Badge shows the count from 1 to 9; from 10 up, or when false, a dot |
| `sidebarEdge` | `"right"` \| `"left"` | `"right"` | Which screen edge the panel docks to |
| `appearance` | `"system"` \| `"light"` \| `"dark"` | `"system"` | Applies to all windows |
| `notify` | object | `{"now":true,"today":true,"whenever":false,"sound":false,"slideIn":true}` | Which urgencies notify, sound, and whether "now" asks slide the panel in |
| `presence` | `"auto"` \| `"home"` \| `"away"` | `"auto"` | [Away mode](using.md#away-mode): `auto` follows the screen lock, display sleep, user switching, Screen Sharing and idle time; `home` and `away` set it by hand |
| `awayAfterMinutes` | 5, 10, 15, 30 or 60 | 10 | Automatic: minutes without input before Hook marks you away |
| `repoPath` | path | none | Set by the installer; Settings › Agents runs `relay integrations` from it |
| `sidebarDisplay` | display UUID string | none | The display the panel is pinned to. Dragging the panel sets it (and `sidebarEdge`); while that display is disconnected, the main display is used. Delete it to go back to the main display |
| `afterClose` | `"next"` \| `"queue"` | `"next"` | After Done or Skip in an ask: open the next ask in the list, or go back to the queue with the next row selected. Any other value means `"next"` |
| `mailboxUpdateCommand` | string | none | Pond mode: the shell command **Update Pond…** runs in a new terminal window (the `terminal` below) through your login shell. One line; empty or missing opens the [update guide](mailbox-protocol.md#updating-the-mailbox) instead. Set it in Settings › Queue › Pond › Update command |
| `openDocumentsIn` | `"hook"` \| `"system"` \| an app's bundle id or path | `"hook"` | Where a file row's **Open** goes. `hook`: Hook's viewer for Markdown and text, the default app for anything else; `system`: the file's default app; an app (`com.apple.TextEdit`, or `/Applications/Writer.app` for an app without a bundle id): that app for every document, or the default app when it isn't installed. Empty, missing or anything else means `hook`. Whatever the setting, Hook opens only document types (see [Using Hook](using.md)). Set it in Settings › General › Documents |
| `terminal` | `"automatic"` \| a terminal's bundle id | `"automatic"` | Where Resume Session opens: `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `com.github.wez.wezterm`, `dev.warp.Warp-Stable` or `org.alacritty`. `automatic`, an unknown id or a terminal that isn't installed means the first installed of Ghostty, iTerm2, WezTerm, kitty, Warp and Alacritty, else Terminal |
| `crashReports` | `"ask"` \| `"auto"` \| `"off"` | `"ask"` | After Hook quits unexpectedly: `ask` docks a bar in the panel and shows the report before anything is sent; `auto` sends it to your own Pond without asking when `crashReportTarget` is `pond` (and works like `ask` for GitHub); `off` shows and sends nothing. Any other value means `ask`. Set it in Settings › General › Privacy; see [Privacy](privacy.md) |
| `crashReportTarget` | `"github"` \| `"pond"` | `"github"` | Where a crash report goes: `github` opens a prefilled issue in your browser for you to submit; `pond` files it on your Pond as a Hook bug. `pond` counts only while the source is a Pond and this Mac's owner key is approved; otherwise it reads as `github`. Any other value means `github` |

## Agent integrations

`relay integrations` keeps its own files; Settings never edits them ([Agents](agents.md)):

- `~/.config/relay/integrations.json` (the manifest): every file, key and block Hook wrote in an agent's setup, with its hash, the asks it posted for your steps, and `autoSetup`, which Settings › Agents › Set up new agents automatically changes through `relay integrations set auto-setup on|off`. One that isn't valid JSON moves to `integrations.json.bad-<time>`. `integrations.lock` beside it keeps two runs apart.
- `~/.local/share/hook/plugins/<agent>`: the Claude Code, Gemini CLI and Antigravity plugins, rendered for this Mac with its paths filled in. Cursor's goes to `~/.cursor/plugins/local/hook`.
- `~/.local/share/hook/backups`: copies of folders Hook replaced. A file's copy is `<file>.bak` beside it.
- `~/.local/state/relay/integrations/claude-md-proposal.md`: the proposal for Claude Code's CLAUDE.md section, while it waits for your answer.

## The away flag

While you're away, Hook keeps the file `$HOME/.local/state/relay/away` (folder mode 0700, file mode 0600). It has two lines:

```
since=2026-10-16T10:22:00Z
reason=screen locked
```

Hook removes it when you're back and when it quits (including on SIGTERM). After a crash the file stays until Hook next launches and rewrites or removes it. Other tools can test for it. For example, this `~/.ssh/config` block makes ssh skip the 1Password SSH agent while you're away, so no Touch ID prompt waits on an empty desk:

```
Match exec "test -e $HOME/.local/state/relay/away"
    IdentityAgent none
```

## Reload and errors

Hook applies edits without a restart. A missing, wrong-typed or out-of-range key takes its default; only unparseable JSON or a bad `port` makes the file invalid. A broken edit keeps the last good config in use and shows a note.
