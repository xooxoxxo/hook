# Contributing

Issues and pull requests are welcome. For a large change, open an issue first.

1. Run the tests in [Development](docs/development.md) before opening a pull request.
2. Keep Python under `bin/`, `clients/` and `mcp/` compatible with Python 3.9 (`/usr/bin/python3`), standard library only.
3. Add no third-party Swift packages.

## Triaging crash reports

Hook's crash sheet searches the repo for an issue holding a report's `hook-crash-<signature>` line. It treats an open (or closed, unmilestoned) issue as the crash's home only when the owner, a member or a collaborator filed it, or when it carries the `crash-confirmed` label. When an issue from anyone else is a real report, check it and add `crash-confirmed`; the next person with that crash is then sent to it. A closed issue under a release milestone (such as `0.12.1`) counts as fixed in that release whoever filed it. Never add `crash-confirmed` to the issue template: template labels go on every issue.

Report security issues as [SECURITY.md](SECURITY.md) describes, not in a public issue.
