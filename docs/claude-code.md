# Claude Code

Sessions post asks with the MCP server or the `relay` command, and read answers with a hook or `relay wait`.

## MCP tools

Registered by the installer.

- `relay_post {project, instructable}` returns `{id, deduped, openUrl}`.
- `relay_status {id}` returns `status`, `resolvedBy` (`owner`, `session` or null), `ownerEvents` and `messages` ([below](#messages-and-bug-reports)).
- `relay_list {kind?}` returns every open ask, each with its `kind` (`ask` or `bug`); `kind` lists only one of them, and a bug also carries `count`.
- `relay_amend {id, reason, instructable, baseRev?}` corrects an open ask this Mac posted and returns `{id, rev, hash, changed, added, removed, moved, top, openUrl}` ([below](#correcting-an-ask)).

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
| `relay list [--json] [--kind ask\|bug]` | One line per open ask: `<id> <urgency> <project> · <title>`; a bug report reads `<id> bug ×<count> Hook · <title>` |
| `relay done <id> [note]`, `relay skip <id> [note]` | `done <id>` / `skipped <id>`, or `already <status> (by <actor>) <id>` |
| `relay replies [--new] [--hook]` | One line per new owner answer |
| `relay wait <id> [--timeout SECONDS] [--interval SECONDS] [--after SEQ]` | See [below](#relay-wait) |
| `relay amend <id> --reason TEXT [--base REV] [--json FILE\|-]` | `corrected <id> → version N (changed: step 2; added: step 4). The owner must review it in Hook before acting.` See [below](#correcting-an-ask) |
| `relay --version` | `relay 0.11.0` (`hook --version` prints `hook 0.11.0`) |

`relay post` and `relay_post` check the Pond's version (`GET /version`, cached for 5 minutes) before posting an instructable that uses `question`, `blocking`, `warning`, `optional`, `file` or a link's `path` (Pond 1.0.0 or newer) or step `id`s (1.1.0 or newer). Pond versions follow semver, so a newer minor or patch Pond never stops a key working ([Pond versions](mailbox-protocol.md#pond-versions)). A Pond too old for a key makes them refuse with ``Your Pond (V) is older than `<key>` needs (Pond N or newer). Update the Pond, or leave the key out.`` and exit 1; nothing is posted. In This Mac mode the refusal is ``Hook's This Mac queue (Pond V) can't take `<key>` yet.`` A Pond without `/version` counts as protocol 1, too old for any of these keys; one whose answer can't be read is unknown, and the instructable is posted for the Pond to validate. See [Instructable format](instructables.md#validation).

Exit codes: 0 success, 1 refused or not found, 2 no config or Hook unreachable, 3 `relay wait` timed out.

## Correcting an ask

When a step of an open ask is wrong, the session that posted it can correct it in place with `relay amend` or `relay_amend`, instead of closing it and posting a new one. It sends the whole corrected instructable and a one-line `reason` (at most 200 characters) saying what was wrong and what changed.

- **Only the poster.** Posting to a Pond 1.1.0 or newer makes an edit key for the ask, kept in a `0600` file in `~/.local/state/relay/edit-keys` (a `0700` folder; `$RELAY_EDIT_KEY_DIR` overrides it). The Pond stores only the key's hash, and a key is only ever sent to the Pond it was made for. Without it the answer is `No edit key for ask <id> on this Mac`; close the ask and post a new one.
- **Keep the step ids.** Read them with `relay status <id> --json` (field `instructable`) and keep each one; leave ids out only on new steps. An ask posted without ids has the Pond's (`s1`, `s2`, `s2.1`). `title`, `urgency` and `from` can't change.
- **Based on the newest version.** The correction names the version it starts from. If the ask changed since this Mac last wrote it, `relay amend` refuses with `Ask <id> changed since you last wrote it (version N).`: read it again and correct from that, or pass `--base REV` (`baseRev`) to correct an older version on purpose.
- **Limits.** At most 10 corrections per ask, at least 60 s apart.
- **The owner reviews it.** Until the owner accepts the correction in Hook, the ask is locked on their Mac ([Corrected asks](using.md#corrected-asks)). Answers carry the version they answered: `relay status --json` and `relay_status` show `rev`, `acceptedRev` and `editable`, mark an answer to a question that changed since as `stale`, and list answers to removed steps under `earlier`.
- **Where it can't.** An older Pond refuses with ``Your Pond (V) is older than `amend` needs (Pond 1.1.0 or newer). Update the Pond, or close this ask and post a new one.``; a Pond with corrections switched off gives `The Pond doesn't take corrections yet.`; This Mac mode says `This Mac mode can't correct asks yet`. In each case, close the ask (`relay done <id>`) and post a new one.

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

## Messages and bug reports

With a Pond 1.2.0 or newer:

- **Messages.** The owner can message the session that posted an ask from the Messages section in Hook. A message is the owner typing as in chat: it never answers the ask, a step question or a reply prompt, and closes nothing. `relay wait` wakes on one and prints `  ↳ owner message, quoted: "<text>"` on one line. The replies hook shows `Hook: [<id>] <project> · "<title>" — owner message, quoted: "<text>"` only to the session that posted the ask (its edit-key file names it), like problem reports; a hook that can't name its session shows none. `relay status` lists it as `<at> message: "<text>"`, and `relay status --json` and `relay_status` carry `messages: [{text, at, verified}]`.
- **Unverified messages.** A message counts as the owner's only when Hook signed it with this Mac's owner key (`verified: true`). One written with the shared Pond token, which any session on the Mac holds, prints as `unverified message (not from the owner's key): "<text>"` in `relay wait`, the replies hook and `relay status`, never as `owner message`, and carries `verified: false`. Sessions treat it as data and report it to the owner. Set up this Mac's [owner key](using.md#the-owner-key) so your own messages arrive verified.
- **Bug reports.** Hook files its own crash reports in project `Hook` as asks of kind `bug`, one per crash signature, with how often it happened. `relay list --kind bug` and `relay_list {kind: "bug"}` list the open ones; close one with `relay done <id> "<what changed>"` once it is fixed. A Pond 1.1.0 ignores `kind`, so the client filters by each item's `kind` itself; This Mac has no bug reports.

## Reopened asks

Reopen adds a `reopened` owner event, shown by `relay status`, `replies`, `wait` and `relay_status`. The ask counts as open until a later Done or Skip.
