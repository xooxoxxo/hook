# Development

Build Hook, run its tests and find your way around the code.

## Build and test

```bash
swift build && swift test                                   # RelayCore and RelayUI tests (Swift Testing)
python3 -m unittest discover -s clients -p 'test_*.py' -v   # CLI and client
python3 -m unittest discover -s mcp -p 'test_*.py' -v       # MCP server
BUILD_ONLY=1 ./scripts/build.sh                             # assembles ./build/Hook.app, installs nothing
./scripts/test-install.sh                                   # installer, in a sandbox HOME
./scripts/smoke-local.sh                                    # This Mac only, end to end
scripts/gallery.sh [scene…]                                 # renders the UI offscreen to build/gallery/
./scripts/check-tokens.sh                                   # no literal sizes, colours or durations outside Design/
```

Test-only switches:
- `RELAY_DATA_DIR` moves the app's queue folder.
- `RELAY_NO_AUTOLAUNCH=1` stops the `relay` CLI from starting Hook. The smoke run sets it, so it can't touch an installed app.
- `scripts/install.sh` honours `RELAY_SKIP_BUILD`, `RELAY_SKIP_LAUNCH` and `RELAY_SKIP_MCP` (see its header).

## Design gallery

`scripts/gallery.sh` renders every design-system component and screen offscreen,
in light and dark, into `build/gallery/` (git-ignored), with an `index.html` grid.
Nothing appears on screen. Pass scene names to render only those
(`scripts/gallery.sh components queue`), and these flags for the accessibility
variants, whose files get a `-contrast`, `-rt` or `-xl` suffix:

- `--contrast`: Increase Contrast.
- `--reduce-transparency`: the panel stand-in becomes opaque (see below).
- `--xl`: text 1.35× larger (macOS ignores Dynamic Type, so the gallery scales
  the DS text styles; stock controls that don't use a DS font or inherit the
  body font stay at their normal size).

Panel scenes paint a stand-in where the panel's sidebar material would be,
because the material doesn't render offscreen: the window background,
translucent over the gallery canvas, or opaque under `--reduce-transparency`,
as the real material falls back. `index.html` labels them "panel material:
stand-in". The real material follows the system setting, so a `-rt` PNG checks
only the opaque backdrop. So a pull request that changes
`Sources/RelayUI/` attaches before and after gallery PNGs of the scenes it
touches, plus one `screencapture -l <windowID>` of the running panel per theme.
Menus are checked with `screencapture -w`.

`scripts/check-tokens.sh` fails on literal sizes, colours, durations or custom
shapes outside `Sources/RelayUI/Design/`, and on switch toggles or Liquid Glass
calls anywhere; CI runs it with its self-test.

### Review rule

A pull request that changes `Sources/RelayUI/` attaches the before and after PNGs of every scene it touches (`scripts/gallery.sh <scene…>`, light and dark), plus one `screencapture -l <windowID>` of the running panel per theme over a real desktop. Menus (the queue menu, the row context menu, the menu-bar menu) are checked with `screencapture -w`. `./scripts/check-tokens.sh` must print nothing: outside `Sources/RelayUI/Design/`, no literal sizes, colours, durations or shapes.

## CI

[CI](../.github/workflows/ci.yml) runs on pushes to `main` and on pull requests. It builds, runs the Swift, client and MCP tests (again on `/usr/bin/python3` if it is 3.9+), and runs the installer tests.

## Releasing

1. **Version.** Bump it in the three places that carry it: `CFBundleShortVersionString` and
   `CFBundleVersion` in `Resources/Info.plist`, `VERSION` in `clients/relay_client.py`, and the
   `relay --version` row in [docs/claude-code.md](claude-code.md). Hook's version stays 0.x.
2. **CHANGELOG.** Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and read it as release
   notes: one line per change a user would notice, under Added, Changed and Fixed.
3. **Privacy scan.** The repository is public. Read the diff since the last tag
   (`git diff vX.Y.Z-1..HEAD`) for personal names, home-folder paths (`/Users/<name>`), host
   names, internal ticket ids and tokens, and remove any you find.
4. **CI.** Push the release commit and wait for [CI](../.github/workflows/ci.yml) to pass on it.
5. **Tag.** `git tag vX.Y.Z` on that commit and push the tag. Hook's updater moves a checkout to
   the latest release tag, so tag only a commit that passed CI.
6. **Release notes.** Create the GitHub release for the tag with that version's CHANGELOG
   section as its notes. Every release's notes carry the hidden marker
   `<!-- hook:mailbox-protocol=N -->`, where N is the mailbox protocol level that release needs
   (4 from 0.9.1; see [Mailbox protocol](mailbox-protocol.md#protocol-levels)). Before updating,
   Hook compares N with the connected mailbox's level and offers to update the mailbox first.
   Raise N only when the release needs a mailbox feature older mailboxes lack.

## Layout

```
Sources/Relay/         AppKit shell: panel window, menu bar, notifications, Settings and setup windows, loopback server
Sources/RelayCore/     queue, validator, config, mailbox client, and the panel's pure logic
Sources/RelayUI/       design tokens and components, the Store, every SwiftUI surface
Sources/RelayGallery/  offscreen renderer for the gallery (never bundled)
Tests/              Swift tests and fixtures
clients/  mcp/      relay CLI and MCP server, with tests
bin/relay           CLI entry point
schema/  skill/     instructable schema, Claude Code skill
scripts/            build, install, test
```

`Tests/RelayCoreTests/Fixtures/instructable-vectors.json` is the validator's source of truth. The validator tests run against it. It is maintained by hand, except the `optional-*` and `file-*` cases, which the mailbox's reference validator generates; the tests check those cases' error order too.

## Vendored viewer scripts

The document viewer's marked and DOMPurify live in `Sources/RelayUI/Resources/Viewer/` (a SwiftPM resource of RelayUI; `scripts/build.sh` copies the folder into `Hook.app/Contents/Resources/Viewer`). They are the unmodified browser builds from the npm tarballs; [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) lists the versions, the tarball integrity hashes and how to update them. The gallery's `viewer-*` scenes render the viewer with WebKit's own snapshot.
