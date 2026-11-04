# Pond protocol

What Hook sends to your Pond (formerly called the mailbox), the small server you run that holds asks while you're away, and what it reads back. Hook includes no Pond server. The names in the protocol itself stay as they were: the `mailboxURL` and `mailboxUpdateCommand` config keys and the `hook:mailbox-protocol` release marker.

The app polls every `pollSeconds`; the CLI and MCP server use the same routes.

## Requests

Every request carries `Authorization: Bearer <content of tokenFile>` and `X-Hook-Protocol: 6`, which says the client reads revision histories (without 5 or more a Pond 1.1.0 serves a corrected ask as a stub) and choice objects (below 6 a Pond 1.4.0 serves an ask that holds one with labels only, [below](#choices-with-words)). Owner acts from the app also carry `X-Hook-Owner-Key` once this Mac's [owner key](#the-owner-key) is approved. Bodies are JSON (`Content-Type: application/json`).

| Request | Sent by | Body or query | Hook expects |
|---|---|---|---|
| `POST /asks` | CLI, MCP server, Settings › Queue test ask | `{project, context, instructable}` | 201 or 200 `{item, deduped?, openUrl?}` |
| `POST /asks` with `kind: "bug"` | app (a crash report sent to My Pond; Pond 1.2.0, owner key required) | `{project, context, instructable, kind: "bug", signature}`: `signature` is 12 lowercase hex digits | 201 `{item, occurrences: 1}` for a new report; 200 `{item, deduped: true, occurrences}` when an open bug has the same signature. Never sent to Telegram |
| `GET /asks` | app, CLI, MCP server | `status=open`, `days=36500` | 200 `{items}`, newest first |
| `GET /asks` | `relay list --kind`, `relay_list {kind}` (Pond 1.2.0) | adds `kind=ask` or `kind=bug` | 200 `{items}` of that kind; an older Pond ignores `kind`, so the client filters too |
| `GET /asks` | app (Closed today) | `status=done` or `status=dismissed`, `days=14` | 200 `{items}`; Hook keeps those whose `completedAt` falls in its window |
| `GET /asks/{id}` | app, CLI (including `relay wait`), MCP server | none | 200 `{item, events}`, or 404 |
| `POST /asks/{id}/resolve` | app (Done, Skip), CLI and MCP (`done`, `skip`) | `{verdict, actor, note?}`: `verdict` is `done` or `declined`; `actor` is `owner` from the app and `session` from the CLI and MCP server | 200 `{item}`; from Pond 1.3.0, an owner Done (`verdict: done`, `actor: owner`) on an ask with something left before Done answers 409 `{"error": "requirements_unmet", "left": [{"kind": "step", "id": "s2", "path": "2"}, {"kind": "reply"}, {"kind": "message"}], "details": ["step 2", "the reply", "a message"]}`, after the revision check (`ask was corrected` comes first). Skip and the session's Done are never refused this way |
| `POST /asks/{id}/reopen` | app (Reopen in Closed today) | `{actor}`: always `owner` | 200 `{item}`, or 404 |
| `POST /asks/{id}/reply` | app (Reply, reply choices) | `{text}` | 200 `{item}` |
| `POST /asks/{id}/reply` with `kind: "message"` | app (the Messages section; Pond 1.2.0; the owner key when this Mac has one) | `{text, kind: "message"}`: the text as typed, multi-line, at most 1,000 characters | 200 `{item}`; 400 `invalid message` (`text: secret-like value`, `text: too long`) or `missing text`; 409 `ask is closed` or `too many messages` (50 per ask) |
| `POST /asks/{id}/progress` | app (ticks on an ask with requirements; Pond 1.3.0; the owner key when this Mac has one) | `{"tick": [ids], "untick": [ids], rev, hash}`: step ids only, at most 60, the two lists disjoint | 200 `{item}` with `requirements`; 409 `ask is closed` or `ask was corrected`; 400 `invalid progress` (`tick: must be a list of step ids`, `tick[2]: unknown step`, `untick[0]: also in tick`, `tick: more than 60 ids`). A delta that changes nothing stores nothing |
| `POST /asks/{id}/answers` | app (Send answers) | `{"answers": [...]}`: 1 to 20 of `{"step": "3.2", "picked": ["Staging"]}` or `{"step": "4", "text": "..."}` | 200 `{item}`; 409 when the ask is closed |
| `GET /events` | `relay replies` | `after=<seq>`, `limit=1000` | 200 `{events, next, epoch?}`: events with `seq > after`, ascending; `next` is the last seq returned, or `after` |
| `GET /version` | app (on connect, then at most every 30 minutes; Settings › Queue › Check), `relay post` and `relay_post` (before an instructable with a key that needs a newer Pond; cached for 5 minutes), `relay amend` | none | 200 `{"service": "pond", "version": "1.1.0", "protocol": 5}`; a 404 is protocol 1 ([below](#pond-versions)) |
| `POST /asks/{id}/amend` | `relay amend`, `relay_amend` (Pond 1.1.0) | `{editKey, baseRev, baseHash, reason, instructable}` | 200 `{item, revision: {rev, hash, changed, added, removed, moved, top}, openUrl?, warning?}`; 409 `{"error": "corrections not enabled"}` when the Pond has them off |
| `POST /asks/{id}/accept` | app (Use Version N; Pond 1.1.0, owner key required) | `{rev, hash}` | 200 `{item}` |
| `GET /owner` | app (Settings › Queue › Owner Key) | none | 200 `{required, keys: [{id, label, status, created, approvedAt?}], self?}` |
| `POST /owner/enroll`, `GET /owner/enroll/{id}` | app (Set Up This Mac…) | `{keyHash, label}`: only the key's SHA-256, never the key | 200 `{id, code?, status?, expires?}` |
| `POST /owner/require` | app (Require Owner Key…, Turn Off…) | `{required}` | 200 `{required}`, or 202 `{pending: true}` while turning it off waits for Telegram |

<a id="protocol-levels"></a>

## Pond versions

`GET /version` names the Pond's version in `version`. It is authenticated like every other route. From 1.0.0 on, Pond versions follow [semver](https://semver.org): a minor release adds features without breaking anything, a patch fixes, and only a major release breaks clients. Each Hook release names the Pond versions it works with as an npm-style range: this one needs `^1.1.0` (1.1.0 or newer, below 2.0.0).

| Pond | Adds |
|---|---|
| 1.0.0 | everything up to the old protocol level 4: asks, events, resolve, reply, reopen, step `question` and `POST /asks/{id}/answers`, the `blocking`, `warning` and `optional` step keys, and file links (`file`, a link's `path`) |
| 1.1.0 | step `id`s, revisions and corrections (`amend`, `accept`), and the owner key (`/owner`, `X-Hook-Owner-Key`) |
| 1.2.0 | bug reports (`POST /asks` with `kind: "bug"`, `GET /asks?kind=`) and messages to the posting session (the `message` reply kind). This Hook works without them on 1.1.0: a crash report goes out as a plain ask, and the Messages section is hidden |
| 1.3.0 | required before Done: the `required` step key and the ask-level `done` list, `POST /asks/{id}/progress`, `requirements` on an item, `progress` events, and the 409 `requirements_unmet` on an owner Done. `protocol` stays 5. `relay post`, `relay_post` and `relay amend` refuse the two keys on an older Pond; This Hook still works with 1.1.0 and 1.2.0, and keeps Done off on an ask that carries requirements whatever the Pond's version |
| 1.4.0 | long text and [choices with words](#choices-with-words): messages and problem reports up to 8000 characters (1000 and 300 before; a report may span lines), Telegram splitting anything past 4096 into further messages, and the choice object `{"label": "Mix", "text": "What should change?"}` in a question's or the reply's `choices`, with the owner's words beside a pick. `protocol` stays 5. On an older Pond Hook keeps 1000 and 300 and a one-line report, and `relay post`, `relay_post` and `relay amend` refuse a choice object |

A Pond 1.x still answers `protocol` (5 for 1.1.0) for Hook 0.9.x, which reads only that. Hook reads `version` first:

| `GET /version` answers | Hook reads it as |
|---|---|
| a strict semver `version` (`1.1.0`) | that version |
| a dated `version` with an integer `protocol` (a Pond from before semver) | protocol 4 as 1.0.0, protocol N below 4 as 0.N.0; Settings shows "Pond (protocol 4)" |
| 404 (no such route) | protocol 1: an older Pond, so the Notice and the update check apply |
| 200 with neither | to the app, a failed check: no Notice, and Settings shows "Couldn't check"; to the CLI and MCP server, unknown: they post as before and let the Pond validate |

In This Mac mode the app answers `GET /version` itself as Pond 1.0.0 ([Local API](local-api.md)): it has no corrections, owner key or requirements yet.

How a version compares with the range:

- **Inside it** (1.1.0, 1.4.2): Settings › Queue › Connection says "Pond 1.1.0 ✓ (needs ^1.1.0)".
- **Below it** (1.0.0, protocol 4): "Pond 1.0.0 (needs ^1.1.0)" and **Needs an update**, and the panel's Notice says "Your Pond (1.0.0) is older than this Hook needs (^1.1.0).", naming what won't work until it is updated (step corrections and the owner key). An ask this Mac saw corrected stays locked while such a Pond serves it.
- **A newer major** (2.0.0): "Pond 2.0.0 (this Hook needs ^1.1.0)" and **Newer than Hook**; the Notice says "Hook is older than your Pond (2.0.0). Update Hook to catch up.", with **Check for Updates**.

A range is npm's syntax without the shortcuts: sets joined by `||`, each a space-separated list of comparators `^V`, `~V`, `>=V`, `>V`, `<=V`, `<V`, `=V` or a bare `V`, with full `MAJOR.MINOR.PATCH` versions. A pre-release such as `1.2.0-rc.1` matches only a range that names a pre-release of 1.2.0. The CLI and MCP server check each key against the first Pond version that has it, the same way.

## What the service should do

- **Post.** If an open ask with the same context and title was created in the last 24 h, return it with `deduped: true`. `openUrl` is optional; the CLI prints it.
- **Resolve.** Set the item's `status` to `done` or `dismissed`, and add a `resolved` or `declined` event with the given actor.
- **Reopen.** Set a `done` or `dismissed` item back to `open`, clear `completedAt`, and add a `reopened` event with actor `owner`. Reopening an open ask changes nothing but still answers 200 with the item.
- **Reply.** Add a `reply` event with actor `owner`.
- **Answers.** Answer 404 for an unknown ask, then 409 `{"error": "ask is closed"}` unless the ask is open, then 400 `{"error": "invalid answers", "details": [...]}` when an answer doesn't fit its step's question. Otherwise add one `answer` event per answer (actor `owner`) in one transaction and leave the ask open. A later answer for the same step replaces the earlier one: the latest event wins, and the earlier ones stay in the log.
- **Epoch.** Optional string. Change it when the event sequence restarts, so `relay replies` resets its cursors.

## Corrections

From Pond 1.1.0 an ask has revisions. Version 1 is the ask as posted; each `amend` adds the next. An item carries its newest one as `revision: {rev, hash, prev, at, reason, body, acceptedRev}`, and `GET /asks/{id}` adds `revisions`, every one from 1 up, oldest first.

- **body** is the revision's instructable as a JSON string, exactly as served. Hook hashes the string as it is and reads it strictly: broken JSON, a lone surrogate or a key named twice in one object makes the history unreadable.
- **hash** is the lowercase hex SHA-256 of `hook-rev-v1`, `rev`, `prev`, `at`, `reason` and `body`, joined with U+001F, over UTF-8. **prev** is the previous revision's hash, `""` for version 1, and version 1's `reason` is `""`.
- **acceptedRev** is the revision the owner accepted, in force for Telegram, answers and Done.
- Hook checks every hash and every `prev`, needs every revision from 1 to `rev`, refuses one that changes `title`, `urgency` or `from`, and remembers each hash it has seen. A history that fails any of these, or serves a revision older than one this Mac saw, locks the ask with the history Notice.
- **Edit keys.** `POST /asks` from the CLI or MCP server carries `editKeyHash`, the SHA-256 of a key the poster keeps. `amend` must bring the key, name the revision it starts from (`baseRev`, `baseHash`), and keep `title`, `urgency` and `from`.
- **Acts bound to a version.** Done and answers from Hook add the `rev` and `hash` of the version shown to their body. A Pond whose version in force is another one answers 409 `{"error": "ask was corrected"}`, so neither applies to a version the owner didn't see. Skip goes without a revision: it closes the ask whatever version is in force, so it always works.

## The owner key

A Pond 1.1.0 can tell the owner's acts from a session's. Each Mac makes a 32-byte key, sends only its SHA-256 to `POST /owner/enroll` with a label, and shows the six-digit code the Pond's Telegram request repeats: the decimal value of the first 12 hex digits of `sha256("hook-enroll-v1\n" + id + "\n" + keyHash)`, modulo 1,000,000, zero-padded. Once the owner approves on Telegram, Hook sends the key as `X-Hook-Owner-Key` on owner acts, and only over https (or plain http to this Mac itself), to the scheme it was set up on.

- `accept` always needs the key: 403 `{"error": "owner key required"}` without it.
- With `required` on, every owner act needs it. A key the Pond doesn't know gets 403 `{"error": "unknown owner key"}`; Hook then marks it refused and asks the owner to set it up again.
- Turning `required` on needs two approved keys, the caller's among them. Turning it off answers 202 and waits for the owner's tap on Telegram.

<a id="updating-the-mailbox"></a>

## Updating the Pond

**What Hook checks.** The app reads `GET /version` when it connects to the Pond, when you switch to another one, and then at most every 30 minutes while it is reachable. Settings › Queue › Connection shows the Pond's version against the range this Hook needs, then ✓ or "Needs an update", with **Check** to read it again.

- **Older than Hook** (below the range this Hook needs): the panel says which features won't work ("step corrections and the owner key") until the Pond is updated, with **Update Pond…** and **How to update** (this section).
- **Newer than Hook** (a newer major version): the panel says Hook is older, with **Check for Updates**. A newer minor or patch Pond needs nothing.
- **Up to date:** once an update (or **Check** after one) brings the Pond into the range, "Your Pond is up to date (1.1.0)." shows for 8 seconds and goes on its own.
- **Before Hook updates itself.** A release's notes carry a hidden `<!-- hook:pond=<range> -->` marker: the Pond range that release needs. When the connected Pond is below it, the update dialog says "Hook X needs Pond ^1.1.0. Your Pond is 1.0.0." and offers **Update Pond First**, **Update Hook Anyway** and **Cancel**. A Pond inside the range, or past it, passes, so a minor or patch Pond release never holds an update back. When the check fails, the dialog says "Hook couldn't check your Pond" and still offers **Update Hook Anyway**. This Mac mode always passes. Releases also keep the old `<!-- hook:mailbox-protocol=N -->` marker for older Hooks, which read only that.

**Update Pond…** sits in the menu-bar menu next to Check for Updates… and in the panel's Notice. It runs the command in Settings › Queue › Pond › Update command (`mailboxUpdateCommand` in [config.json](configuration.md)) in a new window of your Resume terminal, through your login shell, so you see its output and answer any ssh or sudo prompt there. When the command ends, the window waits for Return and Hook reads the version again. Without a command, Update Pond… opens this section.

The command is yours: whatever pulls the new Pond and restarts it. For example, a Pond run with Docker Compose on another machine:

```
ssh pond-host 'cd /srv/pond && git pull && docker compose up -d --build'
```

## Responses

- `401`: token refused. `404`: no such ask.
- Other errors: `{"error": "<message>", "details": ["<field>: <problem>"]}`, shown to the caller.
- A redirect (3xx) is an error and never followed.

## Items

Hook reads these item keys and ignores the rest.

| Key | Meaning |
|---|---|
| `id` | String id, used in every `/asks/{id}` route |
| `title` | The ask's title |
| `status` | `open`, `done` or `dismissed` |
| `projectId` | The `project` the ask was posted with |
| `created`, `updated` | Timestamps |
| `completedAt` | When the ask was closed; null while it is open |
| `payload.instructable` | The instructable as posted (see the [format](instructables.md)) |
| `kind`, `bug` | Pond 1.2.0, on a bug report only: `kind: "bug"` and `bug: {signature, count, firstSeen, lastSeen}`. A plain ask has neither |
| `requirements` | Pond 1.3.0: `{"left": [{"kind": "step", "id", "path"}, {"kind": "reply"}, {"kind": "message"}], "ready": bool}`, what the owner must still finish before their Done. Only on `GET /asks/{id}` and the answers that carry one item (resolve, reply, answers, progress, accept, problems, reopen), never on `GET /asks`, and absent on an ask without requirements |

Without `payload.instructable`, an item is shown from `payload.why`, `payload.cmd`, `payload.link` and the text of its `steps` events.

## Events

An event is `{seq, itemId, kind, actor, text, at}`; `seq` is an integer that only grows.

- An owner's action has actor `owner` and kind `resolved`, `declined`, `reply` or `answer`.
- `message` (actor `owner`, Pond 1.2.0): a message to the session that posted the ask, its `text` verbatim. It answers and closes nothing. A bug report's repeats add `occurrence` events (actor `hook`).
- `answer` (actor `owner`): the answer to one step's question. Its `text` is compact JSON with `step` first: `{"step":"3.2","picked":["Staging"]}` for a choice question (picks in the order of the choices), `{"step":"4","text":"Use the EU region"}` for a free-text one. A step path is `"3"` or `"3.2"`, 1-based. Pond 1.4.0 adds the owner's words beside a single pick of a choice that takes them: `{"step":"2","id":"s2","picked":["Mix"],"text":"Staff on Monday"}`.

### Choices with words

From Pond 1.4.0 a choice in a question's or the reply's `choices` may be an object, `{"label": "Mix", "text": "What should change?"}`: `label` is 1–60 characters on one line and distinct in its list, `text` (the placeholder of the owner's field) 1–100 characters on one line; both are required, and such a choice is refused in a `multi` question. The owner's words travel with the pick:

- a reply event's `text` is `choice: Mix · <words>` (U+00B7 with a space on each side), or `choice: Mix` without words; the Pond stores it like any reply. Hook caps the words at 1000 characters;
- an `answer` event adds `text` (1–1000 characters, line breaks allowed) beside `picked`; words on any other pick are refused (`answers[0].text: this choice takes no words`).

A client that sends `X-Hook-Protocol: 6` gets the objects. Below 6, an ask with an object in any revision comes back with labels only: revision 1 as its labels-only body, a later revision as the update stub, and no `revision` or `revisions` keys, so Hook 0.13 and older clients never see an unreadable question. Sessions read an answer with words as `answer 2 (version 1): "Mix · <words>"`.

Messages and problem reports take 8000 characters on Pond 1.4.0. Owner text reaches a session cut at 8000 characters per event, followed by ` (N more characters: relay status <id> --json)`; `relay status <id> --json` carries all of it.
- An ask closed by an agent has actor `session`.
- `reopened` (actor `owner`): the ask is open again, and no client shows it closed until a later `resolved` or `declined`.
- `progress` (actor `owner`, Pond 1.3.0): the owner's ticks on an ask with requirements, its `text` the compact JSON `{"tick":[ids],"untick":[ids]}`, step ids only. It is bookkeeping for the Done gate: no client shows it, and it never appears in `ownerEvents`, `relay replies` or `relay wait`.

## Timestamps

UTC, ISO 8601 with an offset: `2026-10-11T09:30:00+00:00`.
