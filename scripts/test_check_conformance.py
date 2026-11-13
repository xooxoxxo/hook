"""Tests for scripts/check-conformance.py, run on a throwaway tree."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / 'check-conformance.py'
CASES = {'version': 1, 'cases': [{'name': 'one', 'kind': 'hash'}, {'name': 'two', 'kind': 'assign'}]}


class CheckConformance(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.entry = {'path': 'data/demo-vectors.json', 'pond': '1.1.0', 'feature': 'demo',
                      'roles': ['reader', 'server'], 'kinds': {'hash': ['reader'], 'assign': ['server']},
                      'copies': ['Tests/Fixtures/demo-vectors.json']}
        self.write('conformance/data/demo-vectors.json', json.dumps(CASES, indent=1) + '\n')
        self.write('Tests/Fixtures/demo-vectors.json', json.dumps(CASES, indent=1) + '\n')
        self.write_manifest([self.entry])

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def write_manifest(self, files):
        self.write('conformance/manifest.json', json.dumps({'suite': 1, 'files': files}, indent=1) + '\n')

    def run_check(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)],
                                capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def test_identical_copy_passes(self):
        code, out = self.run_check()
        self.assertEqual(code, 0, out)

    def test_one_byte_difference_fails_naming_the_copy(self):
        copy = self.root / 'Tests/Fixtures/demo-vectors.json'
        data = bytearray(copy.read_bytes())
        data[-1:] = b' '
        copy.write_bytes(bytes(data))
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('Tests/Fixtures/demo-vectors.json', out)

    def test_missing_copy_fails(self):
        (self.root / 'Tests/Fixtures/demo-vectors.json').unlink()
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('Tests/Fixtures/demo-vectors.json', out)

    def test_file_not_in_manifest_fails(self):
        self.write('conformance/wire/stray-vectors.json', '{"version": 1, "cases": []}\n')
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('wire/stray-vectors.json', out)

    def test_manifest_path_missing_fails(self):
        self.write_manifest([self.entry, {'path': 'wire/gone-vectors.json', 'pond': '1.2.0',
                                          'feature': 'gone', 'roles': ['server'], 'copies': []}])
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('wire/gone-vectors.json', out)

    def test_unknown_role_fails(self):
        self.entry['roles'] = ['reader', 'phone']
        self.write_manifest([self.entry])
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('phone', out)

    def test_case_kind_missing_from_kinds_fails(self):
        del self.entry['kinds']['assign']
        self.write_manifest([self.entry])
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('assign', out)

    def test_missing_field_fails(self):
        del self.entry['pond']
        self.write_manifest([self.entry])
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('pond', out)

    def test_no_manifest_fails(self):
        (self.root / 'conformance/manifest.json').unlink()
        code, out = self.run_check()
        self.assertEqual(code, 1, out)
        self.assertIn('manifest.json', out)


if __name__ == '__main__':
    unittest.main()
