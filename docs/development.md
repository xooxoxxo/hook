# Development

How to build Hook, run its tests and find your way around the code.

## Build from source

A clone you build yourself is a developer checkout:

```bash
git clone https://github.com/xooxoxxo/hook.git
cd hook
HOOK_DEV=1 ./scripts/install.sh
```

Building needs macOS 14.5+ and the Command Line Tools with Swift 6 (`xcode-select --install`).

`install.sh` builds from source only in a developer's clone: `HOOK_DEV=1`, uncommitted changes, or a local branch other than `main`. The config records such a build (`"updateMode": "developer"`, `repoPath` naming the clone). Later runs in that clone build from source without `HOOK_DEV=1`, including the one Check for Updates starts. `HOOK_DEV=0 ./scripts/install.sh` ignores the record and moves a clean clone on `main` to the release download.

Any other clone gets the prebuilt release of its version, and builds from source only if that download fails. That is how 0.9.x's updater moves a clone install to the release download.

Check for Updates moves a developer checkout to the newest release tag (from `main`, by fast-forward) and reruns `install.sh`. Settings › General › Updates shows **Developer checkout**. `get.sh` leaves alone a developer clone that `~/.local/bin/relay` links into.

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
- `scripts/install.sh` honours `RELAY_SKIP_BUILD`, `RELAY_SKIP_LAUNCH` and `RELAY_SKIP_INTEGRATIONS` (`RELAY_SKIP_MCP` is its old name). Under `RELAY_TEST_STEP`, fenced by `RELAY_APP_SCOPE`, it runs a single quit or start step. Its header has the details.
- `scripts/get.sh` downloads from `HOOK_RELEASES_URL` (a folder laid out like GitHub's `releases/`) instead of GitHub.

## Design gallery

`scripts/gallery.sh` renders every design-system component and screen offscreen, in light and dark, into `build/gallery/` (git-ignored). It adds an `index.html` grid. Nothing appears on screen. Pass scene names to render only those (`scripts/gallery.sh components queue`). These flags render the accessibility variants, with a `-contrast`, `-rt` or `-xl` file suffix:

- `--contrast`: Increase Contrast.
- `--reduce-transparency`: the panel stand-in becomes solid (see below).
- `--xl`: text 1.35× larger. macOS ignores Dynamic Type, so the gallery scales the DS text styles. Stock controls that don't use a DS font or inherit the body font keep their normal size.

The panel's sidebar material doesn't render offscreen, so panel scenes paint the window background in its place. It is translucent over the gallery canvas, or solid under `--reduce-transparency`, as the real material falls back. `index.html` labels these scenes "panel material: stand-in". The real material follows the system setting, so a `-rt` PNG checks only the solid backdrop.

`scripts/check-tokens.sh` fails on literal sizes, colours, durations or custom shapes outside `Sources/RelayUI/Design/`. It also fails on switch toggles and Liquid Glass calls anywhere. CI runs it with its self-test.

### Review rule

A pull request that changes `Sources/RelayUI/` attaches:

- before and after PNGs, light and dark, of every scene it touches (`scripts/gallery.sh <scene…>`);
- one `screencapture -l <windowID>` of the running panel per theme, over a real desktop;
- `screencapture -w` shots of the menus it touches: the queue menu, the row context menu, the menu-bar menu.

`./scripts/check-tokens.sh` must print nothing.

## CI

[CI](../.github/workflows/ci.yml) runs on pushes to `main` and on pull requests. It builds and runs the Swift, client and MCP tests, and the last two again on `/usr/bin/python3` if that is 3.9 or newer. It also runs the installer and packaging tests: `test-install.sh`, `test-get.sh`, `test-package.sh` and `test-make-signing-cert.sh`.

[Release](../.github/workflows/release.yml) runs on a `vX.Y.Z` tag: see [Releasing](#releasing).

## Conformance suite

[`conformance/`](../conformance/README.md) holds the canonical JSON test vectors that the Swift core, other client cores and the Pond all run. `conformance/manifest.json` lists each file, the roles that run it and the paths that hold copies of it, such as `Tests/RelayCoreTests/Fixtures/`. Edit a vector in `conformance/`, copy it over each path in `copies`, then run `python3 scripts/check-conformance.py`. It fails when a copy differs or a file is missing from the manifest. CI runs it.

## Releasing

1. **Version.** Bump it in the three places that carry it: `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, `VERSION` in `clients/relay_client.py`, and the `relay --version` row in [docs/agents.md](agents.md). Hook's version stays 0.x.
2. **CHANGELOG.** Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`. Read it as release notes: one line per change a user would notice, under Added, Changed and Fixed.
3. **Privacy scan.** The repository is public. Check the diff since the last tag (`git diff vX.Y.Z-1..HEAD`) and remove personal names, home-folder paths (`/Users/<name>`), host names, internal ticket ids and tokens.
4. **CI.** Push the release commit and wait for [CI](../.github/workflows/ci.yml) to pass on it.
5. **Pond markers.** The version's CHANGELOG section ends with the two hidden markers its release notes need:
   - `<!-- hook:pond=<range> -->`: the npm-style Pond range this release needs, read by Hook 0.10 and later;
   - `<!-- hook:mailbox-protocol=N -->`: the old protocol level, read by 0.9.x updaters (see [Pond protocol](mailbox-protocol.md)).

   Before updating, Hook checks the connected Pond against them and offers to update the Pond first. `scripts/release-notes.sh X.Y.Z` prints the section, and fails without the markers.
6. **Candidate approval and tag.** Get owner approval through Hook for the exact green commit before pushing its `vX.Y.Z` tag. The tag runs [Release](../.github/workflows/release.yml), which requires Developer ID signing, notarization and verification of the final ZIP. It creates a **draft**, never a public release. Existing drafts/assets are not overwritten on rerun.
7. **Publication approval.** Inspect the draft, its `SHA256SUMS`, accepted `notary-result.json`, and clean-Mac/upgrade checks. Request a separate Hook release approval naming the full commit, version and ZIP checksum. After verifying the owner's current answer, dispatch [Publish approved release](../.github/workflows/publish-release.yml) with those values and the approval ask UUID. It downloads and checks the same draft bytes, then publishes without rebuilding. The UUID is an audit reference; the workflow cannot authenticate private Hook answers. Never dispatch without verifying the answer yourself.
8. **Recovery.** A failed candidate remains unpublished. Inspect the failure and get explicit recovery approval before removing a draft or retrying a tag. Never replace assets of a public release. Retain the previous app and data until the signed upgrade passes; never reset owner keys to resolve a signing prompt.

### Signing

Production releases require repository secrets `MACOS_SIGN_P12` (base64 Developer ID Application identity with private key), `MACOS_SIGN_PASSWORD`, `APPLE_API_KEY` (base64 App Store Connect team API key), `APPLE_API_KEY_ID` and `APPLE_API_ISSUER_ID`. Set repository variables `APPLE_TEAM_ID` and `MACOS_SIGN_SHA1` (uppercase SHA-1 fingerprint of the intended certificate). No values belong in source, logs, issues or asks. Configure them through the owner's approved credential flow.

The workflow selects that exact valid Developer ID Application identity, uses hardened runtime and a secure timestamp, requires accepted notarization, staples, and checks the extracted final app's identity, version, entitlements and Gatekeeper assessment. Missing settings or failed checks stop the release. Cleanup runs even after a partial import.

Ad-hoc and self-signed builds remain development-only. `scripts/make-signing-cert.sh` is not an Apple certificate enrollment tool. Locally, `SIGN_IDENTITY`, `SIGN_KEYCHAIN`, `HARDENED=1`, `BUILD_ONLY=1` and `UNIVERSAL=1` configure `scripts/build.sh` without installing. Run `python3 -m unittest discover -s scripts -p 'test_release_*.py' -v` for credential-free release refusal tests.

Before the first signed release, test a quarantined browser download and an existing-install upgrade on real Macs, including Keychain approval, notifications, terminal automation, integrations and URL handling. A simulator or mocked signing test does not establish Gatekeeper acceptance or migration safety.

## Layout

```
Sources/Relay/         AppKit shell: panel window, menu bar, notifications, Settings and setup windows, loopback server
Sources/RelayCore/     queue, validator, config, Pond client (MailboxClient), and the panel's pure logic
Sources/RelayUI/       design tokens and components, the Store, every SwiftUI surface
Sources/RelayGallery/  offscreen renderer for the gallery (never bundled)
Sources/HookTelemetry/ empty slot for a future crash-reporting adapter (links nothing)
Tests/              Swift tests and fixtures
clients/  mcp/      relay CLI and MCP server, with tests
bin/relay           CLI entry point
schema/  skill/     instructable schema, Claude Code skill
scripts/            build, install, test
```

`Tests/RelayCoreTests/Fixtures/instructable-vectors.json` is the validator's source of truth, and the validator tests run against it. It is kept by hand, except the `optional-*` and `file-*` cases. The Pond's reference validator makes those, and the tests check their error order too.

## App icon

The icon's source is `Resources/AppIcon.icon`, an Icon Composer document with one full-bleed 1024 px layer. `scripts/app-icon.sh` compiles it into `Resources/Assets.car`, which is committed because only Xcode 26 or later can compile a `.icon`. Run it after changing the `.icon` and commit both. `Info.plist` names the catalog in `CFBundleIconName`. macOS 26 and later mask the layered icon to their own shape; macOS 14 and 15 use the rounded images actool renders into the same catalog. `Resources/AppIcon.icns` (`CFBundleIconFile`, the rounded tile on the older grid) is for anything that reads the `.icns` directly, such as the gallery.

## Vendored viewer scripts

The document viewer uses marked and DOMPurify from `Sources/RelayUI/Resources/Viewer/`, a SwiftPM resource of RelayUI. `scripts/build.sh` copies the folder into `Hook.app/Contents/Resources/Viewer`. They are the unmodified browser builds from the npm tarballs. [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) lists the versions, the tarball integrity hashes and how to update them. The gallery's `viewer-*` scenes render the viewer with WebKit's own snapshot.
