#!/bin/bash
# Build Hook.app from SwiftPM, ad-hoc sign it, and install it to ~/Applications.
# The SwiftPM executable target is still called Relay; it is copied in as MacOS/Hook.
# BUILD_ONLY=1 assembles ./build/Hook.app and installs nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Relay"

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
plutil -lint "$APP/Contents/Info.plist"
codesign --force -s - "$APP"

if [ "${BUILD_ONLY:-0}" != "1" ]; then
  # Launch Services must know the app for relay:// to resolve.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
echo "built $APP"
