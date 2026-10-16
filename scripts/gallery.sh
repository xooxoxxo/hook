#!/bin/bash
# Renders the design gallery into build/gallery (git-ignored). Pass scene names
# to render only those, and --contrast, --reduce-transparency or --xl for the variants.
set -euo pipefail
cd "$(dirname "$0")/.."
swift run RelayGallery build/gallery "$@"
