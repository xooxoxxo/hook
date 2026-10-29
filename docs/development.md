# Development

Build Hook, run its tests and find your way around the code.

## Build from source

A clone you build yourself is a developer checkout:

```bash
git clone https://github.com/xooxoxxo/hook.git
cd hook
HOOK_DEV=1 ./scripts/install.sh
```

`install.sh` builds Hook from source only in a developer's clone: `HOOK_DEV=1`, changes that aren't committed, or a local branch other than `main`. In any other clone it installs the prebuilt release of the clone's version instead (that is how 0.9.x's updater moves a clone install to the release download), and builds from source only when that download fails. Building needs macOS 14.5+ and the Command Line Tools with Swift 6 (`xcode-select --install`).

A developer checkout updates the old way: Check for Updates moves it to the newest release tag (from `main`, by fast-forward) and reruns `install.sh`; Settings › General › Updates shows **Developer checkout**. `get.sh` leaves a developer clone that `~/.local/bin/relay` links into alone.

## Build and test

```bash
swift build && swift test                                   # RelayCore and RelayUI tests (Swift Testing)
python3 -m unittest discover -s clients -p 'test_*.py' -v   # CLI and client
python3 -m unittest discover -s mcp -p 'test_*.py' -v       # MCP server
BUILD_ONLY=1 ./scripts/build.sh                             # assembles ./build/Hook.app, installs nothing
./scripts/test-install.sh                                   # installer, in a sandbox HOME
./scripts/test-get.sh                                       # one-line installer, against fixture releases on file:// and a local http server
./scripts/test-package.sh                                   # release zip, SHA256SUMS and release notes
./scripts/test-make-signing-cert.sh                         # the signing certificate script, uploads nothing
./scripts/smoke-local.sh                                    # This Mac only, end to end
scripts/gallery.sh [scene…]                                 # renders the UI offscreen to build/gallery/
./scripts/check-tokens.sh                                   # no literal sizes, colours or durations outside Design/
```

Test-only switches:
- `RELAY_DATA_DIR` moves the app's queue folder.
- `RELAY_NO_AUTOLAUNCH=1` stops the `relay` CLI from starting Hook. The smoke run sets it, so it can't touch an installed app.
- `scripts/install.sh` honours `RELAY_SKIP_BUILD`, `RELAY_SKIP_LAUNCH` and `RELAY_SKIP_MCP`, and runs a single quit or start step under `RELAY_TEST_STEP` fenced by `RELAY_APP_SCOPE` (see its header).
- `scripts/get.sh` downloads from `HOOK_RELEASES_URL` (a folder laid out like GitHub's `releases/`) instead of GitHub.

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

[CI](../.github/workflows/ci.yml) runs on pushes to `main` and on pull requests. It builds, runs the Swift, client and MCP tests (again on `/usr/bin/python3` if it is 3.9+), and runs the installer and packaging tests (`test-install.sh`, `test-get.sh`, `test-package.sh` and `test-make-signing-cert.sh`).

[Release](../.github/workflows/release.yml) runs on a `vX.Y.Z` tag: see [Releasing](#releasing).

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
5. **Pond markers.** The version's CHANGELOG section ends with the two hidden markers its
   release notes need: `<!-- hook:pond=<range> -->`, the npm-style Pond range this release
   needs (read by Hook 0.10 and later), and `<!-- hook:mailbox-protocol=N -->`, the old
   protocol level (read by 0.9.x updaters; see [Pond protocol](mailbox-protocol.md)). Before
   updating, Hook checks the connected Pond against them and offers to update the Pond first.
   `scripts/release-notes.sh X.Y.Z` prints the section and fails without them.
6. **Tag.** `git tag vX.Y.Z` on that commit and push the tag. Tag only a commit that passed CI.
7. **Release workflow.** The tag runs [Release](../.github/workflows/release.yml): it checks the
   tag matches `Info.plist` and the notes carry both markers, builds a universal (arm64 and
   x86_64) Hook.app, packs `Hook-X.Y.Z.zip` (the app and the `support/` payload:
   `bin/relay`, `clients/`, `mcp/`, `schema/`, `skill/`, `scripts/install.sh`, `scripts/get.sh`,
   `docs/claude-md-section.md`, `VERSION`) with `scripts/package-release.sh`, writes
   `SHA256SUMS`, and publishes the release with the CHANGELOG section as its notes. A new
   release stays a draft until both files are attached, so `get.sh` and the updater never see
   a release they can't download. A release you made by hand gets the files attached and keeps
   its notes.

### Signing

Without signing secrets the release is ad-hoc signed, and macOS asks once more for Keychain
access after every update. With a stable identity it doesn't:

- **Self-signed.** `scripts/make-signing-cert.sh` makes a code-signing certificate in
  `./signing` (git-ignored, `0700`) and prints the two values to store as repository secrets,
  `MACOS_SIGN_P12` (the base64 `.p12`) and `MACOS_SIGN_PASSWORD`. It uploads nothing. Keep the
  folder safe: a new certificate is a new identity.
- **Developer ID.** Store the Developer ID identity the same way, plus an App Store Connect API
  key as `APPLE_API_KEY` (the base64 `.p8`), `APPLE_API_KEY_ID` and `APPLE_API_ISSUER_ID`. The
  workflow then signs with the hardened runtime (`Resources/Hook.entitlements`), notarizes
  and staples, and a browser download opens normally.

Locally, `SIGN_IDENTITY`, `SIGN_KEYCHAIN`, `HARDENED=1` and `UNIVERSAL=1` do the same for
`scripts/build.sh`.

## Layout

```
Sources/Relay/         AppKit shell: panel window, menu bar, notifications, Settings and setup windows, loopback server
Sources/RelayCore/     queue, validator, config, Pond client (MailboxClient), and the panel's pure logic
Sources/RelayUI/       design tokens and components, the Store, every SwiftUI surface
Sources/RelayGallery/  offscreen renderer for the gallery (never bundled)
Tests/              Swift tests and fixtures
clients/  mcp/      relay CLI and MCP server, with tests
bin/relay           CLI entry point
schema/  skill/     instructable schema, Claude Code skill
scripts/            build, install, test
```

`Tests/RelayCoreTests/Fixtures/instructable-vectors.json` is the validator's source of truth. The validator tests run against it. It is maintained by hand, except the `optional-*` and `file-*` cases, which the Pond's reference validator generates; the tests check those cases' error order too.

## Vendored viewer scripts

The document viewer's marked and DOMPurify live in `Sources/RelayUI/Resources/Viewer/` (a SwiftPM resource of RelayUI; `scripts/build.sh` copies the folder into `Hook.app/Contents/Resources/Viewer`). They are the unmodified browser builds from the npm tarballs; [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) lists the versions, the tarball integrity hashes and how to update them. The gallery's `viewer-*` scenes render the viewer with WebKit's own snapshot.
