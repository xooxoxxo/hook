# Mailbox protocol

What Hook sends to a mailbox service you run, and what it reads back. Hook includes no mailbox server.

The app polls every `pollSeconds`; the CLI and MCP server use the same routes.

## Requests

Every request carries `Authorization: Bearer <content of tokenFile>`. Bodies are JSON (`Content-Type: application/json`).

| Request | Sent by | Body or query | Hook expects |
|---|---|---|---|
| `POST /asks` | CLI, MCP server, Settings › Queue test ask | `{project, context, instructable}` | 201 or 200 `{item, deduped?, openUrl?}` |
| `GET /asks` | app, CLI, MCP server | `status=open`, `days=36500` | 200 `{items}`, newest first |
| `GET /asks` | app (Closed today) | `status=done` or `status=dismissed`, `days=14` | 200 `{items}`; Hook keeps those whose `completedAt` falls in its window |
| `GET /asks/{id}` | app, CLI (including `relay wait`), MCP server | none | 200 `{item, events}`, or 404 |
| `POST /asks/{id}/resolve` | app (Done, Skip), CLI and MCP (`done`, `skip`) | `{verdict, actor, note?}`: `verdict` is `done` or `declined`; `actor` is `owner` from the app and `session` from the CLI and MCP server | 200 `{item}` |
| `POST /asks/{id}/reopen` | app (Reopen in Closed today) | `{actor}`: always `owner` | 200 `{item}`, or 404 |
| `POST /asks/{id}/reply` | app (Reply, reply choices) | `{text}` | 200 `{item}` |
| `POST /asks/{id}/answers` | app (Send answers) | `{"answers": [...]}`: 1 to 20 of `{"step": "3.2", "picked": ["Staging"]}` or `{"step": "4", "text": "..."}` | 200 `{item}`; 409 when the ask is closed |
| `GET /events` | `relay replies` | `after=<seq>`, `limit=1000` | 200 `{events, next, epoch?}`: events with `seq > after`, ascending; `next` is the last seq returned, or `after` |
| `GET /version` | app (on connect, then at most every 30 minutes; Settings › Queue › Check), `relay post` and `relay_post` (before an instructable with `question`, `blocking` or `warning`; cached for 5 minutes) | none | 200 `{"service": "mailbox", "version": "<string>", "protocol": <int>}`; a 404 is level 1 to the app and unknown to the CLI and MCP server ([below](#protocol-levels)) |

## Protocol levels

`GET /version` names the mailbox's protocol level in `protocol`. It is authenticated like every other route. Hook 0.9.1 uses level 4.

| Level | Adds |
|---|---|
| 1 | asks, events, resolve, reply, reopen (a mailbox without `/version`) |
| 2 | step `question` and `POST /asks/{id}/answers` (Hook 0.7) |
| 3 | the `blocking` and `warning` step keys (Hook 0.9) |
| 4 | the `optional` step key, and file links: the `file` step key and a link's `path` (Hook 0.9.1) |

A mailbox that adds a level answers the higher number; one that doesn't change the protocol keeps its level whatever its own `version` says. In This Mac mode the app answers `GET /version` itself with its own level ([Local API](local-api.md)).

How each side reads an answer it can't use:

| `GET /version` answers | The app | The CLI and MCP server |
|---|---|---|
| 200 with an integer `protocol` of 1 or more | that level | that level |
| 404 (no such route) | level 1: an older mailbox, so the Notice and the update check apply | unknown: post as before and let the mailbox validate |
| 200 without such a `protocol` | a failed check: no Notice, and Settings shows "Couldn't check" | unknown: post as before |

The CLI and MCP server refuse an instructable only when the mailbox reports a level below what one of its keys needs.

## What the service should do

- **Post.** If an open ask with the same context and title was created in the last 24 h, return it with `deduped: true`. `openUrl` is optional; the CLI prints it.
- **Resolve.** Set the item's `status` to `done` or `dismissed`, and add a `resolved` or `declined` event with the given actor.
- **Reopen.** Set a `done` or `dismissed` item back to `open`, clear `completedAt`, and add a `reopened` event with actor `owner`. Reopening an open ask changes nothing but still answers 200 with the item.
- **Reply.** Add a `reply` event with actor `owner`.
- **Answers.** Answer 404 for an unknown ask, then 409 `{"error": "ask is closed"}` unless the ask is open, then 400 `{"error": "invalid answers", "details": [...]}` when an answer doesn't fit its step's question. Otherwise add one `answer` event per answer (actor `owner`) in one transaction and leave the ask open. A later answer for the same step replaces the earlier one: the latest event wins, and the earlier ones stay in the log.
- **Epoch.** Optional string. Change it when the event sequence restarts, so `relay replies` resets its cursors.

## Updating the mailbox

**What Hook checks.** The app reads `GET /version` when it connects to the mailbox, when you switch to another one, and then at most every 30 minutes while it is reachable. Settings › Queue › Connection shows the mailbox's version and level, then ✓ or "Needs an update", with **Check** to read it again.

- **Older than Hook** (a level below Hook's): the panel says which features won't work ("per-step answers", "blocking steps", "optional steps", "file links") until the mailbox is updated, with **Update Mailbox…** and **How to update** (this section).
- **Newer than Hook** (a level Hook doesn't know): the panel says Hook is older, with **Check for Updates**.
- **Before Hook updates itself.** A release's notes carry a hidden `<!-- hook:mailbox-protocol=N -->` marker: the level that release needs. When the connected mailbox is below it, the update dialog says "Hook X needs mailbox level N; yours is M." and offers **Update Mailbox First**, **Update Hook Anyway** and **Cancel**. When that check fails, the dialog says "Hook couldn't check your mailbox" and still offers **Update Hook Anyway**. This Mac mode always passes.

**Update Mailbox…** sits in the menu-bar menu next to Check for Updates… and in the panel's Notice. It runs the command in Settings › Queue › Mailbox › Update command (`mailboxUpdateCommand` in [config.json](configuration.md)) in a new window of your Resume terminal, through your login shell, so you see its output and answer any ssh or sudo prompt there. When the command ends, the window waits for Return and Hook reads the version again. Without a command, Update Mailbox… opens this section.

The command is yours: whatever pulls the new mailbox and restarts it. For example, a mailbox run with Docker Compose on another machine:

```
ssh mailbox-host 'cd /srv/mailbox && git pull && docker compose up -d --build'
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

Without `payload.instructable`, an item is shown from `payload.why`, `payload.cmd`, `payload.link` and the text of its `steps` events.

## Events

An event is `{seq, itemId, kind, actor, text, at}`; `seq` is an integer that only grows.

- An owner's action has actor `owner` and kind `resolved`, `declined`, `reply` or `answer`.
- `answer` (actor `owner`): the answer to one step's question. Its `text` is compact JSON with `step` first: `{"step":"3.2","picked":["Staging"]}` for a choice question (picks in the order of the choices), `{"step":"4","text":"Use the EU region"}` for a free-text one. A step path is `"3"` or `"3.2"`, 1-based.
- An ask closed by an agent has actor `session`.
- `reopened` (actor `owner`): the ask is open again, and no client shows it closed until a later `resolved` or `declined`.

## Timestamps

UTC, ISO 8601 with an offset: `2026-10-11T09:30:00+00:00`.
