#!/usr/bin/env python3
"""Fail closed on a signed, stapled Mac app or a final release (ZIP and DMG). No installation."""
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


def check_signature(path, team):
    """The Developer ID identity, team and secure timestamp of a signed app or disk image."""
    # codesign writes display metadata to stderr, even on success.
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], check=True, capture_output=True)
    signature = result.stderr.decode()
    if ('TeamIdentifier=' + team) not in signature.splitlines():
        raise ValueError('Unexpected signing team')
    if not re.search(r'^Authority=Developer ID Application: .+ \(' + re.escape(team) + r'\)$', signature, re.M):
        raise ValueError('Not a Developer ID Application signature')
    if not re.search(r'^Timestamp=.+$', signature, re.M):
        raise ValueError('Secure timestamp missing')
    return signature


def verify_app(app, version, team):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'io.github.xooxoxxo.relay':
        raise ValueError('Unexpected bundle identity')
    if info.get('CFBundleShortVersionString') != version or info.get('CFBundleVersion') != version:
        raise ValueError('Unexpected app version')
    # The support payload is sealed into the app: Hook's first launch installs from it.
    support = app / 'Contents/Resources/support'
    if not (support / 'VERSION').is_file() or (support / 'VERSION').read_text().strip() != version:
        raise ValueError('Bundled support payload missing or of another version')
    if not (support / 'scripts/install.sh').is_file() or not (support / 'scripts/get.sh').is_file():
        raise ValueError('Bundled installer missing')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    signature = check_signature(app, team)
    if not re.search(r'^CodeDirectory .*flags=.*\bruntime\b', signature, re.M):
        raise ValueError('Hardened runtime missing')
    entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', str(app)))
    if entitlements.get('com.apple.security.get-task-allow'):
        raise ValueError('Debug entitlement is forbidden')
    run('xcrun', 'stapler', 'validate', str(app))
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))


def verify_dmg(image, version, team):
    """A signed, notarized and stapled disk image holding Hook.app and a link to /Applications."""
    run('codesign', '--verify', '--strict', str(image))
    check_signature(image, team)
    run('xcrun', 'stapler', 'validate', str(image))
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', str(image))
    run('hdiutil', 'verify', '-quiet', str(image))
    with tempfile.TemporaryDirectory() as tmp:
        mount = Path(tmp) / 'mount'
        mount.mkdir()
        run('hdiutil', 'attach', '-quiet', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(image))
        try:
            names = sorted(name for name in os.listdir(mount) if not name.startswith('.'))
            if names != ['Applications', 'Hook.app']:
                raise ValueError('Unexpected disk image contents')
            link = mount / 'Applications'
            if not link.is_symlink() or os.readlink(link) != '/Applications':
                raise ValueError('Disk image lacks the Applications link')
            verify_app(mount / 'Hook.app', version, team)
        finally:
            run('hdiutil', 'detach', '-quiet', str(mount))


def sums_text(entries):
    return ''.join(digest + '  ' + name + '\n' for name, digest in entries)


def verify_package(directory, version, team, expected=None, expected_dmg=None):
    """The ZIP and DMG that SHA256SUMS lists, in that order and nothing else; returns both hashes."""
    name = 'Hook-' + version + '.zip'
    image_name = 'Hook-' + version + '.dmg'
    archive = directory / name
    image = directory / image_name
    if not image.is_file():
        raise ValueError('Release disk image missing')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    image_digest = hashlib.sha256(image.read_bytes()).hexdigest()
    if (directory / 'SHA256SUMS').read_text() != sums_text([(name, digest), (image_name, image_digest)]):
        raise ValueError('Package checksum manifest mismatch')
    if expected is not None and digest != expected:
        raise ValueError('Package differs from the approved checksum')
    if expected_dmg is not None and image_digest != expected_dmg:
        raise ValueError('Disk image differs from the approved checksum')
    with tempfile.TemporaryDirectory() as tmp:
        run('ditto', '-x', '-k', str(archive), tmp)
        verify_app(Path(tmp) / 'Hook.app', version, team)
        if (Path(tmp) / 'support/VERSION').read_text().strip() != version:
            raise ValueError('Support payload version mismatch')
    verify_dmg(image, version, team)
    return digest, image_digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--app', type=Path)
    group.add_argument('--dmg', type=Path)
    group.add_argument('--package', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--sha256')
    parser.add_argument('--dmg-sha256')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'[A-Z0-9]{10}', args.team):
        parser.error('Invalid release version or team')
    if args.app:
        verify_app(args.app, args.version, args.team)
    elif args.dmg:
        verify_dmg(args.dmg, args.version, args.team)
    else:
        digest, image_digest = verify_package(args.package, args.version, args.team, args.sha256, args.dmg_sha256)
        print(digest + '  Hook-' + args.version + '.zip')
        print(image_digest + '  Hook-' + args.version + '.dmg')


if __name__ == '__main__':
    main()
