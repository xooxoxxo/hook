#!/bin/bash
# Renders the design gallery into build/gallery (git-ignored). Pass scene names
# to render only those, and --contrast, --reduce-transparency or --xl for the variants.
# --reduce-transparency makes the panel stand-in opaque. --xl renders text 1.35x
# larger (macOS ignores Dynamic Type, so the gallery scales the DS text styles;
# stock controls that don't use a DS font or inherit the body font stay at their
# normal size).
set -euo pipefail
cd "$(dirname "$0")/.."
swift run RelayGallery build/gallery "$@"
