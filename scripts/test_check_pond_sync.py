"""Tests for scripts/check-pond-sync.py, run on throwaway trees built from conformance/."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / 'check-pond-sync.py'
REPO = SCRIPT.parent.parent

_spec = importlib.util.spec_from_file_location('check_pond_sync', SCRIPT)
sync = importlib.util.module_from_spec(_spec)
sys.modules['check_pond_sync'] = sync  # dataclasses looks the module up by name
_spec.loader.exec_module(sync)


class PinnedLists(unittest.TestCase):
    def test_the_pinned_lists_are_well_formed(self):
        self.assertEqual(len(sync.SHARED), 25)
        self.assertEqual(len(set(sync.SHARED)), len(sync.SHARED))
        names = [Path(p).name for p in sync.SHARED]
        self.assertEqual(len(set(names)), len(names), 'two shared paths share a basename')
        self.assertFalse(set(names) & set(sync.POND_ONLY))

    def test_every_shared_path_is_in_this_manifest(self):
        manifest = json.loads((REPO / 'conformance/manifest.json').read_text(encoding='utf-8'))
        listed = {entry['path'] for entry in manifest['files']}
        self.assertEqual(set(sync.SHARED) - listed, set())
        self.assertEqual({Path(p).name for p in listed} & set(sync.POND_ONLY), set())


class CheckPondSync(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.root, self.pond = tmp / 'hook', tmp / 'pond'
        self.suite, self.tests = self.root / 'conformance', self.pond / 'mailbox' / 'tests'
        self.tests.mkdir(parents=True)
        for path in sync.SHARED:
            src = REPO / 'conformance' / path
            (self.suite / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, self.suite / path)
            shutil.copyfile(src, self.tests / src.name)
        for name in sync.POND_ONLY:
            (self.tests / name).write_text('{}\n', encoding='utf-8')
        (self.suite / 'data/hook-only-vectors.json').write_text('{}\n', encoding='utf-8')
        self.write_manifest(list(sync.SHARED) + ['data/hook-only-vectors.json'])

    def tearDown(self):
        self._tmp.cleanup()

    def write_manifest(self, paths):
        files = [{'path': p} for p in paths]
        (self.suite / 'manifest.json').write_text(json.dumps({'suite': 1, 'files': files}), encoding='utf-8')

    def run_check(self, *args, pond=None):
        argv = ['--root', str(self.root), '--pond', str(pond or self.pond), *args]
        result = subprocess.run([sys.executable, str(SCRIPT), *argv], capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def fails(self, pond=None):
        report = sync.compare(self.suite, (pond or self.pond) / 'mailbox' / 'tests')
        code, out = self.run_check(pond=pond)
        self.assertFalse(report.ok)
        self.assertNotEqual(code, 0, out)
        return report, out

    def test_trees_that_agree_pass(self):
        report = sync.compare(self.suite, self.tests)
        self.assertEqual(report.errors, [])
        self.assertEqual(len(report.matched), 25)
        code, out = self.run_check()
        self.assertEqual(code, 0, out)
        self.assertIn('25 shared files match', out)

    def test_a_missing_copy_fails(self):
        (self.tests / 'bug-vectors.json').unlink()
        report, out = self.fails()
        self.assertNotEqual(report.missing_expected, set())
        self.assertEqual(report.missing_expected, {'wire/bug-vectors.json'})
        self.assertIn('bug-vectors.json', out)

    def test_a_one_byte_drift_fails(self):
        target = self.tests / 'revision-vectors.json'
        data = bytearray(target.read_bytes())
        data[-2] ^= 0x01
        target.write_bytes(bytes(data))
        report, out = self.fails()
        self.assertEqual(report.mismatched, {'data/revision-vectors.json'})
        self.assertIn('revision-vectors.json', out)

    def test_a_manifest_path_with_no_file_fails(self):
        (self.suite / 'wire/limits-vectors.json').unlink()
        report, _ = self.fails()
        self.assertEqual(report.missing_in_hook, {'wire/limits-vectors.json'})

    def test_an_empty_intersection_fails(self):
        empty = Path(self._tmp.name) / 'empty-pond'
        (empty / 'mailbox' / 'tests').mkdir(parents=True)
        report, out = self.fails(pond=empty)
        self.assertIn('empty intersection', out)
        self.assertEqual(report.matched, [])

    def test_a_shared_path_dropped_from_the_manifest_fails(self):
        self.write_manifest([p for p in sync.SHARED if p != 'data/lint-vectors.json'])
        report, _ = self.fails()
        self.assertEqual(report.not_in_manifest, {'data/lint-vectors.json'})

    def test_an_unpinned_shared_file_fails(self):
        (self.tests / 'hook-only-vectors.json').write_text('{}\n', encoding='utf-8')
        report, _ = self.fails()
        self.assertEqual(report.unpinned, {'data/hook-only-vectors.json'})

    def test_an_unclassified_pond_vector_fails(self):
        (self.tests / 'new-vectors.json').write_text('{}\n', encoding='utf-8')
        report, _ = self.fails()
        self.assertEqual(report.unclassified, {'new-vectors.json'})

    def test_a_pond_only_file_in_the_manifest_fails(self):
        shutil.copyfile(self.tests / 'then-instructable-vectors.json',
                        self.suite / 'data/then-instructable-vectors.json')
        self.write_manifest(list(sync.SHARED) + ['data/then-instructable-vectors.json'])
        report, _ = self.fails()
        self.assertEqual(report.misclassified, {'then-instructable-vectors.json'})

    def test_no_manifest_fails(self):
        (self.suite / 'manifest.json').unlink()
        self.fails()

    def test_no_pond_tests_folder_fails(self):
        self.fails(pond=Path(self._tmp.name) / 'no-such-pond')

    def test_the_command_without_a_pond_fails(self):
        env = {'PATH': '/usr/bin:/bin'}
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)],
                                capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('POND_DIR', result.stderr)


if __name__ == '__main__':
    unittest.main()
