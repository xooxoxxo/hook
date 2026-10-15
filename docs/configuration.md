# Configuration

Relay reads `~/.config/relay/config.json`, and Settings edits the same file.

`$RELAY_CONFIG` overrides the path; `local-token` and `replies-cursor.json` live next to whichever file is used. The config never contains a token.

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `source` | `"local"` \| `"mailbox"` | `"mailbox"` when `mailboxURL` is set | Where asks live: `local` keeps them in `~/Library/Application Support/Relay/queue.json`, served on `127.0.0.1`. Switch it in Settings › Queue or with `install.sh --local` / `--mailbox` |
| `mailboxURL` | http(s) string | none | Mailbox mode: the service's base URL |
| `tokenFile` | path | none | Mailbox mode: file holding the bearer token |
| `context` | string | `"personal"` | Mailbox mode: sent with every post |
| `port` | 1–65535 | 47823 | The `127.0.0.1` listener |
| `pollSeconds` | int ≥ 1 | 15 | Mailbox mode: how often to check |
| `hotkey` | string | `"ctrl+opt+cmd+r"` | Shows or hides the sidebar; `""` turns it off |
| `keepDays` | 1–365 | 14 | This Mac only: how long finished asks are kept |
| `showCount` | bool | true | Badge shows the count from 1 to 9; from 10 up, or when false, a dot |
| `sidebarEdge` | `"right"` \| `"left"` | `"right"` | Which screen edge the sidebar docks to |
| `appearance` | `"system"` \| `"light"` \| `"dark"` | `"system"` | Applies to all windows |
| `notify` | object | `{"now":true,"today":true,"whenever":false,"sound":false,"slideIn":true}` | Which urgencies notify, sound, and whether "now" asks slide the sidebar in |
| `repoPath` | path | none | Set by the installer; Settings › Connect builds its commands from it |

## Reload and errors

Relay applies edits without a restart. A missing, wrong-typed or out-of-range key takes its default; only unparseable JSON or a bad `port` makes the file invalid. A broken edit keeps the last good config in use and shows a note.
