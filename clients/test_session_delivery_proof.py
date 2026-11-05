"""Safety boundaries of the opt-in synthetic experiment; no model calls in CI."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'experiments/session-delivery/proof.py'
spec = importlib.util.spec_from_file_location('delivery_proof', path)
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class FakeRPC:
    def __init__(self, acknowledge=True, fail=False):
        self.calls, self.events = [], []
        self.acknowledge, self.fail = acknowledge, fail

    def call(self, method, params):
        self.calls.append((method, params))
        if self.fail:
            raise TimeoutError('ambiguous send')
        marker = params['input'][0]['text'].split()[3].rstrip('.')
        if self.acknowledge:
            self.events.append({'method': 'item/completed', 'params': {
                'threadId': 'owned', 'turnId': 'turn', 'item': {'text': marker}}})
        return {'turn': {'id': 'turn'}, 'turnId': 'turn'}

    def completed(self, thread, turn):
        pass


class DeliveryProofTests(unittest.TestCase):
    def test_unverified_or_wrong_recipient_never_reaches_runtime(self):
        rpc = FakeRPC()
        delivery = proof.SyntheticDelivery(rpc, 'owned', {})
        for recipient, synthetic in [('other', True), ('owned', False)]:
            with self.assertRaises(ValueError):
                delivery.deliver(recipient, 'event', synthetic=synthetic)
        self.assertEqual(rpc.calls, [])

    def test_acknowledgment_and_duplicate_survive_adapter_recreation(self):
        rpc, records = FakeRPC(), {}
        proof.SyntheticDelivery(rpc, 'owned', records).deliver('owned', 'event', synthetic=True)
        result = proof.SyntheticDelivery(rpc, 'owned', records).deliver('owned', 'event', synthetic=True)
        self.assertEqual(result['status'], 'acknowledged')
        self.assertEqual(len(rpc.calls), 1)

    def test_completion_without_marker_is_not_acknowledgment(self):
        rpc, records = FakeRPC(acknowledge=False), {}
        with self.assertRaises(RuntimeError):
            proof.SyntheticDelivery(rpc, 'owned', records).deliver('owned', 'event', synthetic=True)
        self.assertEqual(records['event']['status'], 'pending')

    def test_ambiguous_send_is_not_replayed(self):
        rpc, records = FakeRPC(fail=True), {}
        with self.assertRaises(TimeoutError):
            proof.SyntheticDelivery(rpc, 'owned', records).deliver('owned', 'event', synthetic=True)
        result = proof.SyntheticDelivery(rpc, 'owned', records).deliver('owned', 'event', synthetic=True)
        self.assertEqual(result['status'], 'pending')
        self.assertEqual(len(rpc.calls), 1)

    def test_running_delivery_requires_the_expected_turn(self):
        rpc = FakeRPC()
        proof.SyntheticDelivery(rpc, 'owned', {}).deliver('owned', 'event', synthetic=True, running='active')
        method, params = rpc.calls[0]
        self.assertEqual(method, 'turn/steer')
        self.assertEqual(params['expectedTurnId'], 'active')


if __name__ == '__main__':
    unittest.main()
