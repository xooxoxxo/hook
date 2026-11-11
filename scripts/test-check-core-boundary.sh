#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/Sources/RelayCore" "$fixture/Sources/RelayUI"
check=(python3 scripts/check-core-boundary.py --root "$fixture")
printf 'import Foundation\nstruct Shared {}\n' > "$fixture/Sources/RelayCore/Shared.swift"
"${check[@]}"
printf '@preconcurrency import RelayMacCore\n' > "$fixture/Sources/RelayCore/Bad.swift"
if "${check[@]}" > "$fixture/output" 2>&1; then echo 'reverse import escaped the gate' >&2; exit 1; fi
rm "$fixture/Sources/RelayCore/Bad.swift"
# Every scoped-import kind is valid Swift syntax and must respect the same boundary.
for kind in class struct enum func protocol typealias let var; do
    printf 'import %s RelayMacCore.Scoped\n' "$kind" > "$fixture/Sources/RelayCore/Bad.swift"
    xcrun swiftc -frontend -parse "$fixture/Sources/RelayCore/Bad.swift"
    if "${check[@]}" > "$fixture/output" 2>&1; then echo "scoped $kind import escaped the gate" >&2; exit 1; fi
    printf 'import\n%s\nRelayMacCore.Scoped\n' "$kind" > "$fixture/Sources/RelayCore/Bad.swift"
    xcrun swiftc -frontend -parse "$fixture/Sources/RelayCore/Bad.swift"
    if "${check[@]}" > "$fixture/output" 2>&1; then echo "multiline scoped $kind import escaped the gate" >&2; exit 1; fi
done
printf 'import\nRelayMacCore\n' > "$fixture/Sources/RelayCore/Bad.swift"
xcrun swiftc -frontend -parse "$fixture/Sources/RelayCore/Bad.swift"
if "${check[@]}" > "$fixture/output" 2>&1; then echo 'multiline import escaped the gate' >&2; exit 1; fi
printf 'import/* separator */protocol\nRelayMacCore.PresenceCheck\n' > "$fixture/Sources/RelayCore/Bad.swift"
xcrun swiftc -frontend -parse "$fixture/Sources/RelayCore/Bad.swift"
if "${check[@]}" > "$fixture/output" 2>&1; then echo 'comment-separated scoped import escaped the gate' >&2; exit 1; fi
rm "$fixture/Sources/RelayCore/Bad.swift"
printf 'let child = Process()\n' > "$fixture/Sources/RelayCore/Bad.swift"
if "${check[@]}" > "$fixture/output" 2>&1; then echo 'process API escaped the source gate' >&2; exit 1; fi
rm "$fixture/Sources/RelayCore/Bad.swift"
printf 'import RelayMacCore\n' > "$fixture/Sources/RelayUI/Mac.swift"
"${check[@]}"
if "${check[@]}" --include-ui > "$fixture/output" 2>&1; then echo 'UI reverse import escaped strict gate' >&2; exit 1; fi
rm "$fixture/Sources/RelayUI/Mac.swift"
printf 'import SwiftUI\nlet font = SwiftUI.Font.system(.body)\n' > "$fixture/Sources/RelayUI/Font.swift"
"${check[@]}" --include-ui
for call in 'system("true")' 'Darwin.system("true")' 'Darwin . system("true")' 'fork()'; do
    printf 'let value = %s\n' "$call" > "$fixture/Sources/RelayUI/Bad.swift"
    if "${check[@]}" --include-ui > "$fixture/output" 2>&1; then echo "process call $call escaped UI source gate" >&2; exit 1; fi
done
rm "$fixture/Sources/RelayUI/Bad.swift"
# Check real native symbols, including a defined launch function as well as a reference.
printf 'int shared(void) { return 1; }\n' > "$fixture/good.c"
xcrun clang -c "$fixture/good.c" -o "$fixture/good.o"
"${check[@]}" --binary "$fixture/good.o"
printf 'extern int system(const char *); int launch(void) { return system("true"); }\n' > "$fixture/bad.c"
xcrun clang -c "$fixture/bad.c" -o "$fixture/bad.o"
if "${check[@]}" --binary "$fixture/bad.o" > "$fixture/output" 2>&1; then echo 'process symbol escaped the binary gate' >&2; exit 1; fi
printf 'int posix_spawn(void) { return 0; }\n' > "$fixture/defined.c"
xcrun clang -c "$fixture/defined.c" -o "$fixture/defined.o"
if "${check[@]}" --binary "$fixture/defined.o" > "$fixture/output" 2>&1; then echo 'defined process symbol escaped the binary gate' >&2; exit 1; fi
echo 'Core boundary self-tests passed.'
