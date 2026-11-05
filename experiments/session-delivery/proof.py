#!/usr/bin/env python3
"""Opt-in synthetic app-server proof. Never attaches an existing chat or reads Hook state."""
import argparse
import json
import queue
import subprocess
import tempfile
import threading
import time
import uuid


class RPC:
    def __init__(self, binary, cwd):
        self.process = subprocess.Popen([binary, 'app-server', '--listen', 'stdio://'],
                                        cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True)
        self.inbox = queue.Queue()
        self.events = []
        self.sequence = 0
        threading.Thread(target=self._read, daemon=True).start()
        try:
            self.call('initialize', {'clientInfo': {'name': 'hook_delivery_proof', 'version': '0.1.0'},
                                     'capabilities': {'experimentalApi': True}})
            self.write({'method': 'initialized'})
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.process.stdout:
            try:
                self.inbox.put(json.loads(line))
            except ValueError:
                continue
        self.inbox.put(None)

    def write(self, value):
        self.process.stdin.write(json.dumps(value) + '\n')
        self.process.stdin.flush()

    def receive(self, deadline):
        message = self.inbox.get(timeout=max(0.01, deadline - time.monotonic()))
        if message is None:
            raise RuntimeError('app-server exited')
        # The proof never approves tools, commands, patches or external actions.
        if 'method' in message and 'id' in message:
            self.write({'id': message['id'], 'error': {'code': -32601, 'message': 'Proof refuses tools'}})
        return message

    def call(self, method, params):
        self.sequence += 1
        request = self.sequence
        self.write({'id': request, 'method': method, 'params': params})
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            message = self.receive(deadline)
            if message.get('id') == request:
                if 'error' in message:
                    raise RuntimeError('RPC refused ' + method + ': ' + str(message['error'].get('code')))
                return message['result']
            self.events.append(message)
        raise TimeoutError(method)

    def completed(self, thread, turn):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            for index, event in enumerate(self.events):
                params = event.get('params', {})
                if (event.get('method') == 'turn/completed' and params.get('threadId') == thread
                        and params.get('turn', {}).get('id') == turn):
                    self.events.pop(index)
                    if params['turn'].get('status') != 'completed':
                        raise RuntimeError('Synthetic turn did not complete')
                    return
            self.events.append(self.receive(deadline))
        raise TimeoutError('turn/completed')

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()


class SyntheticDelivery:
    """Exact-recipient, fixed-input experiment, not a trust verifier or production queue.

    Ambiguous delivery is retained as pending and is NEVER automatically replayed.
    Only an observed completed turn with the expected reply is acknowledged.
    """
    def __init__(self, rpc, thread, records):
        self.rpc, self.thread, self.records = rpc, thread, records

    def deliver(self, recipient, event, *, synthetic=False, running=None):
        if not synthetic or recipient != self.thread:
            raise ValueError('Only this disposable session accepts synthetic proof events')
        if event in self.records:
            return self.records[event]
        marker = 'HOOK_PROOF_' + uuid.uuid4().hex
        record = {'status': 'pending', 'marker': marker}
        self.records[event] = record
        params = {'threadId': self.thread,
                  'input': [{'type': 'text', 'text': 'Reply with exactly ' + marker + '. Use no tools.'}],
                  'clientUserMessageId': str(uuid.uuid4())}
        if running:
            params['expectedTurnId'] = running
            result = self.rpc.call('turn/steer', params)
            turn = result['turnId']
        else:
            result = self.rpc.call('turn/start', params)
            turn = result['turn']['id']
        record['turn'] = turn
        self.rpc.completed(self.thread, turn)
        texts = [e.get('params', {}).get('item', {}).get('text', '') for e in self.rpc.events
                 if e.get('method') == 'item/completed'
                 and e.get('params', {}).get('threadId') == self.thread
                 and e.get('params', {}).get('turnId') == turn]
        if not any(marker == text.strip() for text in texts):
            raise RuntimeError('Transport completion without the synthetic acknowledgment')
        record['status'] = 'acknowledged'
        return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-codex', required=True, metavar='BINARY')
    args = parser.parse_args()
    results = {}
    with tempfile.TemporaryDirectory(prefix='hook-delivery-proof-') as cwd:
        rpc = RPC(args.live_codex, cwd)
        try:
            thread = rpc.call('thread/start', {
                'cwd': cwd, 'approvalPolicy': 'never', 'sandbox': 'read-only',
                'ephemeral': False,
                'developerInstructions': 'Synthetic transport test. Reply to markers only. Never use tools.'
            })['thread']['id']
            records = {}
            delivery = SyntheticDelivery(rpc, thread, records)
            results['idle_delivery'] = delivery.deliver(thread, 'one', synthetic=True)['status']
            results['duplicate'] = delivery.deliver(thread, 'one', synthetic=True)['status']
            # New adapter instance reconnects to the same owned runtime, without a second runner.
            delivery = SyntheticDelivery(rpc, thread, records)
            results['adapter_reconnect'] = delivery.deliver(thread, 'two', synthetic=True)['status']
            active = rpc.call('turn/start', {'threadId': thread, 'input': [{'type': 'text',
                'text': 'Think about a twelve digit multiplication, without tools, then reply READY.'}]})['turn']['id']
            results['running_steer'] = delivery.deliver(thread, 'three', synthetic=True, running=active)['status']
            rpc.close()
            rpc = RPC(args.live_codex, cwd)
            rpc.call('thread/resume', {'threadId': thread, 'cwd': cwd,
                                      'approvalPolicy': 'never', 'sandbox': 'read-only'})
            delivery = SyntheticDelivery(rpc, thread, records)
            results['runtime_restart'] = delivery.deliver(thread, 'four', synthetic=True)['status']
            rpc.call('thread/archive', {'threadId': thread})
            results['desktop_attachment'] = 'not demonstrated; this proof owns a separate app-server'
            print(json.dumps(results, indent=2))
        finally:
            rpc.close()


if __name__ == '__main__':
    main()
