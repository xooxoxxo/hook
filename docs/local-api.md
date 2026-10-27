# Local API

In This Mac only mode, the CLI and MCP server use this API. You need it only to write your own client.

## Access

- Relay listens on `127.0.0.1:<port>` only (`port` in `config.json`, 47823 by default).
- Every request except `/health` and `/i/<id>` needs `Authorization: Bearer <token>`: the 64 hex characters in `local-token` next to `config.json` (created by Relay, `0600`).
- Bodies are JSON objects of at most 65536 bytes. `Transfer-Encoding` is refused.

Before checking anything else, Relay answers 403 `forbidden` to:
- a `Host` other than `127.0.0.1:<port>` or `localhost:<port>`;
- any request with an `Origin` header;
- a `Sec-Fetch-Site` other than `none`.

## Routes

| Route | Body or query | Success | Errors |
|---|---|---|---|
| `POST /asks` | `{project, instructable}` | 201 `{item, openUrl}`; 200 `{item, deduped: true, openUrl}` when the same project and title is already open (24 h) | 400 `missing fields`, `invalid instructable` or `invalid project` (+ `details`); 429 `queue full` (200 open asks); 500 `store failed` |
| `GET /asks` | `status` = `open` (default), `done`, `dismissed`, `all`; `days` 0–36500 (default 14) | 200 `{items}`, newest first | 400 `invalid query` |
| `GET /asks/{id}` | none | 200 `{item, events}` | 404 `not found` |
| `POST /asks/{id}/resolve` | `{verdict: "done"\|"declined", actor?: "session", note?}` | 200 `{item}` (unchanged if already finished) | 400 `invalid verdict`, `invalid actor`, `invalid note`; 403 `owner actions are app-only`; 404 |
| `GET /events` | `after` ≥ 0, `limit` 1–1000 (default 100) | 200 `{events, next, epoch}` | 400 `invalid query` |
| `GET /health` | optional `X-Relay-Nonce` header (32–64 hex) | 200 `{"ok":true,"app":"relay","source":"local"\|"mailbox"\|"none"}`, plus `proof` in local mode | none |
| `GET /i/<id>` | none | Brings Relay forward on that ask (`relay://i/<id>` does the same) | 403 for web-page requests |

The body format and the `project` rule are in [Instructable format](instructables.md).

## Owner answers

Only the app records owner answers: replies, Done and Skip, and per-step answers to questions. The API has no reply or answers route and refuses actor `owner`. `GET /asks/{id}` and `GET /events` include the `answer` events the app records (shape in [Mailbox protocol](mailbox-protocol.md#events)).

## Server proof

```
proof = hex(HMAC-SHA256(key: token, message: "relay-proof-v1\n" + <port> + "\n" + nonce))
```

`<port>` is the decimal port the request reached. The clients check the proof against the port they connected to before every call that carries the token, so a program squatting on the port, or relaying another port's proof, never gets it.
