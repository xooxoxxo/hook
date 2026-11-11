#!/usr/bin/env python3
"""Enforce shared source dependencies and scan an iOS object/app for Mac launch APIs."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
parser.add_argument('--include-ui', action='store_true', help='Enable when RelayUI is portable (iOS task 3).')
parser.add_argument('--binary', action='append', type=Path, default=[], help='Linked iOS app executable or shared product object; repeatable.')
args = parser.parse_args()
failures = []
modules = ['RelayCore'] + (['RelayUI'] if args.include_ui else [])
for module in modules:
    directory = args.root / 'Sources' / module
    if not directory.is_dir():
        failures.append(f'missing shared source directory: {directory}')
        continue
    for source in sorted(directory.rglob('*.swift')):
        text = source.read_text()
        # Preserve line numbers while ignoring comments. Source checks supplement SDK compilation.
        text = re.sub(r'/\*[\s\S]*?\*/|//[^\n]*', lambda m: ' ' + '\n' * m.group().count('\n'), text)
        # Swift permits newlines between import tokens, including scoped imports.
        for match in re.finditer(r'\bimport\s+(?:(?:class|struct|enum|func|protocol|typealias|let|var)\s+)?RelayMacCore\b', text):
            number = text.count('\n', 0, match.start()) + 1
            failures.append(f'{source.relative_to(args.root)}:{number}: shared code imports RelayMacCore')
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r'\b(?:Process|NSTask|NSAppleScript)\s*[.(]|(?<![.\w])(?:(?:Darwin|Glibc)\s*\.\s*)?(?:posix_spawn\w*|fork|vfork|execve|execv|execl|popen|system)\s*\(', line):
                failures.append(f'{source.relative_to(args.root)}:{number}: process launch API in shared code')
# nm -a includes defined as well as undefined symbols, so static linking cannot hide a launch API.
for binary in args.binary:
    if not binary.is_file():
        failures.append(f'missing iOS binary: {binary}')
        continue
    result = subprocess.run(['xcrun', 'nm', '-a', str(binary)], capture_output=True, text=True)
    if result.returncode:
        failures.append(f'nm failed for {binary}: {result.stderr.strip()}')
        continue
    forbidden = re.compile(r'(?:^|\s)_(?:posix_spawn\w*|fork|vfork|execve|execv|execvp|execl|execlp|popen|system)(?:$|\s)|(?:Foundation7ProcessC|NSTask|NSAppleScript|RelayMacCore)')
    for line in result.stdout.splitlines():
        if forbidden.search(line):
            failures.append(f'{binary.name}: forbidden linked symbol: {line.strip()}')
if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('Shared core boundary passed' + (' (including UI)' if args.include_ui else '') + f'; scanned {len(args.binary)} iOS binaries.')
