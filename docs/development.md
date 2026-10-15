# Development

Build Relay, run its tests and find your way around the code.

## Build and test

```bash
swift build && swift test                                   # RelayCore tests (Swift Testing)
python3 -m unittest discover -s clients -p 'test_*.py' -v   # CLI and client
python3 -m unittest discover -s mcp -p 'test_*.py' -v       # MCP server
BUILD_ONLY=1 ./scripts/build.sh                             # assembles ./build/Relay.app, installs nothing
./scripts/test-install.sh                                   # installer, in a sandbox HOME
./scripts/smoke-local.sh                                    # This Mac only, end to end
```

Test-only switches:
- `RELAY_DATA_DIR` moves the app's queue folder.
- `RELAY_NO_AUTOLAUNCH=1` stops the `relay` CLI from starting Relay. The smoke run sets it, so it can't touch an installed app.
- `scripts/install.sh` honours `RELAY_SKIP_BUILD`, `RELAY_SKIP_LAUNCH` and `RELAY_SKIP_MCP` (see its header).

## CI

[CI](../.github/workflows/ci.yml) runs on pushes to `main` and on pull requests. It builds, runs the Swift, client and MCP tests (again on `/usr/bin/python3` if it is 3.9+), and runs the installer tests.

## Layout

```
Sources/Relay/      app, Settings, loopback server
Sources/RelayCore/  queue, validator, config, mailbox client
Tests/              Swift tests and fixtures
clients/  mcp/      relay CLI and MCP server, with tests
bin/relay           CLI entry point
schema/  skill/     instructable schema, Claude Code skill
scripts/            build, install, test
```

`Tests/RelayCoreTests/Fixtures/instructable-vectors.json` is the validator's source of truth. The validator tests run against it, and it is maintained by hand.
