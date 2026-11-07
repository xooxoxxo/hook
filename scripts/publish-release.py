#!/usr/bin/env python3
"""Promote an existing verified draft; never rebuild or replace its assets."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import importlib.util

spec = importlib.util.spec_from_file_location('verify_release', Path(__file__).with_name('verify-release.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def publish(tag, commit, checksum, team, approval):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('Invalid release tag')
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or not re.fullmatch(r'[0-9a-f]{64}', checksum):
        raise ValueError('Exact commit and checksum required')
    if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', approval):
        raise ValueError('Hook approval ask ID required')
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Expected signing team required')
    actual = verify.run('git', 'rev-parse', 'refs/tags/' + tag + '^{commit}').decode().strip()
    if actual != commit:
        raise ValueError('Tag differs from approved commit')
    release = json.loads(verify.run('gh', 'release', 'view', tag, '--json', 'isDraft,isPrerelease,tagName'))
    if not release['isDraft'] or release['isPrerelease'] or release['tagName'] != tag:
        raise ValueError('Only the intended draft may be published')
    with tempfile.TemporaryDirectory() as tmp:
        verify.run('gh', 'release', 'download', tag, '--dir', tmp, '--pattern', 'Hook-*.zip', '--pattern', 'SHA256SUMS', '--pattern', 'notary-result.json')
        if json.loads((Path(tmp) / 'notary-result.json').read_text()).get('status') != 'Accepted':
            raise ValueError('Accepted notarization evidence missing')
        verify.verify_package(Path(tmp), tag[1:], team, checksum)
    # The ID is an audit reference, not proof: the operator must verify the owner answer
    # before dispatching. This script has no access to the owner's private Hook queue.
    print('Publishing reviewed draft; Hook approval ' + approval, flush=True)
    subprocess.run(['gh', 'release', 'edit', tag, '--draft=false', '--latest'], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('tag', 'commit', 'sha256', 'team', 'approval'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    publish(args.tag, args.commit, args.sha256, args.team, args.approval)
