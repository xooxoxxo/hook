# Local API

The CLI and MCP server use this API in This Mac only mode. Read on only to write your own client.

## Access

- Hook listens only on `127.0.0.1:<port>` (`port` in `config.json`, 47823 by default).
- Every request except `/health` and `/i/<id>` needs `Authorization: Bearer <token>`: the 64 hex characters in `local-token` next to `config.json` (created by Hook, `0600`).
- Bodies are JSON objects of at most 65536 bytes. `Transfer-Encoding` is refused.

Before any other check, Hook answers 403 `forbidden` to:
- a `Host` other than `127.0.0.1:<port>` or `localhost:<port>`;
- any request with an `Origin` header;
- a `Sec-Fetch-Site` other than `none`.

## Routes

| Route | Body or query | Success | Errors |
|---|---|---|---|
| `POST /asks` | `{project, instructable}` | 201 `{item, openUrl}`. 200 `{item, deduped: true, openUrl}` when the same project and title is already open (24 h) | 400 `missing fields`, `invalid instructable` or `invalid project` (+ `details`). 429 `queue full` (200 open asks). 500 `store failed` |
| `GET /asks` | `status` = `open` (default), `done`, `dismissed`, `all`; `days` 0–36500 (default 14) | 200 `{items}`, newest first | 400 `invalid query` |
| `GET /asks/{id}` | none | 200 `{item, events}` | 404 `not found` |
| `POST /asks/{id}/resolve` | `{verdict: "done"\|"declined", actor?: "session", note?}` | 200 `{item}` (unchanged if already finished) | 400 `invalid verdict`, `invalid actor`, `invalid note`. 403 `owner actions are app-only`. 404 |
| `GET /events` | `after` ≥ 0, `limit` 1–1000 (default 100) | 200 `{events, next, epoch}` | 400 `invalid query` |
| `GET /version` | none | 200 `{"service": "hook", "version": "1.0.0", "protocol": 4}`: the Pond version the built-in queue implements (no step corrections yet). A client checks This Mac like a Pond | 401 |
| `GET /health` | optional `X-Relay-Nonce` header (32–64 hex) | 200 `{"ok":true,"app":"relay","source":"local"\|"mailbox"\|"none"}`, plus `proof` in local mode | none |
| `GET /i/<id>` | none | Brings Hook forward on that ask (`hook://i/<id>` does the same; `relay://i/<id>` still works) | 403 for web-page requests |

Hook registers `hook://` and keeps `relay://`. If another app owns `hook://` on your Mac (Hookmark does), use `relay://`.

The body format and the `project` rule are in [Instructable format](instructables.md).

This Mac's queue takes no requirements before Done (Pond 1.3.0's `required` step key and `done` list). `relay post` and `relay_post` refuse them before posting: "Hook's This Mac queue (Pond 1.0.0) can't take `required` yet." `POST /asks` answers 400 `invalid instructable` for either one, as an unknown key. Post without them, and say in the step's `warning` that it must be done before Done.

## Owner answers

Only the app records owner answers: replies, Done and Skip, and answers to step questions. The API has no reply or answers route and refuses actor `owner`. `GET /asks/{id}` and `GET /events` include the app's `answer` events (shape in [Pond protocol](mailbox-protocol.md#events)).

## Server proof

```
proof = hex(HMAC-SHA256(key: token, message: "relay-proof-v1\n" + <port> + "\n" + nonce))
```

`<port>` is the decimal port the request reached. Before every call that carries the token, the clients check the proof against the port they connected to. A program squatting on the port, or passing on another port's proof, never gets the token.

The version response advertises `capabilities: ["ask-warning"]` when the local queue supports ask-wide warnings. This does not imply support for other newer Pond features.
