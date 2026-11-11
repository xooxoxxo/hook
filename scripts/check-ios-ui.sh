#!/bin/bash
# Compile only the shared UI dependency graph with the iOS SDK, without signing.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -scheme RelayUI -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios-ui CODE_SIGNING_ALLOWED=NO build
python3 scripts/check-core-boundary.py --include-ui \
  --binary build/ios-ui/Build/Products/Debug-iphonesimulator/RelayCore.o \
  --binary build/ios-ui/Build/Products/Debug-iphonesimulator/RelayUI.o "$@"
