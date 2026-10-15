# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub private vulnerability
reporting: open the repo's **Security** tab and choose **Report a vulnerability**.
Don't open a public issue for a security problem.

Include what you found, how to reproduce it, and the Relay version (`relay --version`).

## Scope

- The app's loopback API on `127.0.0.1`, including the Host, Origin and server-proof
  checks.
- Token handling: the local token, the mailbox token file and file permissions.
- The clients: the `relay` CLI and the MCP server.
- The installer, `scripts/install.sh`.

The design is described in [docs/security.md](docs/security.md).

## Supported versions

Fixes go into the latest release.
