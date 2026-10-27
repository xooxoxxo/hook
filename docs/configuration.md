# Configuration

Hook reads `~/.config/relay/config.json`, and Settings edits the same file.

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
| `hotkey` | string | `"ctrl+opt+cmd+r"` | Shows or hides the panel; `""` turns it off |
| `keepDays` | 1–365 | 14 | This Mac only: how long finished asks are kept |
| `showCount` | bool | true | Badge shows the count from 1 to 9; from 10 up, or when false, a dot |
| `sidebarEdge` | `"right"` \| `"left"` | `"right"` | Which screen edge the panel docks to |
| `appearance` | `"system"` \| `"light"` \| `"dark"` | `"system"` | Applies to all windows |
| `notify` | object | `{"now":true,"today":true,"whenever":false,"sound":false,"slideIn":true}` | Which urgencies notify, sound, and whether "now" asks slide the panel in |
| `presence` | `"auto"` \| `"home"` \| `"away"` | `"auto"` | [Away mode](using.md#away-mode): `auto` follows the screen lock, display sleep, user switching, Screen Sharing and idle time; `home` and `away` set it by hand |
| `awayAfterMinutes` | 5, 10, 15, 30 or 60 | 10 | Automatic: minutes without input before Hook marks you away |
| `repoPath` | path | none | Set by the installer; Settings › Connect builds its commands from it |
| `sidebarDisplay` | display UUID string | none | The display the panel is pinned to. Dragging the panel sets it (and `sidebarEdge`); while that display is disconnected, the main display is used. Delete it to go back to the main display |
| `afterClose` | `"next"` \| `"queue"` | `"next"` | After Done or Skip in an ask: open the next ask in the list, or go back to the queue with the next row selected. Any other value means `"next"` |

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
