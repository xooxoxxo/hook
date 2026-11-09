"""Exercise release refusals without signing credentials or publication."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

verify = module('verify_release', 'verify-release.py')
publisher = module('publish_release', 'publish-release.py')
TEAM = 'ABCDEFGHIJ'
SIGNATURE = ('TeamIdentifier=' + TEAM + '\nAuthority=Developer ID Application: Example (' + TEAM + ')\nCodeDirectory flags=0x10000(runtime)\nTimestamp=Nov 8, 2026\n').encode()


class AppVerification(unittest.TestCase):
    def exercise(self, signature=SIGNATURE, debug=False, failed_command=None):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            (app / 'Contents').mkdir()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.github.xooxoxxo.relay', 'CFBundleShortVersionString': '0.15.2', 'CFBundleVersion': '0.15.2'}))
            def call(argv, **kwargs):
                if failed_command and failed_command in argv:
                    raise subprocess.CalledProcessError(1, argv)
                stdout = plistlib.dumps({'com.apple.security.get-task-allow': debug}) if '--entitlements' in argv else b''
                return subprocess.CompletedProcess(argv, 0, stdout, signature)
            with patch.object(verify.subprocess, 'run', side_effect=call) as commands:
                verify.verify_app(app, '0.15.2', TEAM)
                return [c.args[0] for c in commands.call_args_list]

    def test_valid_app_requires_signature_staple_and_gatekeeper(self):
        calls = self.exercise()
        self.assertTrue(any('--strict' in c for c in calls))
        self.assertTrue(any('stapler' in c for c in calls))
        self.assertTrue(any('spctl' in c for c in calls))

    def test_wrong_identity_runtime_timestamp_and_debug_rejected(self):
        for signature in (SIGNATURE.replace(TEAM.encode(), b'XXXXXXXXXX'), SIGNATURE.replace(b'Developer ID Application', b'Apple Development'), SIGNATURE.replace(b'runtime', b'none'), SIGNATURE.replace(b'Timestamp=', b'Unsigned=')):
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                self.exercise(signature)
        with self.assertRaises(ValueError):
            self.exercise(debug=True)

    def test_failed_signature_staple_or_gatekeeper_is_fatal(self):
        for command in ('--verify', 'stapler', 'spctl'):
            with self.subTest(command=command), self.assertRaises(subprocess.CalledProcessError):
                self.exercise(failed_command=command)

    def test_altered_archive_fails_before_extract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Hook-0.15.2.zip').write_bytes(b'altered')
            (root / 'SHA256SUMS').write_text('0' * 64 + '  Hook-0.15.2.zip\n')
            with patch.object(verify, 'run') as command, self.assertRaises(ValueError):
                verify.verify_package(root, '0.15.2', TEAM)
            command.assert_not_called()


class SigningSettings(unittest.TestCase):
    def test_missing_and_partial_credentials_fail_before_keychain(self):
        for extra in ({}, {'MACOS_SIGN_P12': 'not-a-secret'}, {'MACOS_SIGN_P12': 'x', 'MACOS_SIGN_PASSWORD': 'x'}):
            with tempfile.TemporaryDirectory() as tmp:
                env = dict(PATH=os.environ['PATH'], RUNNER_TEMP=tmp, GITHUB_ENV=tmp + '/env', **extra)
                result = subprocess.run(['bash', str(ROOT / 'prepare-release-signing.sh')], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Missing required release setting', result.stderr)
                self.assertFalse((Path(tmp) / 'env').exists())


class Publication(unittest.TestCase):
    def test_wrong_commit_and_already_published_never_publish(self):
        args = ('v0.15.2', 'a'*40, 'b'*64, TEAM, '11111111-1111-4111-8111-111111111111')
        for responses in ([b'c'*40], [b'a'*40, json.dumps({'isDraft': False, 'isPrerelease': False, 'tagName': args[0]}).encode()]):
            with patch.object(publisher.verify, 'run', side_effect=responses), patch.object(publisher.subprocess, 'run') as publish, self.assertRaises(ValueError):
                publisher.publish(*args)
            publish.assert_not_called()

    def test_rejected_notarization_never_reaches_publication(self):
        def response(*argv):
            if argv[0] == 'git':
                return b'a'*40
            if 'view' in argv:
                return json.dumps({'isDraft': True, 'isPrerelease': False, 'tagName': 'v0.15.2'}).encode()
            directory = Path(argv[argv.index('--dir') + 1])
            (directory / 'notary-result.json').write_text('{"status":"Invalid"}')
            return b''
        with patch.object(publisher.verify, 'run', side_effect=response), patch.object(publisher.verify, 'verify_package') as package, patch.object(publisher.subprocess, 'run') as publish, self.assertRaises(ValueError):
            publisher.publish('v0.15.2', 'a'*40, 'b'*64, TEAM, '11111111-1111-4111-8111-111111111111')
        package.assert_not_called()
        publish.assert_not_called()

    def test_failed_package_verification_never_publishes(self):
        def response(*argv):
            if argv[0] == 'git':
                return b'a'*40
            if 'view' in argv:
                return json.dumps({'isDraft': True, 'isPrerelease': False, 'tagName': 'v0.15.2'}).encode()
            directory = Path(argv[argv.index('--dir') + 1])
            (directory / 'notary-result.json').write_text('{"status":"Accepted"}')
            return b''
        with patch.object(publisher.verify, 'run', side_effect=response), patch.object(publisher.verify, 'verify_package', side_effect=ValueError('bad package')), patch.object(publisher.subprocess, 'run') as publish, self.assertRaises(ValueError):
            publisher.publish('v0.15.2', 'a'*40, 'b'*64, TEAM, '11111111-1111-4111-8111-111111111111')
        publish.assert_not_called()


if __name__ == '__main__':
    unittest.main()
