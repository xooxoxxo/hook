# Mailbox protocol

What Relay sends to a mailbox service you run, and what it reads back. Relay includes no mailbox server.

The app polls every `pollSeconds` (15 by default); the CLI and MCP server use the same routes.

## Requests

Every request carries `Authorization: Bearer <token>`, the token being the content of `tokenFile`. Bodies are JSON (`Content-Type: application/json`).

| Request | Sent by | Body or query | Relay expects |
|---|---|---|---|
| `POST /asks` | CLI, MCP server, Settings › Queue test ask | `{project, context, instructable}`; `context` comes from the config (`"personal"` by default) | 201 or 200 `{item, deduped?, openUrl?}` |
| `GET /asks` | app, CLI, MCP server | `status=open`, `days=36500` | 200 `{items}`, newest first |
| `GET /asks` | app (Closed today) | `status=done` or `status=dismissed`, `days=14` | 200 `{items}`; Relay keeps those whose `completedAt` falls in its window |
| `GET /asks/{id}` | app, CLI (including `relay wait`), MCP server | none | 200 `{item, events}`, or 404 |
| `POST /asks/{id}/resolve` | app (Done, Skip), CLI and MCP (`done`, `skip`) | `{verdict, actor, note?}`: `verdict` is `done` or `declined`; `actor` is `owner` from the app and `session` from the CLI and MCP server | 200 `{item}` |
| `POST /asks/{id}/reopen` | app (Reopen in Closed today) | `{actor}`: always `owner` | 200 `{item}`, or 404 |
| `POST /asks/{id}/reply` | app (Reply, reply choices) | `{text}` | 200 `{item}` |
| `GET /events` | `relay replies` | `after=<seq>`, `limit=1000` | 200 `{events, next, epoch?}`: events with `seq > after`, ascending; `next` is the last seq returned, or `after` |

## What the service should do

- **Post.** If an open ask with the same context and title was created in the last 24 h, return it with `deduped: true`. `openUrl` is optional; the CLI prints it.
- **Resolve.** Set the item's `status` to `done` or `dismissed`, and add a `resolved` or `declined` event with the given actor.
- **Reopen.** Set a `done` or `dismissed` item back to `open`, clear `completedAt`, and add a `reopened` event with actor `owner`. Reopening an open ask changes nothing but still answers 200 with the item.
- **Reply.** Add a `reply` event with actor `owner`.
- **Epoch.** Optional string. Change it when the event sequence restarts, so `relay replies` resets its cursors.

## Responses

- `401`: token refused. `404`: no such ask.
- Other errors: `{"error": "<message>", "details": ["<field>: <problem>"]}`, shown to whoever made the call.
- A redirect (3xx) is an error and never followed.

## Items

Relay reads these item keys and ignores the rest.

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

- An owner's answer has actor `owner` and kind `resolved`, `declined` or `reply`.
- An ask closed by an agent has actor `session`. Clients show `by owner` or `by session`.
- `reopened` (actor `owner`): the ask is open again, and no client shows it closed until a later `resolved` or `declined`.

## Timestamps

UTC, ISO 8601 with an offset: `2026-10-11T09:30:00+00:00`.
