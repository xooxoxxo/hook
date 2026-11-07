#!/usr/bin/env python3
"""Fail closed on a signed, stapled Mac app or a final release ZIP. No installation."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def verify_app(app, version, team):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'io.github.xooxoxxo.relay':
        raise ValueError('Unexpected bundle identity')
    if info.get('CFBundleShortVersionString') != version or info.get('CFBundleVersion') != version:
        raise ValueError('Unexpected app version')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    # codesign writes display metadata to stderr, even on success.
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(app)], check=True, capture_output=True)
    signature = result.stderr.decode()
    if ('TeamIdentifier=' + team) not in signature.splitlines():
        raise ValueError('Unexpected signing team')
    if not re.search(r'^Authority=Developer ID Application: .+ \(' + re.escape(team) + r'\)$', signature, re.M):
        raise ValueError('Not a Developer ID Application signature')
    if not re.search(r'^CodeDirectory .*flags=.*\bruntime\b', signature, re.M):
        raise ValueError('Hardened runtime missing')
    if not re.search(r'^Timestamp=.+$', signature, re.M):
        raise ValueError('Secure timestamp missing')
    entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', str(app)))
    if entitlements.get('com.apple.security.get-task-allow'):
        raise ValueError('Debug entitlement is forbidden')
    run('xcrun', 'stapler', 'validate', str(app))
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))


def verify_package(directory, version, team, expected=None):
    name = 'Hook-' + version + '.zip'
    archive = directory / name
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if (directory / 'SHA256SUMS').read_text() != digest + '  ' + name + '\n':
        raise ValueError('Package checksum manifest mismatch')
    if expected is not None and digest != expected:
        raise ValueError('Package differs from the approved checksum')
    with tempfile.TemporaryDirectory() as tmp:
        run('ditto', '-x', '-k', str(archive), tmp)
        verify_app(Path(tmp) / 'Hook.app', version, team)
        if (Path(tmp) / 'support/VERSION').read_text().strip() != version:
            raise ValueError('Support payload version mismatch')
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--app', type=Path)
    group.add_argument('--package', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--sha256')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'[A-Z0-9]{10}', args.team):
        parser.error('Invalid release version or team')
    if args.app:
        verify_app(args.app, args.version, args.team)
    else:
        print(verify_package(args.package, args.version, args.team, args.sha256))


if __name__ == '__main__':
    main()
