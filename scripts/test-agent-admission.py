#!/usr/bin/env python3
"""Exercise the Hook CLI and MCP against an isolated Pond checkout, over loopback TLS.

Usage: python3 scripts/test-agent-admission.py /path/to/pond
Requires OpenSSL with req -addext. Uses a temporary CA and an in-memory secret
store. All SQLite data, agent profiles and edit keys live in the temporary tree.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import urllib.request
from unittest.mock import patch

if len(sys.argv) != 2:
    raise SystemExit('usage: python3 scripts/test-agent-admission.py POND_CHECKOUT')

HOOK = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(HOOK / 'clients'), str(HOOK / 'mcp'), str(Path(sys.argv[1]).resolve())]
from mailbox.server import MailboxServer
from mailbox.telegram import FakeTelegramClient
import pond_enroll
import relay_cli
import relay_mcp


def run(root):
    cert, private = root / 'test-ca.pem', root / 'test-ca.key'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=Hook test', '-addext', 'subjectAltName=IP:127.0.0.1',
                    '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
                    '-addext', 'basicConstraints=critical,CA:TRUE',
                    '-keyout', str(private), '-out', str(cert)], check=True, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, private)
    pond = MailboxServer(root/'data', root/'backups', 'synthetic', 1, 'personal', port=0, host='127.0.0.1')
    pond.service.telegram = pond.telegram = FakeTelegramClient(owner_id=1)
    server = pond.http_server
    server.socket = context.wrap_socket(server.socket, server_side=True)
    origin = 'https://127.0.0.1:' + str(server.server_address[1])
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with patch.dict(os.environ, SSL_CERT_FILE=str(cert), no_proxy='127.0.0.1',
                        RELAY_EDIT_KEY_DIR=str(root/'edit-keys')):
            verify(pond, root, origin)
    finally:
        pond.stop()
        thread.join(10)


def verify(pond, root, origin):
    admin = secrets.token_urlsafe(32)
    first = pond.service.admission.operator_invite('first', origin)
    secrets_used = [admin, urllib.parse.urlsplit(first['link']).fragment]

    def request(path, body=None, *, bearer=admin):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(origin + path, data=data, headers={'Content-Type': 'application/json'})
        if bearer is not None:
            req.add_header('Authorization', 'Bearer ' + bearer)
        with urllib.request.urlopen(req, timeout=5) as response:
            return json.load(response)

    request('/admission/claim', dict(invite=secrets_used[-1], kind='device', label='Desktop',
                                     keyHash=hashlib.sha256(admin.encode()).hexdigest()), bearer=None)

    class Owner(io.StringIO):
        def write(self, text):
            if text.startswith('Compare code '):
                code = text.split()[2]
                pending, = request('/admission/pending')['pending']
                assert pending['code'] == code
                request('/admission/requests/' + pending['id'] + '/decision', dict(decision='approve', code=code))
            return super().write(text)

    out, store, asks = Owner(), {}, []
    with patch.object(pond_enroll, 'save_key', side_effect=store.__setitem__), \
         patch.object(pond_enroll, 'read_key', side_effect=store.__getitem__):
        for agent in ('Builder', 'Reviewer'):
            config = str(root / (agent + '.json'))
            link = request('/admission/invites', dict(kind='agent'))['link']
            secrets_used.append(urllib.parse.urlsplit(link).fragment)
            with patch.dict(os.environ, RELAY_CONFIG=config), patch.object(pond_enroll, 'hidden_invite', return_value=link):
                assert relay_cli.main(['host', 'enroll', '--agent', agent], stdout=out, stderr=out) == 0
                ask = dict(v=1, title='Review changes', why='The build is ready.', steps=[{'do': 'Check the build'}])
                response = relay_mcp.call_tool(dict(name='relay_post', arguments=dict(project='Example', instructable=ask)))
                assert not response['isError'], response['structuredContent'].get('error')
                asks.append(response['structuredContent']['id'])
        assert asks[0] != asks[1]
        request('/asks/' + asks[0] + '/reply', {'text': 'Approved in review'})
        for index, agent in enumerate(('Builder', 'Reviewer')):
            with patch.dict(os.environ, RELAY_CONFIG=str(root/(agent + '.json'))):
                items = relay_mcp.call_tool(dict(name='relay_list'))['structuredContent']['items']
                assert [item['id'] for item in items] == [asks[index]]
                other = asks[1-index]
                assert relay_mcp.call_tool(dict(name='relay_status', arguments={'id': other}))['isError']
                assert relay_cli.main(['wait', other], stdout=out, stderr=out) == 1
                if index == 0:
                    assert relay_cli.main(['wait', asks[0]], stdout=out, stderr=out) == 0
        member = next(p for p in request('/admission/principals')['principals'] if p['label'] == 'Builder')
        request('/admission/principals/' + member['id'] + '/revoke', {})
        with patch.dict(os.environ, RELAY_CONFIG=str(root/'Builder.json')):
            assert relay_mcp.call_tool(dict(name='relay_list'))['isError']
            assert relay_cli.main(['wait', asks[0]], stdout=out, stderr=out) == 1
    assert 'Approved in review' in out.getvalue()
    assert all(secret not in out.getvalue() for secret in [*secrets_used, *store.values()])


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='hook-admission-test-') as tree:
        run(Path(tree))
    print('Two agents enrolled over TLS. Scoped posts, lists, waits and revocation passed.')
