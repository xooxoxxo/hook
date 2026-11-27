"""Enroll an agent and keep its Pond credential in the OS secret store."""
from __future__ import annotations

import ctypes
import fcntl
import getpass
import hashlib
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.parse
import warnings

from relay_client import Client, ConfigMissing, RelayError, check_trusted_dir, config_path, load_config, private_write

SERVICE = 'org.hook.pond.agent'
SECRET = re.compile(r'[A-Za-z0-9_-]{43}')
STORE_HELP = ('Unlock the login Keychain on macOS. On Linux, install secret-tool and unlock '
              'a Secret Service collection in the agent service account’s D-Bus session.')


def origin(value):
    try:
        if not isinstance(value, str) or not value.isascii() or any(
                ch.isspace() or ord(ch) < 32 or ch in '\\?#@' for ch in value):
            raise ValueError
        url = urllib.parse.urlsplit(value)
        host = url.hostname or ''
        port = url.port
        if url.scheme != 'https' or url.path not in ('', '/') or not host or port == 0:
            raise ValueError
        if ':' in host:
            host = '[' + str(ipaddress.IPv6Address(host)) + ']'
        elif not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part)
                     for part in host.split('.')):
            raise ValueError
        authority = host + (':' + str(port) if port is not None else '')
        if url.netloc.lower() != authority:
            raise ValueError
        return 'https://' + host + (':' + str(port) if port not in (None, 443) else '')
    except ValueError:
        raise ConfigMissing('Expected a single HTTPS Pond origin.') from None


def parse_invite(link):
    try:
        value = urllib.parse.urlsplit(link)
        pairs = urllib.parse.parse_qsl(value.query, strict_parsing=True, keep_blank_values=True)
        if (value.scheme, value.netloc, value.path) != ('hook', 'join', '') or len(pairs) != 2:
            raise ValueError
        fields = dict(pairs)
        if fields.get('v') != '2' or 'pond' not in fields or not SECRET.fullmatch(value.fragment):
            raise ValueError
        return origin(fields['pond']), value.fragment
    except ValueError:
        raise ConfigMissing('Expected a v2 Pond invite link.') from None


def hidden_invite():
    with warnings.catch_warnings():
        warnings.simplefilter('error', getpass.GetPassWarning)
        try:
            return getpass.getpass('Paste the Pond invite (hidden): ').strip()
        except (EOFError, getpass.GetPassWarning):
            raise ConfigMissing('Run hook host enroll in a terminal with hidden input.') from None


def new_key():
    return secrets.token_urlsafe(32)


def account(url, ref):
    return hashlib.sha256((url + '\n' + ref).encode()).hexdigest()


def store_command(args, data=None):
    try:
        result = subprocess.run(args, input=data or b'', stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise ConfigMissing(STORE_HELP) from None
    if result.returncode:
        raise ConfigMissing(STORE_HELP)
    return result.stdout


def read_key(name):
    if sys.platform == 'darwin':
        try:
            sec = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
            find = sec.SecKeychainFindGenericPassword
            size, ptr = ctypes.c_uint32(), ctypes.c_void_p()
            find.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32,
                             ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32),
                             ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
            status = find(None, len(SERVICE), SERVICE.encode(), len(name), name.encode(),
                          ctypes.byref(size), ctypes.byref(ptr), None)
            if status:
                raise ConfigMissing(STORE_HELP)
            try:
                key = ctypes.string_at(ptr, size.value)
            finally:
                sec.SecKeychainItemFreeContent(None, ptr)
        except (OSError, AttributeError):
            raise ConfigMissing(STORE_HELP) from None
    elif sys.platform.startswith('linux'):
        key = store_command(['secret-tool', 'lookup', 'service', SERVICE, 'account', name]).strip()
    else:
        raise ConfigMissing(STORE_HELP)
    if not re.fullmatch(rb'[A-Za-z0-9_-]{43}', key):
        raise ConfigMissing(STORE_HELP)
    return key.decode('ascii')


def save_key(name, key):
    if sys.platform == 'darwin':
        # The command-line add operation takes its password in argv. Use Security.framework
        # directly so process listings cannot expose it.
        try:
            sec = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
            add = sec.SecKeychainAddGenericPassword
            add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32,
                            ctypes.c_char_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
            status = add(None, len(SERVICE), SERVICE.encode(), len(name), name.encode(),
                         len(key), key.encode(), None)
        except (OSError, AttributeError):
            raise ConfigMissing(STORE_HELP) from None
        if status:
            raise ConfigMissing(STORE_HELP)
    elif sys.platform.startswith('linux'):
        store_command(['secret-tool', 'store', '--label=Hook Pond agent', 'service', SERVICE,
                       'account', name], key.encode())
    else:
        raise ConfigMissing(STORE_HELP)


def write_config(path, data):
    private_write(path, (json.dumps(data, indent=2) + '\n').encode())


def enroll(agent, env, out):
    if not agent.strip() or len(agent) > 40 or any(not ch.isprintable() for ch in agent):
        raise ConfigMissing('Choose a printable agent label of 1 to 40 characters.')
    path = config_path(env)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    check_trusted_dir(path.parent)
    with path.with_name(path.name + '.enroll.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ConfigMissing('Another enrollment is using this configuration.') from None
        try:
            return _enroll(path, agent, env, out)
        except OSError:
            raise ConfigMissing('Could not save the agent configuration.') from None


def _enroll(path, agent, env, out):
    existing = load_config(env) if path.exists() else None
    if existing is not None and (existing.get('enrolledAgent') != agent
                                 or existing.get('source') != 'mailbox'
                                 or not existing.get('credentialRef')):
        raise ConfigMissing('Set RELAY_CONFIG to a separate agent config path before enrolling.')
    url, invite = parse_invite(hidden_invite())
    pending_path = path.with_name(path.name + '.enrollment')
    pending = load_config({'RELAY_CONFIG': str(pending_path)}) if pending_path.exists() else {}
    digest = hashlib.sha256(invite.encode()).hexdigest()
    if (pending.get('inviteHash'), pending.get('url'), pending.get('agent')) == (digest, url, agent):
        ref = pending['ref']
        key = read_key(account(url, ref))
    else:
        ref = secrets.token_hex(16)
        key = new_key()
        name = account(url, ref)
        save_key(name, key)
        if read_key(name) != key:
            raise ConfigMissing(STORE_HELP)
        write_config(pending_path, dict(url=url, ref=ref, agent=agent, inviteHash=digest))

    cfg = dict(existing or {}, source='mailbox', mailboxURL=url, credentialRef=ref, enrolledAgent=agent)
    cfg.pop('tokenFile', None)
    client = Client(cfg, env=env, autolaunch=False)
    def request(method, route, *, body=None, auth=key):
        status, response = client._transport(method, route, body=body, auth=auth)
        return status, response if isinstance(response, dict) else {}

    status, state = request('GET', '/admission/me')
    if status == 401:
        body = dict(kind='agent', label=agent, invite=invite, keyHash=hashlib.sha256(key.encode()).hexdigest())
        status, state = request('POST', '/admission/claim', body=body, auth=None)
        if status != 201 or state.get('status') != 'pending':
            raise RelayError(f'Pond declined the agent invite (HTTP {status}).')
    elif status != 200:
        raise RelayError(f'Could not check enrollment (HTTP {status}).')

    identity = state.get('id')
    if not isinstance(identity, str) or not identity:
        raise RelayError('Pond returned an invalid enrollment ID.')
    if state.get('status') == 'pending':
        code, expires = state.get('code'), state.get('expires')
        if (not isinstance(code, str) or not re.fullmatch('[0-9]{6}', code)
                or type(expires) is not int):
            raise RelayError('Pond returned an invalid pending request.')
        print(f'Compare code {code} on an approved device.', file=out, flush=True)
        deadline = time.monotonic() + max(0, min(600, expires - time.time()))
        while time.monotonic() < deadline:
            status, state = request('GET', '/admission/me')
            if status != 200 or state.get('status') != 'pending' or state.get('id') != identity:
                break
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    if (status != 200 or state.get('id') != identity or state.get('status') != 'approved'
            or state.get('kind') != 'agent' or state.get('role') != 'agent'):
        raise RelayError('This agent was not approved. Check the request on an admitted device.')
    status, version = request('GET', '/version')
    features = version.get('features')
    if status != 200 or not isinstance(features, list) or 'admission' not in features:
        raise RelayError('This Pond does not advertise agent admission.')
    events = client.events(limit=1)
    if not isinstance(events.get('events'), list):
        raise RelayError('Pond returned an invalid answer feed.')
    if (load_config(env) if path.exists() else None) != existing:
        raise ConfigMissing('The config changed during enrollment. Check RELAY_CONFIG before retrying.')
    write_config(path, cfg)
    pending_path.unlink()
    print(f'Enrolled {agent} on {url}.', file=out)
    return 0
