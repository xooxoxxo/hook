# Security model

What Hook protects, and how. To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## The queue and the network

- In This Mac only mode, the queue never leaves the Mac: asks, answers and replies stay in Hook's folder. Hook still connects to GitHub, over https and without an account or cookies, to check for updates and to look up crash reports in its issues:
  - **Updates.** A minute after launch, then once a day, and when you choose **Check for Updates…**, Hook asks `api.github.com` for the latest release of `xooxoxxo/hook`. The request carries Hook's version in its `User-Agent` (`Hook/<version>`) and nothing else about you or your asks. Only when you choose **Update Hook to X.Y.Z…** does it download that release's zip and `SHA256SUMS` from `github.com`.
  - **Crash issues.** When you open **Send a Crash Report** with GitHub as the target, Hook searches the repository's issues once, on `api.github.com`, for the crash's signature: a 12-character hash, with the `User-Agent` `Hook`. The report itself goes to GitHub only if you submit the issue in your browser.
  - Like any web request, both show GitHub your IP address.
- The listener binds `127.0.0.1` only, and every API call needs the 256-bit token, kept `0600` in a `0700` folder. That separates user accounts; a process running as you can read the token and the queue, but it already has your privileges.
- The Pond token and every ask travel with each request, so use an https `mailboxURL` unless the Pond is only on a private, encrypted network such as a VPN. Hook never follows a Pond redirect.

## Who can answer

Agents can post, read and close asks. Only the app can record owner answers. Clients show who closed an ask (`by owner` or `by session`).

## Corrections

A session can correct an open ask it posted; Hook shows nothing from a corrected ask until it has checked the whole history.

- Every revision is hashed and names the previous one's hash. Hook recomputes each hash, needs every revision from 1 up, and remembers every hash it has seen on this Mac. A history that fails, loses a revision or goes back locks the ask with a red Notice until you [trust it again](using.md#corrected-asks).
- A correction you haven't accepted locks the ask: no copy, links, files, ticks, answers or Done. Skip always works. Accepting a change to a command, link or file needs Touch ID or your password.
- Done and answers name the revision you saw, so the Pond can't apply them to another. Skip names none, so it works whatever the version.
- What you accepted and the hashes Hook has seen are sealed in `reviews.json` with a key in the Keychain ("Hook review seal"), which Hook uses only when `reviews.json` names it. A process running as you that can read that key, or rewrite both, can still forge them: see [Keychain items](../SECURITY.md#keychain-items). Edit keys stay on the posting Mac; the Pond stores only their hashes.

## The owner key

- Each Mac makes its own 32-byte key in the Keychain; the Pond stores only its SHA-256, and only after you approve the Mac on Telegram with the code Hook shows.
- The key goes only over https (or plain http to this Mac itself), and only to the scheme it was set up on.
- With **Require the owner key** on, sessions and scripts can't answer, press Done or reopen as you. Accepting a correction always needs the key.

What Hook doesn't defend against, and the Keychain limits of today's ad-hoc signed builds, are in [SECURITY.md](../SECURITY.md#threat-model).

## Browsers

The Host check stops DNS rebinding, requests with `Origin` or a cross-site `Sec-Fetch-Site` are rejected, and no CORS headers are ever sent.

## Port squatting

Another user can't bind the port while Hook holds it, and clients check the [server proof](local-api.md#server-proof) before sending the token. The remaining window is the milliseconds between proof and request.

## Files

- Files are created `0600` (never restricted afterwards) in `0700` folders. An existing folder holding a custom `$RELAY_CONFIG` is left as it is.
- Hook and the clients refuse a config, token or queue folder that another user owns or can write to, and any file there that isn't a regular file you own.

## Logs and display

- Hook's [activity log](privacy.md#the-activity-log) records typed events only, never ask ids, ask contents, tokens or hook prompts, and error messages are redacted. A crash report redacts again before it is shown or sent.
- Ask text shows hidden characters as `⟨U+XXXX⟩`. Links show their real host, with a warning for non-ASCII hosts.
- The validator [refuses secrets](instructables.md#secrets-are-refused) and hidden characters that could disguise them.
