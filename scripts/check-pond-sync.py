#!/usr/bin/env python3
"""Compare this repo's conformance/ with the Pond's vector copies.

The Pond (github.com/xooxoxxo/pond) generates most of these vectors
(`mailbox/tests/gen_*.py`) and keeps its own copies in `mailbox/tests/`. The two
repos must hold the same bytes for every file in SHARED.

The check fails, naming each file, when:
- conformance/manifest.json is missing or unreadable, or the Pond tests folder is missing;
- a SHARED path is not in the manifest, or the manifest lists it and conformance/ has no file;
- the Pond has no copy of a SHARED file, or its copy differs by a byte;
- no manifest file has a copy in the Pond at all (an empty intersection);
- a manifest file has a Pond copy that SHARED does not list (pin it);
- a Pond vector file is in neither SHARED nor POND_ONLY (classify it);
- a POND_ONLY file is also in the manifest (move it to SHARED).

Manifest files without a Pond copy stay governed by scripts/check-conformance.py.

The Pond carries the same check as `mailbox/tests/conformance_sync.py`. Keep
SHARED and POND_ONLY the same in both repos.

Usage: python3 scripts/check-pond-sync.py --pond POND_CHECKOUT [--root REPO]
       (or set POND_DIR instead of --pond)
Stdlib only.
"""
import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import sys

# The manifest paths whose basename the Pond also writes to mailbox/tests/.
SHARED = (
    "wire/admission-vectors.json",
    "data/revision-vectors.json",
    "data/answers-vectors.json",
    "data/lint-vectors.json",
    "data/blocking-vectors.json",
    "data/optional-vectors.json",
    "data/questions-vectors.json",
    "data/required-vectors.json",
    "data/substeps-vectors.json",
    "data/history-vectors.json",
    "data/progress-vectors.json",
    "data/strictjson-vectors.json",
    "data/append-vectors.json",
    "data/doc-vectors.json",
    "data/brief-vectors.json",
    "data/fields-vectors.json",
    "wire/append-wire-vectors.json",
    "wire/doc-wire-vectors.json",
    "wire/choice-vectors.json",
    "wire/limits-vectors.json",
    "wire/message-vectors.json",
    "wire/requirements-vectors.json",
    "wire/bug-vectors.json",
    "wire/phone-setup-vectors.json",
    "wire/phone-acts-vectors.json",
    "wire/phone-errors-vectors.json",
)

# Vector files only the Pond's own tests read. Hook has no canonical copy.
POND_ONLY = (
    "golden_asks_path.json",
    "then-instructable-vectors.json",
)


@dataclass
class Report:
    matched: list = field(default_factory=list)
    missing_expected: set = field(default_factory=set)   # SHARED path with no Pond copy
    mismatched: set = field(default_factory=set)         # SHARED path whose bytes differ
    missing_in_hook: set = field(default_factory=set)    # SHARED path listed but no Hook file
    not_in_manifest: set = field(default_factory=set)    # SHARED path the manifest lacks
    unpinned: set = field(default_factory=set)           # manifest path with a copy, not in SHARED
    unclassified: set = field(default_factory=set)       # Pond vector file in neither list
    misclassified: set = field(default_factory=set)      # POND_ONLY file the manifest lists
    errors: list = field(default_factory=list)

    @property
    def ok(self):
        return not self.errors


# Keep this function identical to compare() in mailbox/tests/conformance_sync.py in the Pond repo.
def compare(hook_suite, pond_tests, shared=SHARED, pond_only=POND_ONLY):
    """Compare Hook's conformance folder with the Pond's tests folder."""
    hook_suite, pond_tests = Path(hook_suite), Path(pond_tests)
    report = Report()
    err = report.errors
    manifest_path = hook_suite / "manifest.json"
    if not manifest_path.is_file():
        err.append(f"{manifest_path}: no Hook manifest.json to compare with")
        return report
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        paths = [entry["path"] for entry in manifest["files"]]
    except (ValueError, KeyError, TypeError) as error:
        err.append(f"{manifest_path}: unreadable manifest ({error})")
        return report
    if not pond_tests.is_dir():
        err.append(f"{pond_tests}: no Pond tests folder")
        return report

    listed = set(paths)
    by_name = {Path(p).name: p for p in paths}
    intersection = {p for p in paths if (pond_tests / Path(p).name).is_file()}
    if not intersection:
        err.append("no manifest file has a copy in the Pond tests folder (empty intersection)")

    for path in shared:
        name = Path(path).name
        ours, theirs = pond_tests / name, hook_suite / path
        if path not in listed:
            report.not_in_manifest.add(path)
            err.append(f"{path}: pinned as shared, but Hook's manifest.json does not list it")
            continue
        if not theirs.is_file():
            report.missing_in_hook.add(path)
            err.append(f"{path}: listed in Hook's manifest.json, but Hook has no such file")
            continue
        if not ours.is_file():
            report.missing_expected.add(path)
            err.append(f"{path}: the Pond has no copy {name} (regenerate it or copy it over)")
            continue
        if ours.read_bytes() != theirs.read_bytes():
            report.mismatched.add(path)
            err.append(f"{path}: the Pond's {name} differs from Hook's (regenerate it or copy it over)")
            continue
        report.matched.append(path)

    for path in sorted(intersection - set(shared)):
        report.unpinned.add(path)
        err.append(f"{path}: both repos have it, but SHARED does not list it (pin it in both repos)")

    shared_names = {Path(p).name for p in shared}
    for vec in sorted(pond_tests.glob("*.json")):
        if vec.name not in shared_names and vec.name not in pond_only:
            report.unclassified.add(vec.name)
            err.append(f"{vec.name}: a Pond vector in neither SHARED nor POND_ONLY (classify it)")
    for name in pond_only:
        if name in by_name:
            report.misclassified.add(name)
            err.append(f"{name}: classified POND_ONLY, but Hook's manifest lists {by_name[name]}")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pond", type=Path, default=os.environ.get("POND_DIR"),
                        help="a Pond checkout, the folder holding mailbox/ (default: $POND_DIR)")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="this repository's root (default: this script's repository)")
    args = parser.parse_args(argv)
    if not args.pond:
        print("pond sync: no Pond checkout (pass --pond or set POND_DIR)", file=sys.stderr)
        return 1
    pond_tests = Path(args.pond).expanduser().resolve() / "mailbox" / "tests"
    report = compare(args.root.resolve() / "conformance", pond_tests)
    for error in report.errors:
        print(error, file=sys.stderr)
    if not report.ok:
        print(f"pond sync: {len(report.errors)} problem(s)", file=sys.stderr)
        return 1
    print(f"pond sync: {len(report.matched)} shared files match byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
