# Configuration

Hook reads `~/.config/relay/config.json`, and Settings edits it. `$RELAY_CONFIG` sets another path; `local-token` and `replies-cursor.json` live next to the file in use. The config never holds a token.

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `source` | `"local"` \| `"mailbox"` | `"mailbox"` when `mailboxURL` is set | Where asks live. `local`: in `~/Library/Application Support/Relay/queue.json`, served on `127.0.0.1`. `"mailbox"`: on the Pond, by its old name. Switch in Settings › Queue or with `install.sh --local` / `--mailbox` |
| `mailboxURL` | http(s) string | none | Pond mode: the Pond's base URL |
| `tokenFile` | path | none | Pond mode: the file that holds the Pond's bearer token |
| `context` | string | `"personal"` | Pond mode: sent with every post |
| `port` | 1–65535 | 47823 | The `127.0.0.1` listener |
| `pollSeconds` | int ≥ 1 | 15 | Pond mode: how often to check |
| `hotkey` | string | `"ctrl+opt+cmd+r"` | Shows or hides the panel; `""` turns it off |
| `keepDays` | 1–365 | 14 | This Mac only: how long finished asks are kept |
| `showCount` | bool | true | No effect since 0.15.0, when the fish glyph replaced the menu-bar count and dot |
| `sidebarEdge` | `"right"` \| `"left"` | `"right"` | The screen edge the panel docks to |
| `appearance` | `"system"` \| `"light"` \| `"dark"` | `"system"` | Applies to all windows |
| `notify` | object | `{"now":true,"today":true,"whenever":false,"sound":true,"slideIn":true}` | Which urgencies notify, whether they play a sound, and whether "now" asks slide the panel in |
| `presence` | `"auto"` \| `"home"` \| `"away"` | `"auto"` | [Away mode](using.md#away-mode). `auto` follows the screen lock, display sleep, user switching, Screen Sharing and idle time. `home` and `away` set it by hand |
| `awayAfterMinutes` | 5, 10, 15, 30 or 60 | 10 | With `auto`: minutes without input before Hook marks you away |
| `repoPath` | path | none | Set by the installer. Settings › Agents runs `relay integrations` from it |
| `sidebarDisplay` | display UUID string | none | The display the panel is pinned to. Dragging the panel sets it, and `sidebarEdge` too. While that display is disconnected, the main display is used. Delete the key to go back to the main display |
| `afterClose` | `"next"` \| `"queue"` | `"next"` | After Done or Skip: open the next ask, or go back to the queue with the next row selected. Any other value means `"next"` |
| `mailboxUpdateCommand` | string | none | Pond mode: the one-line shell command **Update Pond…** runs through your login shell, in a new window of the `terminal` below. Empty or missing opens the [update guide](mailbox-protocol.md#updating-the-mailbox) instead. Set it in Settings › Queue › Pond › Update command |
| `openDocumentsIn` | `"hook"` \| `"system"` \| an app's bundle id or path | `"hook"` | Where a file row's **Open** goes. `hook`: Hook's viewer for Markdown and text, the default app for the rest. `system`: the file's default app. An app (`com.apple.TextEdit`, or `/Applications/Writer.app` without a bundle id): that app for every document, if it is installed. Any other value means `hook`. Hook opens only document types ([Using Hook](using.md)). Set it in Settings › General › Documents |
| `terminal` | `"automatic"` \| a terminal's bundle id | `"automatic"` | Where Resume Session opens: `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `com.github.wez.wezterm`, `dev.warp.Warp-Stable` or `org.alacritty`. `automatic`, an unknown id or a missing terminal means the first installed of Ghostty, iTerm2, WezTerm, kitty, Warp and Alacritty, else Terminal |
| `crashReports` | `"ask"` \| `"auto"` \| `"off"` | `"ask"` | After Hook quits unexpectedly. `ask` docks a bar in the panel and shows the report before anything is sent. `auto` sends it to your Pond without asking when `crashReportTarget` is `pond`, and acts like `ask` for GitHub. `off` shows and sends nothing. Any other value means `ask`. Set it in Settings › General › Privacy; see [Privacy](privacy.md) |
| `crashReportTarget` | `"github"` \| `"pond"` | `"github"` | Where a crash report goes. `github` opens a prefilled issue in your browser for you to submit. `pond` files it on your Pond as a Hook bug, but only while the source is a Pond and this Mac's owner key is approved. Otherwise, and for any other value, it means `github` |

## Agent integrations

`relay integrations` keeps its own files, and Settings never edits them ([Agents](agents.md)):

- `~/.config/relay/integrations.json`, the manifest. It holds every file, key and block Hook wrote in an agent's setup, with its hash, and the asks it posted for your steps. It also holds `autoSetup`, which `relay integrations set auto-setup on|off` changes (Settings › Agents › Set up new agents automatically). A manifest that isn't valid JSON moves to `integrations.json.bad-<time>`. `integrations.lock` next to it keeps two runs apart.
- `~/.local/share/hook/plugins/<agent>`: the Claude Code, Gemini CLI and Antigravity plugins, built for this Mac with its paths filled in. Cursor's goes to `~/.cursor/plugins/local/hook`.
- `~/.local/share/hook/backups`: copies of folders Hook replaced. A file's copy is `<file>.bak` next to it.
- `~/.local/state/relay/integrations/claude-md-proposal.md`: the proposal for Claude Code's CLAUDE.md section, while it waits for your answer.

## The away flag

While you're away, Hook keeps the file `$HOME/.local/state/relay/away` (folder mode 0700, file mode 0600). It has two lines:

```
since=2026-10-16T10:22:00Z
reason=screen locked
```

Hook removes the file when you're back and when it quits, SIGTERM included. After a crash, it stays until Hook launches again. Other tools can test for it. This `~/.ssh/config` block makes ssh skip the 1Password SSH agent while you're away, so no Touch ID prompt waits at an empty desk:

```
Match exec "test -e $HOME/.local/state/relay/away"
    IdentityAgent none
```

## Reload and errors

Hook applies edits without a restart. A missing, wrong-typed or out-of-range key takes its default. Only unparseable JSON or a bad `port` makes the file invalid. After a broken edit, Hook keeps the last good config and shows a note.
