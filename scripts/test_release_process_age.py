"""Installer process-age regression without starting, inspecting or killing real apps."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class InstallerProcessAgeTests(unittest.TestCase):
    def classify(self, scan_at, age_at, age):
        source = Path(__file__).with_name('install.sh').read_text()
        function = re.search(r'^old_pids\(\) \{\n.*?^\}', source, re.M | re.S).group()
        # A deterministic clock models a slow process scan and a slow ps age query.
        # Run the actual installer function; none of the installer's top-level work runs.
        script = '''set -euo pipefail
INSTALL_STARTED=100
scan_at=$1
age_at=$2
observed_age=$3
echo 100 > clock
date() { cat clock; }
our_pids() { echo "$scan_at" > clock; echo 42; }
pid_age() { echo "$age_at" > clock; printf '%s' "$observed_age"; }
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', '-c', script + function + '\nold_pids\n',
                                     'process-age-test', str(scan_at), str(age_at), age],
                                    cwd=directory, text=True, capture_output=True, check=True)
        return result.stdout.strip()

    def test_new_process_is_not_old_after_slow_discovery(self):
        self.assertEqual(self.classify(scan_at=102, age_at=102, age='1'), '')

    def test_new_process_is_not_old_after_slow_age_query(self):
        self.assertEqual(self.classify(scan_at=100, age_at=102, age='1'), '')

    def test_genuinely_old_process_is_still_rejected(self):
        self.assertEqual(self.classify(scan_at=102, age_at=103, age='9'), '42')

    def test_process_that_exited_during_scan_is_ignored(self):
        self.assertEqual(self.classify(scan_at=102, age_at=103, age=''), '')


if __name__ == '__main__':
    unittest.main()
