#!/bin/bash
# Self-test for check-tokens.sh: plants violations in a temporary tree and
# expects the lint to catch them (and to let Design/ keep its literals).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
lint="$here/check-tokens.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-tokens-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Sources/RelayUI/Design" "$tmp/Sources/RelayUI/Panel"

fail() { echo "test-check-tokens: FAIL: $1"; exit 1; }

printf 'import SwiftUI\nlet a = Text("x").padding(DS.Space.gutter)\n' > "$tmp/Sources/RelayUI/Panel/Clean.swift"
"$lint" "$tmp/Sources/RelayUI" >/dev/null 2>&1 || fail "a clean tree failed the lint"

printf 'let b = Text("x").padding(12)\n' > "$tmp/Sources/RelayUI/Design/Tokens.swift"
"$lint" "$tmp/Sources/RelayUI" >/dev/null 2>&1 || fail "a literal inside Design failed the lint"

printf 'let c = Text("x").padding(12)\n' > "$tmp/Sources/RelayUI/Panel/Bad.swift"
if "$lint" "$tmp/Sources/RelayUI" >/dev/null 2>&1; then fail ".padding(12) outside Design passed"; fi
"$lint" "$tmp/Sources/RelayUI" 2>/dev/null | grep -q 'Panel/Bad.swift:1:' || fail "the hit was not printed as path:line:"
rm "$tmp/Sources/RelayUI/Panel/Bad.swift"

printf 'let d = Toggle("x", isOn: .constant(true)).toggleStyle(.switch)\n' > "$tmp/Sources/RelayUI/Design/Switch.swift"
if "$lint" "$tmp/Sources/RelayUI" >/dev/null 2>&1; then fail "a switch inside Design passed"; fi
rm "$tmp/Sources/RelayUI/Design/Switch.swift"

printf 'let e = Text("x").glassEffect()\n' > "$tmp/Sources/RelayUI/Panel/Glass.swift"
if "$lint" "$tmp/Sources/RelayUI" >/dev/null 2>&1; then fail "glassEffect passed"; fi
rm "$tmp/Sources/RelayUI/Panel/Glass.swift"

for bad in 'font(.system(size: 13))' 'RoundedRectangle(cornerRadius: 6)' 'Color(white: 0.11)' '.opacity(0.5)' \
           'withAnimation(.easeOut(duration: 0.2))' 'Capsule()' '.shadow(radius: 2)'; do
  printf 'let f = %s\n' "$bad" > "$tmp/Sources/RelayUI/Panel/Literal.swift"
  if "$lint" "$tmp/Sources/RelayUI" >/dev/null 2>&1; then fail "$bad passed"; fi
done
rm "$tmp/Sources/RelayUI/Panel/Literal.swift"

if "$lint" "$tmp/Sources/Missing" >/dev/null 2>&1; then fail "a missing path passed"; fi
echo "test-check-tokens: ok"
