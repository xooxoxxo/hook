# Pond protocol

Your Pond (formerly the mailbox) is a small server you run that holds asks while you're away. Hook ships no Pond server. This page lists what Hook sends to a Pond and what it reads back.

Some names stay as they were: the `mailboxURL` and `mailboxUpdateCommand` config keys and the `hook:mailbox-protocol` release marker. The app polls every `pollSeconds`, and the CLI and MCP server use the same routes.

## Requests

Every request carries `Authorization: Bearer <content of tokenFile>` and `X-Hook-Protocol: 6`. Bodies are JSON (`Content-Type: application/json`). The protocol header says the client reads revision histories (from 5) and choice objects (from 6). Below 5, a Pond 1.1.0 serves a corrected ask as a stub. Below 6, a Pond 1.4.0 serves a choice object as its label only ([below](#choices-with-words)).

Owner acts from the app also carry `X-Hook-Owner-Key` once this Mac's [owner key](#the-owner-key) is approved.

| Request | Sent by | Body or query | Hook expects |
|---|---|---|---|
| `POST /asks` | CLI, MCP server, Settings › Queue test ask | `{project, context, instructable}` | 201 or 200 `{item, deduped?, openUrl?}` |
| `POST /asks` with `kind: "bug"` | app (a crash report sent to My Pond; Pond 1.2.0, owner key required) | `{project, context, instructable, kind: "bug", signature}`. `signature` is 12 lowercase hex digits | 201 `{item, occurrences: 1}` for a new report. 200 `{item, deduped: true, occurrences}` when an open bug has the same signature. Never sent to Telegram |
| `GET /asks` | app, CLI, MCP server | `status=open`, `days=36500` | 200 `{items}`, newest first |
| `GET /asks` | `relay list --kind`, `relay_list {kind}` (Pond 1.2.0) | adds `kind=ask` or `kind=bug` | 200 `{items}` of that kind. An older Pond ignores `kind`, so the client filters too |
| `GET /asks` | app (Closed today) | `status=done` or `status=dismissed`, `days=14` | 200 `{items}`. Hook keeps those whose `completedAt` falls in its window |
| `GET /asks/{id}` | app, CLI (including `relay wait`), MCP server | none | 200 `{item, events}`, or 404 |
| `POST /asks/{id}/resolve` | app (Done, Skip), CLI and MCP (`done`, `skip`) | `{verdict, actor, note?}`. `verdict` is `done` or `declined`. `actor` is `owner` from the app, `session` from the CLI and MCP server | 200 `{item}`. From Pond 1.3.0, an owner Done (`verdict: done`, `actor: owner`) with work left answers 409 `{"error": "requirements_unmet", "left": [{"kind": "step", "id": "s2", "path": "2"}, {"kind": "reply"}, {"kind": "message"}], "details": ["step 2", "the reply", "a message"]}`. The revision check comes first (`ask was corrected`). Skip and a session's Done are never refused this way |
| `POST /asks/{id}/reopen` | app (Reopen in Closed today) | `{actor}`, always `owner` | 200 `{item}`, or 404 |
| `POST /asks/{id}/reply` | app (Reply, reply choices) | `{text}` | 200 `{item}` |
| `POST /asks/{id}/reply` with `kind: "message"` | app (the Messages section; Pond 1.2.0; the owner key when this Mac has one) | `{text, kind: "message"}`: the text as typed, multi-line, at most 1,000 characters (8,000 on Pond 1.4.0) | 200 `{item}`. 400 `invalid message` (`text: secret-like value`, `text: too long`) or `missing text`. 409 `ask is closed` or `too many messages` (50 per ask) |
| `POST /asks/{id}/problems` | app (Report a Problem; Pond 1.1.0, owner key required) | `{step, note, rev, hash}`. `step` is the step's id | 200 `{item}`. The Pond refuses a note that looks like a secret |
| `POST /asks/{id}/progress` | app (ticks on an ask with requirements; Pond 1.3.0; the owner key when this Mac has one) | `{"tick": [ids], "untick": [ids], rev, hash}`: step ids only, at most 60, no id in both lists | 200 `{item}` with `requirements`. 409 `ask is closed` or `ask was corrected`. 400 `invalid progress` (`tick: must be a list of step ids`, `tick[2]: unknown step`, `untick[0]: also in tick`, `tick: more than 60 ids`). A request that changes nothing stores nothing |
| `POST /asks/{id}/answers` | app (Send answers) | `{"answers": [...]}`: 1 to 20 of `{"step": "3.2", "picked": ["Staging"]}` or `{"step": "4", "text": "..."}` | 200 `{item}`. 409 when the ask is closed |
| `GET /events` | `relay replies` | `after=<seq>`, `limit=1000` | 200 `{events, next, epoch?}`: events with `seq > after`, ascending. `next` is the last seq returned, or `after` |
| `GET /version` | app ([when it checks](#updating-the-mailbox)). `relay post` and `relay_post` (before an instructable with a key that needs a newer Pond; cached for 5 minutes). `relay amend` | none | 200 `{"service": "pond", "version": "1.1.0", "protocol": 5}`. A 404 is protocol 1 ([below](#pond-versions)) |
| `POST /asks/{id}/amend` | `relay amend`, `relay_amend` (Pond 1.1.0) | `{editKey, baseRev, baseHash, reason, instructable}` | 200 `{item, revision: {rev, hash, changed, added, removed, moved, top}, openUrl?, warning?}`. 409 `{"error": "corrections not enabled"}` when the Pond has them off |
| `POST /asks/{id}/accept` | app (Use Version N; Pond 1.1.0, owner key required) | `{rev, hash}` | 200 `{item}` |
| `GET /owner` | app (Settings › Queue › Owner Key) | none | 200 `{required, keys: [{id, label, status, created, approvedAt?}], self?}` |
| `POST /owner/enroll`, `GET /owner/enroll/{id}` | app (Set Up This Mac…) | `{keyHash, label}`: only the key's SHA-256, never the key | 200 `{id, code?, status?, expires?}` |
| `POST /owner/require` | app (Require Owner Key…, Turn Off…) | `{required}` | 200 `{required}`, or 202 `{pending: true}` while turning it off waits for Telegram |

<a id="protocol-levels"></a>

## Pond versions

`GET /version` names the Pond's version in `version`. It needs the token like every other route. From 1.0.0 on, Pond versions follow [semver](https://semver.org). A minor release adds features, a patch fixes bugs, and only a major release breaks clients. Each Hook release names the Pond versions it works with as an npm-style range. This one needs `^1.1.0`: 1.1.0 or newer, below 2.0.0.

| Pond | Adds |
|---|---|
| 1.0.0 | everything up to the old protocol level 4. That is asks, events, resolve, reply, reopen, step `question` and `POST /asks/{id}/answers`, the `blocking`, `warning` and `optional` step keys, and file links (`file`, a link's `path`) |
| 1.1.0 | step `id`s, revisions and corrections (`amend`, `accept`), problem reports (`problems`), and the owner key (`/owner`, `X-Hook-Owner-Key`) |
| 1.2.0 | bug reports (`POST /asks` with `kind: "bug"`, `GET /asks?kind=`) and messages to the posting session (the `message` reply kind). On 1.1.0 a crash report goes out as a plain ask, and the Messages section is hidden |
| 1.3.0 | required before Done: the `required` step key and the ask-level `done` list, `POST /asks/{id}/progress`, `requirements` on an item, `progress` events, and the 409 `requirements_unmet` on an owner Done. `protocol` stays 5. `relay post`, `relay_post` and `relay amend` refuse the two keys on an older Pond. Hook still works with 1.1.0 and 1.2.0, and keeps Done off on an ask with requirements on any Pond |
| 1.4.0 | long text and [choices with words](#choices-with-words). Messages and problem reports take 8000 characters (1000 and 300 before), and a report may span lines. Telegram splits anything past 4096 into more messages. `protocol` stays 5. On an older Pond Hook keeps 1000, 300 and a one-line report, and `relay post`, `relay_post` and `relay amend` refuse a choice object |

A Pond 1.x still answers `protocol` (5 for 1.1.0) for Hook 0.9.x, which reads only that. Newer Hook reads `version` first:

| `GET /version` answers | Hook reads it as |
|---|---|
| a strict semver `version` (`1.1.0`) | that version |
| a dated `version` with an integer `protocol` (a Pond from before semver) | protocol 4 as 1.0.0, protocol N below 4 as 0.N.0. Settings shows "Pond (protocol 4)" |
| 404 (no such route) | protocol 1: an older Pond, so the Notice and the update check apply |
| 200 with neither | the app: a failed check, no Notice, and Settings shows "Couldn't check". The CLI and MCP server: unknown, so they post as before and let the Pond validate |

In This Mac mode the app answers `GET /version` itself as Pond 1.0.0 ([Local API](local-api.md)). It has no corrections, owner key or requirements yet.

How Hook shows the version:

- **Inside it** (1.1.0, 1.4.2): Settings › Queue › Connection says "Pond 1.1.0 ✓ (needs ^1.1.0)".
- **Below it** (1.0.0, protocol 4): Settings says "Pond 1.0.0 (needs ^1.1.0)" and **Needs an update**. The panel's Notice says "Your Pond (1.0.0) is older than this Hook needs (^1.1.0)". It lists what needs the update: step corrections and the owner key. An ask this Mac saw corrected stays locked while such a Pond serves it.
- **A newer major** (2.0.0): Settings says "Pond 2.0.0 (this Hook needs ^1.1.0)" and **Newer than Hook**. The Notice says "Hook is older than your Pond (2.0.0). Update Hook to catch up.", with **Check for Updates**.

A range uses npm's syntax without the shortcuts. Sets are joined by `||`. Each set is a space-separated list of comparators (`^V`, `~V`, `>=V`, `>V`, `<=V`, `<V`, `=V` or a bare `V`) with full `MAJOR.MINOR.PATCH` versions. A pre-release such as `1.2.0-rc.1` matches only a range that names a pre-release of 1.2.0. The CLI and MCP server check each key against the first Pond version with it.

## What the service should do

- **Post.** If an open ask with the same context and title was created in the last 24 h, return it with `deduped: true`. `openUrl` is optional; the CLI prints it.
- **Resolve.** Set the item's `status` to `done` or `dismissed`. Add a `resolved` or `declined` event with the given actor.
- **Reopen.** Set a `done` or `dismissed` item back to `open`, clear `completedAt`, and add a `reopened` event with actor `owner`. For an open ask, change nothing but answer 200 with the item.
- **Reply.** Add a `reply` event with actor `owner`.
- **Answers.** Answer 404 for an unknown ask. Then answer 409 `{"error": "ask is closed"}` unless the ask is open. Then answer 400 `{"error": "invalid answers", "details": [...]}` when an answer doesn't fit its step's question. Otherwise add one `answer` event per answer (actor `owner`) in one transaction, and leave the ask open. A later answer for the same step replaces the earlier one: the latest event wins, and the earlier ones stay in the log.
- **Epoch.** An optional string. Change it when the event sequence restarts, so `relay replies` resets its cursors.

## Corrections

From Pond 1.1.0 an ask has revisions. Version 1 is the ask as posted, and each `amend` adds the next. An item carries its newest one as `revision: {rev, hash, prev, at, reason, body, acceptedRev}`. `GET /asks/{id}` adds `revisions`: all of them from 1 up, oldest first.

- **body** is the revision's instructable as a JSON string, exactly as served. Hook hashes the string as it is and parses it strictly. Broken JSON, a lone surrogate or a key named twice in one object makes the history unreadable.
- **hash** is the lowercase hex SHA-256, over UTF-8, of `hook-rev-v1`, `rev`, `prev`, `at`, `reason` and `body` joined with U+001F.
- **prev** is the previous revision's hash. Version 1 has `""` as its `prev` and its `reason`.
- **acceptedRev** is the revision the owner accepted. It is in force for Telegram, answers and Done.
- **Checks.** Hook checks every hash and every `prev`, and needs every revision from 1 to `rev`. It refuses a revision that changes `title`, `urgency` or `from`, and remembers each hash it has seen. A history that fails a check, or serves a revision older than one this Mac saw, locks the ask with the history Notice.
- **Edit keys.** `POST /asks` from the CLI or MCP server carries `editKeyHash`, the SHA-256 of a key the poster keeps. `amend` must bring the key, name its starting revision (`baseRev`, `baseHash`), and keep `title`, `urgency` and `from`.
- **Acts bound to a version.** Done and answers from Hook add the shown version's `rev` and `hash` to their body. If another version is in force, the Pond answers 409 `{"error": "ask was corrected"}`. So neither act applies to a version the owner didn't see. Skip sends no revision and closes the ask whatever version is in force, so it always works.

## The owner key

A Pond 1.1.0 can tell the owner's acts from a session's. Each Mac makes a 32-byte key and sends only its SHA-256, with a label, to `POST /owner/enroll`. Hook then shows a six-digit code, and the Pond's Telegram request repeats it. The code is the decimal value of the first 12 hex digits of `sha256("hook-enroll-v1\n" + id + "\n" + keyHash)`, modulo 1,000,000, zero-padded.

Once the owner approves on Telegram, Hook sends the key as `X-Hook-Owner-Key` on owner acts. It sends the key only over https (or plain http to this Mac itself), and only to the scheme it was set up on.

- `accept` always needs the key: 403 `{"error": "owner key required"}` without it.
- With `required` on, every owner act needs the key. A key the Pond doesn't know gets 403 `{"error": "unknown owner key"}`. Hook then marks the key refused and asks the owner to set it up again.
- Turning `required` on needs two approved keys, one of them the caller's. Turning it off answers 202 and waits for the owner's tap on Telegram.

<a id="updating-the-mailbox"></a>

## Updating the Pond

**What Hook checks.** The app reads `GET /version` on connect, when you switch Ponds, and at most every 30 minutes while the Pond is reachable. Settings › Queue › Connection shows the version against the needed range, then ✓ or "Needs an update". **Check** reads it again.

- **Older or newer than Hook:** the panel's Notice says so, as in [Pond versions](#pond-versions). An older Pond's Notice offers **Update Pond…** and **How to update** (this section). A newer minor or patch Pond needs nothing.
- **Up to date:** after an update brings the Pond into the range, "Your Pond is up to date (1.1.0)." shows for 8 seconds.
- **Before Hook updates itself.** Release notes carry a hidden `<!-- hook:pond=<range> -->` marker: the Pond range that release needs. If the connected Pond is below it, the update dialog says "Hook X needs Pond ^1.1.0. Your Pond is 1.0.0." It offers **Update Pond First**, **Update Hook Anyway** and **Cancel**. A Pond inside or past the range passes, so a minor or patch Pond release never blocks an update. If the check fails, the dialog says "Hook couldn't check your Pond" and still offers **Update Hook Anyway**. This Mac mode always passes. Releases also keep the old `<!-- hook:mailbox-protocol=N -->` marker, the only one older Hooks read.

**Update Pond…** is in the menu-bar menu, next to Check for Updates…, and in the panel's Notice. It runs Settings › Queue › Pond › Update command (`mailboxUpdateCommand` in [config.json](configuration.md)) through your login shell. The command opens in a new window of your Resume terminal. There you see its output and answer any ssh or sudo prompt. When it ends, the window waits for Return, and Hook reads the version again. Without a command, Update Pond… opens this section.

The command is yours: whatever pulls the new Pond and restarts it. For a Pond in Docker Compose on another machine:

```
ssh pond-host 'cd /srv/pond && git pull && docker compose up -d --build'
```

## Responses

- `401`: token refused. `404`: no such ask.
- Other errors: `{"error": "<message>", "details": ["<field>: <problem>"]}`, shown to the caller.
- A redirect (3xx) is an error, never followed.

## Items

Hook reads these item keys and ignores the rest.

| Key | Meaning |
|---|---|
| `id` | String id, used in every `/asks/{id}` route |
| `title` | The ask's title |
| `status` | `open`, `done` or `dismissed` |
| `projectId` | The `project` the ask was posted with |
| `created`, `updated` | Timestamps |
| `completedAt` | When the ask was closed. Null while it is open |
| `payload.instructable` | The instructable as posted (see the [format](instructables.md)) |
| `kind`, `bug` | Pond 1.2.0, on a bug report only: `kind: "bug"` and `bug: {signature, count, firstSeen, lastSeen}`. A plain ask has neither |
| `requirements` | Pond 1.3.0: `{"left": [{"kind": "step", "id", "path"}, {"kind": "reply"}, {"kind": "message"}], "ready": bool}`, what the owner must still finish before their Done. Only on `GET /asks/{id}` and on answers that carry one item (resolve, reply, answers, progress, accept, problems, reopen). Never on `GET /asks`, and absent on an ask without requirements |

Without `payload.instructable`, Hook shows an item from `payload.why`, `payload.cmd`, `payload.link` and the text of its `steps` events.

## Events

An event is `{seq, itemId, kind, actor, text, at}`. `seq` is an integer that only grows.

- An owner's action has actor `owner` and kind `resolved`, `declined`, `reopened`, `reply`, `answer`, `message`, `problem` or `accepted`. An ask closed by an agent has actor `session`.
- `reopened`: the ask is open again. No client shows it closed until a later `resolved` or `declined`.
- `answer`: the answer to one step's question. Its `text` is compact JSON with `step` first. A choice question gives `{"step":"3.2","picked":["Staging"]}`, picks in the order of the choices. A free-text one gives `{"step":"4","text":"Use the EU region"}`. A step path is `"3"` or `"3.2"`, 1-based. Pond 1.4.0 adds the owner's words beside a single pick of a choice that takes them: `{"step":"2","id":"s2","picked":["Mix"],"text":"Staff on Monday"}`.
- `message` (Pond 1.2.0): a message to the session that posted the ask, its `text` verbatim. It answers and closes nothing.
- `problem` (Pond 1.1.0): a Report a Problem note on one step, named by the step's `id`.
- `occurrence` (actor `hook`, Pond 1.2.0): a repeat of an open bug report.
- `progress` (actor `owner`, Pond 1.3.0): the owner's ticks on an ask with requirements. Its `text` is the compact JSON `{"tick":[ids],"untick":[ids]}`, step ids only. It is bookkeeping for the Done check: no client shows it, and it never appears in `ownerEvents`, `relay replies` or `relay wait`.

A session gets owner text cut at 8000 characters per event, then ` (N more characters: relay status <id> --json)`. `relay status <id> --json` carries all of it.

### Choices with words

From Pond 1.4.0 a choice in a question's or the reply's `choices` may be an object: `{"label": "Mix", "text": "What should change?"}`. `label` is 1–60 characters on one line, unique in its list. `text`, the placeholder of the owner's field, is 1–100 characters on one line. Both are required, and a `multi` question refuses such a choice. The owner's words travel with the pick:

- A reply event's `text` is `choice: Mix · <words>` (U+00B7 with a space on each side), or `choice: Mix` without words. The Pond stores it like any reply. Hook caps the words at 1000 characters.
- An `answer` event adds `text` (1–1000 characters, line breaks allowed) beside `picked`. Words on any other pick are refused (`answers[0].text: this choice takes no words`).

A client that sends `X-Hook-Protocol: 6` gets the objects. Below 6, an ask with an object in any revision comes back with labels only. Revision 1 comes as its labels-only body and a later one as the update stub, without `revision` or `revisions`. So Hook 0.13 and older never see a question they can't read. Sessions read an answer with words as `answer 2 (version 1): "Mix · <words>"`.

## Timestamps

UTC, ISO 8601 with an offset: `2026-10-11T09:30:00+00:00`.
