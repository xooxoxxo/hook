# Hook documentation

Hook (formerly Relay) is a macOS menu-bar inbox for the asks of your coding agents. Start with Install, then Using Hook. Everything else is reference.

## Get started

- [Install](install.md): install, update, uninstall
- [Using Hook](using.md): sidebar, keys, Settings, talking to the session, crash reports, corrected asks, the owner key
- [Agents](agents.md): what Hook sets up in each agent, `relay integrations`, the MCP tools and `relay` command, correcting an ask
- [Claude Code](claude-code.md): the Hook plugin, the rules file, moving from the CLAUDE.md section

## Reference

- [Instructable format](instructables.md): what an ask contains
- [Configuration](configuration.md): every config key
- [Troubleshooting](troubleshooting.md): not answering, port in use, `relay_post` missing, edited or blocked agent files, logs and crashes
- [Privacy](privacy.md): the activity log, crash reports and where they go

## Internals

- [Local API](local-api.md): for your own client
- [Pond protocol](mailbox-protocol.md): for your own Pond (formerly called the mailbox), the server that holds asks when you're away
- [Security model](security.md): what Hook protects; the threat model and residual risks are in [SECURITY.md](../SECURITY.md)
- [Development](development.md): build, test, layout
