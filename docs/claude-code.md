# Claude Code

Sessions post asks with the MCP server or the `relay` command, and read answers with a hook or `relay wait`.

## MCP tools

Registered by the installer.

- `relay_post {project, instructable}` returns `{id, deduped, openUrl}`.
- `relay_status {id}` returns `status`, `resolvedBy` (`owner`, `session` or null) and `ownerEvents`.
- `relay_list {}` returns every open ask.

## Skill and CLAUDE.md

- The [skill](../skill/instructables/SKILL.md) tells sessions when to ask and how to write a good instructable.
- Paste [the CLAUDE.md section](claude-md-section.md) into `~/.claude/CLAUDE.md` (Settings › Connect › Copy CLAUDE.md section).

## The `relay` command

The installer also links it as `hook`; both names run the same command. The MCP server and tools keep their `relay` names, so existing sessions, skills and permission lists keep working.

Commands start Hook if it isn't running, except `relay replies --hook` and `relay wait`.

| Command | Prints |
|---|---|
| `relay post <project> --json -` or `--json <file>` | `posted <id>` or `deduped <id>`, then `open <url>`. Refused: `refused: <error>` and one line per field error on stderr |
| `relay status <id> [--json]` | `<status> (by owner\|by session) · <project> · <title>`, then one line per owner event |
| `relay list [--json]` | One line per open ask: `<id> <urgency> <project> · <title>` |
| `relay done <id> [note]`, `relay skip <id> [note]` | `done <id>` / `skipped <id>`, or `already <status> (by <actor>) <id>` |
| `relay replies [--new] [--hook]` | One line per new owner answer |
| `relay wait <id> [--timeout SECONDS] [--interval SECONDS] [--after SEQ]` | See [below](#relay-wait) |
| `relay --version` | `relay 0.9.1` (`hook --version` prints `hook 0.9.1`) |

`relay post` and `relay_post` check the mailbox's protocol level (`GET /version`, cached for 5 minutes) before posting an instructable that uses `question` (level 2), `blocking` / `warning` (level 3) or `optional`, `file` or a link's `path` (level 4). A mailbox that reports a level too low makes them refuse with ``This mailbox speaks protocol M; `<key>` needs N. Ask the owner to update the mailbox (Hook › Update Mailbox…).`` and exit 1; nothing is posted. In This Mac mode the refusal is ``Hook speaks protocol M; `<key>` needs N. Update Hook (Check for Updates…).`` A mailbox without `/version` is unknown, and the instructable is posted for the mailbox to validate. See [Instructable format](instructables.md#validation).

Exit codes: 0 success, 1 refused or not found, 2 no config or Hook unreachable, 3 `relay wait` timed out.

## Replies hook

In `~/.claude/settings.json`, this shows each new owner answer in every session's next prompt:

```json
{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "relay replies --new --hook", "timeout": 5}]}]}}
```

- It prints nothing when nothing is new, never starts Hook, gives up after 2 s and always exits 0. The `timeout` lets Claude Code end it if it hangs.
- Each session keeps a cursor in `~/.config/relay/replies-cursor.json`. Its first run, like the first `relay replies` in a terminal, only marks where to start.

## `relay wait`

A session that needs your answer runs `relay wait <id>` in the background after posting. When you answer, it prints `[<project>] <title>`, one `  ↳ owner <kind> <at>: <text>` line per answer and `last seq: <n>`, and exits.

An ask can carry per-step questions that you answer one by one without closing it. `relay wait` also wakes on those answers, but settles first: after an answer it keeps polling until 10 s pass with no newer one, so a burst of taps wakes the session once (Done, Skip and a reply still wake it at once). Each answer prints as `  ↳ owner answer <path>: <value>` (for example `3.2: Staging`), followed by `answered <X> of <Y>; open: <paths>` (the `; open:` part is left out when nothing is open) and `last seq: <n>`.

`relay status` adds an `Answers (X of Y):` block with each question's prompt and your latest answer under it, then `Unanswered: <paths>`; `relay status --json` and the MCP `relay_status` gain `answers` and `unanswered`, and `ownerEvents` includes the `answer` events. `relay replies` and the prompt hook show them as `Hook: [<id>] <project> · <title> — answer <path>: <value>`.

With no answer it exits 3 after `--timeout` (default 8 h). Pass `--after <last seq>` to wait for the next answer.

## Reopened asks

Reopen adds a `reopened` owner event, shown by `relay status`, `replies`, `wait` and `relay_status`. The ask counts as open until a later Done or Skip.
