# Mailbox protocol

Relay does not include a mailbox server. Mailbox mode is for a service you run that
speaks this protocol. This page lists only what Relay sends and what it reads.

In mailbox mode the app polls the service every `pollSeconds` (15 by default). The
`relay` CLI and the MCP server use the same routes.

## Requests

Every request carries `Authorization: Bearer <token>`, where the token is the content
of the file named by `tokenFile`. Request bodies are JSON with
`Content-Type: application/json`.

| Request | Sent by | Body or query | Relay expects |
|---|---|---|---|
| `POST /asks` | CLI, MCP server, Settings › Queue test ask | `{project, context, instructable}`; `context` comes from the config (`"personal"` by default) | 201 or 200 `{item, deduped?, openUrl?}` |
| `GET /asks` | app, CLI, MCP server | `status=open`, `days=36500` | 200 `{items}`, newest first |
| `GET /asks` | app (Closed today) | `status=done` or `status=dismissed`, `days=14` | 200 `{items}`; Relay keeps those whose `completedAt` falls in its window |
| `GET /asks/{id}` | app, CLI (including `relay wait`), MCP server | — | 200 `{item, events}`, or 404 |
| `POST /asks/{id}/resolve` | app (Done, Skip), CLI and MCP (`done`, `skip`) | `{verdict, actor, note?}`: `verdict` is `done` or `declined`; `actor` is `owner` from the app and `session` from the CLI and MCP server | 200 `{item}` |
| `POST /asks/{id}/reopen` | app (Reopen in Closed today) | `{actor}`: always `owner` | 200 `{item}`, or 404 |
| `POST /asks/{id}/reply` | app (Reply, reply choices) | `{text}` | 200 `{item}` |
| `GET /events` | `relay replies` | `after=<seq>`, `limit=1000` | 200 `{events, next, epoch?}`: events with `seq > after`, ascending; `next` is the last seq returned, or `after` |

What the service should do:
- **Post:** when an open ask with the same context and title was created in the last
  24 h, return it with `deduped: true` instead of adding a new one. `openUrl` is
  optional; the CLI prints it when present.
- **Resolve:** set the item's `status` to `done` or `dismissed`, and add a `resolved`
  or `declined` event with the given actor.
- **Reopen:** set a `done` or `dismissed` item back to `open`, clear `completedAt`, and
  add a `reopened` event with actor `owner`. Reopening an open ask changes nothing and
  adds no event; it still answers 200 with the item.
- **Reply:** add a `reply` event with actor `owner`.
- **Epoch:** an optional string. Change it whenever the event sequence restarts, so
  `relay replies` resets its cursors.

Responses:
- `401` means the token was refused.
- `404` means no such ask.
- For other errors, return `{"error": "<message>", "details": ["<field>: <problem>"]}`.
  Relay shows `error` and `details` to the person or agent that made the call.
- A redirect (3xx) is treated as an error and never followed.

## Items

Relay reads these item keys. Other keys are ignored.

| Key | Meaning |
|---|---|
| `id` | String id, used in every `/asks/{id}` route |
| `title` | The ask's title |
| `status` | `open`, `done` or `dismissed` |
| `projectId` | The `project` the ask was posted with |
| `created`, `updated` | Timestamps |
| `completedAt` | When the ask was closed; null while it is open |
| `payload.instructable` | The instructable as posted (see the [format](../README.md#instructable-format)) |

An item without `payload.instructable` is shown from `payload.why`, `payload.cmd` and
`payload.link`, plus the text of its `steps` events. Other payload keys are ignored.

## Events

`{seq, itemId, kind, actor, text, at}`. `seq` is an integer that only grows.

An owner's answer is an event with actor `owner` and kind `resolved`, `declined` or
`reply`. An ask closed by an agent has actor `session`. Clients show which one closed
the ask (`by owner` or `by session`).

`reopened` (actor `owner`) means the owner took back a close: the ask is open again,
and no client shows it as closed until a later `resolved` or `declined`.

## Timestamps

UTC, ISO 8601 with an offset: `2026-10-11T09:30:00+00:00`.
