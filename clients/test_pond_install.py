import io
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import pond_host
import pond_install
import pond_ssh
import relay_cli


class Inputs(unittest.TestCase):
    def test_ssh_accepts_alias_or_user_at_host_and_rejects_option_and_shell_inputs(self):
        for host in ("pond-test", "operator@pond.example", "alice@192.0.2.12"):
            self.assertEqual(pond_ssh.host_name(host), host)
        for host in ("-oForwardAgent=yes", "alice@-p22", "a;id", "a b", "a\nb", ""):
            with self.subTest(host=host), self.assertRaises(ValueError):
                pond_ssh.host_name(host)

    def test_folder_stays_below_remote_home_and_never_follows_symlinks(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp).resolve()
            (home / "linked").symlink_to(Path("/tmp"), target_is_directory=True)
            self.assertEqual(pond_host.folder_path("~/pond", home), home / "pond")
            for raw in ("~/../escape", "/", str(home), "~/linked/pond", "~other/pond", "~/two words"):
                with self.subTest(raw=raw), self.assertRaises(ValueError):
                    pond_host.folder_path(raw, home)

    def test_requires_an_https_origin(self):
        self.assertEqual(pond_install.origin("https://pond.example:8443/"), "https://pond.example:8443")
        for url in ("http://pond.example", "https://user@pond.example", "https://pond.example/?x=1",
                    "https://pond.example/#secret", "https://pond.example/path", "https://pond.example\\@bad",
                    "https://pond.example:invalid"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                pond_install.origin(url)

    def test_status_from_packaged_entry_point_with_empty_config(self):
        with TemporaryDirectory() as tmp:
            out, err = io.StringIO(), io.StringIO()
            code = relay_cli.main(["pond","status"], stdout=out, stderr=err,
                                  env={"RELAY_CONFIG": str(Path(tmp) / "config.json")})
            self.assertEqual(code, 2)
            self.assertIn("managed Pond", err.getvalue())


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "config.json"
        self.path.write_text('{"source":"local","unrelated":7}')
        self.env = {"RELAY_CONFIG": str(self.path)}
        self.status = {"installation": "a" * 32, "version": {"service":"pond", "version":"1.16.0",
                       "features":["longAnswers","admission"]}, "admission":"native", "claimed": False,
                       "health":{"ok":True}, "telegram":False}
        self.operations = []
        self.failure = None
        self.descriptor = {"version":"1.16.0", "digest":"sha256:" + "a"*64, "features":["longAnswers","admission"],
                           "platform":"linux/arm64"}
        self.tty = io.StringIO()
        self.tty.isatty = lambda: True

    def ssh(self, host, request):
        op = request["action"]
        self.operations.append(op)
        if op == self.failure:
            raise ValueError("host operation refused")
        if op == "preflight":
            return {"platform":"linux/arm64","installed": False}
        if op == "install":
            return {"installation": "a"*32}
        if op == "status":
            return {"report":self.status, "current":self.descriptor, "operation":None, "backup":None}
        if op == "invite":
            return {"link":"hook://join?v=2&pond=https%3A%2F%2Fpond.example#synthetic"}

    def run_cli(self, *args, route_error=None):
        err = io.StringIO()
        with patch.object(pond_ssh, "request", self.ssh), patch.object(pond_install, "candidate", return_value=self.descriptor), \
             patch.object(pond_host, "routed_health", side_effect=route_error):
            code = relay_cli.main(["pond",*args], env=self.env, stdout=self.tty, stderr=err)
        return code, err.getvalue()

    def test_install_verifies_both_routes_before_handoff_and_config_commit(self):
        code, err = self.run_cli("install", "operator@pond.example", "--url", "https://pond.example")
        self.assertEqual((code,err),(0,""))
        self.assertEqual(self.operations, ["preflight","install","status","invite"])
        config=json.loads(self.path.read_text())
        self.assertEqual((config["pondSSHHost"],config["pondFolder"],config["unrelated"]),
                         ("operator@pond.example","~/pond",7))
        self.assertIn("#synthetic", self.tty.getvalue())
        self.assertNotIn("#synthetic", self.path.read_text())

    def test_failed_ssh_preflight_disk_start_tls_and_identity_preserve_previous_queue(self):
        for fault in ("preflight", "install", "status", "route", "identity"):
            self.failure = fault
            self.operations.clear()
            self.status["installation"] = "b"*32 if fault == "identity" else "a"*32
            code, _ = self.run_cli("install", "operator@pond.example", "--url", "https://pond.example",
                                   route_error=ValueError("TLS") if fault == "route" else None)
            self.assertNotEqual(code,0)
            self.assertNotIn("invite", self.operations)
            self.assertEqual(json.loads(self.path.read_text()), {"source":"local","unrelated":7})

    def test_claimed_pond_rerun_does_not_mint_first_invite(self):
        self.status["claimed"] = True
        code, err = self.run_cli("install", "operator@pond.example", "--url", "https://pond.example")
        self.assertEqual((code,err),(0,""))
        self.assertNotIn("invite", self.operations)

class ManagementSafetyTests(unittest.TestCase):
    def test_switching_origins_never_reuses_a_previous_principal_or_bearer(self):
        with TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.json"
            config.write_text(json.dumps({"mailboxURL":"https://old.example", "tokenFile":"/old",
                                          "credentialRef":"old-device", "enrolledAgent":"Previous",
                                          "context":"work"}))
            pond_install.bind_config(config, "host", "~/pond", "https://new.example", "b"*32)
            new = json.loads(config.read_text())
            for key in ("tokenFile","credentialRef","enrolledAgent"):
                self.assertNotIn(key, new)
            self.assertEqual(new["context"], "work")

    def test_keychain_access_failure_and_incomplete_config_fail_before_ssh_install(self):
        import subprocess
        for owner, reply in (("1","missing"), ("abc",""), ("1","invalid")):
            with self.subTest(owner=owner, reply=reply), patch("pond_install.subprocess.run") as run:
                if reply == "missing":
                    run.side_effect = subprocess.CalledProcessError(44, ["security"])
                else:
                    run.return_value.stdout = reply
                with self.assertRaises(ValueError):
                    pond_install.telegram_config(owner, "https://pond.example")
        with patch("pond_install.subprocess.run") as run:
            run.return_value.stdout = "123:" + "s"*25
            result = pond_install.telegram_config("1", "https://pond.example")
            self.assertNotIn(result["token"], run.call_args.args[0])

    def test_noninteractive_handoff_requires_a_terminal(self):
        with patch("builtins.open", side_effect=OSError("no tty")), self.assertRaises(ValueError):
            pond_install.terminal_for(io.StringIO())

    def test_real_ssh_command_uses_stdin_and_checks_known_host(self):
        with patch("pond_ssh.subprocess.run") as run:
            run.return_value.returncode = 255
            with self.assertRaisesRegex(ValueError, "host key"):
                pond_ssh.request("operator@pond.example", {"secret":"synthetic-only-test-value"})
            command = run.call_args.args[0]
            self.assertIn("StrictHostKeyChecking=yes", command)
            self.assertNotIn("synthetic-only-test-value", " ".join(command))
            self.assertIn("synthetic-only-test-value", run.call_args.kwargs["input"])
