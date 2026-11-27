"""Two agent profiles through the public CLI, wait and MCP entry points."""
import hashlib
import io
import json
import os
import pathlib
import tempfile
import unittest
from urllib.parse import quote
from unittest.mock import patch

import relay_mcp
import relay_cli
import relay_client
import pond_enroll

URL = 'https://pond.example.test'


class AgentTransport(unittest.TestCase):
    def test_two_enrolled_profiles_and_revocation(self):
        owners, pending, keys, out = {}, {}, {}, io.StringIO()

        def exchange(client, method, path, *, body=None, auth=None):
            if path == '/admission/claim':
                pending[body['keyHash']] = body['label']
                return 201, dict(id=body['label'], code='003145', status='pending', expires=1999999999)
            label = pending.get(hashlib.sha256(auth.encode()).hexdigest())
            if not label:
                return 401, {}
            if path == '/admission/me':
                return 200, dict(id=label, role='agent', kind='agent', status='approved')
            if path == '/version':
                return 200, dict(features=['admission'])
            if path.startswith('/events?'):
                return 200, dict(events=[])
            if path.startswith('/asks?'):
                return 200, dict(items=[item for item in owners.values() if item['title'] == label])
            if path.startswith('/asks/'):
                item = owners.get(path.split('/')[2], {})
                if item.get('title') != label:
                    return 404, {}
                return 200, dict(item=item, events=[dict(seq=1, actor='owner', kind='reply', text='Reviewed')])
            self.fail(path)

        with tempfile.TemporaryDirectory() as directory, \
             patch.object(pond_enroll, 'save_key', side_effect=keys.__setitem__), \
             patch.object(pond_enroll, 'read_key', side_effect=keys.__getitem__), \
             patch.object(relay_client.Client, '_transport', autospec=True, side_effect=exchange):
            profiles = []
            for label in ('Builder', 'Reviewer'):
                config = str(pathlib.Path(directory) / (label + '.json'))
                profiles.append(config)
                env = {'RELAY_CONFIG': config}
                link = 'hook://join?v=2&pond=' + quote(URL, safe='') + '#' + label[0] * 43
                with patch.object(pond_enroll, 'hidden_invite', return_value=link):
                    self.assertEqual(relay_cli.main(['host', 'enroll', '--agent', label],
                                                    env=env, stdout=out, stderr=out), 0)
                # The simulated Pond owns one ask per enrolled agent.
                owners[label] = dict(id=label, title=label, status='open')
                self.assertNotIn(link, out.getvalue())
            for config, own, other in [(profiles[0], 'Builder', 'Reviewer'), (profiles[1], 'Reviewer', 'Builder')]:
                with patch.dict(os.environ, RELAY_CONFIG=config):
                    listed = relay_mcp.handle('tools/call', dict(name='relay_list', arguments={}))
                    self.assertEqual([i['id'] for i in listed['structuredContent']['items']], [own])
                    denied = relay_mcp.handle('tools/call', dict(name='relay_status', arguments={'id': other}))
                    self.assertTrue(denied['isError'])
                    self.assertNotIn('Reviewed', json.dumps(denied))
                    self.assertEqual(relay_cli.main(['wait', own, '--timeout', '1'], stdout=out, stderr=out), 0)
                    self.assertEqual(relay_cli.main(['wait', other, '--timeout', '1'], stdout=out, stderr=out), 1)
            pending.clear()
            with patch.dict(os.environ, RELAY_CONFIG=profiles[0]):
                self.assertTrue(relay_mcp.handle('tools/call', dict(name='relay_list'))['isError'])
                self.assertEqual(relay_cli.main(['wait', 'Builder'], stdout=out, stderr=out), 1)
            for secret in keys.values():
                self.assertNotIn(secret, out.getvalue())
