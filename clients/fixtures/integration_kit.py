"""Test helpers for relay_integrations: a temp world (HOME, link root, bundle, fake CLIs).
Standard library only. Nothing here touches the real HOME: every path is under one temp root,
subprocesses get HOME=<temp home> and a PATH of fake CLIs only, and the extra bin folders and
app folders the engine looks in are pointed into the temp root."""
from __future__ import annotations

import io
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

CLIENTS = Path(__file__).resolve().parent.parent
ROOT = CLIENTS.parent
sys.path.insert(0, str(CLIENTS))

import relay_bundle as rb  # noqa: E402
import relay_integrations as ri  # noqa: E402

FAKECLI = Path(__file__).resolve().parent / "fakecli.py"
TEST_VERSION = "9.9.9"
SECRET = "sk-test-not-a-secret"


def _static_prefix(argv: List[Any]) -> List[str]:
    """The leading arguments of a command that name the subcommand: up to the first one that
    holds a placeholder, is an object, is an option, or is the server name."""
    out: List[str] = []
    for arg in argv[1:]:
        if not isinstance(arg, str) or "{{" in arg or arg.startswith("-") or arg == "relay":
            break
        out.append(arg)
    return out


class World:
    """One temp root holding home/, bin/ and the fake CLI's files."""

    def __init__(self, table: List[Dict[str, Any]], *, version: str = TEST_VERSION) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="hookint-")).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "fakecli.log"
        self.config_path = self.root / "fakecli.json"
        self.state = self.root / "fakecli-state.json"
        self.config: Dict[str, Any] = {"rules": [], "fail": [], "sleep": {}, "stdout": {}}
        self.table = table
        self.link_root = self.home / ".local" / "share" / "hook" / "current"
        (self.link_root / "mcp").mkdir(parents=True)
        (self.link_root / "mcp" / "relay_mcp.py").write_text("# fake MCP server\n", "utf-8")
        (self.link_root / "bin").mkdir()
        (self.link_root / "bin" / "relay").write_text("#!/bin/sh\nexit 0\n", "utf-8")
        self.build(version)
        self.save_config()

    # --- setup ---------------------------------------------------------------------------

    def build(self, version: str = TEST_VERSION, *, instructions: Optional[str] = None) -> None:
        """(Re)build the bundle at <link root>/integration from the repo sources and this table."""
        src = ROOT / "integration" / "src"
        if instructions is not None:
            src = self.root / "src"
            if src.exists():
                shutil.rmtree(src)
            shutil.copytree(ROOT / "integration" / "src", src)
            (src / "instructions" / "hook.md").write_text(instructions, "utf-8")
        tables = self.root / "table"
        tables.mkdir(exist_ok=True)
        (tables / "harnesses.json").write_text(json.dumps(self.table, indent=2) + "\n", "utf-8")
        shutil.copyfile(ROOT / "integration" / "harnesses.schema.json", tables / "harnesses.schema.json")
        rb.build(src, ROOT / "skill" / "instructables", tables / "harnesses.json",
                 self.link_root / "integration", version)

    def add_cli(self, *names: str) -> None:
        for name in names:
            dest = self.bin / name
            text = FAKECLI.read_text("utf-8")
            dest.write_text(f"#!{sys.executable}\n" + text, "utf-8")
            dest.chmod(0o755)

    def drop_cli(self, *names: str) -> None:
        for name in names:
            (self.bin / name).unlink()

    def add_app(self, name: str) -> None:
        (self.home / "Applications" / name).mkdir(parents=True, exist_ok=True)

    def rules_from_table(self) -> None:
        """Fake behaviour for every command the table names: an add writes Hook's server at the
        declared key, a remove takes it out again, a plugin link makes its declared path."""
        rules: List[Dict[str, Any]] = []
        for entry in self.table:
            ph = self.placeholders(entry)
            for alts in entry["pieces"].values():
                for alt in alts:
                    if alt["method"] != "cli" or "writes" not in alt:
                        continue
                    writes = self.render_writes(alt["writes"], ph)
                    prog = alt["add"][0]
                    rules.append({"prog": prog, "prefix": _static_prefix(alt["add"]), "action": "set", "writes": writes})
                    rules.append({"prog": alt["remove"][0], "prefix": _static_prefix(alt["remove"]),
                                  "action": "delete", "writes": writes})
            plugin = entry.get("plugin")
            if plugin and plugin.get("writes"):
                writes = self.render_writes(plugin["writes"], ph)
                for argv in plugin["add"]:
                    rules.append({"prog": argv[0], "prefix": _static_prefix(argv), "action": "touch", "writes": writes})
                for argv in plugin["remove"]:
                    rules.append({"prog": argv[0], "prefix": _static_prefix(argv), "action": "rm", "writes": writes})
            probe = entry["detect"].get("probe")
            if probe:
                rules.append({"prog": probe["argv"][0], "prefix": _static_prefix(probe["argv"]),
                              "action": "print", "text": f"usage: the {probe['expect']}\n"})
        self.config["rules"] = rules
        self.save_config()

    def placeholders(self, entry: Dict[str, Any]) -> Dict[str, str]:
        values = self.values()
        return ri.placeholders(values, entry)

    def render_writes(self, writes: Dict[str, Any], ph: Dict[str, str]) -> Dict[str, Any]:
        out = dict(writes)
        out["path"] = str(ri.expand(writes["path"], ph, self.home))
        return out

    def save_config(self) -> None:
        self.config_path.write_text(json.dumps(self.config), "utf-8")

    # --- running -------------------------------------------------------------------------

    def env(self, **extra: str) -> Dict[str, str]:
        env = {
            "HOME": str(self.home), "PATH": str(self.bin), "HOOK_BIN_DIRS": "",
            "HOOK_APP_DIRS": str(self.home / "Applications"),
            "FAKECLI_LOG": str(self.log), "FAKECLI_CONFIG": str(self.config_path),
            "FAKECLI_STATE": str(self.state), "FAKECLI_CLIENTS": str(CLIENTS),
            "PYTHONDONTWRITEBYTECODE": "1",      # the system Python caches under $HOME/Library otherwise
        }
        env.update(extra)
        return env

    def values(self) -> "ri.Values":
        bundle = self.link_root / "integration"
        meta = json.loads((bundle / "bundle.json").read_text("utf-8"))
        return ri.Values(home=self.home, link_root=self.link_root, bundle=bundle,
                         plugins=self.home / ".local" / "share" / "hook" / "plugins",
                         version=meta["version"], schema=meta["schema"], env=self.env(),
                         app_dirs=(self.home / "Applications",))

    def run(self, *argv: str, link_root: Optional[Path] = None, env: Optional[Dict[str, str]] = None,
            now=None):
        out, err = io.StringIO(), io.StringIO()
        args = list(argv) + ["--link-root", str(link_root or self.link_root)]
        rc = ri.main(args, env=env or self.env(), out=out, err=err, now=now)
        return rc, out.getvalue(), err.getvalue()

    def status(self, *extra: str) -> Dict[str, Any]:
        rc, out, err = self.run("status", "--json", *extra)
        assert rc == 0, (rc, out, err)
        return json.loads(out)

    def harness(self, hid: str) -> Dict[str, Any]:
        return next(h for h in self.status()["harnesses"] if h["id"] == hid)

    def piece(self, hid: str, piece: str) -> Dict[str, Any]:
        return next(p for p in self.harness(hid)["pieces"] if p["piece"] == piece)

    def calls(self) -> List[Dict[str, Any]]:
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text("utf-8").splitlines() if line.strip()]
        return [r for r in rows if "argv" in r]

    def clear_calls(self) -> None:
        if self.log.exists():
            self.log.unlink()

    def manifest(self) -> Dict[str, Any]:
        return json.loads((self.home / ".config" / "relay" / "integrations.json").read_text("utf-8"))

    # --- looking at files ------------------------------------------------------------------

    def snapshot(self, root: Optional[Path] = None, *, skip: Iterable[str] = ()) -> Dict[str, Any]:
        """{relpath: (kind, bytes or link target, mtime_ns)} of every file, link and folder."""
        root = root or self.home
        found: Dict[str, Any] = {}
        skip = tuple(skip)
        for here, dirs, names in os.walk(root):
            for name in sorted(dirs + names):
                path = Path(here) / name
                rel = path.relative_to(root).as_posix()
                if any(rel == s or rel.startswith(s + "/") for s in skip):
                    continue
                info = path.lstat()
                if stat.S_ISLNK(info.st_mode):
                    found[rel] = ("link", os.readlink(path), info.st_mtime_ns)
                elif stat.S_ISDIR(info.st_mode):
                    found[rel] = ("dir", None, None)
                else:
                    found[rel] = ("file", path.read_bytes(), info.st_mtime_ns)
        return found

    def baks(self) -> List[str]:
        return sorted(p.relative_to(self.home).as_posix() for p in self.home.rglob("*") if ".bak" in p.name)

    def close(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


def synthetic_table() -> List[Dict[str, Any]]:
    """Three entries: alpha (a cli piece with a key fallback, a block), beta (key pieces, an
    owned file, an append), gamma (found by app; an owned file from files/). All three list the
    shared skill copy."""
    skill = {"method": "copy", "path": "~/.agents/skills/instructables", "source": "skills/instructables",
             "verified": "pending"}
    common = {"plugin": None, "owner_steps": [], "smoke": [{"parse": True}],
              "sources": ["https://example.com/docs"], "checked": "2026-11-03", "verified": "pending"}
    server = {"command": "{{python}}", "args": ["{{mcp_server}}"]}
    return [
        dict(common, id="alpha", name="Alpha", home={"env": "ALPHA_HOME", "default": "~/.alpha"},
             detect={"bins": ["alpha"], "paths": [], "apps": [], "probe": None},
             pieces={
                 "mcp": [
                     {"method": "cli", "requires": "alpha",
                      "add": ["alpha", "mcp", "add", "relay", "--", "{{python}}", "{{mcp_server}}"],
                      "remove": ["alpha", "mcp", "remove", "relay"],
                      "writes": {"path": "{{harness_home}}/config.json", "format": "json", "key": ["mcpServers", "relay"]},
                      "verified": "pending"},
                     {"method": "key", "path": "{{harness_home}}/config.json", "format": "json",
                      "key": ["mcpServers", "relay"], "value": server, "verified": "pending"},
                 ],
                 "skill": [skill],
                 "instructions": [{"method": "block", "path": "{{harness_home}}/AGENTS.md", "content": "full",
                                   "verified": "pending"}],
                 "replies": [{"method": "none", "reason": "Alpha has no hooks.", "verified": "pending"}],
             }),
        dict(common, id="beta", name="Beta", home={"default": "~/.beta"},
             detect={"bins": [], "paths": ["{{harness_home}}"], "apps": [], "probe": None},
             pieces={
                 "mcp": [{"method": "key", "path": "{{harness_home}}/settings.json", "format": "jsonc",
                          "key": ["mcpServers", "relay"], "value": server, "verified": "pending"}],
                 "skill": [skill],
                 "instructions": [{"method": "file", "path": "{{harness_home}}/rules/hook.md",
                                   "source": "instructions/hook.md", "verified": "pending"}],
                 "replies": [{"method": "key", "path": "{{harness_home}}/hooks.json", "format": "json",
                              "key": ["hooks", "UserPromptSubmit"], "op": "append", "match": "hook replies",
                              "value": {"hooks": [{"type": "command", "command": "{{replies:claude}}", "timeout": 5}]},
                              "verified": "pending"}],
             }),
        dict(common, id="gamma", name="Gamma", home={"default": "~/.gamma"},
             detect={"bins": [], "paths": [], "apps": ["/Applications/Gamma.app"], "probe": None},
             pieces={
                 "mcp": [{"method": "key", "path": "{{harness_home}}/mcp.json", "format": "json",
                          "key": ["mcpServers", "relay"], "value": server, "verified": "pending"}],
                 "skill": [skill],
                 "instructions": [{"method": "block", "path": "{{harness_home}}/AGENTS.md", "content": "full",
                                   "verified": "pending"}],
                 "replies": [{"method": "file", "path": "{{harness_home}}/hooks/hook.json",
                              "source": "files/copilot-hooks.json", "verified": "pending"}],
             }),
    ]


def real_table() -> List[Dict[str, Any]]:
    return json.loads((ROOT / "integration" / "harnesses.json").read_text("utf-8"))
