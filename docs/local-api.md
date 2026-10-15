# Local API

In "This Mac only" mode, Relay serves the queue itself. The `relay` CLI and the MCP
server talk to this API; you only need it to write your own client.

Relay listens on `127.0.0.1:<port>` only (`port` in `config.json`, 47823 by default).
Every request except `/health` and `/i/<id>` needs `Authorization: Bearer <token>`,
where the token is the 64 hex characters in `local-token` next to `config.json`
(created by Relay, mode `0600`).

Before checking anything else, Relay answers 403 `forbidden` to:
- a `Host` other than `127.0.0.1:<port>` or `localhost:<port>`;
- any request with an `Origin` header;
- a `Sec-Fetch-Site` other than `none`.

Bodies are JSON objects of at most 65536 bytes. `Transfer-Encoding` is refused.

## Routes

| Route | Body or query | Success | Errors |
|---|---|---|---|
| `POST /asks` | `{project, instructable}` | 201 `{item, openUrl}`; 200 `{item, deduped: true, openUrl}` when the same project and title is already open (24 h) | 400 `missing fields`, `invalid instructable` or `invalid project` (+ `details`); 429 `queue full` (200 open asks); 500 `store failed` |
| `GET /asks` | `status` = `open` (default), `done`, `dismissed`, `all`; `days` 0–36500 (default 14) | 200 `{items}`, newest first | 400 `invalid query` |
| `GET /asks/{id}` | — | 200 `{item, events}` | 404 `not found` |
| `POST /asks/{id}/resolve` | `{verdict: "done"\|"declined", actor?: "session", note?}` | 200 `{item}` (unchanged if already finished) | 400 `invalid verdict`, `invalid actor`, `invalid note`; 403 `owner actions are app-only`; 404 |
| `GET /events` | `after` ≥ 0, `limit` 1–1000 (default 100) | 200 `{events, next, epoch}` | 400 `invalid query` |
| `GET /health` | optional `X-Relay-Nonce` header (32–64 hex) | 200 `{"ok":true,"app":"relay","source":"local"\|"mailbox"\|"none"}`, plus `proof` in local mode | — |
| `GET /i/<id>` | — | Brings Relay forward on that ask (`relay://i/<id>` does the same) | 403 for web-page requests |

The instructable format and the `project` rule are in the
[README](../README.md#instructable-format).

## Owner answers

Owner answers (Done, Skip and Reply in the sidebar) are recorded by the app only. The
API has no reply route and refuses actor `owner`.

## Server proof

`proof` is:

```
hex(HMAC-SHA256(key: token, message: "relay-proof-v1\n" + <port> + "\n" + nonce))
```

`<port>` is the decimal port of the listener the request reached. The bundled clients
check the proof, with the port they connected to, before every call that carries the
token. A program squatting on the port, or relaying a proof from another port, never
receives the token.
