#!/bin/bash
# Checks the UI code for hard-coded styling: outside Sources/RelayUI/Design/ there
# must be no literal sizes, colours, durations or custom shapes (they belong in the
# design tokens), and nowhere a switch-style toggle or a Liquid Glass call. Prints path:line:text per hit.
# Exit 0 clean, 1 on any hit, 2 when a path doesn't exist.
set -u
cd "$(dirname "$0")/.." || exit 2
if [ "$#" -gt 0 ]; then paths=("$@"); else paths=(Sources/RelayUI Sources/Relay); fi
for p in "${paths[@]}"; do
  [ -e "$p" ] || { echo "check-tokens: no such path: $p" >&2; exit 2; }
done
literals='font\(\.system\(size:|\.padding\([^)]*[0-9]|cornerRadius: *[0-9]|Color\(white|\.opacity\(0\.[0-9]|duration: *[0-9]|RoundedRectangle|Capsule\(|\.shadow\('
banned='\.toggleStyle\(\.switch\)|glassEffect'
hits="$(
  {
    grep -rnE --include='*.swift' "$literals" "${paths[@]}" | grep -vE '(^|/)Sources/RelayUI/Design/'
    grep -rnE --include='*.swift' "$banned" "${paths[@]}"
  } | sort -u
)"
if [ -n "$hits" ]; then
  echo "$hits"
  echo "check-tokens: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') hit(s); use a DS token (Sources/RelayUI/Design/Tokens.swift)" >&2
  exit 1
fi
echo "check-tokens: clean"
