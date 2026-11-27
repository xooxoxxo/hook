"""Fault injection at the durable boundaries of a managed update."""
import json
import tempfile
import unittest
from pathlib import Path

import pond_host


OLD = {"version": "1.16.0", "digest": "sha256:" + "1" * 64, "volume": "previous", "imageID": "old-image"}
NEW = {"version": "1.16.1", "digest": "sha256:" + "2" * 64}
IDENTITY = "d" * 32
DB = {"counts": {"items": 3, "principals": 2}, "schema": 6, "contents": "a" * 64}


class Disconnect(BaseException):
    pass


class Runtime:
    def __init__(self):
        self.fail = ""
        self.active = OLD
        self.fenced = False
        self.backups = {}
        self.database = DB.copy()
        self.started = []
        self.captured = 0

    def identify(self, state):
        if self.active != state["current"]:
            raise ValueError("Wrong source")

    def pull(self, target):
        if self.fail == "pull":
            raise ValueError("Pull failure")
        return "new-image"

    def check_backup(self, previous):
        if previous["backup"] not in self.backups:
            raise ValueError("Missing backup")

    def preserve(self, journal):
        pass

    def stop(self):
        self.active = None
        self.fenced = True

    def snapshot(self, current, op):
        if self.fail == "disk full":
            raise OSError("No space")
        self.backups[op] = self.database.copy()
        return self.backups[op]

    def clone(self, current, target, op):
        if self.fail == "corrupt":
            raise ValueError("Snapshot refused")

    def serve(self, descriptor, fenced):
        self.active = descriptor
        self.fenced = fenced
        self.started.append((descriptor["version"], fenced))

    def verify(self, state, descriptor, fenced):
        if descriptor["version"] == NEW["version"] and self.fail in ("503", "wrong version"):
            raise ValueError("Candidate health or version mismatch")
        return self.database.copy()


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.runtime = Runtime()
        self.state = {"installation": IDENTITY, "current": OLD, "url": "https://pond.example"}
        pond_host.save(self.path / "state.json", self.state)

    def run_op(self, kind="update", target=NEW):
        return pond_host.operate(self.path, self.runtime, kind, target)

    def state_now(self):
        return json.loads((self.path / "state.json").read_text())

    def test_commit_then_same_digest_noop(self):
        self.run_op()
        record = self.state_now()
        self.assertEqual(record["current"]["digest"], NEW["digest"])
        self.assertEqual(record["previous"]["source"], OLD)
        self.assertIn(record["previous"]["backup"], self.runtime.backups)
        self.assertEqual(self.runtime.started, [("1.16.1", True), ("1.16.1", False)])
        self.run_op()
        self.assertEqual(len(self.runtime.started), 2)

    def test_precommit_failures_preserve_or_restore_original(self):
        for fault in ("pull", "disk full", "corrupt", "503", "wrong version"):
            with self.subTest(fault=fault):
                self.runtime.fail = fault
                with self.assertRaises((ValueError, OSError)):
                    self.run_op()
                self.assertEqual(self.state_now()["current"], OLD)
                self.assertEqual(self.runtime.active, OLD)
                self.assertFalse(self.runtime.fenced)
                self.assertEqual(self.runtime.database, DB)

    def test_another_process_holding_the_install_lock_prevents_change(self):
        with pond_host.lock(self.path), self.assertRaises(ValueError):
            self.run_op()
        self.assertEqual(self.runtime.started, [])

    def test_rollback_keeps_changed_data_and_takes_a_new_recovery_copy(self):
        self.run_op()
        self.runtime.database = dict(DB, contents="changed after a revocation")
        with self.assertRaisesRegex(ValueError, "reconciliation"):
            self.run_op("rollback", None)
        self.assertEqual(self.state_now()["current"]["digest"], NEW["digest"])
        self.assertEqual(self.runtime.active["digest"], NEW["digest"])
        self.assertEqual(len(self.runtime.backups), 2)

    def test_verified_rollback_reattaches_previous_volume(self):
        self.run_op()
        self.run_op("rollback", None)
        self.assertEqual(self.state_now()["current"], OLD)
        self.assertEqual(self.runtime.active, OLD)

    def test_power_loss_in_each_phase_recovers_without_opening_two_writers(self):
        from unittest.mock import patch
        for phase in ("prepared", "stopping", "snapshotted", "testing", "opening"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp)
                pond_host.save(folder / "state.json", self.state)
                runtime = Runtime()
                real_save = pond_host.save
                def interrupted(path, record):
                    real_save(path, record)
                    if path.name == "operation.json" and record.get("phase") == phase:
                        raise Disconnect()
                with patch.object(pond_host, "save", interrupted), self.assertRaises(Disconnect):
                    pond_host.operate(folder, runtime, "update", NEW)
                pond_host.operate(folder, runtime, "update", NEW)
                record = json.loads((folder / "state.json").read_text())
                self.assertEqual(runtime.active, record["current"])
                self.assertFalse(runtime.fenced)
                self.assertEqual(runtime.database, DB)

    def test_missing_backup_never_disturbs_serving_candidate(self):
        self.run_op()
        self.runtime.backups.clear()
        started = list(self.runtime.started)
        with self.assertRaisesRegex(ValueError, "backup"):
            self.run_op("rollback", None)
        self.assertEqual(self.runtime.started, started)


class DockerContractTests(unittest.TestCase):
    def test_compose_uses_verified_image_private_mount_and_loopback(self):
        state = {"installation": IDENTITY, "url": "https://pond.example"}
        item = dict(OLD, features=["admission"], volume="pond-volume")
        spec = pond_host.compose(state, item, True)
        service = spec["services"]["mailbox"]
        self.assertEqual(service["image"], "ghcr.io/xooxoxxo/pond:1.16.0@" + OLD["digest"])
        self.assertEqual(service["ports"], ["127.0.0.1:8790:8790"])
        self.assertEqual(service["environment"]["POND_MAINTENANCE"], "1")
        self.assertEqual(spec["volumes"]["data"], {"external": True, "name": "pond-volume"})
        self.assertEqual(service["volumes"], ["data:/data", "./backups:/backups"])
        self.assertNotIn("build", service)

    def test_mismatched_install_id_version_readiness_or_missing_feature_refuses_switch(self):
        descriptor = dict(OLD, features=["longAnswers", "admission"])
        good = {"installation": IDENTITY, "version": {"service":"pond", "version":"1.16.0",
                "features":["admission", "longAnswers"]}, "health":{"ok": True, "fenced": True}, "admission": "native"}
        for report in (dict(good, installation="other"), dict(good, health={"ok":False, "fenced":True}),
                       dict(good, version=dict(good["version"],version="1.17.0")),
                       dict(good, version=dict(good["version"],features=["longAnswers"]))):
            with self.subTest(report=report), self.assertRaises(ValueError):
                pond_host.check_status(report, IDENTITY, descriptor, True)
        pond_host.check_status(good, IDENTITY, descriptor, True)

class InterruptedStatusTests(unittest.TestCase):
    def test_status_can_report_journal_while_service_is_stopped(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            state = {"installation": IDENTITY, "current": dict(OLD, features=[], platform="linux/arm64")}
            pond_host.save(folder / "operation.json", {"id": IDENTITY, "phase": "snapshotted"})
            pond_host.save(folder / "worker.json", {"id": IDENTITY, "state":"running"})
            with patch.object(pond_host.Docker, "inspect", side_effect=ValueError("stopped")):
                status = pond_host.public_status(folder, state)
            self.assertEqual(status["operation"], "snapshotted")
            self.assertEqual(status["worker"]["state"], "interrupted")
            self.assertFalse(status["report"]["health"]["ok"])
