# Hook

Hook (formerly Relay) is a macOS menu-bar inbox for Claude Code. When a session needs a key, a decision or a manual step, it lands here as a checklist you tick off.

[![CI](https://github.com/xooxoxxo/hook/actions/workflows/ci.yml/badge.svg)](https://github.com/xooxoxxo/hook/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<!-- screenshot: docs/assets/sidebar.png -->

How an ask goes:

- Your session posts an ask: numbered steps with copy-paste commands.
- You follow it in the sidebar and press Done, Skip or Reply.
- The session carries on with your answer.

Runs entirely on your Mac by default. Optional [mailbox mode](docs/mailbox-protocol.md) forwards asks to you when you are away from it.

For people who run Claude Code on a Mac and want one place to answer what their sessions are waiting on.

## Quick start

Hook builds from source; there is no prebuilt download yet. You need:

- macOS 14.5+ to build
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.9+
- Claude Code (the `claude` command)

```bash
git clone https://github.com/xooxoxxo/hook.git
cd hook
./scripts/install.sh
```

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
