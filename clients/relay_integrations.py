"""`relay integrations`: install Hook into every agent harness on this Mac, keep it current,
report drift, and remove exactly what Hook wrote. Standard library only (Python 3.9).

    relay_integrations.py status   [--harness X] [--json] [--smoke]
    relay_integrations.py sync     [--harness X] [--dry-run] [--json] [--include-new|--only-known]
                                   [--if-changed] [--no-asks]
    relay_integrations.py reinstall [--harness X [--piece P]] [--force] [--dry-run] [--json]
    relay_integrations.py accept   --harness X [--piece P] [--json]       (Keep Mine)
    relay_integrations.py diff     --harness X [--piece P] [--json]       (Show Difference)
    relay_integrations.py remove   (--harness X | --all) [--force] [--dry-run] [--json]
    relay_integrations.py migrate claude-md [--choose CHOICE] [--again] [--dry-run] [--json]
    relay_integrations.py set auto-setup on|off
    hidden: --link-root DIR, --bundle DIR, --home DIR

The harness table (harnesses.json in the integration bundle) says, per harness, how to detect it
and how to install each piece (mcp, skill, instructions, replies). This module has no
harness-specific code. Everything Hook writes is recorded in ~/.config/relay/integrations.json
(the manifest) with its sha, so a later run can tell installed, outdated (Hook's content
changed), drifted (the user changed it) and foreign (not Hook's) apart.

Owner-only steps and the edited files a sync leaves alone reach the owner as instructables
(relay_owner_steps); Claude Code's pre-0.13 setup moves to the plugin (relay_migrate_claude).

Under ~/.config/relay this opens only integrations.json and integrations.lock. Reports, logs
and JSON output name paths and key paths, never values from a harness config.

Exit codes: 0 ok (skipped and drifted items included); 1 bad arguments; 2 the bundle or table is
missing or invalid, or the lock timed out; 4 at least one item failed.
"""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import difflib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, ContextManager, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple

import relay_bundle as rb
import relay_edits as ed
import relay_jsonschema

SCHEMA = 1
MANIFEST = "integrations.json"
LOCK = "integrations.lock"
PIECES = ("mcp", "skill", "instructions", "replies")
# Worst first. `accepted` counts as installed; `none` (nothing to install) never counts.
STATE_ORDER = ("blocked", "drifted", "foreign", "needs-owner", "outdated", "not-set-up", "installed")
EXTRA_BIN_DIRS = ("~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.bun/bin", "~/.npm-global/bin")
APP_DIRS = ("/Applications", "~/Applications")
HERE = Path(__file__).resolve().parent.parent
LOCK_TIMEOUT = 30.0
RUN_TIMEOUT = 20.0
IF_CHANGED_AGE = timedelta(hours=24)
ABSENT = "absent"                 # the sha of a target that isn't there (for accept)
HOOKISH = ("relay_mcp.py", "hook replies", "relay replies", "/integration/instructions/hook.md", "hook:instructions")
DIFFABLE = ("block", "key", "file", "copy")
EMPTY_SHAPE = re.compile(r"\ufeff?[ \t\r\n]{0,64}(?:\{[ \t\r\n]{0,64}\}[ \t\r\n]{0,64})?")


class TableError(Exception):
    """The bundle or its harness table is missing or invalid (exit 2)."""


class UsageError(Exception):
    """Bad arguments (exit 1)."""


class LockTimeout(Exception):
    """Another run holds the lock (exit 2)."""


class _Fail(Exception):
    """An item failed (a command, a write, or an edit Hook refused): blocked, exit 4."""


class _Blocked(Exception):
    """A file doesn't parse: blocked, but not a failure."""


# --- values and placeholders ---------------------------------------------------------------

@dataclass(frozen=True)
class Values:
    home: Path
    link_root: Path
    bundle: Path
    plugins: Path
    version: str
    schema: int
    env: Mapping[str, str]
    app_dirs: Tuple[Path, ...] = ()


def tilde(path: Any, home: Path) -> str:
    """path with the home folder written as ~/."""
    text = str(path)
    root = str(home).rstrip("/")
    if text == root:
        return "~"
    if text.startswith(root + "/"):
        return "~/" + text[len(root) + 1:]
    return text


def _home_path(text: str, home: Path) -> Path:
    if text == "~":
        return home
    if text.startswith("~/"):
        return home / text[2:]
    return Path(text)


def _base_placeholders(values: Values) -> Dict[str, str]:
    instructions = values.bundle / "instructions" / "hook.md"
    ref = tilde(instructions, values.home)
    return {
        "home": str(values.home),
        "python": "python3",
        "mcp_server": str(values.link_root / "mcp" / "relay_mcp.py"),
        "relay": str(values.link_root / "bin" / "relay"),
        "bundle": str(values.bundle),
        "instructions": str(instructions),
        "instructions_home_ref": ref if ref.startswith("~/") else "",
        "plugins": str(values.plugins),
        "version": values.version,
        "schema": str(values.schema),
    }


def placeholders(values: Values, entry: Dict[str, Any]) -> Dict[str, str]:
    """Every {{name}} value for one entry, {{harness_home}} included."""
    ph = _base_placeholders(values)
    home = entry.get("home") or {}
    env_name = home.get("env")
    custom = values.env.get(env_name, "") if env_name else ""
    raw = custom or rb.render_text(home.get("default", "~"), ph, json_escape=False)
    ph["harness_home"] = str(_home_path(raw, values.home))
    return ph


def expand(text: str, ph: Mapping[str, str], home: Path) -> Path:
    """A table path with its placeholders filled and ~/ expanded."""
    return _home_path(rb.render_text(text, ph, json_escape=False), home)


def _render_value(value: Any, ph: Mapping[str, str]) -> Any:
    if isinstance(value, str):
        return rb.render_text(value, ph, json_escape=False)
    if isinstance(value, list):
        return [_render_value(v, ph) for v in value]
    if isinstance(value, dict):
        return {k: _render_value(v, ph) for k, v in value.items()}
    return value


def _argv(argv: Sequence[Any], ph: Mapping[str, str]) -> List[str]:
    out: List[str] = []
    for arg in argv:
        if isinstance(arg, dict):
            out.append(json.dumps(_render_value(arg["json"], ph)))
        else:
            out.append(rb.render_text(arg, ph, json_escape=False))
    return out


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canon_sha(value: Any) -> str:
    return _sha(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def _block_body(body: str) -> str:
    body = body.replace("\r\n", "\n")
    return body if body.endswith("\n") else body + "\n"


def _block_sha(body: str) -> str:
    return _sha(_block_body(body).encode("utf-8"))


def _hookish(value: Any) -> bool:
    if isinstance(value, str):
        return any(mark in value for mark in HOOKISH)
    if isinstance(value, list):
        return any(_hookish(v) for v in value)
    if isinstance(value, dict):
        return any(_hookish(v) for v in value.values())
    return False


def _strings(value: Any) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            yield from _strings(v)
    elif isinstance(value, dict):
        for v in value.values():
            yield from _strings(v)


def _matcher(text: str) -> Callable[[Any], bool]:
    return lambda element: any(text in s for s in _strings(element))


# --- where things are ----------------------------------------------------------------------

def _same(a: Path, b: Path) -> bool:
    try:
        return a.exists() and b.exists() and os.path.samefile(a, b)
    except OSError:
        return False


def resolve_link_root(here: Path, home: Path, manifest: "Manifest", explicit: Optional[Path]) -> Path:
    """explicit > ~/.local/share/hook/current if it resolves to here > the manifest's
    linkRoot if it resolves to here > here."""
    if explicit is not None:
        return Path(explicit)
    current = home / ".local" / "share" / "hook" / "current"
    if _same(current, here):
        return current
    recorded = manifest.data.get("linkRoot")
    if isinstance(recorded, str) and recorded:
        path = _home_path(recorded, home)
        if _same(path, here):
            return path
    return here


def resolve_bundle(link_root: Path, explicit: Optional[Path]) -> Path:
    """explicit > <link_root>/integration > <link_root>/build/integration, each when it holds
    bundle.json; else TableError."""
    if explicit is not None:
        if not (Path(explicit) / "bundle.json").is_file():
            raise TableError(f"no integration bundle at {explicit} (bundle.json is missing)")
        return Path(explicit)
    for path in (link_root / "integration", link_root / "build" / "integration"):
        if (path / "bundle.json").is_file():
            return path
    raise TableError(f"no integration bundle under {link_root}; build one with "
                     f"python3 clients/relay_bundle.py build --out build/integration")


def _bundle_meta(bundle: Path) -> Dict[str, Any]:
    try:
        meta = json.loads((bundle / "bundle.json").read_text("utf-8"))
    except (OSError, ValueError) as exc:
        raise TableError(f"the bundle's bundle.json can't be read: {exc}") from None
    if not isinstance(meta, dict) or not isinstance(meta.get("version"), str):
        raise TableError("the bundle's bundle.json has no version")
    return meta


def load_table(bundle: Path) -> List[Dict[str, Any]]:
    """The harness table, validated against its schema. An empty or invalid table raises."""
    path = bundle / "harnesses.json"
    try:
        table = json.loads(path.read_text("utf-8"))
    except OSError:
        raise TableError(f"the harness table is missing: {path}") from None
    except ValueError as exc:
        raise TableError(f"the harness table is not JSON: {exc}") from None
    if not isinstance(table, list) or not table:
        raise TableError("the harness table is empty")
    for schema_path in (bundle / "harnesses.schema.json", HERE / "integration" / "harnesses.schema.json"):
        if schema_path.is_file():
            errors = relay_jsonschema.validate(table, json.loads(schema_path.read_text("utf-8")))
            if errors:
                raise TableError("the harness table is invalid: " + "; ".join(errors[:5]))
            break
    ids = [e.get("id") for e in table if isinstance(e, dict)]
    if len(ids) != len(table) or len(set(ids)) != len(ids):
        raise TableError("the harness table has entries without a unique id")
    return table


def _config_dir(values: Values) -> Path:
    custom = values.env.get("RELAY_CONFIG")
    if custom:
        return _home_path(custom, values.home).parent
    return values.home / ".config" / "relay"


# --- running harness commands --------------------------------------------------------------

class Runner:
    """Harness commands: stdin from /dev/null, a timeout, and PATH plus the usual bin folders
    (HOOK_BIN_DIRS, colon-separated, replaces those folders; tests set it empty)."""

    def __init__(self, env: Mapping[str, str], home: Path, extra: Optional[Sequence[str]] = None) -> None:
        if extra is None:
            custom = env.get("HOOK_BIN_DIRS")
            extra = EXTRA_BIN_DIRS if custom is None else [d for d in custom.split(":") if d]
        dirs = [d for d in env.get("PATH", "").split(":") if d]
        for d in extra:
            d = str(_home_path(d, home))
            if d not in dirs:
                dirs.append(d)
        self.path = ":".join(dirs)
        self.env = dict(env)
        self.env["PATH"] = self.path
        self.env["HOME"] = str(home)

    def which(self, name: str) -> Optional[str]:
        return shutil.which(name, path=self.path) if self.path else None

    def run(self, argv: List[str], timeout: float = RUN_TIMEOUT) -> Tuple[int, str, str]:
        exe = self.which(argv[0])
        if exe is None:
            return 127, "", f"{argv[0]}: command not found"
        try:
            proc = subprocess.run([exe] + list(argv[1:]), stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=timeout, env=self.env)
        except subprocess.TimeoutExpired:
            return 124, "", f"{argv[0]}: timed out after {timeout:g} s"
        except OSError as exc:
            return 126, "", f"{argv[0]}: {exc.strerror or exc}"
        return proc.returncode, proc.stdout or "", proc.stderr or ""


def _first_line(text: str, fallback: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()[:200]
    return fallback


# --- the manifest --------------------------------------------------------------------------

def _empty_manifest() -> Dict[str, Any]:
    return {"schema": SCHEMA, "autoSetup": True, "harnesses": {}, "targets": {}, "asks": {}, "migrations": []}


class Manifest:
    """~/.config/relay/integrations.json: what Hook wrote, per target, with owners."""

    def __init__(self, path: Path, data: Dict[str, Any], problem: Optional[str] = None) -> None:
        self.path = path
        self.data = data
        self.problem = problem

    @classmethod
    def load(cls, path: Path, *, move: bool = True, now: Optional[datetime] = None) -> "Manifest":
        """A missing file gives an empty manifest; an unparseable one is moved to .bad-<time>
        (when move) and an empty one is used."""
        try:
            raw = path.read_text("utf-8")
        except FileNotFoundError:
            return cls(path, _empty_manifest())
        except OSError as exc:
            return cls(path, _empty_manifest(), f"the manifest can't be read: {exc.strerror}")
        try:
            data = json.loads(raw)
            if not isinstance(data, dict):
                raise ValueError("not an object")
        except ValueError:
            problem = "the manifest was not valid JSON"
            if move:
                stamp = (now or datetime.now(timezone.utc)).strftime("%Y%m%d-%H%M%S")
                dest = path.with_name(f"{path.name}.bad-{stamp}")
                n = 2
                while dest.exists():
                    dest = path.with_name(f"{path.name}.bad-{stamp}-{n}")
                    n += 1
                os.replace(path, dest)
                problem += f"; moved to {dest.name}"
            return cls(path, _empty_manifest(), problem)
        base = _empty_manifest()
        base.update(data)
        for key in ("harnesses", "targets", "asks"):
            if not isinstance(base.get(key), dict):
                base[key] = {}
        if not isinstance(base.get("migrations"), list):
            base["migrations"] = []
        return cls(path, base)

    def save(self) -> None:
        """Atomic, 0600, in a 0700 folder."""
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        data = json.dumps(self.data, indent=2, sort_keys=True) + "\n"
        ed.atomic_write(self.path, data.encode("utf-8"), mode=0o600)

    @property
    def targets(self) -> Dict[str, Dict[str, Any]]:
        return self.data["targets"]

    @property
    def harnesses(self) -> Dict[str, Dict[str, Any]]:
        return self.data["harnesses"]

    def target(self, key: str) -> Optional[Dict[str, Any]]:
        return self.targets.get(key)

    def own(self, key: str, harness: str, record: Dict[str, Any]) -> None:
        old = self.targets.get(key) or {}
        owners = list(old.get("owners") or [])
        merged = dict(old)
        merged.update(record)
        if harness not in owners:
            owners.append(harness)
        merged["owners"] = owners
        self.targets[key] = merged

    def disown(self, key: str, harness: str) -> bool:
        """Drop harness from the target's owners; True when no owner is left."""
        rec = self.targets.get(key)
        if rec is None:
            return True
        rec["owners"] = [o for o in rec.get("owners") or [] if o != harness]
        return not rec["owners"]

    def forget(self, key: str) -> None:
        self.targets.pop(key, None)
        for h in self.harnesses.values():
            pieces = h.get("pieces") or {}
            for piece in [p for p, info in pieces.items() if info.get("target") == key]:
                del pieces[piece]
            if h.get("plugin") == key:
                h["plugin"] = None

    def find(self, *keys: Optional[str]) -> Optional[str]:
        """The recorded target key for any of keys: a record at that key, or a command whose
        `writes` names it."""
        wanted = [k for k in keys if k]
        for k in wanted:
            if k in self.targets:
                return k
        for k, rec in self.targets.items():
            if rec.get("writes") in wanted:
                return k
        return None

    def owned_by(self, harness: str) -> List[str]:
        return [k for k, rec in self.targets.items() if harness in (rec.get("owners") or [])]

    @property
    def removed(self) -> List[str]:
        """The harnesses the owner removed: no sync sets them up again until Set Up
        (`sync --harness X`) or `sync --include-removed` (a first install)."""
        ids = self.data.get("removed")
        return [i for i in ids if isinstance(i, str)] if isinstance(ids, list) else []

    def mark_removed(self, ids: Sequence[str]) -> None:
        known = self.removed
        self.data["removed"] = known + [i for i in ids if i not in known]

    def clear_removed(self, harness: Optional[str] = None) -> None:
        left = [] if harness is None else [i for i in self.removed if i != harness]
        if left:
            self.data["removed"] = left
        else:
            self.data.pop("removed", None)


@contextlib.contextmanager
def lock(values: Values, timeout: Optional[float] = None) -> Iterator[None]:
    """flock on integrations.lock; waits up to timeout (30 s, or HOOK_LOCK_TIMEOUT), then
    LockTimeout."""
    if timeout is None:
        try:
            timeout = float(values.env.get("HOOK_LOCK_TIMEOUT", LOCK_TIMEOUT))
        except ValueError:
            timeout = LOCK_TIMEOUT
    folder = _config_dir(values)
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(folder / LOCK), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise LockTimeout(f"another `relay integrations` run holds {tilde(folder / LOCK, values.home)}; "
                                      f"waited {timeout:g} s") from None
                time.sleep(0.05)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


# --- detection -----------------------------------------------------------------------------

@dataclass
class Detection:
    id: str
    found: bool
    why: List[str]


def _app_dirs(values: Values) -> Tuple[Path, ...]:
    if values.app_dirs:
        return values.app_dirs
    custom = values.env.get("HOOK_APP_DIRS")
    dirs = APP_DIRS if custom is None else [d for d in custom.split(":") if d]
    return tuple(_home_path(d, values.home) for d in dirs)


def detect(table: List[Dict[str, Any]], values: Values, runner: Runner) -> Dict[str, Detection]:
    """Bins (through runner.which), paths, app bundles, and a probe only when nothing else
    found the harness. Only a probe runs anything."""
    found: Dict[str, Detection] = {}
    for entry in table:
        ph = placeholders(values, entry)
        spec = entry.get("detect") or {}
        why: List[str] = []
        for name in spec.get("bins") or []:
            if runner.which(name):
                why.append(f"bin {name}")
        for raw in spec.get("paths") or []:
            path = expand(raw, ph, values.home)
            if path.exists() or path.is_symlink():
                why.append(f"path {tilde(path, values.home)}")
        for app in spec.get("apps") or []:
            name = Path(app).name
            if any((d / name).is_dir() for d in _app_dirs(values)):
                why.append(f"app {name}")
        probe = spec.get("probe")
        if not why and probe and runner.which(probe["argv"][0]):
            rc, out, err = runner.run(_argv(probe["argv"], ph), timeout=float(probe.get("timeout", 3)))
            if rc not in (124, 126, 127) and probe["expect"] in out + err:
                why.append(f"probe {probe['argv'][0]}")
        found[entry["id"]] = Detection(entry["id"], bool(why), why)
    return found


# --- items: one piece's target, what Hook would write, and what is there -----------------------

@dataclass
class Item:
    harness: str
    piece: str                      # mcp | skill | instructions | replies | plugin
    method: str
    alt_index: Optional[int] = None
    alt: Optional[Dict[str, Any]] = None
    definer: Optional[Tuple[str, str, Optional[int]]] = None
    key: Optional[str] = None       # the target key in the manifest
    loc: Optional[str] = None       # a command's `writes` location
    path: Optional[Path] = None
    fmt: Optional[str] = None
    keypath: Optional[List[str]] = None
    record: Optional[Dict[str, Any]] = None
    state: str = "not-set-up"
    note: Optional[str] = None
    want: Optional[str] = None
    content: Optional[str] = None   # sha of Hook's content (cli: of its add command)
    disk: Optional[str] = None      # sha of what is there; None when absent
    payload: Any = None
    ph: Dict[str, str] = field(default_factory=dict)
    adopt: bool = False             # no record, but the content already is Hook's
    replace: bool = False           # no record, an earlier Hook setup is there
    legacy: bool = False            # a legacy Hook symlink (copy targets)
    unavailable: Optional[str] = None
    failed: Optional[str] = None    # the last apply failed with this note
    plugin_item: Optional["Item"] = None
    moved_from: Optional[str] = None  # the record Hook wrote before a `prefer` file filled up
    moved_item: Optional["Item"] = None


def _want(values: Values, content: str, extra: str = "") -> str:
    return _sha(f"{values.schema}\n{content}\n{extra}".encode("utf-8"))


def _read_text(path: Path) -> Optional[str]:
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return None
    except IsADirectoryError:
        raise _Blocked(f"{path.name} is a folder") from None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise _Blocked("the file is not UTF-8") from None


def _key_text(fmt: str, keypath: Sequence[str]) -> str:
    return ".".join(keypath)


def _target_key(kind: str, path: Path, piece: str, fmt: Optional[str] = None,
                keypath: Optional[Sequence[str]] = None) -> str:
    if kind == "key":
        return f"{path}#{fmt}:{'.'.join(keypath or [])}"
    if kind == "block":
        return f"{path}#block:{piece}"
    if kind == "file":
        return f"{path}#file"
    return f"{path}#tree"


def _writes_loc(writes: Dict[str, Any], ph: Mapping[str, str], home: Path) -> Tuple[Path, str]:
    path = expand(writes["path"], ph, home)
    if writes["format"] == "exists":
        return path, f"{path}#exists"
    return path, f"{path}#{writes['format']}:{'.'.join(writes.get('key') or [])}"


def _choose_alt(entry: Dict[str, Any], piece: str, manifest: Manifest, runner: Runner) -> Tuple[Optional[int], Optional[str]]:
    """(the alternative's index, None) or (None, why none can be used). A recorded choice is
    kept while its record exists."""
    alts = entry["pieces"][piece]
    info = ((manifest.harnesses.get(entry["id"]) or {}).get("pieces") or {}).get(piece)
    if info and isinstance(info.get("alt"), int) and 0 <= info["alt"] < len(alts) \
            and alts[info["alt"]]["method"] == info.get("method") and info.get("target") in manifest.targets:
        return info["alt"], None
    missing: List[str] = []
    for k, alt in enumerate(alts):
        if alt["method"] == "cli" and not runner.which(alt["requires"]):
            missing.append(alt["requires"])
            continue
        return k, None
    return None, "needs " + " or ".join(f"`{m}`" for m in missing)


def _plugin_requires(plugin: Dict[str, Any]) -> Optional[str]:
    if plugin.get("method") == "cli" and plugin.get("add"):
        return plugin["add"][0][0]
    return None


class Context:
    """What one run knows: the table, the manifest, the values and the runner."""

    def __init__(self, table: List[Dict[str, Any]], manifest: Manifest, values: Values, runner: Runner) -> None:
        self.table = table
        self.by_id = {e["id"]: e for e in table}
        self.manifest = manifest
        self.values = values
        self.runner = runner

    def tilde(self, path: Any) -> str:
        return tilde(path, self.values.home)

    # --- building items ---

    def items(self, entry: Dict[str, Any]) -> List[Item]:
        """One item per piece (and one for the plugin, first, when the entry has one)."""
        out: List[Item] = []
        plugin_item = self.plugin_item(entry) if entry.get("plugin") else None
        placed = plugin_item is None
        for piece in PIECES:
            idx, why = _choose_alt(entry, piece, self.manifest, self.runner)
            if idx is None:
                alt = entry["pieces"][piece][0]
                item = Item(entry["id"], piece, alt["method"], None, alt, unavailable=why,
                            ph=placeholders(self.values, entry))
                self._locate(item, entry)
                self._evaluate(item)
                if item.record is None and item.state in ("not-set-up",):
                    item.note = why
                out.append(item)
                continue
            alt = entry["pieces"][piece][idx]
            if alt["method"] == "plugin":
                if not placed:
                    out.append(plugin_item)
                    placed = True
                item = Item(entry["id"], piece, "plugin", idx, alt, plugin_item=plugin_item)
                if plugin_item is not None:
                    item.state, item.note, item.key = plugin_item.state, plugin_item.note, plugin_item.key
                    item.path, item.failed = plugin_item.path, plugin_item.failed
                out.append(item)
                continue
            out.append(self.item(entry, piece, idx))
        if not placed:
            out.insert(0, plugin_item)
        return out

    def item(self, entry: Dict[str, Any], piece: str, idx: int) -> Item:
        alt = entry["pieces"][piece][idx]
        item = Item(entry["id"], piece, alt["method"], idx, alt, definer=(entry["id"], piece, idx),
                    ph=placeholders(self.values, entry))
        self._locate(item, entry)
        found = self.manifest.find(item.key, item.loc)
        if found and found != item.key:
            # A shared target first written through another entry's alternative.
            rec = self.manifest.targets[found]
            d = rec.get("def")
            if isinstance(d, list) and len(d) == 3 and d[0] in self.by_id and d[0] != entry["id"]:
                other = self.by_id[d[0]]
                alts = other["pieces"].get(d[1]) or []
                if isinstance(d[2], int) and d[2] < len(alts):
                    shared = self.item(other, d[1], d[2])
                    shared.harness, shared.piece = entry["id"], piece
                    shared.failed = self._failure(entry["id"], piece)
                    return shared
        self._evaluate(item)
        return item

    def _failure(self, hid: str, piece: str) -> Optional[str]:
        return ((self.manifest.harnesses.get(hid) or {}).get("failed") or {}).get(piece)

    def _locate(self, item: Item, entry: Dict[str, Any]) -> None:
        alt, ph, home = item.alt or {}, item.ph, self.values.home
        m = item.method
        if m in ("file", "copy", "block", "key"):
            path = expand(alt["path"], ph, home)
            info = ((self.manifest.harnesses.get(item.harness) or {}).get("pieces") or {}).get(item.piece) or {}
            recorded = info.get("target")
            preferred = None
            for raw in alt.get("prefer") or []:
                cand = expand(raw, ph, home)
                if cand.is_file() and cand.stat().st_size > 0:
                    preferred = cand
                    break
            path = preferred or path
            if recorded and recorded in self.manifest.targets and info.get("method") == m:
                was = Path(self.manifest.targets[recorded].get("path", path))
                if preferred is not None and preferred != was and not _same(preferred, was):
                    # The harness reads the first non-empty `prefer` file, and one has filled up
                    # since Hook wrote into `was` (Codex: AGENTS.override.md over AGENTS.md).
                    item.moved_from = recorded
                else:
                    path = was
            item.path = path
            item.fmt = alt.get("format")
            item.keypath = list(alt.get("key") or []) or None
            item.key = _target_key(m, path, item.piece, item.fmt, item.keypath)
        elif m == "cli":
            item.key = f"cli:{item.harness}:{item.piece}"
            if alt.get("writes"):
                item.path, item.loc = _writes_loc(alt["writes"], ph, home)
                item.fmt = alt["writes"]["format"]
                item.keypath = list(alt["writes"].get("key") or []) or None
        elif m == "owner":
            item.key = None
        item.record = self.manifest.targets.get(item.key) if item.key else None
        if item.failed is None:
            item.failed = self._failure(item.harness, item.piece)

    def plugin_item(self, entry: Dict[str, Any]) -> Item:
        plugin = entry["plugin"]
        ph = placeholders(self.values, entry)
        item = Item(entry["id"], "plugin", "plugin", None, plugin, definer=(entry["id"], "plugin", None), ph=ph)
        item.path = expand(plugin["dest"], ph, self.values.home)
        item.key = f"plugin:{entry['id']}"
        item.record = self.manifest.targets.get(item.key)
        item.failed = self._failure(entry["id"], "plugin")
        need = _plugin_requires(plugin)
        if need and not self.runner.which(need):
            item.unavailable = f"needs `{need}`"
        self._evaluate(item)
        if item.record is None and item.state == "not-set-up" and item.unavailable:
            item.note = item.unavailable
        return item

    # --- what Hook would write, and what is there ---

    def _evaluate(self, item: Item) -> None:
        try:
            self._desired(item)
            self._disk(item)
        except _Blocked as exc:
            item.state, item.note = "blocked", str(exc)
            return
        except (ed.ParseError,) as exc:
            item.state, item.note = "blocked", f"{self.tilde(item.path)} doesn't parse ({exc}); Hook left it alone"
            return
        except ed.EditError as exc:
            item.state, item.note = "blocked", f"Hook won't edit {self.tilde(item.path)}: {exc}"
            return
        except rb.BundleError as exc:
            item.state, item.note = "blocked", f"the bundle: {exc}"
            return
        except OSError as exc:
            item.state, item.note = "blocked", _os_note(exc, self.values.home)
            return
        self._state(item)
        if item.moved_from is not None:
            self._moved(item)

    def _moved(self, item: Item) -> None:
        """The item's file is now a `prefer` file other than the one Hook wrote: outdated (the
        next sync moves Hook's piece there), or drifted when Hook's piece in the old file was
        edited (moved only with --force)."""
        rec = self.manifest.targets[item.moved_from]
        old = _record_item(self, item.harness, item.moved_from, rec)
        item.moved_item = old
        was, now = self.tilde(rec.get("path")), self.tilde(item.path)
        reads = f"{now} is the file it reads now"
        if old.state in ("drifted", "blocked"):
            item.state = "drifted"
            item.note = f"{reads}; Hook's {item.piece} in {was} is edited by you, so Hook won't move it"
        elif item.state == "not-set-up" or (item.state == "foreign" and item.method == "block"):
            item.state, item.adopt = "outdated", False
            item.note = f"{reads}; the next sync moves Hook's {item.piece} there from {was}"
        else:
            item.note = f"{reads}, not {was}" + (f"; {item.note}" if item.note else "")

    def _desired(self, item: Item) -> None:
        v, alt, ph, m = self.values, item.alt or {}, item.ph, item.method
        if m == "file":
            src = v.bundle / alt["source"]
            text = src.read_text("utf-8")
            if src.suffix in rb.JSON_SUFFIXES + rb.RAW_SUFFIXES:
                text = rb.render_text(text, ph, json_escape=src.suffix in rb.JSON_SUFFIXES)
            item.payload = text.encode("utf-8")
            item.content = _sha(item.payload)
        elif m == "copy":
            item.payload = v.bundle / alt["source"]
            item.content = rb.tree_sha(item.payload)
        elif m == "block":
            full = (v.bundle / "instructions" / "hook.md").read_text("utf-8")
            if alt.get("content") == "ref-or-full" and ph.get("instructions_home_ref"):
                body = rb.render_text(alt["ref"], ph, json_escape=False) + "\n"
            else:
                body = full
            item.payload = _block_body(body)
            item.content = _block_sha(body)
        elif m == "key":
            item.payload = _render_value(alt["value"], ph)
            item.content = _canon_sha(item.payload)
        elif m == "cli":
            item.payload = {"add": _argv(alt["add"], ph), "remove": _argv(alt["remove"], ph)}
            item.content = _canon_sha(item.payload["add"])
        elif m == "plugin":
            src = v.bundle / alt["render"]
            extra = rb.plugin_extras(v.bundle, src.name)
            item.payload = (src, extra)
            item.content = rb.files_sha(rb.render_files(src, ph, extra))
            item.want = _want(v, item.content, v.version)
            return
        else:
            return
        item.want = _want(v, item.content)

    def _disk(self, item: Item) -> None:
        m, path = item.method, item.path
        item.disk = None
        if m == "file":
            if path.is_dir() and not path.is_symlink():
                item.disk = "folder"
            elif path.is_file():
                item.disk = _sha(path.read_bytes())
        elif m in ("copy", "plugin"):
            if path.is_symlink():
                target = Path(os.path.realpath(path))
                if m == "copy" and target.name == "instructables" and target.parent.name == "skill" \
                        and (target.parent.parent / "mcp" / "relay_mcp.py").is_file():
                    item.legacy = True
                item.disk = "link"
            elif path.is_dir():
                try:
                    item.disk = rb.tree_sha(path)
                except rb.BundleError:
                    item.disk = "links"
            elif path.exists():
                item.disk = "file"
        elif m == "block":
            text = _read_text(path)
            if text is not None:
                got = ed.md_get_block(text, item.piece)
                if got is not None:
                    item.disk = _block_sha(got[0])
        elif m == "key":
            text = _read_text(path)
            value = self._key_value(item, text)
            if value is not _MISSING:
                item.disk = _canon_sha(value)
            elif text is not None:
                self._would_edit(item, text)
        elif m == "cli" and item.loc:
            if item.fmt == "exists":
                item.disk = "exists" if (path.exists() or path.is_symlink()) else None
            else:
                text = _read_text(path)
                value = _writes_value(item.fmt, text, item.keypath or [])
                if value is not _MISSING:
                    item.disk = _canon_sha(value)
                    item.payload = dict(item.payload, found=value)
        elif m == "cli":
            item.disk = (item.record or {}).get("sha")

    def _key_value(self, item: Item, text: Optional[str]) -> Any:
        """The value at Hook's key (or Hook's element, for an append), or _MISSING."""
        if text is None:
            return _MISSING
        alt, fmt, keypath = item.alt or {}, item.fmt, item.keypath or []
        if fmt in ("json", "jsonc"):
            if not text.strip():
                return _MISSING
            ed.loads_jsonc(text)
            found, value = ed.json_get(text, keypath)
            if not found:
                return _MISSING
            if alt.get("op") == "append":
                if not isinstance(value, list):
                    raise ed.EditError(f"{'.'.join(keypath)} is not a list")
                match = _matcher(alt["match"])
                hits = [e for e in value if match(e)]
                return hits[0] if hits else _MISSING
            return value
        if fmt == "toml":
            got = ed.toml_get_owned(text, item.piece)
            return _MISSING if got is None else got
        if fmt == "yaml":
            got = ed.yaml_get_owned(text, item.piece)
            return _MISSING if got is None else got
        raise ed.EditError(f"unknown format {fmt}")

    def _would_edit(self, item: Item, text: str) -> None:
        """Raise what an edit would raise (a key Hook can't add, a value set elsewhere)."""
        keypath = item.keypath or []
        if item.fmt == "toml":
            ed.toml_set_table(text, keypath, item.payload, item.piece, item.content[:16])
        elif item.fmt == "yaml":
            if len(keypath) != 2:
                raise ed.EditError("a YAML key is parent.child")
            ed.yaml_set_child(text, keypath[0], keypath[1], item.payload, item.piece, item.content[:16])
        elif item.fmt in ("json", "jsonc") and text.strip():
            if (item.alt or {}).get("op") == "append":
                ed.json_append(text, keypath, item.payload, _matcher(item.alt["match"]))
            else:
                ed.json_set(text, keypath, item.payload)

    def _state(self, item: Item) -> None:
        rec, disk, m = item.record, item.disk, item.method
        if m == "none":
            item.state, item.note = "none", (item.alt or {}).get("reason")
            return
        if m == "owner":
            step = (item.alt or {}).get("step")
            ask = (self.manifest.data.get("asks") or {}).get(step) or {}
            if ask.get("state") == "done":
                item.state = "installed"
            elif ask.get("state") == "skipped":
                item.state, item.note = "installed", "skipped by you"
            else:
                item.state, item.note = "needs-owner", "only you can do this step"
            return
        if rec is None:
            if disk is None:
                item.state = "not-set-up"
            elif item.legacy:
                item.state, item.replace, item.note = "not-set-up", True, "replaces an earlier Hook link"
            elif disk == item.content or self._cli_same(item):
                item.state, item.adopt = "not-set-up", True
            elif self._earlier_hook(item):
                item.state, item.replace = "not-set-up", True
            else:
                item.state, item.note = "foreign", f"{self.tilde(item.path)} is there and is not Hook's"
        else:
            accepted = rec.get("accepted")
            here = disk if disk is not None else ABSENT
            if accepted is not None:
                if here == accepted and item.want == rec.get("want"):
                    item.state, item.note = "accepted", "your edit is kept"
                else:
                    item.state = "drifted"
                    item.note = "Hook's text changed since you kept your edit" if here == accepted else "edited by you"
            elif disk is None and not (m == "cli" and not item.loc):
                item.state, item.note = "drifted", "removed by you"
            elif disk != rec.get("sha"):
                item.state, item.note = "drifted", "edited by you"
            elif item.want != rec.get("want"):
                item.state = "outdated"
            else:
                item.state = "installed"
        if item.failed and item.state in ("not-set-up", "outdated"):
            item.note = item.failed

    def _cli_same(self, item: Item) -> bool:
        """A command's `writes` location already holds exactly the JSON its add would pass
        (Claude Code's add-json): adopt it instead of removing and adding it again. Empty
        keys the harness adds on its own (env: {}) don't count."""
        if item.method != "cli" or not isinstance((item.payload or {}).get("found"), dict):
            return False
        found = {k: v for k, v in item.payload["found"].items() if v not in ({}, [], "", None)}
        for arg in (item.alt or {}).get("add") or []:
            if isinstance(arg, dict):
                want = _render_value(arg["json"], item.ph)
                if isinstance(want, dict) and found == {k: v for k, v in want.items() if v not in ({}, [], "", None)}:
                    return True
        return False

    def _earlier_hook(self, item: Item) -> bool:
        """No record, but what is there is from an earlier Hook setup."""
        m = item.method
        if m == "block":
            return True                           # Hook's markers are there
        if m == "key":
            if (item.alt or {}).get("op") == "append":
                return True                       # it matched Hook's text
            if item.fmt in ("toml", "yaml"):
                return True                       # inside Hook's markers
            text = _read_text(item.path) or ""
            _, value = ed.json_get(text, item.keypath or [])
            return _hookish(value)
        if m == "file":
            try:
                return _hookish(item.path.read_text("utf-8"))
            except (OSError, UnicodeDecodeError):
                return False
        if m == "cli":
            return _hookish((item.payload or {}).get("found"))
        if m == "plugin":
            return str(item.path).startswith(str(self.values.plugins) + "/")
        return False


_MISSING = object()


def _writes_value(fmt: str, text: Optional[str], keypath: Sequence[str]) -> Any:
    """The value a command wrote at keypath, or _MISSING. TOML is read by its table header,
    since Python 3.9 has no TOML parser."""
    if text is None or not text.strip():
        return _MISSING
    if fmt in ("json", "jsonc"):
        ed.loads_jsonc(text)
        found, value = ed.json_get(text, keypath)
        return value if found else _MISSING
    if fmt == "toml":
        head = re.compile(r"^\s*\[\s*" + r"\s*\.\s*".join(re.escape(k) for k in keypath) + r"\s*\]\s*(#.*)?$")
        lines = text.splitlines()
        for k, line in enumerate(lines):
            if head.match(line):
                body = []
                for row in lines[k + 1:]:
                    if re.match(r"^\s*\[", row):
                        break
                    if row.strip() and not row.lstrip().startswith("#"):
                        body.append(row.strip())
                return "\n".join(body)
        return _MISSING
    if fmt == "yaml":
        return text if re.search(rf"^\s+{re.escape(keypath[-1])}\s*:", text, re.M) else _MISSING
    return _MISSING


# --- planning ------------------------------------------------------------------------------

@dataclass
class Action:
    harness: str
    piece: str
    kind: str                       # install | update | replace | force | adopt | own | skip | remove | disown | keep
    target: str                     # a ~/ path or a command key
    detail: Dict[str, Any]


WRITES = ("install", "update", "replace", "force", "adopt", "own")
VERBS = {"install": "install", "update": "update", "replace": "replace", "force": "overwrite (with a .bak)",
         "adopt": "record", "own": "share", "skip": "skip", "remove": "remove", "disown": "release",
         "keep": "leave", "migrate": "migrate"}


def _target_label(ctx: Context, item: Item) -> str:
    if item.path is not None:
        return ctx.tilde(item.path)
    return item.key or item.piece


def plan(table, manifest, detections, values, runner, *, mode: str, harness: Optional[str],
         force: bool, include_new: bool, piece: Optional[str] = None, only_known: bool = False,
         include_removed: bool = False) -> List[Action]:
    """The actions for sync, reinstall or remove. Nothing is written. A harness the owner
    removed is left out unless it is named (Set Up) or `include_removed` (a first install)."""
    ctx = Context(table, manifest, values, runner)
    if harness is not None and harness not in ctx.by_id:
        raise UsageError(f"no harness {harness!r} in the table")
    if mode == "remove":
        return _plan_remove(ctx, harness, force)
    auto = bool(manifest.data.get("autoSetup", True)) and not only_known
    removed = set() if include_removed else set(manifest.removed)
    actions: List[Action] = []
    claimed: Dict[str, str] = {}
    for entry in table:
        hid = entry["id"]
        if harness is not None and hid != harness:
            continue
        det = detections.get(hid)
        managed = hid in manifest.harnesses
        if not (det and det.found) and not managed:
            continue
        if hid in removed and harness != hid:
            continue
        if not managed and not (include_new or auto or harness == hid):
            continue
        for item in ctx.items(entry):
            if item.method in ("none", "owner") or (item.method == "plugin" and item.piece != "plugin"):
                continue
            if piece is not None and not _piece_matches(item, piece, entry):
                continue
            label = _target_label(ctx, item)
            ids = [k for k in (item.key, item.loc) if k]
            shared = next((claimed[k] for k in ids if k in claimed), None)
            if shared is not None:
                first_key, first_kind = shared
                rec = manifest.targets.get(first_key)
                if first_kind in WRITES:
                    if not rec or hid not in (rec.get("owners") or []):
                        actions.append(Action(hid, item.piece, "own", label, {"item": item, "key": first_key}))
                elif first_kind == "skip":
                    actions.append(Action(hid, item.piece, "skip", label,
                                          {"item": item, "key": first_key, "state": item.state, "note": item.note}))
                continue
            kind = _decide(item, mode, force)
            for k in ids:
                claimed[k] = (item.key, kind)
            if kind is None:
                continue
            if kind == "own" and (item.record and hid in (item.record.get("owners") or [])):
                continue
            actions.append(Action(hid, item.piece, kind, label,
                                  {"item": item, "key": item.key, "state": item.state, "note": item.note}))
    return actions


def _piece_matches(item: Item, piece: str, entry: Dict[str, Any]) -> bool:
    if item.piece == piece:
        return True
    if item.piece == "plugin":
        alts = entry["pieces"].get(piece) or []
        return any(a["method"] == "plugin" for a in alts)
    return False


def _decide(item: Item, mode: str, force: bool) -> Optional[str]:
    st = item.state
    if st == "not-set-up":
        if item.unavailable and item.record is None:
            return "skip"
        return "adopt" if item.adopt else ("replace" if item.replace else "install")
    if st == "outdated":
        return "update"
    if st == "installed":
        return "update" if mode == "reinstall" else "own"
    if st in ("drifted", "foreign", "accepted"):
        if force:
            return "force"
        return None if st == "accepted" else "skip"
    if st == "blocked":
        return "skip"
    return None


def _plan_remove(ctx: Context, harness: Optional[str], force: bool) -> List[Action]:
    actions: List[Action] = []
    manifest = ctx.manifest
    hids = [harness] if harness else list(manifest.harnesses)
    done: set = set()
    for hid in hids:
        if hid not in manifest.harnesses:
            continue
        entry = ctx.by_id.get(hid)
        items = {it.key: it for it in (ctx.items(entry) if entry else []) if it.key}
        for key in manifest.owned_by(hid):
            rec = manifest.targets[key]
            label = ctx.tilde(rec["path"]) if rec.get("path") else key
            others = [o for o in rec.get("owners") or [] if o != hid and (harness is not None or o not in hids)]
            if others:
                actions.append(Action(hid, rec.get("piece", "?"), "disown", label, {"key": key}))
                continue
            if key in done:
                continue
            done.add(key)
            item = items.get(key) or _record_item(ctx, hid, key, rec)
            st = item.state
            if st in ("drifted", "accepted", "foreign") and not force:
                kind = "keep"
            elif st == "blocked":
                kind = "keep"
            else:
                kind = "remove"
            actions.append(Action(hid, rec.get("piece", "?"), kind, label,
                                  {"key": key, "item": item, "state": st, "note": item.note}))
    return actions


def _record_item(ctx: Context, hid: str, key: str, rec: Dict[str, Any]) -> Item:
    """An item for a record whose entry left the table: its state from the disk alone."""
    item = Item(hid, rec.get("piece", "?"), rec.get("kind", "file"), key=key, record=rec)
    item.path = Path(rec["path"]) if rec.get("path") else None
    item.fmt, item.keypath = rec.get("format"), rec.get("keypath")
    item.state = "installed"
    try:
        if item.method in ("file", "copy", "plugin", "block", "key") and item.path is not None:
            item.alt = {"op": rec.get("op"), "match": rec.get("match")}
            ctx._disk(item)
            if item.disk != rec.get("sha"):
                item.state = "drifted"
    except (_Blocked, ed.ParseError, ed.EditError):
        item.state = "blocked"
    return item


# --- applying ------------------------------------------------------------------------------

@dataclass
class Report:
    results: List[Dict[str, Any]] = field(default_factory=list)
    failed: int = 0
    dry_run: bool = False
    applied: Dict[str, List[str]] = field(default_factory=dict)   # harness → pieces written
    changed: Dict[str, List[str]] = field(default_factory=dict)   # harness → pieces whose content changed
    drifted: List[Dict[str, Any]] = field(default_factory=list)   # edited items a sync left alone
    errors: List[str] = field(default_factory=list)

    def add(self, action: Action, outcome: str, note: Optional[str] = None) -> None:
        self.results.append({"harness": action.harness, "piece": action.piece, "action": action.kind,
                             "target": action.target, "outcome": outcome, "note": note})


def _iso(now: datetime) -> str:
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _mkparents(path: Path) -> List[str]:
    """Make path's missing parent folders; return the ones made, outermost first."""
    made: List[Path] = []
    parent = path.parent
    while not parent.exists():
        made.append(parent)
        parent = parent.parent
    for d in reversed(made):
        d.mkdir()
    return [str(d) for d in reversed(made)]


def _rmdirs(dirs: Sequence[str]) -> List[str]:
    """rmdir each folder that is empty, deepest first; return the ones still there."""
    for d in sorted(set(dirs), key=len, reverse=True):
        try:
            os.rmdir(d)
        except OSError:
            pass
    return [d for d in dirs if os.path.isdir(d)]


def _backup_tree(path: Path, values: Values, now: datetime) -> Path:
    """Folders are backed up outside the harness's folder, so a harness never loads the copy."""
    root = values.home / ".local" / "share" / "hook" / "backups"
    root.mkdir(parents=True, exist_ok=True)
    name = f"{path.name}-{now.strftime('%Y%m%d-%H%M%S')}"
    dest, n = root / name, 2
    while dest.exists() or dest.is_symlink():
        dest, n = root / f"{name}-{n}", n + 1
    if path.is_symlink():
        os.symlink(os.readlink(path), dest)
    else:
        shutil.copytree(path, dest, symlinks=True)
    return dest


def _remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def _copy_into(src: Path, dest: Path) -> str:
    """Copy the bundle folder src to dest (replacing it) and return its tree sha."""
    tmp = dest.with_name(f".{dest.name}.hook-tmp-{os.getpid()}")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir()
    try:
        rb._copy_tree(src, tmp)
        sha = rb.tree_sha(tmp)
        if dest.exists() or dest.is_symlink():
            old = dest.with_name(f".{dest.name}.hook-old-{os.getpid()}")
            if dest.is_symlink() or dest.is_file():
                dest.unlink()
            else:
                dest.rename(old)
                shutil.rmtree(old, ignore_errors=True)
        tmp.rename(dest)
        return sha
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


class Applier:
    def __init__(self, ctx: Context, report: Report, now: datetime) -> None:
        self.ctx = ctx
        self.values = ctx.values
        self.manifest = ctx.manifest
        self.report = report
        self.now = now

    def run(self, actions: List[Action]) -> None:
        for action in actions:
            if self.report.dry_run:
                self.report.add(action, "would", action.detail.get("note"))
                continue
            try:
                outcome = self.one(action)
                if outcome == "skipped":
                    self._note_drift(action)
                self._clear_failure(action)
                noted = outcome in ("skipped", "left", "restored")
                self.report.add(action, outcome, action.detail.get("note") if noted else None)
            except _Blocked as exc:
                self.report.add(action, "blocked", str(exc))
            except (ed.ParseError,) as exc:
                self.report.add(action, "blocked", f"{action.target} doesn't parse ({exc}); Hook left it alone")
            except (_Fail, ed.EditError, rb.BundleError, OSError) as exc:
                note = str(exc) if isinstance(exc, (_Fail, ed.EditError)) else _os_note(exc, self.values.home)
                self.report.failed += 1
                self.report.add(action, "failed", note)
                self._set_failure(action, note)

    def _note_drift(self, action: Action) -> None:
        """Remember an edited item a sync left alone, once per target, for the drift ask."""
        item: Optional[Item] = action.detail.get("item")
        if item is None or item.state not in ("drifted", "foreign") or item.key is None:
            return
        key = action.detail.get("key") or item.key
        if any(d["key"] == key for d in self.report.drifted):
            return
        entry = self.ctx.by_id.get(action.harness) or {}
        doc = None
        if item.path is not None:
            if item.path.is_file():
                doc = self.ctx.tilde(item.path)
            elif (item.path / "SKILL.md").is_file():
                doc = self.ctx.tilde(item.path / "SKILL.md")
        self.report.drifted.append({
            "key": key, "disk": item.disk if item.disk is not None else ABSENT, "harness": action.harness,
            "name": entry.get("name", action.harness), "piece": item.piece, "path": action.target,
            "file": doc, "diffable": item.method in DIFFABLE})

    def _clear_failure(self, action: Action) -> None:
        h = self.manifest.harnesses.get(action.harness)
        if h and (h.get("failed") or {}).pop(action.piece, None) is not None and not h["failed"]:
            del h["failed"]

    def _set_failure(self, action: Action, note: str) -> None:
        if action.kind in ("remove", "disown", "keep"):
            return
        h = self._harness(action.harness)
        h.setdefault("failed", {})[action.piece] = note

    def _made(self, dirs: List[str]) -> List[str]:
        """Remember folders Hook made, so a remove can take them away again once empty."""
        known = self.manifest.data.setdefault("dirs", [])
        for d in dirs:
            if d not in known:
                known.append(d)
        return dirs

    def _harness(self, hid: str) -> Dict[str, Any]:
        h = self.manifest.harnesses.get(hid)
        if h is None:
            h = {"pieces": {}, "plugin": None, "since": _iso(self.now)}
            self.manifest.harnesses[hid] = h
        h.setdefault("pieces", {})
        return h

    def _bind(self, item: Item, key: str) -> None:
        h = self._harness(item.harness)
        if item.piece == "plugin":
            h["plugin"] = key
        else:
            h["pieces"][item.piece] = {"alt": item.alt_index, "method": item.method, "target": key}
        self.report.applied.setdefault(item.harness, []).append(item.piece)

    def one(self, action: Action) -> str:
        kind, d = action.kind, action.detail
        if kind == "skip":
            return "skipped"
        if kind == "keep":
            return "left"
        if kind == "own":
            item: Item = d["item"]
            key = d["key"]
            if key not in self.manifest.targets:
                raise _Fail("the shared target was not written")
            self.manifest.own(key, action.harness, {})
            self._bind(item, key)
            return "shared"
        if kind == "disown":
            self.manifest.disown(d["key"], action.harness)
            self._unbind(action.harness, d["key"])
            return "released"
        if kind == "remove":
            note = self.remove(d["item"], d["key"])
            if note:
                d["note"] = note
                return "restored"
            return "removed"
        item = d["item"]
        old_sha = (item.record or {}).get("sha")
        if item.moved_from is not None and item.moved_from in self.manifest.targets:
            self._move_out(item, kind == "force")
        record = self.write(item, kind)
        if kind != "adopt" and (item.record is None or record.get("sha") != old_sha):
            self.report.changed.setdefault(item.harness, []).append(item.piece)
        record.update({"kind": item.method, "piece": item.piece, "schema": self.values.schema,
                       "want": item.want, "written": _iso(self.now),
                       "linkRoot": tilde(self.values.link_root, self.values.home),
                       "def": list(item.definer) if item.definer else None})
        if item.path is not None:
            record["path"] = str(item.path)
        if item.fmt:
            record["format"] = item.fmt
        if item.keypath:
            record["keypath"] = item.keypath
        if item.loc:
            record["writes"] = item.loc
        if item.method == "key" and (item.alt or {}).get("op") == "append":
            record["op"], record["match"] = "append", item.alt["match"]
        record.pop("accepted", None)
        old = self.manifest.targets.get(item.key) or {}
        self.manifest.targets[item.key] = {k: v for k, v in old.items() if k != "accepted"}
        self.manifest.own(item.key, item.harness, record)
        self._bind(item, item.key)
        return {"install": "installed", "update": "updated", "replace": "replaced", "force": "overwritten",
                "adopt": "recorded"}[kind]

    def _move_out(self, item: Item, force: bool) -> None:
        """Take Hook's piece out of the file it wrote before a `prefer` file filled up; a target
        another harness shares is only released."""
        key = item.moved_from
        rec = self.manifest.targets[key]
        if [o for o in rec.get("owners") or [] if o != item.harness]:
            self.manifest.disown(key, item.harness)
            self._unbind(item.harness, key)
            return
        old = item.moved_item or _record_item(self.ctx, item.harness, key, rec)
        if old.state in ("drifted", "blocked") and not force:
            raise _Fail(f"Hook's {item.piece} in {self.ctx.tilde(rec.get('path'))} is edited by you")
        self.remove(old, key)

    def _unbind(self, hid: str, key: str) -> None:
        h = self.manifest.harnesses.get(hid)
        if not h:
            return
        for piece in [p for p, info in (h.get("pieces") or {}).items() if info.get("target") == key]:
            del h["pieces"][piece]
        if h.get("plugin") == key:
            h["plugin"] = None
        (h.get("failed") or {}).clear()
        if not h.get("pieces") and not h.get("plugin"):
            del self.manifest.harnesses[hid]

    # --- writing one item ---

    def write(self, item: Item, kind: str) -> Dict[str, Any]:
        """Write the item and return the fields of its new record."""
        rec = dict(item.record or {})
        force = kind == "force"
        if kind == "adopt":
            adopted = {"sha": item.disk, "backup": rec.get("backup"), "created": False, "dirs": []}
            if item.method == "cli":
                adopted["remove"] = item.payload["remove"]
            return adopted
        m = item.method
        if m == "file":
            return self._write_file(item, rec, force)
        if m == "copy":
            return self._write_copy(item, rec, force)
        if m in ("block", "key"):
            return self._write_text(item, rec, force)
        if m == "cli":
            return self._write_cli(item, rec, kind)
        if m == "plugin":
            return self._write_plugin(item, rec, kind)
        raise _Fail(f"Hook can't install a {m} piece")

    def _backup_file(self, path: Path) -> Optional[str]:
        if path.is_file():
            return str(ed.make_backup(path, self.now))
        return None

    def _write_file(self, item: Item, rec: Dict[str, Any], force: bool) -> Dict[str, Any]:
        path = item.path
        backup = rec.get("backup")
        existed = path.exists() or path.is_symlink()
        # A file Hook has no record of is someone's, even when it reads like Hook's: keep a
        # copy, so a remove can put it back.
        if existed and (force or not rec):
            if path.is_dir() and not path.is_symlink():
                made = str(_backup_tree(path, self.values, self.now))
                shutil.rmtree(path)
            else:
                made = self._backup_file(path)
            if not (rec.get("created") is False and backup):   # keep the copy of the file from before Hook
                backup = made or backup
        created = rec.get("created", not existed)
        dirs = rec.get("dirs") or self._made(_mkparents(path))
        ed.atomic_write(path, item.payload)
        return {"sha": _sha(item.payload), "backup": backup, "created": created, "dirs": dirs}

    def _write_copy(self, item: Item, rec: Dict[str, Any], force: bool) -> Dict[str, Any]:
        path = item.path
        backup = rec.get("backup")
        if force and (path.exists() or path.is_symlink()):
            backup = str(_backup_tree(path, self.values, self.now))
        if item.legacy:
            path.unlink()
        dirs = rec.get("dirs") or self._made(_mkparents(path))
        sha = _copy_into(item.payload, path)
        return {"sha": sha, "backup": backup, "created": True, "dirs": dirs}

    def _write_text(self, item: Item, rec: Dict[str, Any], force: bool) -> Dict[str, Any]:
        path = item.path
        text = _read_text(path)
        existed = text is not None
        text = text or ""
        backup = rec.get("backup")
        first = not rec
        prune = rec.get("prune", 0)
        alt = item.alt or {}
        empty = rec.get("empty")
        if item.method == "block":
            new = ed.md_set_block(text, item.piece, item.payload, self.values.schema)
        elif item.fmt in ("json", "jsonc"):
            if first and not item.replace and existed and EMPTY_SHAPE.fullmatch(text):
                # `{ }`, `{\n}\n`, a newline: a remove gives these bytes back. Only braces and
                # whitespace are kept, never a comment (a comment-only object round-trips anyway).
                empty = text
            if text.strip():
                ed.loads_jsonc(text)
            keypath = item.keypath or []
            if alt.get("op") == "append":
                match = _matcher(alt["match"])
                base = ed.json_remove_matching(text, keypath, match) if (item.record or item.replace) else text
                if first and not item.replace:
                    prune = ed.json_missing_containers(base, keypath, append=True)
                new = ed.json_append(base, keypath, item.payload, match)
            else:
                if first and not item.replace:
                    prune = ed.json_missing_containers(text, keypath)
                new = ed.json_set(text, keypath, item.payload)
        elif item.fmt == "toml":
            new = ed.toml_set_table(text, item.keypath or [], item.payload, item.piece, item.content[:16])
        elif item.fmt == "yaml":
            keypath = item.keypath or []
            if len(keypath) != 2:
                raise ed.EditError("a YAML key is parent.child")
            new = ed.yaml_set_child(text, keypath[0], keypath[1], item.payload, item.piece, item.content[:16])
        else:
            raise _Fail(f"unknown format {item.fmt}")
        if (force or (first and text.strip())) and existed:
            backup = self._backup_file(path) or backup
        created = rec.get("created", not existed)
        dirs = rec.get("dirs") or self._made(_mkparents(path))
        if new != text or not existed:
            ed.atomic_write(path, new.encode("utf-8"))
        item.disk = item.content
        out = {"sha": item.content, "backup": backup, "created": created, "dirs": dirs, "prune": prune}
        if empty is not None:
            out["empty"] = empty
        return out

    def _confirm(self, item: Item, what: str) -> Optional[str]:
        """The sha of what a command wrote at its `writes` location (None without one)."""
        if not item.loc:
            return item.content
        if item.fmt == "exists":
            if item.path.exists() or item.path.is_symlink():
                return "exists"
            raise _Fail(f"{what} ran, but {self.ctx.tilde(item.path)} is not there")
        value = _writes_value(item.fmt, _read_text(item.path), item.keypath or [])
        if value is _MISSING:
            raise _Fail(f"{what} ran, but {self.ctx.tilde(item.path)} has no {'.'.join(item.keypath or [])}")
        return _canon_sha(value)

    def _check_writes_file(self, item: Item) -> None:
        """Never let a command rewrite a file that doesn't parse."""
        if item.loc and item.fmt in ("json", "jsonc"):
            text = _read_text(item.path)
            if text is not None and text.strip():
                ed.loads_jsonc(text)

    def _cmd(self, argv: List[str]) -> None:
        rc, out, err = self.ctx.runner.run(argv)
        if rc != 0:
            raise _Fail(_first_line(err, f"`{argv[0]}` exited {rc}"))

    def _write_cli(self, item: Item, rec: Dict[str, Any], kind: str) -> Dict[str, Any]:
        self._check_writes_file(item)
        backup = rec.get("backup")
        if kind == "force" and item.loc and item.fmt != "exists":
            backup = self._backup_file(item.path) or backup
        if kind in ("update", "replace", "force"):
            old = rec.get("remove") or item.payload["remove"]
            self.ctx.runner.run(old)                  # it may already be gone
        self._cmd(item.payload["add"])
        sha = self._confirm(item, f"`{item.payload['add'][0]}`")
        return {"sha": sha, "backup": backup, "remove": item.payload["remove"], "created": False, "dirs": []}

    def _write_plugin(self, item: Item, rec: Dict[str, Any], kind: str) -> Dict[str, Any]:
        plugin, dest = item.alt or {}, item.path
        src, extra = item.payload
        backup = rec.get("backup")
        if kind == "force" and (dest.exists() or dest.is_symlink()):
            backup = str(_backup_tree(dest, self.values, self.now))
            _remove_path(dest)
        elif dest.is_symlink() or dest.is_file():
            _remove_path(dest)
        dirs = rec.get("dirs") or self._made(_mkparents(dest))
        sha = rb.render_tree(src, dest, item.ph, extra)
        if plugin.get("method") == "cli":
            fresh = not rec or kind in ("replace", "force") or rec.get("added") is False
            if fresh:
                for argv in plugin.get("add") or []:
                    self._cmd(_argv(argv, item.ph))
            else:
                for argv in plugin.get("update") or []:
                    self._cmd(_argv(argv, item.ph))
            if plugin.get("writes"):
                wpath, _ = _writes_loc(plugin["writes"], item.ph, self.values.home)
                if not (wpath.exists() or wpath.is_symlink()):
                    raise _Fail(f"`{plugin['add'][0][0]}` ran, but {self.ctx.tilde(wpath)} is not there")
        return {"sha": sha, "backup": backup, "created": True, "dirs": dirs, "version": self.values.version,
                "remove": [_argv(a, item.ph) for a in plugin.get("remove") or []],
                "treeChanged": sha != rec.get("sha")}

    # --- removing one target ---

    def remove(self, item: Item, key: str) -> Optional[str]:
        """Remove the target and forget its record; a note when it put back an earlier file."""
        rec = self.manifest.targets.get(key) or {}
        m = rec.get("kind", item.method)
        path = Path(rec["path"]) if rec.get("path") else None
        forced = item.state in ("drifted", "accepted", "foreign")
        note = None
        if m == "file" and path is not None:
            if path.exists() or path.is_symlink():
                if forced and path.is_file():
                    self._backup_file(path)
                _remove_path(path)
            earlier = Path(rec["backup"]) if rec.get("created") is False and rec.get("backup") else None
            if earlier is not None and (earlier.exists() or earlier.is_symlink()):
                shutil.move(str(earlier), str(path))           # the file that was there before Hook's
                note = "your earlier file is back"
        elif m in ("copy", "plugin") and path is not None:
            if m == "plugin":
                for argv in rec.get("remove") or []:
                    self._cmd(argv)
            if path.exists() or path.is_symlink():
                if forced:
                    _backup_tree(path, self.values, self.now)
                _remove_path(path)
        elif m in ("block", "key") and path is not None:
            text = _read_text(path)
            if text is not None:
                if forced:
                    self._backup_file(path)
                new = self._unedit(rec, text, item)
                if new != text:
                    if not new and rec.get("created"):
                        path.unlink()
                    else:
                        ed.atomic_write(path, new.encode("utf-8"))
                elif not text and rec.get("created"):
                    path.unlink()
        elif m == "cli":
            argv = rec.get("remove")
            if argv:
                if not self.ctx.runner.which(argv[0]):
                    raise _Fail(f"needs `{argv[0]}` to remove it")
                self._cmd(argv)
        _rmdirs(rec.get("dirs") or [])
        self.manifest.forget(key)
        for hid in list(self.manifest.harnesses):
            self._unbind(hid, key)
        return note

    def _unedit(self, rec: Dict[str, Any], text: str, item: Item) -> str:
        piece = rec.get("piece", item.piece)
        if rec.get("kind") == "block":
            return ed.md_remove_block(text, piece)
        fmt, keypath = rec.get("format"), rec.get("keypath") or []
        if fmt in ("json", "jsonc"):
            if not text.strip():
                return text
            restore = rec.get("empty") if isinstance(rec.get("empty"), str) else None
            if rec.get("op") == "append":
                return ed.json_remove_matching(text, keypath, _matcher(rec["match"]), prune=rec.get("prune", 0),
                                               restore=restore)
            return ed.json_delete(text, keypath, prune=rec.get("prune", 0), restore=restore)
        if fmt == "toml":
            return ed.toml_remove_table(text, piece)
        if fmt == "yaml":
            return ed.yaml_remove_child(text, piece)
        return text


def _os_note(exc: OSError, home: Path) -> str:
    name = tilde(exc.filename, home) if getattr(exc, "filename", None) else ""
    return f"{exc.strerror or exc}{': ' + name if name else ''}"


def apply(actions: List[Action], manifest: Manifest, values: Values, runner: Runner, now: datetime, *,
          dry_run: bool, table: Optional[List[Dict[str, Any]]] = None) -> Report:
    """Carry out the actions in order. dry_run writes nothing, not even the manifest."""
    report = Report(dry_run=dry_run)
    ctx = Context(table or [], manifest, values, runner)
    Applier(ctx, report, now).run(actions)
    return report


# --- owner steps and the drift ask -----------------------------------------------------------

def default_client_factory(values: Values) -> Callable[..., Any]:
    """relay_client.Client for this HOME, as `relay post` makes it. The client reads its own
    config and token; this module never opens them."""
    def make(**kw: Any) -> Any:
        import relay_client
        env = dict(values.env)
        env.setdefault("RELAY_CONFIG", str(values.home / ".config" / "relay" / "config.json"))
        return relay_client.Client(env=env, **kw)
    return make


def _owner_phase(ctx: Context, report: Report, poster: Any, now: datetime, *, harness: Optional[str],
                 drift: bool) -> None:
    """Post the owner steps that fell due in this run (or were left pending), then, after a
    sync, one ask for the edited files it left alone."""
    import relay_owner_steps as ros
    steps = []
    for entry in ctx.table:
        hid = entry["id"]
        if hid not in ctx.manifest.harnesses or (harness is not None and hid != harness):
            continue
        if hid in ctx.manifest.removed and hid != harness:
            continue
        written = set(report.changed.get(hid, []))
        for step in ros.due_steps(entry, ctx.manifest, written):
            try:
                doc = ros.render_step(entry, step, ctx.values)
            except (ros.InvalidAsk, rb.BundleError) as exc:
                report.errors.append(f"{hid} owner step {step['id']}: {exc}")
                continue
            steps.append({"id": step["id"], "title": step["title"], "harness": hid, "instructable": doc})
    rows = ros.post_due(steps, ctx.manifest, None, no_asks=poster.no_asks, now=now, poster=poster)
    for step, row in zip(steps, rows):
        report.results.append({"harness": step["harness"], "piece": "owner", "action": "ask", "target": row["title"],
                               "outcome": "posted" if row["askId"] else "pending",
                               "note": None if row["askId"] else "Hook posts it at the next sync"})
    if drift:
        due = ros.drift_items_due(report.drifted, ctx.manifest)
        try:
            rec = ros.post_drift(due, ctx.manifest, ctx.values, poster, now)
        except ros.InvalidAsk as exc:
            report.errors.append(f"the drift ask: {exc}")
            rec = None
        if rec is not None:
            report.results.append({"harness": "hook", "piece": "owner", "action": "ask", "target": rec["title"],
                                   "outcome": "posted", "note": None})
        ros.finish_drift(ctx.manifest, poster)
    report.errors.extend(poster.errors)


MIGRATE_HID = "claude-code"


def _migrate(ctx: Context, report: Report, poster: Any, now: datetime, *, dry_run: bool, again: bool = False,
             choice: Optional[str] = None) -> None:
    """The Claude Code migration, after its entry applied (relay_migrate_claude)."""
    import relay_migrate_claude as mc
    if MIGRATE_HID not in ctx.by_id or MIGRATE_HID not in ctx.manifest.harnesses:
        return
    outcome = next((r["outcome"] for r in report.results if r["harness"] == MIGRATE_HID and r["piece"] == "mcp"
                    and r["action"] in ("replace", "adopt")), None)
    try:
        items = mc.migrate(ctx.values, ctx.manifest, ctx.runner, None, now, dry_run=dry_run, again=again,
                           choice=choice, poster=poster, mcp_outcome=outcome)
    except (OSError, ed.EditError) as exc:
        note = _os_note(exc, ctx.values.home) if isinstance(exc, OSError) else str(exc)
        report.failed += 1
        report.results.append({"harness": MIGRATE_HID, "piece": "migrate", "action": "migrate", "target": "~/.claude",
                               "outcome": "failed", "note": note})
        return
    for it in items:
        state = it["state"]
        if dry_run:
            what = state[len("would "):] if state.startswith("would ") else state
            note = f"{what}: {it['note']}" if it.get("note") else what
            row = {"harness": MIGRATE_HID, "piece": it["id"], "action": "migrate",
                   "target": it["path"], "outcome": "would", "note": note}
            if it.get("diff"):
                row["diff"] = it["diff"]
            report.results.append(row)
        else:
            report.results.append({"harness": MIGRATE_HID, "piece": it["id"], "action": "migrate",
                                   "target": it["path"], "outcome": state, "note": it.get("note")})


def _migration_backups(manifest: Manifest, report: Report, values: Values) -> None:
    """Uninstall never undoes the migration; it says where the originals are."""
    import relay_migrate_claude as mc
    for path, backup in mc.backups(manifest):
        report.results.append({"harness": MIGRATE_HID, "piece": "migrate", "action": "keep", "target": path,
                               "outcome": "left", "note": f"Hook's earlier change stays; your original is {backup}"})


def _drift_answers(ctx: Context, report: Report, detections: Dict[str, Detection], now: datetime) -> None:
    """Carry out the owner's answers to the drift ask: Keep mine is `accept`, Use Hook's is
    `reinstall --force --piece` (owner pick 6, rule 17). An item that changed since is left
    for a new ask."""
    import relay_owner_steps as ros
    for choice in ros.drift_choices(ctx.manifest):
        row = choice["row"]
        hid, piece = row["harness"], row["piece"]
        if hid not in ctx.by_id:
            row["done"] = "gone"
            continue
        items = [it for it in _select(ctx, hid, piece) if it.key == row["key"]]
        here = items[0].disk if items and items[0].disk is not None else ABSENT
        if not items or items[0].state not in ("drifted", "foreign") or here != row["disk"]:
            row["done"] = "changed"
            continue
        if choice["choice"] == ros.KEEP and items[0].moved_item is not None:
            report.results.append({"harness": hid, "piece": piece, "action": "keep",
                                   "target": _target_label(ctx, items[0]), "outcome": "left",
                                   "note": _moved_refusal(ctx, items[0])})
            row["done"] = "moved"
        elif choice["choice"] == ros.KEEP:
            for done in _accept(ctx, hid, piece, now):
                report.results.append({"harness": hid, "piece": done["piece"], "action": "accept",
                                       "target": done["target"], "outcome": "kept", "note": "your choice in Hook"})
            row["done"] = "kept"
        else:
            actions = [a for a in plan(ctx.table, ctx.manifest, detections, ctx.values, ctx.runner, mode="reinstall",
                                       harness=hid, force=True, include_new=False, piece=piece)
                       if a.kind == "force" and a.detail.get("key") == row["key"]]
            failed = report.failed
            Applier(ctx, report, now).run(actions)
            row["done"] = "replaced" if report.failed == failed else "failed"


# --- status --------------------------------------------------------------------------------

def _worst(states: Sequence[str]) -> str:
    ranked = [s if s != "accepted" else "installed" for s in states if s != "none"]
    for st in STATE_ORDER:
        if st in ranked:
            return st
    return "installed"


def _shown(state: str) -> str:
    return "drifted" if state == "foreign" else state


def _piece_json(ctx: Context, item: Item) -> Dict[str, Any]:
    state = item.state
    if item.failed and state in ("not-set-up", "outdated"):
        state = "blocked"
    target, key = None, None
    if item.method in ("file", "copy", "block", "key", "plugin") and item.path is not None:
        target = ctx.tilde(item.path)
    elif item.method == "cli" and item.path is not None:
        target = ctx.tilde(item.path)
    if item.method == "key" or (item.method == "cli" and item.keypath):
        key = ".".join(item.keypath or [])
    reveal = None
    if item.path is not None:
        for cand in (item.path, item.path.parent):
            if cand.exists():
                reveal = ctx.tilde(cand)
                break
    method = item.method
    edited = item.state in ("drifted", "foreign")
    return {"piece": item.piece, "method": method, "state": _shown(state), "target": target, "key": key,
            "note": item.note, "diffable": edited and method in DIFFABLE,
            "keepable": edited and item.moved_item is None, "reveal": reveal}


def _changes(ctx: Context, hid: str) -> List[Dict[str, str]]:
    out = []
    for key in ctx.manifest.owned_by(hid):
        rec = ctx.manifest.targets[key]
        kind = rec.get("kind")
        what = {"file": "file", "copy": "folder", "plugin": "plugin"}.get(kind)
        if kind == "block":
            what = f"block {rec.get('piece')}"
        elif kind == "key":
            what = f"key {'.'.join(rec.get('keypath') or [])}"
        elif kind == "cli":
            what = f"command {rec.get('piece')}"
        path = rec.get("path")
        out.append({"path": ctx.tilde(path) if path else key, "what": what or str(kind)})
    return out


def status(table, manifest, detections, values, runner, *, smoke: bool) -> Dict[str, Any]:
    """The status JSON (T11 reads it; its keys are stable). Fast: files and the manifest only,
    unless smoke runs the harnesses' own checks."""
    ctx = Context(table, manifest, values, runner)
    harnesses = []
    asks = manifest.data.get("asks") or {}
    removed = set(manifest.removed)
    for entry in table:
        hid = entry["id"]
        det = detections.get(hid) or Detection(hid, False, [])
        managed = bool(manifest.owned_by(hid)) or hid in manifest.harnesses
        items = [it for it in ctx.items(entry) if it.piece != "plugin"]
        pieces = [_piece_json(ctx, it) for it in items]
        steps = [{"id": s["id"], "title": (asks.get(s["id"]) or {}).get("title", s["title"]),
                  "askId": (asks.get(s["id"]) or {}).get("askId"), "state": asks[s["id"]].get("state")}
                 for s in entry.get("owner_steps") or [] if s["id"] in asks]
        states = [p["state"] if p["state"] != "drifted" else "drifted" for p in pieces]
        if any(s["state"] in ("open", "pending") for s in steps):
            states.append("needs-owner")
        state = _worst(states) if (det.found or managed) else "not-set-up"
        if not managed and det.found and state == "installed":
            state = "not-set-up"
        h = {"id": hid, "name": entry["name"], "detected": det.found, "managed": managed,
             "removed": hid in removed, "state": state,
             "verified": entry.get("verified"), "pieces": pieces, "ownerSteps": steps, "changes": _changes(ctx, hid)}
        if smoke:
            h["smoke"] = _smoke(ctx, entry, items)
        harnesses.append(h)
    errors = []
    if manifest.problem:
        errors.append(manifest.problem)
    checked = sorted(e.get("checked", "") for e in table)
    return {
        "schema": SCHEMA, "hookVersion": values.version, "tableChecked": checked[-1] if checked else None,
        "autoSetup": bool(manifest.data.get("autoSetup", True)), "lastSync": manifest.data.get("lastSync"),
        "linkRoot": manifest.data.get("linkRoot") or tilde(values.link_root, values.home),
        "harnesses": harnesses,
        "newlyDetected": [h["id"] for h in harnesses if h["detected"] and not h["managed"] and not h["removed"]],
        "migrations": [{k: m.get(k) for k in ("id", "state", "askId", "path", "backup", "note")}
                       for m in manifest.data.get("migrations") or [] if isinstance(m, dict)],
        "errors": errors,
    }


def _smoke(ctx: Context, entry: Dict[str, Any], items: List[Item]) -> Dict[str, Any]:
    checks = []
    ph = placeholders(ctx.values, entry)
    for check in entry.get("smoke") or []:
        if "argv" in check:
            argv = _argv(check["argv"], ph)
            rc, out, err = ctx.runner.run(argv)
            ok = rc == 0 and (check.get("expect") is None or check["expect"] in out)
            checks.append({"check": " ".join(check["argv"][:3]), "ok": ok})
        else:
            ok = all(it.state in ("installed", "accepted", "none") for it in items if it.method in ("key", "cli"))
            checks.append({"check": "parse", "ok": ok})
    return {"ok": all(c["ok"] for c in checks), "checks": checks}


# --- accept and diff -----------------------------------------------------------------------

def _select(ctx: Context, hid: str, piece: Optional[str]) -> List[Item]:
    entry = ctx.by_id.get(hid)
    if entry is None:
        raise UsageError(f"no harness {hid!r} in the table")
    if piece is not None and piece not in PIECES + ("plugin",):
        raise UsageError(f"no piece {piece!r} (one of {', '.join(PIECES)})")
    out = []
    for item in ctx.items(entry):
        if item.method == "plugin" and item.piece != "plugin":
            continue
        if piece is None or _piece_matches(item, piece, entry):
            out.append(item)
    return out


def _moved_refusal(ctx: Context, item: Item) -> str:
    """Why Keep Mine can't keep an edit Hook's piece has moved away from."""
    was = ctx.tilde((ctx.manifest.targets.get(item.moved_from) or {}).get("path"))
    name = (ctx.by_id.get(item.harness) or {}).get("name", item.harness)
    return (f"{item.harness} {item.piece}: {name} reads {ctx.tilde(item.path)} now, not {was}, so an edit kept in "
            f"{was} would do nothing; use Hook's (relay integrations reinstall --force --harness {item.harness} "
            f"--piece {item.piece}) to move Hook's {item.piece} there, or take your edit out of {was}")


def _accept(ctx: Context, hid: str, piece: Optional[str], now: datetime) -> List[Dict[str, Any]]:
    items = [it for it in _select(ctx, hid, piece) if it.state in ("drifted", "foreign")]
    if not items:
        raise UsageError(f"{hid}{' ' + piece if piece else ''}: not edited, so there is nothing to keep")
    moved = [it for it in items if it.moved_item is not None]
    if moved:
        raise UsageError(_moved_refusal(ctx, moved[0]))
    done = []
    for item in items:
        here = item.disk if item.disk is not None else ABSENT
        if item.record is None:
            rec = {"kind": item.method, "piece": item.piece, "sha": None, "schema": ctx.values.schema,
                   "written": None, "path": str(item.path) if item.path else None, "foreign": True,
                   "format": item.fmt, "keypath": item.keypath, "created": False, "dirs": []}
            ctx.manifest.own(item.key, hid, rec)
            h = ctx.manifest.harnesses.setdefault(hid, {"pieces": {}, "plugin": None, "since": _iso(now)})
            if item.piece == "plugin":
                h["plugin"] = item.key
            else:
                h.setdefault("pieces", {})[item.piece] = {"alt": item.alt_index, "method": item.method,
                                                          "target": item.key}
        rec = ctx.manifest.targets[item.key]
        rec["accepted"] = here
        rec["want"] = item.want
        done.append({"harness": hid, "piece": item.piece, "target": _target_label(ctx, item), "state": "accepted"})
    return done


def _lines(text: str) -> List[str]:
    return text.splitlines(keepends=True) if text else []


def _udiff(old: str, new: str, label: str) -> str:
    lines = difflib.unified_diff(_lines(old), _lines(new), fromfile=f"{label} (yours)", tofile=f"{label} (Hook's)")
    out = []
    for line in lines:
        out.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    return "".join(out)


def _pretty(value: Any) -> str:
    return "" if value is _MISSING else json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def _diff(ctx: Context, item: Item) -> str:
    if item.moved_item is not None and item.state == "drifted" and item.moved_item.path is not None:
        # The edit is in the file Hook wrote before the `prefer` file filled up: compare that one.
        item = dataclasses.replace(item, path=item.moved_item.path, moved_item=None)
    label = _target_label(ctx, item)
    m = item.method
    if m == "block":
        text = _read_text(item.path) or ""
        got = ed.md_get_block(text, item.piece)
        return _udiff(got[0].replace("\r\n", "\n") if got else "", item.payload, label)
    if m == "key":
        current = ctx._key_value(item, _read_text(item.path))
        return _udiff(_pretty(current), _pretty(item.payload), label + " " + ".".join(item.keypath or []))
    if m == "file":
        try:
            current = item.path.read_bytes().decode("utf-8", "replace") if item.path.is_file() else ""
        except OSError:
            current = ""
        return _udiff(current, item.payload.decode("utf-8"), label)
    if m == "copy":
        mine = {} if not item.path.is_dir() else {rel: p for rel, p in _plain_files(item.path)}
        hook = {rel: p for rel, p in _plain_files(item.payload)}
        out = []
        for rel in sorted(set(mine) | set(hook)):
            a = mine[rel].read_bytes() if rel in mine else b""
            b = hook[rel].read_bytes() if rel in hook else b""
            if a != b:
                out.append(_udiff(a.decode("utf-8", "replace"), b.decode("utf-8", "replace"), f"{label}/{rel}"))
        return "".join(out)
    raise UsageError(f"{item.harness} {item.piece}: a {m} piece has no text to compare")


def _plain_files(root: Path) -> List[Tuple[str, Path]]:
    out = []
    for here, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in rb.SKIP_NAMES)
        for name in sorted(names):
            p = Path(here) / name
            if name in rb.SKIP_NAMES or p.is_symlink():
                continue
            out.append((p.relative_to(root).as_posix(), p))
    return out


# --- the command line ----------------------------------------------------------------------

class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:            # exit 1, not argparse's 2
        raise UsageError(message)


def _parser(out: Any = None) -> argparse.ArgumentParser:
    """The command line; --help goes to `out` (stdout when None)."""
    class Parser(_Parser):
        def _print_message(self, message: str, file: Any = None) -> None:
            if message:
                ((out or sys.stdout) if file in (None, sys.stdout) else file).write(message)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--link-root", type=Path, help=argparse.SUPPRESS)
    common.add_argument("--bundle", type=Path, help=argparse.SUPPRESS)
    common.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    p = Parser(prog="relay integrations", description="Install Hook into every agent harness on this Mac.")
    sub = p.add_subparsers(dest="cmd", parser_class=Parser)
    sub.required = True
    s = sub.add_parser("status", parents=[common], help="each harness and piece, and its state")
    s.add_argument("--harness")
    s.add_argument("--json", action="store_true")
    s.add_argument("--smoke", action="store_true")
    s = sub.add_parser("sync", parents=[common], help="install what's missing, update what's outdated")
    s.add_argument("--harness")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--json", action="store_true")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--include-new", action="store_true")
    g.add_argument("--include-removed", action="store_true",
                   help="also set up the agents you removed Hook from (a first install)")
    g.add_argument("--only-known", action="store_true")
    s.add_argument("--if-changed", action="store_true")
    s.add_argument("--no-asks", action="store_true")
    s = sub.add_parser("reinstall", parents=[common], help="rewrite everything Hook installs")
    s.add_argument("--harness")
    s.add_argument("--piece")
    s.add_argument("--force", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--json", action="store_true")
    for name, text in (("accept", "keep your edit of a piece (Keep Mine)"),
                       ("diff", "show your edit against Hook's text (Show Difference)")):
        s = sub.add_parser(name, parents=[common], help=text)
        s.add_argument("--harness", required=True)
        s.add_argument("--piece")
        s.add_argument("--json", action="store_true")
    s = sub.add_parser("remove", parents=[common], help="remove what Hook installed")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--harness")
    g.add_argument("--all", action="store_true")
    s.add_argument("--force", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("migrate", parents=[common], help="move Claude Code's old Hook setup (CLAUDE.md asks first)")
    s.add_argument("what", choices=["claude-md"])
    s.add_argument("--choose", help="Apply | Remove the whole section | Keep CLAUDE.md as is")
    s.add_argument("--again", action="store_true", help="propose again after Keep")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("set", parents=[common], help="a setting")
    s.add_argument("name", choices=["auto-setup"])
    s.add_argument("value", choices=["on", "off"])
    s.add_argument("--json", action="store_true")
    return p


def _human_status(st: Dict[str, Any], out) -> None:
    for h in st["harnesses"]:
        if not h["detected"] and not h["managed"]:
            continue
        why = "" if h["managed"] else " (removed by you)" if h.get("removed") else " (not set up)"
        print(f"{h['name']}: {h['state']}{why}", file=out)
        for p in h["pieces"]:
            where = p["target"] or ""
            if p["key"]:
                where += f" {p['key']}"
            note = f" ({p['note']})" if p["note"] else ""
            print(f"  {p['piece']:<12} {p['state']:<11} {where.strip()}{note}", file=out)
    more = [h for h in st["harnesses"] if not h["detected"] and not h["managed"]]
    if more:
        print(f"{len(more)} more supported: {', '.join(h['name'] for h in more)}", file=out)
    for e in st["errors"]:
        print(f"note: {e}", file=out)


def _human_report(report: Report, out) -> None:
    for e in report.errors:
        print(f"note: {e}", file=out)
    for r in report.results:
        if report.dry_run:
            print(f"would {VERBS.get(r['action'], r['action'])} {r['harness']} {r['piece']}: {r['target']}"
                  + (f" ({r['note']})" if r["note"] else ""), file=out)
            for line in r.get("diff") or []:
                print(f"  {line}", file=out)
        elif r["outcome"] not in ("shared", "released") or r["note"]:
            print(f"{r['harness']} {r['piece']}: {r['outcome']} {r['target']}"
                  + (f" ({r['note']})" if r["note"] else ""), file=out)


def _values(args, env: Mapping[str, str], manifest_for: Callable[[Path], Manifest]) -> Tuple[Values, Manifest]:
    home = Path(args.home) if args.home else Path(env.get("HOME") or os.path.expanduser("~"))
    pre = Values(home=home, link_root=home, bundle=home, plugins=home, version="", schema=0, env=env)
    manifest = manifest_for(_config_dir(pre) / MANIFEST)
    link_root = resolve_link_root(HERE, home, manifest, args.link_root)
    bundle = resolve_bundle(link_root, args.bundle)
    meta = _bundle_meta(bundle)
    values = Values(home=home, link_root=link_root, bundle=bundle,
                    plugins=home / ".local" / "share" / "hook" / "plugins",
                    version=meta["version"], schema=int(meta.get("schema", 1)), env=env)
    return values, manifest


def main(argv: Optional[List[str]] = None, *, env=None, runner=None, client_factory=None, now=None,
         out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    env = dict(os.environ if env is None else env)
    parser = _parser(out)
    try:
        args = parser.parse_args(argv)
    except UsageError as exc:
        err.write(parser.format_usage())
        print(f"relay integrations: {exc}", file=err)
        return 1
    except SystemExit as exc:                         # --help
        return 0 if not exc.code else 1
    when = now or datetime.now(timezone.utc)
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    try:
        values, _ = _values(args, env, lambda p: Manifest.load(p, move=False))
        table = load_table(values.bundle)
        run = runner or Runner(values.env, values.home)
        factory = client_factory if client_factory is not None else default_client_factory(values)
        if args.cmd == "status":
            manifest = Manifest.load(_config_dir(values) / MANIFEST, move=False)
            return _cmd_status(args, table, manifest, values, run, out)
        if args.cmd == "diff":
            manifest = Manifest.load(_config_dir(values) / MANIFEST, move=False)
            return _cmd_diff(args, table, manifest, values, run, out, err)
        if getattr(args, "dry_run", False):            # reads only: no lock, nothing moved
            manifest = Manifest.load(_config_dir(values) / MANIFEST, move=False)
            return _cmd_write(args, table, manifest, values, run, when, out, err, factory)
        with lock(values):
            manifest = Manifest.load(_config_dir(values) / MANIFEST, now=when)
            return _cmd_write(args, table, manifest, values, run, when, out, err, factory)
    except UsageError as exc:
        print(f"relay integrations: {exc}", file=err)
        return 1
    except (TableError, LockTimeout) as exc:
        print(f"relay integrations: {exc}", file=err)
        return 2


def _cmd_status(args, table, manifest, values, run, out) -> int:
    if args.harness and args.harness not in {e["id"] for e in table}:
        raise UsageError(f"no harness {args.harness!r} in the table")
    st = status(table, manifest, detect(table, values, run), values, run, smoke=args.smoke)
    if args.harness:
        st["harnesses"] = [h for h in st["harnesses"] if h["id"] == args.harness]
    if args.json:
        print(json.dumps(st, indent=2), file=out)
    else:
        _human_status(st, out)
    return 0


def _cmd_diff(args, table, manifest, values, run, out, err) -> int:
    ctx = Context(table, manifest, values, run)
    items = [it for it in _select(ctx, args.harness, args.piece) if it.state in ("drifted", "foreign")]
    if not items:
        raise UsageError(f"{args.harness}{' ' + args.piece if args.piece else ''}: not edited, so there is no difference")
    texts = [(it, _diff(ctx, it)) for it in items]
    if args.json:
        rows = [{"harness": it.harness, "piece": it.piece, "target": _target_label(ctx, it), "diff": d} for it, d in texts]
        print(json.dumps(rows[0] if len(rows) == 1 else rows, indent=2), file=out)
    else:
        out.write("".join(d for _, d in texts))
    return 0


def _cmd_migrate(args, table, manifest, values, run, when, out, client_factory) -> int:
    import relay_migrate_claude as mc
    import relay_owner_steps as ros
    if args.choose is not None and args.choose not in mc.CHOICES:
        raise UsageError(f"--choose one of: {', '.join(mc.CHOICES)}")
    ctx = Context(table, manifest, values, run)
    if MIGRATE_HID not in manifest.harnesses:
        raise UsageError("Claude Code isn't set up by Hook yet; run sync first")
    report = Report(dry_run=args.dry_run)
    poster = None if args.dry_run else ros.Poster(client_factory, no_asks=False)
    if not args.dry_run:
        ros.refresh(manifest, client_factory)
    _migrate(ctx, report, poster, when, dry_run=args.dry_run, again=args.again, choice=args.choose)
    if not args.dry_run:
        report.errors.extend(poster.errors)
        manifest.save()
    code = 4 if report.failed else 0
    if args.json:
        print(json.dumps({"dryRun": report.dry_run, "results": report.results, "errors": report.errors,
                          "exit": code}, indent=2), file=out)
    else:
        _human_report(report, out)
    return code


def _table_sha(values: Values) -> str:
    return _sha((values.bundle / "harnesses.json").read_bytes())


def _forget_removed(manifest: Manifest, values: Values, harness: Optional[str]) -> None:
    """After a remove, drop what is gone and keep what Hook left or failed to remove: their
    records (for status, a later remove, and drift), their harnesses and their asks. With no
    harness (remove --all), also the harnesses that own nothing now and the rendered plugin
    folders no record holds."""
    import relay_owner_steps as ros
    everything = harness is None
    kept = manifest.targets
    owners = {o for rec in kept.values() for o in rec.get("owners") or []}
    if everything:
        for hid in [h for h in manifest.harnesses if h not in owners]:
            del manifest.harnesses[hid]
        held = [Path(rec["path"]) for rec in kept.values() if rec.get("path")]
        if values.plugins.is_dir():
            for child in values.plugins.iterdir():
                if not any(p == child or child in p.parents for p in held):
                    _remove_path(child)
            _rmdirs([str(values.plugins)])
        for k in ("hookVersion", "tableSha", "linkRoot", "lastSync"):
            manifest.data.pop(k, None)
    asks = manifest.data.get("asks") or {}
    for sid, ask in list(asks.items()):
        if not isinstance(ask, dict):
            continue
        if sid == ros.DRIFT:
            if everything and not any(r.get("key") in kept for r in ask.get("items") or []):
                del asks[sid]
        elif (everything or ask.get("harness") == harness) and ask.get("harness") not in manifest.harnesses:
            del asks[sid]


def _cmd_write(args, table, manifest, values, run, when, out, err, client_factory=None) -> int:
    if args.cmd == "set":
        manifest.data["autoSetup"] = args.value == "on"
        manifest.save()
        if args.json:
            print(json.dumps({"autoSetup": manifest.data["autoSetup"]}, indent=2), file=out)
        else:
            print(f"auto-setup {args.value}", file=out)
        return 0
    if args.cmd == "migrate":
        return _cmd_migrate(args, table, manifest, values, run, when, out, client_factory)
    if args.cmd == "accept":
        ctx = Context(table, manifest, values, run)
        done = _accept(ctx, args.harness, args.piece, when)
        manifest.save()
        if args.json:
            print(json.dumps(done, indent=2), file=out)
        else:
            for d in done:
                print(f"{d['harness']} {d['piece']}: your edit is kept ({d['target']})", file=out)
        return 0
    if args.cmd == "sync" and args.if_changed:
        last = manifest.data.get("lastSync")
        fresh = False
        if isinstance(last, str):
            try:
                at = datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                fresh = when - at < IF_CHANGED_AGE
            except ValueError:
                fresh = False
        import relay_owner_steps as ros
        if fresh and not ros.waiting(manifest) and manifest.data.get("hookVersion") == values.version \
                and manifest.data.get("tableSha") == _table_sha(values) \
                and manifest.data.get("linkRoot") == tilde(values.link_root, values.home):
            return _cmd_status(argparse.Namespace(harness=args.harness, json=args.json, smoke=False),
                               table, manifest, values, run, out)
    detections = detect(table, values, run)
    mode = args.cmd
    piece = getattr(args, "piece", None)
    if piece is not None and not args.harness:
        raise UsageError("--piece needs --harness")
    if piece is not None and piece not in PIECES + ("plugin",):
        raise UsageError(f"no piece {piece!r} (one of {', '.join(PIECES)})")
    if args.harness and args.harness not in {e["id"] for e in table}:
        raise UsageError(f"no harness {args.harness!r} in the table")
    asks_on = mode in ("sync", "reinstall") and not args.dry_run
    no_asks = bool(getattr(args, "no_asks", False))
    ctx = Context(table, manifest, values, run)
    report = Report(dry_run=args.dry_run)
    if asks_on:
        import relay_owner_steps as ros
        if not no_asks:
            ros.refresh(manifest, client_factory)
        if mode == "sync":
            _drift_answers(ctx, report, detections, when)
    include_removed = bool(getattr(args, "include_removed", False))
    if args.cmd == "remove":
        actions = plan(table, manifest, detections, values, run, mode="remove", harness=args.harness,
                       force=args.force, include_new=False)
        # What the owner removed stays removed: the ids set up now, or found, for --all.
        gone = [args.harness] if args.harness else [
            e["id"] for e in table
            if e["id"] in manifest.harnesses or getattr(detections.get(e["id"]), "found", False)]
    else:
        actions = plan(table, manifest, detections, values, run, mode=mode, harness=args.harness,
                       force=getattr(args, "force", False),
                       include_new=getattr(args, "include_new", False) or include_removed,
                       piece=piece, only_known=getattr(args, "only_known", False), include_removed=include_removed)
    Applier(ctx, report, when).run(actions)
    if not args.dry_run:
        if args.cmd == "remove":
            manifest.mark_removed(gone)
        elif include_removed:
            manifest.clear_removed()
        elif args.harness:
            manifest.clear_removed(args.harness)
    poster = None
    if asks_on:
        import relay_owner_steps as ros
        poster = ros.Poster(client_factory, no_asks=no_asks)
    if mode in ("sync", "reinstall") and args.harness in (None, MIGRATE_HID) \
            and MIGRATE_HID not in manifest.removed:
        _migrate(ctx, report, poster, when, dry_run=args.dry_run)
    if not args.dry_run:
        if args.cmd == "remove":
            manifest.data["dirs"] = _rmdirs(manifest.data.get("dirs") or [])
            if args.all or args.harness == MIGRATE_HID:
                _migration_backups(manifest, report, values)
            if args.harness or args.all:
                _forget_removed(manifest, values, None if args.all else args.harness)
        else:
            _owner_phase(ctx, report, poster, when, harness=args.harness, drift=mode == "sync")
            manifest.data.update({"hookVersion": values.version, "tableSha": _table_sha(values),
                                  "linkRoot": tilde(values.link_root, values.home), "lastSync": _iso(when)})
        manifest.save()
    code = 4 if report.failed else 0
    if args.json:
        print(json.dumps({"dryRun": report.dry_run, "results": report.results, "errors": report.errors,
                          "exit": code}, indent=2), file=out)
    else:
        _human_report(report, out)
    return code


if __name__ == "__main__":
    sys.exit(main())
