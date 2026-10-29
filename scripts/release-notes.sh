#!/usr/bin/env bash
# Prints the CHANGELOG section of one version, for the GitHub release notes:
#   scripts/release-notes.sh <X.Y.Z>
# The section must carry both hidden Pond markers, `<!-- hook:pond=<range> -->` (read by
# Hook 0.10 and later) and `<!-- hook:mailbox-protocol=N -->` (read by 0.9.x updaters):
# a release without them would update Hook past a Pond it can't use.
# CHANGELOG names another changelog file (tests only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
file="${CHANGELOG:-$ROOT/CHANGELOG.md}"
[ $# -eq 1 ] || { echo "usage: scripts/release-notes.sh <X.Y.Z>" >&2; exit 2; }
version="$1"

notes="$(awk -v head="## [$version]" '
  index($0, head) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' "$file")"
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "release-notes: $file has no section for $version (## [$version] - YYYY-MM-DD)" >&2
  exit 1
fi
printf '%s\n' "$notes" | grep -Eq '<!-- hook:pond=[^ ]+ -->' \
  || { echo "release-notes: the $version section has no <!-- hook:pond=<range> --> marker" >&2; exit 1; }
printf '%s\n' "$notes" | grep -Eq '<!-- hook:mailbox-protocol=[0-9]+ -->' \
  || { echo "release-notes: the $version section has no <!-- hook:mailbox-protocol=N --> marker" >&2; exit 1; }
# Trim the blank lines around the section.
printf '%s\n' "$notes" | awk 'NF { for (; blanks > 0; blanks--) print ""; print; seen = 1; next } seen { blanks++ }'
