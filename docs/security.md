# Security model

What Hook protects, and how. To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## The queue and the network

- In This Mac only mode, the queue never leaves the Mac: asks, answers and replies stay in Hook's folder. Hook still talks to GitHub over https, with no account or cookies, for updates and crash issues:
  - **Updates.** A minute after launch, then once a day, and when you choose **Check for Updates…**, Hook asks `api.github.com` for the latest release of `xooxoxxo/hook`. The request carries only Hook's version, in its `User-Agent` (`Hook/<version>`). Hook downloads the release's zip and `SHA256SUMS` from `github.com` only when you choose **Update Hook to X.Y.Z…**.
  - **Crash issues.** When you open **Send a Crash Report** with GitHub as the target, Hook searches the repository's issues on `api.github.com` once. It sends the crash's signature (a 12-character hash) with the `User-Agent` `Hook`. The report goes to GitHub only if you submit the issue in your browser.
  - Like any web request, both show GitHub your IP address.
- The listener binds only `127.0.0.1`. Every API call needs the 256-bit token, kept `0600` in a `0700` folder. That keeps other user accounts out. A process running as you can read the token and the queue, but it has your rights anyway.
- The Pond token and every ask travel with each request. So use an https `mailboxURL`, unless the Pond is only on a private, encrypted network such as a VPN. Hook never follows a Pond redirect.

## Who can answer

Agents can post, read and close asks. Only the app can record owner answers. Clients show who closed an ask (`by owner` or `by session`).

## Corrections

A session can correct an open ask it posted. Hook shows nothing from a corrected ask until it has checked the whole history.

- Every revision is hashed and names the previous one's hash. Hook recomputes each hash, needs every revision from 1 up, and remembers every hash it has seen on this Mac. A history that fails a check, loses a revision or goes back locks the ask with a red Notice, until you [trust it again](using.md#corrected-asks).
- A correction you haven't accepted locks the ask: no copy, links, files, ticks, answers or Done. Skip always works. Accepting a changed command, link or file needs Touch ID or your password.
- Done and answers name the revision you saw, so the Pond can't apply them to another one. Skip names none, so it works on any version.
- Hook seals what you accepted and the hashes it has seen in `reviews.json`, with a Keychain key ("Hook review seal"). Hook reads that key only when `reviews.json` names it. A process running as you that can read that key, or rewrite both, can still forge them: see [Keychain items](../SECURITY.md#keychain-items).
- Edit keys stay on the posting Mac. The Pond stores only their hashes.

## The owner key

- Each Mac makes its own 32-byte key in the Keychain. The Pond stores only its SHA-256, and only after you approve the Mac on Telegram with the code Hook shows.
- The key goes only over https (or plain http to this Mac itself), and only to the scheme it was set up on.
- With **Require the owner key** on, sessions and scripts can't answer, press Done or reopen as you. Accepting a correction always needs the key.

[SECURITY.md](../SECURITY.md#threat-model) lists what Hook doesn't defend against, and the Keychain limits of today's ad-hoc signed builds.

## Browsers

The Host check stops DNS rebinding. Hook rejects requests with `Origin` or a cross-site `Sec-Fetch-Site`, and never sends CORS headers.

## Port squatting

Another user can't bind the port while Hook holds it. Clients check the [server proof](local-api.md#server-proof) before they send the token. That leaves only the milliseconds between proof and request.

## Files

- Files are `0600` from the moment they are created, in `0700` folders. An existing folder that holds a custom `$RELAY_CONFIG` is left as it is.
- Hook and the clients refuse a config, token or queue folder that another user owns or can write to. They also refuse any file there that isn't a regular file you own.

## Logs and display

- Hook's [activity log](privacy.md#the-activity-log) records typed events only, never ask ids, ask contents, tokens or hook prompts. Error messages are redacted. A crash report is redacted again before Hook shows or sends it.
- Ask text shows hidden characters as `⟨U+XXXX⟩`. Links show their real host, with a warning for non-ASCII hosts.
- The validator [refuses secrets](instructables.md#secrets-are-refused), and hidden characters that could disguise them.
