import hashlib
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import quote

import relay_cli
import relay_client
import pond_enroll as enroll

ORIGIN = 'https://pond.example.test'
INVITE = 'a' * 43
LINK = 'hook://join?v=2&pond=' + quote(ORIGIN, safe='') + '#' + INVITE
KEY = 'b' * 43


class Enrollment(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = pathlib.Path(temp.name) / 'config.json'
        self.env = {'RELAY_CONFIG': str(self.path)}
        self.out = io.StringIO()
        self.calls = []
        self.keys = {}

    def exchange(self, client, method, path, *, body=None, auth=None):
        self.calls.append((method, path, body, auth))
        if path == '/admission/claim':
            self.assertIsNone(auth)
            self.assertEqual(body, dict(kind='agent', label='Builder', invite=INVITE,
                                        keyHash=hashlib.sha256(KEY.encode()).hexdigest()))
            return 201, {'status': 'pending', 'id': 'one', 'code': '001234', 'expires': 1999999999}
        self.assertEqual(auth, KEY)
        if path == '/admission/me':
            if not any(method == 'POST' for method, *_ in self.calls):
                return 401, {}
            return 200, dict(id='one', kind='agent', role='agent', status='approved')
        if path == '/version':
            return 200, {'features': ['admission']}
        if path.startswith('/events?'):
            return 200, {'events': []}
        self.fail(path)

    def run_enroll(self):
        with patch.object(enroll, 'hidden_invite', return_value=LINK), \
             patch.object(enroll, 'new_key', return_value=KEY), \
             patch.object(enroll, 'save_key', side_effect=self.keys.__setitem__), \
             patch.object(enroll, 'read_key', side_effect=self.keys.__getitem__), \
             patch.object(relay_client.Client, '_transport', autospec=True, side_effect=self.exchange):
            return relay_cli.main(['host', 'enroll', '--agent', 'Builder'], env=self.env,
                                  stdout=self.out, stderr=self.out)

    def test_cli_enroll_binds_agent_reloads_key_and_checks_answers(self):
        self.assertEqual(self.run_enroll(), 0, self.out.getvalue())
        cfg = json.loads(self.path.read_text())
        for text in (self.path.read_text(), self.out.getvalue()):
            self.assertNotIn(KEY, text)
            self.assertNotIn(INVITE, text)
        self.assertIn('001234', self.out.getvalue())
        self.assertIn('/version', [call[1] for call in self.calls])
        self.assertTrue(any(call[1].startswith('/events?') for call in self.calls))
        self.assertNotIn('tokenFile', cfg)
        a = relay_client.Client(cfg)
        with patch.object(enroll, 'read_key', side_effect=self.keys.__getitem__):
            self.assertEqual(a._mailbox_token(), KEY)
        self.assertNotEqual(a.source_key(), relay_client.Client(dict(cfg, credentialRef='c'*32)).source_key())

    def test_store_failure_before_claim(self):
        class Unavailable(dict):
            def __setitem__(self, key, value):
                raise relay_client.ConfigMissing('Unlock the secret store')
        self.keys = Unavailable()
        self.assertNotEqual(self.run_enroll(), 0)
        self.assertEqual(self.calls, [])
        self.assertIn('Unlock', self.out.getvalue())

    def test_only_one_https_origin_and_fragment(self):
        self.assertEqual(enroll.parse_invite(LINK), (ORIGIN, INVITE))
        for value in ('http://x.example', ORIGIN+'/path', ORIGIN+'?k=v', 'https://me@pond.example',
                      'https://pond.example:bad', 'https://pond.example\\@else.example'):
            with self.subTest(value=value), self.assertRaises(relay_client.RelayError):
                enroll.parse_invite(LINK.replace(quote(ORIGIN, safe=''), quote(value, safe='')))
        for value in (LINK.replace('v=2', 'v=2&v=2'), LINK[:-1], LINK.replace('v=2', 'v=1')):
            with self.assertRaises(relay_client.RelayError):
                enroll.parse_invite(value)

    def test_configured_agents_use_separate_local_edit_key_stores(self):
        cfg = dict(source='mailbox', mailboxURL=ORIGIN)
        env = dict(self.env, RELAY_EDIT_KEY_DIR=str(self.path.parent/'keys'))
        first, second = [relay_client.Client(dict(cfg, credentialRef=char * 32), env=env)
                         for char in ('a', 'b')]
        a = relay_client.EditKeys(first.env)
        a.pending('Example', 'Review', first.source_key())
        a.commit('Example', 'Review', 'ask-one', 1, '', '', first.source_key())
        self.assertIsNone(relay_client.EditKeys(second.env).load('ask-one'))

    def test_interrupted_claim_resumes_with_same_key_and_request(self):
        exchange = self.exchange
        def lose_reply(*args, **kwargs):
            status, state = exchange(*args, **kwargs)
            if args[2] == '/admission/claim':
                raise relay_client.Unreachable('connection closed')
            return status, state
        self.exchange = lose_reply
        self.assertNotEqual(self.run_enroll(), 0)
        self.assertFalse(self.path.exists())
        self.exchange = exchange
        self.assertEqual(self.run_enroll(), 0)
        self.assertEqual(len(self.keys), 1)
        self.assertEqual(sum(path == '/admission/claim' for _, path, *_ in self.calls), 1)

    def test_missing_feature_leaves_previous_configuration_intact(self):
        previous = dict(source='mailbox', credentialRef='d'*32, mailboxURL=ORIGIN, enrolledAgent='Builder')
        self.path.write_text(json.dumps(previous))
        exchange = self.exchange
        def older(*args, **kwargs):
            if args[2] == '/version':
                return 200, {'features': []}
            return exchange(*args, **kwargs)
        self.exchange = older
        self.assertNotEqual(self.run_enroll(), 0)
        self.assertEqual(json.loads(self.path.read_text()), previous)

    def test_bare_command_uses_current_service_account_label(self):
        with patch.object(enroll, 'enroll', return_value=0) as call:
            rc = relay_cli.main(['host', 'enroll'], env=self.env, stdout=self.out, stderr=self.out)
        self.assertEqual(rc, 0)
        self.assertTrue(call.call_args.args[0])

    def test_matches_pond_label_limit_before_storing_key(self):
        with patch.object(enroll, 'hidden_invite', side_effect=AssertionError('invalid label prompted')):
            with self.assertRaisesRegex(relay_client.ConfigMissing, '40'):
                enroll.enroll('x' * 41, self.env, self.out)

    def test_linux_secret_store_keeps_password_out_of_arguments(self):
        from subprocess import CompletedProcess
        with patch.object(enroll.sys, 'platform', 'linux'), patch.object(enroll.subprocess, 'run') as run:
            run.return_value = CompletedProcess([], 0, stdout=b'')
            enroll.save_key('agent-account', KEY)
            self.assertNotIn(KEY, str(run.call_args.args))
            self.assertEqual(run.call_args.kwargs['input'], KEY.encode())
            run.return_value = CompletedProcess([], 0, stdout=KEY.encode() + b'\n')
            self.assertEqual(enroll.read_key('agent-account'), KEY)
            run.return_value = CompletedProcess([], 1, stdout=b'')
            with self.assertRaisesRegex(relay_client.ConfigMissing, 'Secret Service'):
                enroll.read_key('agent-account')

    def test_enroll_preserves_owner_profile_before_asking_for_invite(self):
        for cfg in ({'source': 'local'}, {'source': 'mailbox', 'tokenFile': 'legacy'},
                    {'source': 'mailbox', 'credentialRef': 'device-reference'}):
            self.path.write_text(json.dumps(cfg))
            with patch.object(enroll, 'hidden_invite', side_effect=AssertionError('prompted')):
                with self.assertRaisesRegex(relay_client.ConfigMissing, 'RELAY_CONFIG'):
                    enroll.enroll('Builder', self.env, self.out)
            self.assertEqual(json.loads(self.path.read_text()), cfg)
