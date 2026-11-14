#!/bin/bash
# Build Hook.app from SwiftPM, sign it, and install it to ~/Applications.
# The SwiftPM executable target is still called Relay; it is copied in as MacOS/Hook.
# BUILD_ONLY=1      assembles ./build/Hook.app and installs nothing.
# UNIVERSAL=1       builds for arm64 and x86_64 in one binary (needs Xcode, as the release workflow has).
# SIGN_IDENTITY=…   signs with that identity (a name or SHA-1 hash) instead of ad-hoc ("-").
# SIGN_KEYCHAIN=…   the keychain that holds it.
# HARDENED=1        with SIGN_IDENTITY: the hardened runtime, a secure timestamp and
#                   Resources/Hook.entitlements, as notarization requires.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/Relay"

if [ "${BUILD_ONLY:-0}" = "1" ]; then
  DEST="$ROOT/build"
else
  DEST="$HOME/Applications"
fi
APP="$DEST/Hook.app"

mkdir -p "$DEST"
rm -rf "$APP"
# The build from before the rename to Hook, so Launch Services can't pick it up.
if [ "${BUILD_ONLY:-0}" = "1" ]; then rm -rf "$DEST/Relay.app"; fi
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The document viewer's scripts (vendored marked and DOMPurify, and viewer.js) and their licences.
# Package.swift copies them unchanged (.copy), so they come straight from the source tree: where
# SwiftPM puts its resource bundle differs between build systems (.build/out/Products/Release with
# the newer one), and the app reads them from Contents/Resources/Viewer.
VIEWER="$ROOT/Sources/RelayUIMac/Resources/Viewer"
[ -f "$VIEWER/marked.umd.js" ] || { echo "build.sh: no viewer resources at $VIEWER" >&2; exit 1; }
mkdir -p "$APP/Contents/Resources"
cp -R "$VIEWER" "$APP/Contents/Resources/Viewer"
# The menu-bar glyphs (template PNGs at @1x and @2x), read from Contents/Resources/MenuBar,
# and the app icon: Assets.car (CFBundleIconName, compiled from Resources/AppIcon.icon by
# scripts/app-icon.sh) and AppIcon.icns (CFBundleIconFile).
MENUBAR="$ROOT/Sources/RelayUIMac/Resources/MenuBar"
[ -f "$MENUBAR/menubar-idle.png" ] || { echo "build.sh: no menu-bar glyphs at $MENUBAR" >&2; exit 1; }
cp -R "$MENUBAR" "$APP/Contents/Resources/MenuBar"
# The colour fish on the hook that new-ask notifications attach, from Contents/Resources/Notification.
NOTIFICATION="$ROOT/Sources/RelayUIMac/Resources/Notification"
[ -f "$NOTIFICATION/ask-fish.png" ] || { echo "build.sh: no notification image at $NOTIFICATION" >&2; exit 1; }
cp -R "$NOTIFICATION" "$APP/Contents/Resources/Notification"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Assets.car "$APP/Contents/Resources/Assets.car"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# The support payload (the CLI, MCP server, skill and installer), sealed and notarized with
# the app: Hook's first launch installs from it, and package-release.sh packs it into the
# release zip as support/. None of it is Mach-O, so codesign seals it as resources.
"$ROOT/scripts/bundle-support.sh" "$APP/Contents/Resources/support"
plutil -lint "$APP/Contents/Info.plist"
IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force -s "$IDENTITY")
if [ -n "${SIGN_KEYCHAIN:-}" ]; then SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN"); fi
if [ "$IDENTITY" != "-" ] && [ "${HARDENED:-0}" = "1" ]; then
  SIGN_ARGS+=(--options runtime --timestamp --entitlements "$ROOT/Resources/Hook.entitlements")
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  archs="$(lipo -archs "$APP/Contents/MacOS/Hook")"
  for arch in arm64 x86_64; do
    case " $archs " in *" $arch "*) ;; *) echo "build.sh: $APP is $archs, not arm64 and x86_64" >&2; exit 1 ;; esac
  done
fi

if [ "${BUILD_ONLY:-0}" != "1" ]; then
  # Launch Services must know the app for hook:// and relay:// to resolve.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
echo "built $APP"
