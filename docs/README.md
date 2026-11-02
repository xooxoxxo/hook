# Hook documentation

Hook (formerly Relay) is a macOS menu-bar inbox for Claude Code asks. Start with Install, then Using Hook. Everything else is reference.

## Get started

- [Install](install.md): install, update, uninstall
- [Using Hook](using.md): sidebar, keys, Settings, corrected asks, the owner key
- [Claude Code](claude-code.md): MCP, `relay` command, hook, correcting an ask

## Reference

- [Instructable format](instructables.md): what an ask contains
- [Configuration](configuration.md): every config key
- [Troubleshooting](troubleshooting.md): not answering, port in use, `relay_post` missing
- [CLAUDE.md section](claude-md-section.md): copied by Settings › Connect

## Internals

- [Local API](local-api.md): for your own client
- [Pond protocol](mailbox-protocol.md): for your own Pond (formerly called the mailbox), the server that holds asks when you're away
- [Security model](security.md): what Hook protects; the threat model and residual risks are in [SECURITY.md](../SECURITY.md)
- [Development](development.md): build, test, layout
