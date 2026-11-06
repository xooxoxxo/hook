# Synthetic session delivery proof

This opt-in experiment delivers fixed synthetic messages to a disposable Codex
app-server runtime that it creates itself. It never attaches a user chat, reads
Hook events or installs a channel. Its fixed prompts ask for text replies without tools.

Run with Python 3.9+ and an already installed, authenticated Codex binary:

```sh
python3 experiments/session-delivery/proof.py --live-codex /absolute/path/to/codex
```

A live run uses model calls and the CLI's existing configuration/authentication.
It creates a temporary working directory, requests a read-only sandbox and no
approvals, and refuses server requests for approval. This is not a tool-free sandbox: the CLI's existing configuration still applies. The successful run archives
its disposable chat. A failed run may leave that chat in the CLI's history.
Do not attach this adapter to an existing desktop runtime or start a second
runner for an existing user chat.

## Observed result

Tested on 2026-11-06 with Codex CLI 0.165.0-alpha.1.2:

| Case | Result |
| --- | --- |
| Idle session receives a new turn | Acknowledged with the synthetic marker |
| Repeated event | Suppressed by the adapter, no second turn |
| New adapter on the same runtime | Acknowledged |
| Active turn receives `turn/steer` | Acknowledged; exact expected turn supplied |
| Runtime stopped, restarted and thread resumed | Acknowledged |
| Existing desktop chat attachment | **Not demonstrated** |

CI tests cover wrong recipients, non-synthetic inputs, duplicate events, missing
acknowledgments, ambiguous sends and the expected-turn constraint without making
model calls. These test the adapter's restrictions, not the authenticity of real
Hook events. The `synthetic` argument is not a signature check.

The proof stores deduplication records in memory shared between adapters. They
survive the runtime restart in this test, not a broker process crash. A pending
send is deliberately not retried: transport acceptance is not proof of processing.
The proof does not claim exactly-once execution or Codex-native deduplication.
A steer that races a completed turn fails instead of silently creating a new turn.

## What this establishes

A managed Codex app-server can run work while idle when its controller explicitly
starts a turn. An idle desktop chat is not thereby a background runner. A separate
app-server is not evidence that the desktop app exposes the same live session.
Use the host's supported delivery interface; do not duplicate a runtime to simulate
waking its desktop chat.

The next production layer needs durable event IDs, recipient registration, verified
owner events, acknowledgment reconciliation, bounded retries and a single delivery
owner per runtime. Use the existing Hook/Pond event store rather than adding Redis
for this proof. Empty polls should not start model turns. Peer messages must never
count as owner approval. File leases are cooperative; worktrees still isolate edits.

Claude Channels are a separate, opt-in transport and were not enabled or tested
here. Remote Control connects a human to a running Claude session; it is not a
cross-agent event bus. Other agents need their own documented host adapter.

References: [Codex app-server](https://learn.chatgpt.com/docs/app-server),
[Claude Channels](https://code.claude.com/docs/en/channels),
[Claude Remote Control](https://code.claude.com/docs/en/remote-control).
