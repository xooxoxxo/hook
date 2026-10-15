# Security model

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## The queue and the network

- In "This Mac only" mode Relay makes no outbound connections. The queue never leaves
  the Mac.
- The listener binds `127.0.0.1` only, and every API call needs the 256-bit token. The
  token file is `0600` in a `0700` folder, which separates user accounts. A process
  running as the same user can read it, and could edit the queue file too. Such a
  process already has your privileges.
- Use an https `mailboxURL` unless the mailbox is reachable only over a private,
  encrypted network such as a VPN: the bearer token and every ask travel with each
  request. Relay never follows a redirect from the mailbox, so the token only reaches
  the configured address.

## Who can answer

- Agents can post, read and close asks, but can't record owner answers through the
  API. Clients always show who closed an ask (`by owner` or `by session`).

## Browsers

- Browsers are refused. The Host check stops DNS rebinding, requests with `Origin` or
  a cross-site `Sec-Fetch-Site` are rejected, and no CORS headers are ever sent.

## Port squatting

- Another user can't bind the port while Relay holds it, and clients check the server
  proof before sending the token (see [Local API](local-api.md#server-proof)). The
  remaining window is the milliseconds between the proof and the request.

## Files

- Files are created `0600` (never restricted afterwards) in `0700` folders.
- An existing folder holding a custom `$RELAY_CONFIG` is left as it is. Relay and the
  clients refuse a config, token or queue folder that another user owns or can write
  to, and a file there that isn't a regular file you own.

## Logs and display

- Logs carry ids and error categories only, never tokens, ask contents or hook prompts.
- Every string from an ask is shown with hidden characters made visible (`⟨U+XXXX⟩`).
  Links show their real host, with a warning for non-ASCII hosts.
- The validator rejects strings that look like secrets, and hidden characters that
  could disguise them (see the [instructable format](../README.md#instructable-format)).
