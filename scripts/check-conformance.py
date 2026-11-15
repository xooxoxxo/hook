#!/usr/bin/env python3
"""Check conformance/manifest.json against the files on disk.

Fails (exit 1, naming each file) when:
- a manifest entry lacks a field, names an unknown role, or its path is missing;
- a vector file under conformance/ is not in the manifest;
- a path in an entry's `copies` is missing or differs by a byte from the canonical file;
- an entry with `kinds` has a case whose `kind` is not listed there.

Usage: python3 scripts/check-conformance.py [--root REPO]
"""
import argparse
import json
from pathlib import Path
import sys

ROLES = {'reader', 'actor', 'writer', 'server'}
FIELDS = ('path', 'pond', 'feature', 'roles', 'copies')


def check_roles(where, roles, errors):
    if not isinstance(roles, list) or not roles:
        errors.append(f'{where}: must be a non-empty list of roles')
        return
    for role in roles:
        if role not in ROLES:
            errors.append(f'{where}: unknown role {role!r} (one of {", ".join(sorted(ROLES))})')


def check_entry(root, suite, entry, errors):
    if not isinstance(entry, dict):
        errors.append(f'manifest.json: file entry {entry!r} is not an object')
        return None
    name = entry.get('path', '<no path>')
    for field in FIELDS:
        if field not in entry:
            errors.append(f'{name}: manifest entry has no {field}')
    for field in ('path', 'pond', 'feature'):
        if field in entry and (not isinstance(entry[field], str) or not entry[field]):
            errors.append(f'{name}: {field} must be a non-empty string')
    unknown = set(entry) - set(FIELDS) - {'kinds'}
    if unknown:
        errors.append(f'{name}: unknown manifest keys {", ".join(sorted(unknown))}')
    if 'roles' in entry:
        check_roles(f'{name}: roles', entry['roles'], errors)
    if not isinstance(entry.get('path'), str):
        return None

    canonical = suite / entry['path']
    if not canonical.is_file():
        errors.append(f'{name}: listed in manifest.json but missing from conformance/')
        return name
    data = canonical.read_bytes()

    copies = entry.get('copies', [])
    if not isinstance(copies, list):
        errors.append(f'{name}: copies must be a list')
        copies = []
    for copy in copies:
        target = root / copy
        if not target.is_file():
            errors.append(f'{copy}: copy of conformance/{name} is missing')
        elif target.read_bytes() != data:
            errors.append(f'{copy}: differs from conformance/{name} (copy the canonical file over it)')

    if 'kinds' in entry:
        check_kinds(name, entry, data, errors)
    return name


def check_kinds(name, entry, data, errors):
    kinds = entry['kinds']
    if not isinstance(kinds, dict) or not kinds:
        errors.append(f'{name}: kinds must be a non-empty object')
        return
    file_roles = set(entry.get('roles') or [])
    for kind, roles in kinds.items():
        check_roles(f'{name}: kinds.{kind}', roles, errors)
        if isinstance(roles, list):
            extra = set(roles) - file_roles
            if extra:
                errors.append(f'{name}: kinds.{kind} has roles not in roles: {", ".join(sorted(extra))}')
    try:
        cases = json.loads(data).get('cases', [])
    except (ValueError, AttributeError) as error:
        errors.append(f'{name}: not a JSON object with cases ({error})')
        return
    seen = {case.get('kind') for case in cases if isinstance(case, dict)}
    for kind in sorted(seen - set(kinds), key=str):
        errors.append(f'{name}: case kind {kind!r} is not in kinds')


def check(root):
    suite = root / 'conformance'
    manifest_path = suite / 'manifest.json'
    if not manifest_path.is_file():
        return ['conformance/manifest.json: missing']
    try:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    except ValueError as error:
        return [f'conformance/manifest.json: not valid JSON ({error})']

    errors = []
    if not isinstance(manifest, dict) or not isinstance(manifest.get('suite'), int):
        errors.append('conformance/manifest.json: suite must be an integer')
    files = manifest.get('files') if isinstance(manifest, dict) else None
    if not isinstance(files, list) or not files:
        errors.append('conformance/manifest.json: files must be a non-empty list')
        files = []

    listed = set()
    for entry in files:
        name = check_entry(root, suite, entry, errors)
        if name is not None:
            if name in listed:
                errors.append(f'{name}: listed twice in manifest.json')
            listed.add(name)

    for path in sorted(suite.rglob('*.json')):
        rel = path.relative_to(suite).as_posix()
        if rel != 'manifest.json' and rel not in listed:
            errors.append(f'conformance/{rel}: not in manifest.json')
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent,
                        help='repository root (default: this script\'s repository)')
    args = parser.parse_args(argv)
    errors = check(args.root.resolve())
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f'conformance: {len(errors)} problem(s)', file=sys.stderr)
        return 1
    print('conformance: manifest and copies agree')
    return 0


if __name__ == '__main__':
    sys.exit(main())
