# Security model

What Relay protects, and how. To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## The queue and the network

- In This Mac only mode, Relay makes no outbound connections and the queue never leaves the Mac.
- The listener binds `127.0.0.1` only, and every API call needs the 256-bit token, kept `0600` in a `0700` folder. That separates user accounts; a process running as you can read the token and the queue, but it already has your privileges.
- The mailbox token and every ask travel with each request, so use an https `mailboxURL` unless the mailbox is only on a private, encrypted network such as a VPN. Relay never follows a mailbox redirect.

## Who can answer

Agents can post, read and close asks. Only the app can record owner answers. Clients show who closed an ask (`by owner` or `by session`).

## Browsers

The Host check stops DNS rebinding, requests with `Origin` or a cross-site `Sec-Fetch-Site` are rejected, and no CORS headers are ever sent.

## Port squatting

Another user can't bind the port while Relay holds it, and clients check the [server proof](local-api.md#server-proof) before sending the token. The remaining window is the milliseconds between proof and request.

## Files

- Files are created `0600` (never restricted afterwards) in `0700` folders. An existing folder holding a custom `$RELAY_CONFIG` is left as it is.
- Relay and the clients refuse a config, token or queue folder that another user owns or can write to, and any file there that isn't a regular file you own.

## Logs and display

- Logs carry ids and error categories only, never tokens, ask contents or hook prompts.
- Ask text shows hidden characters as `⟨U+XXXX⟩`. Links show their real host, with a warning for non-ASCII hosts.
- The validator [refuses secrets](instructables.md#secrets-are-refused) and hidden characters that could disguise them.
