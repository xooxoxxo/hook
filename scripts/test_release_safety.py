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
APPROVAL = '11111111-1111-4111-8111-111111111111'


def fake_app(app, version='0.15.2', support=True):
    """A stand-in Hook.app: its Info.plist and, unless told otherwise, the bundled payload."""
    (app / 'Contents').mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.github.xooxoxxo.relay', 'CFBundleShortVersionString': version, 'CFBundleVersion': version}))
    if support:
        scripts = app / 'Contents/Resources/support/scripts'
        scripts.mkdir(parents=True)
        (scripts / 'install.sh').write_text('#!/bin/sh\n')
        (scripts / 'get.sh').write_text('#!/bin/sh\n')
        (app / 'Contents/Resources/support/VERSION').write_text(version + '\n')


class AppVerification(unittest.TestCase):
    def exercise(self, signature=SIGNATURE, debug=False, failed_command=None, support=True):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Hook.app'
            fake_app(app, support=support)
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

    def test_app_without_its_bundled_payload_rejected(self):
        with self.assertRaises(ValueError):
            self.exercise(support=False)

    def test_altered_archive_fails_before_extract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'Hook-0.15.2.zip').write_bytes(b'altered')
            (root / 'Hook-0.15.2.dmg').write_bytes(b'image')
            (root / 'SHA256SUMS').write_text('0' * 64 + '  Hook-0.15.2.zip\n' + verify.hashlib.sha256(b'image').hexdigest() + '  Hook-0.15.2.dmg\n')
            with patch.object(verify, 'run') as command, self.assertRaises(ValueError):
                verify.verify_package(root, '0.15.2', TEAM)
            command.assert_not_called()


class DiskImageVerification(unittest.TestCase):
    """verify_dmg: signature, staple, Gatekeeper and contents, without mounting anything."""

    def exercise(self, signature=SIGNATURE, failed_command=None, layout='good'):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / 'Hook-0.15.2.dmg'
            image.write_bytes(b'image')
            calls = []
            self.calls = calls

            def call(argv, **kwargs):
                calls.append(list(argv))
                if failed_command and failed_command in argv:
                    raise subprocess.CalledProcessError(1, argv)
                if 'attach' in argv:
                    mount = Path(argv[argv.index('-mountpoint') + 1])
                    fake_app(mount / 'Hook.app', support=layout != 'no-support')
                    if layout == 'extra':
                        (mount / 'Install me.command').write_text('#!/bin/sh\n')
                    if layout != 'no-link':
                        os.symlink('/Users' if layout == 'wrong-link' else '/Applications', mount / 'Applications')
                stdout = plistlib.dumps({}) if '--entitlements' in argv else b''
                return subprocess.CompletedProcess(argv, 0, stdout, signature)
            with patch.object(verify.subprocess, 'run', side_effect=call):
                verify.verify_dmg(image, '0.15.2', TEAM)
            return calls

    def detached(self):
        return any(c[:2] == ['hdiutil', 'detach'] for c in self.calls)

    def test_valid_image_requires_signature_staple_gatekeeper_and_layout(self):
        calls = self.exercise()
        image_calls = [c for c in calls if c[-1].endswith('.dmg')]
        self.assertIn(['codesign', '--verify', '--strict'], [c[:3] for c in image_calls])
        self.assertTrue(any(c[:3] == ['xcrun', 'stapler', 'validate'] for c in image_calls))
        self.assertTrue(any(c[0] == 'spctl' and 'open' in c and 'context:primary-signature' in c for c in image_calls))
        self.assertTrue(any(c[:2] == ['hdiutil', 'verify'] for c in image_calls))
        # The app inside is verified like the zip's, and the image is detached again.
        self.assertTrue(any(c[0] == 'spctl' and 'execute' in c and c[-1].endswith('Hook.app') for c in calls))
        self.assertTrue(self.detached())

    def test_wrong_identity_or_missing_timestamp_rejected(self):
        for signature in (SIGNATURE.replace(TEAM.encode(), b'XXXXXXXXXX'), SIGNATURE.replace(b'Developer ID Application', b'Apple Development'), SIGNATURE.replace(b'Timestamp=', b'Unsigned=')):
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                self.exercise(signature)

    def test_failed_signature_staple_gatekeeper_or_image_check_is_fatal(self):
        for command in ('--verify', 'stapler', 'spctl', 'verify', 'attach'):
            with self.subTest(command=command), self.assertRaises(subprocess.CalledProcessError):
                self.exercise(failed_command=command)

    def test_wrong_contents_rejected_and_the_image_detached(self):
        for layout in ('extra', 'no-link', 'wrong-link', 'no-support'):
            with self.subTest(layout=layout):
                with self.assertRaises(ValueError):
                    self.exercise(layout=layout)
                self.assertTrue(self.detached())


class PackageManifest(unittest.TestCase):
    """SHA256SUMS lists exactly the zip, then the DMG; both are checked before anything is opened."""

    def package(self, dmg=True):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / 'Hook-0.15.2.zip').write_bytes(b'zip')
        if dmg:
            (root / 'Hook-0.15.2.dmg').write_bytes(b'dmg')
        zip_hash = verify.hashlib.sha256(b'zip').hexdigest()
        dmg_hash = verify.hashlib.sha256(b'dmg').hexdigest()
        (root / 'SHA256SUMS').write_text(zip_hash + '  Hook-0.15.2.zip\n' + dmg_hash + '  Hook-0.15.2.dmg\n')
        return root, zip_hash, dmg_hash

    def refused(self, root, **kwargs):
        with patch.object(verify, 'run') as command, patch.object(verify, 'verify_dmg') as image, self.assertRaises(ValueError):
            verify.verify_package(root, '0.15.2', TEAM, **kwargs)
        command.assert_not_called()
        image.assert_not_called()

    def test_zip_only_manifest_missing_image_and_wrong_order_refused(self):
        root, zip_hash, dmg_hash = self.package()
        (root / 'SHA256SUMS').write_text(zip_hash + '  Hook-0.15.2.zip\n')
        self.refused(root)
        root, zip_hash, dmg_hash = self.package(dmg=False)
        self.refused(root)
        root, zip_hash, dmg_hash = self.package()
        (root / 'SHA256SUMS').write_text(dmg_hash + '  Hook-0.15.2.dmg\n' + zip_hash + '  Hook-0.15.2.zip\n')
        self.refused(root)

    def test_altered_image_and_unapproved_image_refused(self):
        root, zip_hash, dmg_hash = self.package()
        (root / 'Hook-0.15.2.dmg').write_bytes(b'altered')
        self.refused(root)
        root, zip_hash, dmg_hash = self.package()
        self.refused(root, expected=zip_hash, expected_dmg='0' * 64)
        self.refused(root, expected='0' * 64, expected_dmg=dmg_hash)

    def test_matching_package_checks_the_zip_app_and_the_image(self):
        root, zip_hash, dmg_hash = self.package()

        def extract(*argv):
            if argv[0] == 'ditto':
                destination = Path(argv[-1])
                fake_app(destination / 'Hook.app')
                (destination / 'support').mkdir()
                (destination / 'support/VERSION').write_text('0.15.2\n')
            return b''
        with patch.object(verify, 'run', side_effect=extract), patch.object(verify, 'verify_app') as app, patch.object(verify, 'verify_dmg') as image:
            self.assertEqual(verify.verify_package(root, '0.15.2', TEAM, zip_hash, dmg_hash), (zip_hash, dmg_hash))
        app.assert_called_once()
        image.assert_called_once_with(root / 'Hook-0.15.2.dmg', '0.15.2', TEAM)


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
        args = ('v0.15.2', 'a'*40, 'b'*64, TEAM, APPROVAL, 'd'*64)
        for responses in ([b'c'*40], [b'a'*40, json.dumps({'isDraft': False, 'isPrerelease': False, 'tagName': args[0]}).encode()]):
            with patch.object(publisher.verify, 'run', side_effect=responses), patch.object(publisher.subprocess, 'run') as publish, self.assertRaises(ValueError):
                publisher.publish(*args)
            publish.assert_not_called()

    def draft(self, app='Accepted', image='Accepted'):
        """The answers for the intended draft; a status of None leaves that evidence out."""
        self.downloads = []

        def response(*argv):
            if argv[0] == 'git':
                return b'a'*40
            if 'view' in argv:
                return json.dumps({'isDraft': True, 'isPrerelease': False, 'tagName': 'v0.15.2'}).encode()
            self.downloads.append(argv)
            directory = Path(argv[argv.index('--dir') + 1])
            for name, status in (('notary-result.json', app), ('notary-result-dmg.json', image)):
                if status is not None:
                    (directory / name).write_text(json.dumps({'status': status}))
            return b''
        return response

    def test_rejected_notarization_never_reaches_publication(self):
        for app, image in (('Invalid', 'Accepted'), ('Accepted', 'Invalid'), ('Accepted', None)):
            with self.subTest(app=app, image=image):
                with patch.object(publisher.verify, 'run', side_effect=self.draft(app, image)), patch.object(publisher.verify, 'verify_package') as package, patch.object(publisher.subprocess, 'run') as publish, self.assertRaises(ValueError):
                    publisher.publish('v0.15.2', 'a'*40, 'b'*64, TEAM, APPROVAL, 'd'*64)
                package.assert_not_called()
                publish.assert_not_called()

    def test_missing_disk_image_checksum_refused_before_anything_runs(self):
        for dmg in ('', None, 'D'*64, 'd'*63):
            with self.subTest(dmg=dmg), patch.object(publisher.verify, 'run') as command, patch.object(publisher.subprocess, 'run') as publish, self.assertRaises(ValueError):
                publisher.publish('v0.15.2', 'a'*40, 'b'*64, TEAM, APPROVAL, dmg)
            command.assert_not_called()
            publish.assert_not_called()

    def test_verified_draft_downloads_both_files_and_checks_both_checksums(self):
        with patch.object(publisher.verify, 'run', side_effect=self.draft()), patch.object(publisher.verify, 'verify_package') as package, patch.object(publisher.subprocess, 'run') as publish:
            publisher.publish('v0.15.2', 'a'*40, 'b'*64, TEAM, APPROVAL, 'd'*64)
        download = self.downloads[0]
        for pattern in ('Hook-*.zip', 'Hook-*.dmg', 'SHA256SUMS', 'notary-result.json', 'notary-result-dmg.json'):
            self.assertIn(pattern, download)
        self.assertEqual(package.call_args.args[1:], ('0.15.2', TEAM, 'b'*64, 'd'*64))
        publish.assert_called_once_with(['gh', 'release', 'edit', 'v0.15.2', '--draft=false', '--latest'], check=True)

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
            publisher.publish('v0.15.2', 'a'*40, 'b'*64, TEAM, APPROVAL, 'd'*64)
        publish.assert_not_called()


if __name__ == '__main__':
    unittest.main()
