#!/bin/bash
# Compile the shared package target against the iOS SDK, without signing.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -scheme RelayCore -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios-core CODE_SIGNING_ALLOWED=NO build
python3 scripts/check-core-boundary.py --binary build/ios-core/Build/Products/Debug-iphonesimulator/RelayCore.o "$@"
