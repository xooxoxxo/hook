# Hook

Hook (formerly Relay) is a macOS menu-bar inbox for Claude Code. When a session needs a key, a decision or a manual step, it lands here as a checklist you tick off.

[![CI](https://github.com/xooxoxxo/hook/actions/workflows/ci.yml/badge.svg)](https://github.com/xooxoxxo/hook/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<!-- screenshot: docs/assets/sidebar.png -->

How an ask goes:

- Your session posts an ask: numbered steps with copy-paste commands.
- You follow it in the sidebar and press Done, Skip or Reply.
- The session carries on with your answer.

Runs entirely on your Mac by default. Optional [Pond mode](docs/mailbox-protocol.md) forwards asks to you when you are away from it: the Pond (formerly called the mailbox) is a small server you run.

For people who run Claude Code on a Mac and want one place to answer what their sessions are waiting on.

## Quick start

You need macOS 14+, Python 3.9+ and Claude Code (the `claude` command). Nothing is compiled on your Mac.

```bash
curl -fsSL https://raw.githubusercontent.com/xooxoxxo/hook/main/scripts/get.sh | bash
```

It downloads the latest release, checks it against the release's `SHA256SUMS`, and installs Hook.app to `~/Applications` and the `relay` command, MCP server and skill to `~/.local/share/hook`. Installer options go after `bash -s --`, for example `| bash -s -- --local`. Hook then updates itself (Check for Updates…).

Use this command rather than downloading the zip in a browser: macOS blocks a browser download of a build that isn't notarized. To build from source instead, see [development.md](docs/development.md#build-from-source).

1. Right-click the menu-bar icon, choose Settings… › Connect › Copy CLAUDE.md section, and paste it into `~/.claude/CLAUDE.md`. This teaches your sessions to ask through Hook.
2. In Settings › Queue, click Send a test ask. A badge appears on the menu-bar icon; open the ask and press Done.

## Documentation

| I want to | Page |
|---|---|
| Install, update, uninstall | [install.md](docs/install.md) |
| Use the sidebar and shortcuts | [using.md](docs/using.md) |
| Connect Claude Code (MCP, CLI, hook) | [claude-code.md](docs/claude-code.md) |
| Write an ask | [instructables.md](docs/instructables.md) |
| Fix a problem | [troubleshooting.md](docs/troubleshooting.md) |
| Contribute | [CONTRIBUTING.md](CONTRIBUTING.md) |

Everything else: [docs/](docs/README.md).

## License

MIT. See [LICENSE](LICENSE).
