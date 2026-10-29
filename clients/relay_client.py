"""Shared Hook client for the `relay` CLI and the MCP server.

Reads ~/.config/relay/config.json (or $RELAY_CONFIG) and talks to either source:
- local: Hook.app on 127.0.0.1:<port>. Every token-bearing call first checks the
  server proof on GET /health, so the token only ever goes to Hook itself.
- mailbox: the Pond (the server formerly called the mailbox) at mailboxURL.
Tokens are read from disk on every call and never printed or logged.
Standard library only; runs on Python 3.9+.
"""
from __future__ import annotations

import datetime
import hashlib
import hmac
import http.client
import json
import os
import pathlib
import re
import secrets
import socket
import stat
import subprocess
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple

import relay_semver

VERSION = "0.9.3"
DEFAULT_CONFIG = "~/.config/relay/config.json"
DEFAULT_PORT = 47823
DEFAULT_CONTEXT = "personal"
NO_CONFIG = "No Hook config; run scripts/install.sh"
MAILBOX_PROBLEM = 'the Pond (source "mailbox") needs an http(s) mailboxURL and a tokenFile'
NOT_THIS_MAC = "Hook is running but not in This Mac mode."
NOT_RUNNING = "Hook isn't running"
NO_APP = "Hook.app not found; run scripts/install.sh"
# The app by its bundle id: the same before and after the rename to Hook, and never
# another app that happens to be called Hook.
BUNDLE_ID = "io.github.xooxoxxo.relay"
LAUNCH_COMMANDS = (["open", "-g", "-b", BUNDLE_ID],)
LAUNCH_WAIT_S = 5.0
LAUNCH_POLL_S = 0.25
PROOF_PREFIX = "relay-proof-v1\n"   # message: PROOF_PREFIX + str(port) + "\n" + nonce
# The first Pond version (semver) that takes each instructable key, as docs/mailbox-protocol.md
# lists them. A gated key is checked before it is posted; a minor or patch Pond bump never
# blocks a key it already took. 1.0.0 is what was protocol level 4.
KEY_MIN_POND = (("id", "1.1.0"), ("optional", "1.0.0"), ("file", "1.0.0"), ("blocking", "1.0.0"),
                ("warning", "1.0.0"), ("question", "1.0.0"))
LINK_PATH_KEY, LINK_PATH_POND = "links[].path", "1.0.0"   # a link's `path` (a local file)
AMEND_POND = "1.1.0"            # amend, edit keys, accept and problems
PROTOCOL_CACHE_S = 300.0
# Per process: source -> (when checked, (effective version, legacy protocol or None) or None).
_ponds: Dict[str, Tuple[float, Optional[Tuple[relay_semver.Version, Optional[int]]]]] = {}
# Sent on every request: this client reads revision histories (it is not the Pond version it needs).
PROTOCOL_HEADER, CLIENT_PROTOCOL = "X-Hook-Protocol", "5"
EDIT_KEY_DIR = "~/.local/state/relay/edit-keys"
PENDING_MAX_AGE_S = 24 * 3600   # a retry within this reuses the pending edit key
_ASK_ID = re.compile(r"[0-9A-Za-z][0-9A-Za-z-]{0,63}")

# Owner event kinds as the CLI and the hook print them.
OWNER_LABELS = {"resolved": "done", "declined": "skipped", "reply": "reply", "reopened": "reopened",
                "problem": "problem", "accepted": "accepted"}


class RelayError(Exception):
    """A failure reported on stderr; exit_code is the process exit status."""
    exit_code = 1


class ConfigMissing(RelayError):
    exit_code = 2


class Unreachable(RelayError):
    exit_code = 2


class Refused(RelayError):
    """The source answered with an error: .status (HTTP), .error (spec string), .details (field paths)."""
    exit_code = 1

    def __init__(self, status: int, error: str, details: Optional[List[str]] = None) -> None:
        super().__init__(error)
        self.status = status
        self.error = error
        self.details = list(details or [])


class NotFound(RelayError):
    exit_code = 1


class PondTooOld(Refused):
    """The Pond (or, in This Mac mode, Hook's own queue) is older than a key or a call needs.
    .version is the Pond as shown ("1.0.0", or "protocol 4" for an old dated Pond)."""

    def __init__(self, version: str, key: str, needs: str, local: bool = False) -> None:
        if local:
            message = f"Hook's This Mac queue (Pond {version}) can't take `{key}` yet."
        else:
            tail = ("close this ask and post a new one." if key == "amend" else "leave the key out.")
            message = (f"Your Pond ({version}) is older than `{key}` needs (Pond {needs} or newer). "
                       f"Update the Pond, or {tail}")
        super().__init__(0, message)
        self.version, self.key, self.needs, self.local = version, key, needs, local


ProtocolTooOld = PondTooOld   # the name before Pond semver; kept for one release


class LocalCantAmend(RelayError):
    def __init__(self, ask_id: str) -> None:
        super().__init__(f"This Mac mode can't correct asks yet: close this one (relay done {ask_id}) "
                         "and post a new one.")


class NoEditKey(RelayError):
    def __init__(self, ask_id: str) -> None:
        super().__init__(f"No edit key for ask {ask_id} on this Mac: only the process that posted it can "
                         f"correct it. Close it (relay done {ask_id}) and post a new one.")


class ChangedUnderneath(RelayError):
    def __init__(self, ask_id: str, rev: int) -> None:
        super().__init__(f"Ask {ask_id} changed since you last wrote it (version {rev}). "
                         f"Run `relay status {ask_id} --json` and correct from that.")
        self.rev = rev


class CorrectionsOff(RelayError):
    def __init__(self, ask_id: str) -> None:
        super().__init__(f"The Pond doesn't take corrections yet. Close this ask (relay done {ask_id}) "
                         "and post a new one.")


def _version_key(minimum: str) -> relay_semver.Version:
    v = relay_semver.parse_version(minimum)
    assert v is not None, minimum
    return v


def keys_needing_pond(instructable: Any) -> Dict[str, str]:
    """{key: first Pond version} for the gated keys of steps and sub-steps (not verify),
    plus LINK_PATH_KEY when a link carries `path`."""
    found: Dict[str, str] = {}
    links = instructable.get("links") if isinstance(instructable, dict) else None
    if isinstance(links, list) and any(isinstance(link, dict) and "path" in link for link in links):
        found[LINK_PATH_KEY] = LINK_PATH_POND
    steps = instructable.get("steps") if isinstance(instructable, dict) else None
    stack = [s for s in steps if isinstance(s, dict)] if isinstance(steps, list) else []
    while stack:
        step = stack.pop()
        for key, needs in KEY_MIN_POND:
            if key in step:
                found[key] = needs
        subs = step.get("substeps")
        if isinstance(subs, list):
            stack.extend(s for s in subs if isinstance(s, dict))
    return found


def pond_display(pond: Tuple[relay_semver.Version, Optional[int]]) -> str:
    """"1.1.0", or "protocol 4" for an old dated Pond."""
    version, legacy = pond
    return f"protocol {legacy}" if legacy is not None else str(version)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: the bearer token must only reach the configured server."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class _Refused(Exception):
    """Connection refused in local mode; triggers the auto-launch."""


# --- config ---

def _env(env: Optional[Mapping[str, str]]) -> Mapping[str, str]:
    return os.environ if env is None else env


def config_path(env: Optional[Mapping[str, str]] = None) -> pathlib.Path:
    custom = _env(env).get("RELAY_CONFIG")
    return pathlib.Path(custom or DEFAULT_CONFIG).expanduser()


def config_dir(env: Optional[Mapping[str, str]] = None) -> pathlib.Path:
    return config_path(env).parent


def check_trusted_dir(path: Any) -> None:
    """Refuses a folder another user owns or can write to."""
    path = pathlib.Path(path)
    info = os.stat(str(path))
    if info.st_uid != os.getuid():
        raise ConfigMissing(f"{path} belongs to another user; refusing to use it")
    if info.st_mode & 0o022:
        raise ConfigMissing(f"{path} is writable by other users; refusing to use it")


def check_trusted_file(path: Any) -> None:
    """A missing file is fine; otherwise it must be a regular file owned by the current user
    (stat follows symlinks, so a symlink to your own file is accepted)."""
    path = pathlib.Path(path)
    try:
        info = os.stat(str(path))
    except FileNotFoundError:
        return
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ConfigMissing(f"{path} is not a regular file owned by you; refusing to use it")


def _check_trusted(directory: pathlib.Path, file: pathlib.Path) -> None:
    try:
        check_trusted_dir(directory)
    except FileNotFoundError:
        return
    check_trusted_file(file)


def load_config(env: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    path = config_path(env)
    _check_trusted(path.parent, path)
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        raise ConfigMissing(f"No Hook config at {path}; run scripts/install.sh") from None
    except OSError:
        raise ConfigMissing(f"Hook config at {path} can't be read") from None
    try:
        cfg = json.loads(raw.decode("utf-8-sig"))
    except ValueError:
        raise ConfigMissing(f"Hook config at {path} is not valid JSON") from None
    if not isinstance(cfg, dict):
        raise ConfigMissing(f"Hook config at {path} is not a JSON object")
    return cfg


def _valid_http_url(url: str) -> bool:
    try:
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname
    except ValueError:
        return False
    return parts.scheme.lower() in ("http", "https") and bool(host)


def resolve_source(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """The same rule as RelayConfig.resolvedSource() in the app."""
    port = cfg.get("port")
    if port is None:
        port = DEFAULT_PORT
    elif isinstance(port, float) and port.is_integer():
        port = int(port)
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise ConfigMissing("config.json: port must be a whole number from 1 to 65535")
    source = cfg.get("source")
    if source not in ("local", "mailbox"):
        source = None
    url = cfg.get("mailboxURL")
    if not isinstance(url, str):
        url = None
    kind = source or ("mailbox" if url is not None else None)
    if kind is None:
        raise ConfigMissing(NO_CONFIG)
    if kind == "local":
        return {"kind": "local", "port": port}
    token_file = cfg.get("tokenFile")
    if url is None or not _valid_http_url(url) or not isinstance(token_file, str) or not token_file.strip():
        raise ConfigMissing(MAILBOX_PROBLEM)
    context = cfg.get("context")
    if not isinstance(context, str):
        context = DEFAULT_CONTEXT
    return {"kind": "mailbox", "url": url, "token_file": token_file, "context": context}


# --- small helpers ---

def fill_from(instructable: Dict[str, Any], env: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    """A copy with `from` filled (host, cwd, session) when the caller left it out.

    session: $CLAUDE_CODE_SESSION_ID, else $CLAUDE_SESSION_ID. cwd: $CLAUDE_PROJECT_DIR
    when it is set and absolute, else the current directory.
    """
    env = _env(env)
    out = dict(instructable)
    if "from" not in out:
        project_dir = env.get("CLAUDE_PROJECT_DIR") or ""
        cwd = project_dir if os.path.isabs(project_dir) else os.getcwd()
        origin = {"host": socket.gethostname(), "cwd": cwd}
        session = env.get("CLAUDE_CODE_SESSION_ID") or env.get("CLAUDE_SESSION_ID")
        if session:
            origin["session"] = session
        out["from"] = origin
    return out


def one_line(text: str) -> str:
    """Owner text on one terminal line: newlines become ' ⏎ '."""
    return text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", " ⏎ ")


# The Pond's hidden-character policy (mailbox instructable.py, and Hook's Swift validator),
# with no exceptions: in a line a session reads, even TAB and the emoji joiners are shown.
_HIDDEN_CATEGORIES = frozenset(("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp"))
_HIDDEN_RANGES = (
    (0x034F, 0x034F), (0x115F, 0x1160), (0x17B4, 0x17B5), (0x180B, 0x180F),
    (0x3164, 0x3164), (0xFE00, 0xFE0F), (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8),
    (0xD800, 0xDFFF), (0xE0000, 0xE0FFF),
)


def _is_hidden(ch: str) -> bool:
    cp = ord(ch)
    return unicodedata.category(ch) in _HIDDEN_CATEGORIES or any(lo <= cp <= hi for lo, hi in _HIDDEN_RANGES)


def _revealed(value: Any) -> List[str]:
    """one_line, then every hidden or control scalar as ⟨U+XXXX⟩: one token per scalar."""
    text = one_line(value if isinstance(value, str) else ("" if value is None else str(value)))
    return [f"⟨U+{ord(ch):04X}⟩" if _is_hidden(ch) else ch for ch in text]


def _cut(tokens: List[str], cap: int) -> str:
    """At most `cap` characters, the … included; a revealed scalar is never split."""
    if sum(len(t) for t in tokens) <= cap:
        return "".join(tokens)
    out, used = [], 0
    for token in tokens:
        if used + len(token) > cap - 1:
            break
        out.append(token)
        used += len(token)
    return "".join(out) + "…"


def session_text(value: Any, cap: int) -> str:
    """Text from the owner or an ask, as a session reads it: one line, hidden characters shown,
    cut to `cap` characters, always double-quoted with " and \\ escaped, so it can't pass for
    a line of its own."""
    return json.dumps(_cut(_revealed(value), cap), ensure_ascii=False)


# What a bare label can't contain, as it would read in a session line: brackets frame the ask
# id, " opens quoted text, and — · ↳ separate the parts of a line.
_LABEL_MARKS = {"[": "(", "]": ")", '"': "'", "\u2014": "-", "\u00b7": ".", "\u21b3": ">"}


def session_label(value: Any, cap: int) -> str:
    """A short label (a project name, a step, a time) in a session line: one line, hidden
    characters shown, [ ] " — · ↳ as ( ) ' - . >, cut to `cap` characters. Not quoted, so it
    can't open a quote, frame an ask id or start a second part of the line."""
    tokens = [_LABEL_MARKS.get(t, t) for t in _revealed(value)]
    return _cut(tokens, cap)


def session_id(env: Optional[Mapping[str, str]] = None) -> str:
    """This process's Claude Code session: $CLAUDE_CODE_SESSION_ID, else $CLAUDE_SESSION_ID, else ""."""
    env = _env(env)
    return env.get("CLAUDE_CODE_SESSION_ID") or env.get("CLAUDE_SESSION_ID") or ""


def revision_of(detail: Any) -> Optional[Dict[str, Any]]:
    """The served current revision ({rev, hash, …, acceptedRev}) of an ask detail, or None
    (an old Pond, or This Mac mode)."""
    if not isinstance(detail, dict):
        return None
    item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
    for value in (item.get("revision"), detail.get("revision")):
        if isinstance(value, dict) and isinstance(value.get("rev"), int) and isinstance(value.get("hash"), str):
            return value
    return None


def revision_hash_of(detail: Any, rev: int) -> Optional[str]:
    """The hash of revision `rev` from the detail's history or its current revision, or None."""
    history = detail.get("revisions") if isinstance(detail, dict) else None
    for entry in history if isinstance(history, list) else []:
        if isinstance(entry, dict) and entry.get("rev") == rev and isinstance(entry.get("hash"), str):
            return entry["hash"]
    current = revision_of(detail)
    return current["hash"] if current is not None and current["rev"] == rev else None


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


class EditKeys:
    """The edit keys of the asks this Mac posted, one 0600 file per ask in a 0700 folder
    (~/.local/state/relay/edit-keys, or $RELAY_EDIT_KEY_DIR). The Pond stores only a key's
    SHA-256; whoever holds the file can correct that ask. A key is made before the POST, as
    pending-<sha1(project + "\n" + title)[:16]>.json, so a retry after a timeout reuses it."""

    def __init__(self, env: Optional[Mapping[str, str]] = None) -> None:
        self.env = _env(env)
        custom = self.env.get("RELAY_EDIT_KEY_DIR")
        self.dir = pathlib.Path(custom or EDIT_KEY_DIR).expanduser()

    @staticmethod
    def key_hash(key: str) -> str:
        return hashlib.sha256(key.encode("utf-8")).hexdigest()

    def _pending_path(self, project: str, title: str) -> pathlib.Path:
        digest = hashlib.sha1((project + "\n" + title).encode("utf-8")).hexdigest()[:16]
        return self.dir / f"pending-{digest}.json"

    def _path(self, ask_id: str) -> Optional[pathlib.Path]:
        return self.dir / f"{ask_id}.json" if isinstance(ask_id, str) and _ASK_ID.fullmatch(ask_id) else None

    def _read(self, path: pathlib.Path) -> Optional[Dict[str, Any]]:
        try:
            check_trusted_dir(self.dir)
        except FileNotFoundError:
            return None
        check_trusted_file(path)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def _write(self, path: pathlib.Path, data: Dict[str, Any]) -> None:
        private_write(path, (json.dumps(data, indent=1, sort_keys=True) + "\n").encode("utf-8"))

    def pending(self, project: str, title: str) -> Tuple[str, str]:
        """(key, key hash) for a post: the pending key of this project and title when it is
        younger than 24 h, else a new one."""
        path = self._pending_path(project, title)
        data = self._read(path)
        key = data.get("key") if data else None
        try:
            fresh = time.time() - os.stat(str(path)).st_mtime < PENDING_MAX_AGE_S
        except OSError:
            fresh = False
        if not isinstance(key, str) or len(key) != 43 or not fresh:
            key = secrets.token_urlsafe(32)
            self._write(path, {"key": key, "created": _now_iso()})
        return key, self.key_hash(key)

    def commit(self, project: str, title: str, ask_id: str, rev: int, hash_: str, session: str,
               source: str) -> None:
        """The pending key becomes <ask_id>.json. A file already there for the same key is kept."""
        pending = self._pending_path(project, title)
        data = self._read(pending)
        key = data.get("key") if data else None
        path = self._path(ask_id)
        if not isinstance(key, str) or path is None:
            return
        existing = self._read(path)
        if not (existing and existing.get("key") == key):
            self._write(path, {"key": key, "session": session, "source": source, "lastRev": rev,
                               "lastHash": hash_, "hashes": [hash_] if hash_ else [], "created": _now_iso()})
        self.drop_pending(project, title)

    def drop_pending(self, project: str, title: str) -> None:
        try:
            os.unlink(str(self._pending_path(project, title)))
        except OSError:
            pass

    def load(self, ask_id: str) -> Optional[Dict[str, Any]]:
        path = self._path(ask_id)
        return self._read(path) if path is not None else None

    def record_write(self, ask_id: str, rev: int, hash_: str) -> None:
        """After a correction: the newest revision this Mac wrote, and its hash among `hashes`."""
        path = self._path(ask_id)
        data = self._read(path) if path is not None else None
        if path is None or data is None:
            return
        hashes = [h for h in data.get("hashes") or [] if isinstance(h, str)]
        if hash_ not in hashes:
            hashes.append(hash_)
        data.update(lastRev=rev, lastHash=hash_, hashes=hashes)
        self._write(path, data)

    def prune(self, max_age_days: int = 30) -> None:
        """Drops key files (and pending ones) untouched for max_age_days."""
        try:
            entries = list(self.dir.iterdir())
        except OSError:
            return
        cutoff = time.time() - max_age_days * 86400
        for entry in entries:
            if entry.suffix != ".json":
                continue
            try:
                if entry.stat().st_mtime < cutoff:
                    entry.unlink()
            except OSError:
                pass

    def owners(self) -> Dict[str, str]:
        """{ask id: posting session} for every key file ("" when the session was unknown)."""
        found: Dict[str, str] = {}
        try:
            entries = sorted(self.dir.iterdir())
        except OSError:
            return found
        for entry in entries:
            if entry.suffix != ".json" or entry.name.startswith("pending-"):
                continue
            data = self.load(entry.stem)
            if data is not None and isinstance(data.get("key"), str):
                session = data.get("session")
                found[entry.stem] = session if isinstance(session, str) else ""
        return found


def instructable_of(detail: Any) -> Dict[str, Any]:
    """The instructable of an ask detail: payload.instructable, as a dict ({} when absent).
    A JSON string (a local item may carry it encoded) is decoded."""
    item = detail.get("item") if isinstance(detail, dict) and isinstance(detail.get("item"), dict) else {}
    payload = item.get("payload") if isinstance(item.get("payload"), dict) else {}
    value = payload.get("instructable")
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}


def questions(instructable: Any) -> Dict[str, Dict[str, Any]]:
    """Every question of an instructable by step path ("3", "3.2"), in document order:
    a step's own question comes before those of its sub-steps."""
    found: Dict[str, Dict[str, Any]] = {}
    steps = instructable.get("steps") if isinstance(instructable, dict) else None
    if not isinstance(steps, list):
        return found
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        if isinstance(step.get("question"), dict):
            found[f"{i + 1}"] = step["question"]
        subs = step.get("substeps")
        for j, sub in enumerate(subs if isinstance(subs, list) else []):
            if isinstance(sub, dict) and isinstance(sub.get("question"), dict):
                found[f"{i + 1}.{j + 1}"] = sub["question"]
    return found


def parse_answer(event: Any) -> Optional[Dict[str, Any]]:
    """The body of an owner `answer` event ({"step", "picked"|"text"}), or None."""
    if not isinstance(event, dict) or event.get("kind") != "answer" or event.get("actor") != "owner":
        return None
    try:
        body = json.loads(event.get("text") or "")
    except (TypeError, ValueError):
        return None
    return body if isinstance(body, dict) and isinstance(body.get("step"), str) else None


def _seq_of(event: Dict[str, Any]) -> int:
    try:
        return int(event.get("seq") or 0)
    except (TypeError, ValueError):
        return 0


def latest_answers(events: Any) -> Dict[str, Dict[str, Any]]:
    """The owner's current answer per step path: the latest `answer` event wins.
    Each value holds `picked` or `text`, plus `at` and `seq`. Unreadable events are skipped."""
    current: Dict[str, Dict[str, Any]] = {}
    ordered = sorted((e for e in events or [] if isinstance(e, dict)), key=_seq_of)
    for event in ordered:
        body = parse_answer(event)
        if body is None:
            continue
        value: Dict[str, Any] = {}
        if isinstance(body.get("picked"), list):
            value["picked"] = [str(p) for p in body["picked"]]
        elif isinstance(body.get("text"), str):
            value["text"] = body["text"]
        else:
            continue
        value.update(at=event.get("at"), seq=event.get("seq"))
        current[body["step"]] = value
    return current


def event_rev(event: Any) -> int:
    """The version an event belongs to: its `rev`, else 1 (an old Pond, or an event before revisions)."""
    rev = event.get("rev") if isinstance(event, dict) else None
    return rev if isinstance(rev, int) and not isinstance(rev, bool) and rev >= 1 else 1


def _steps_by_id(instructable: Any) -> Dict[str, Tuple[str, Dict[str, Any]]]:
    """{step id: (display path, step)} for the steps and sub-steps that carry an id."""
    found: Dict[str, Tuple[str, Dict[str, Any]]] = {}
    steps = instructable.get("steps") if isinstance(instructable, dict) else None
    for i, step in enumerate(steps if isinstance(steps, list) else []):
        if not isinstance(step, dict):
            continue
        if isinstance(step.get("id"), str):
            found[step["id"]] = (f"{i + 1}", step)
        subs = step.get("substeps")
        for j, sub in enumerate(subs if isinstance(subs, list) else []):
            if isinstance(sub, dict) and isinstance(sub.get("id"), str):
                found[sub["id"]] = (f"{i + 1}.{j + 1}", sub)
    return found


def _step_at(instructable: Any, path: str) -> Optional[Dict[str, Any]]:
    steps = instructable.get("steps") if isinstance(instructable, dict) else None
    try:
        parts = [int(p) - 1 for p in path.split(".")]
        step = steps[parts[0]]
        if len(parts) == 2:
            step = step["substeps"][parts[1]]
    except (AttributeError, IndexError, KeyError, TypeError, ValueError):
        return None
    return step if isinstance(step, dict) and len(parts) <= 2 and min(parts) >= 0 else None


def revision_bodies(detail: Any) -> Dict[int, Dict[str, Any]]:
    """{rev: decoded body} for every revision the detail carries (its history and its current
    revision). The served payload stands in for the current revision when its body is missing."""
    bodies: Dict[int, Dict[str, Any]] = {}
    history = detail.get("revisions") if isinstance(detail, dict) else None
    current = revision_of(detail)
    for entry in (history if isinstance(history, list) else []) + ([current] if current else []):
        if not isinstance(entry, dict) or not isinstance(entry.get("rev"), int):
            continue
        try:
            body = json.loads(entry.get("body")) if isinstance(entry.get("body"), str) else None
        except ValueError:
            body = None
        if isinstance(body, dict):
            bodies[entry["rev"]] = body
    if current is not None and current["rev"] not in bodies and instructable_of(detail):
        bodies[current["rev"]] = instructable_of(detail)
    return bodies


def accepted_rev(detail: Any) -> int:
    current = revision_of(detail)
    value = current.get("acceptedRev") if current is not None else None
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 1 else 1


def _question_of(instructable: Any, step_id: str) -> Optional[Dict[str, Any]]:
    entry = _steps_by_id(instructable).get(step_id)
    question = entry[1].get("question") if entry is not None else None
    return question if isinstance(question, dict) else None


def answer_state(detail: Any) -> Tuple[Dict[str, Dict[str, Any]], List[Dict[str, Any]]]:
    """The owner's latest answer per step, as the Pond counts it: (current, earlier).

    Answers are grouped by step id: an event's `id`, else its path mapped to an id through
    the revision at the event's rev (an old Pond, or no revisions: the current instructable).
    The latest answer per id wins. `current` keys it by that id's path in the current
    instructable, so an answer follows its step when the step moves, and a path that another
    step takes over never shows an answer given to the step that was there. `earlier` lists
    the answers to steps the current instructable no longer has, in log order; they never
    count. An answer with no id at all (an ask from before step ids) keeps its path.

    Each value is latest_answers' value plus `rev` (the version answered), `id`, `step` (the
    path the owner answered), `auth`, and `stale`: the question at that id in the version in
    force (the accepted one) isn't the one the owner answered."""
    events = detail.get("events") if isinstance(detail, dict) and isinstance(detail.get("events"), list) else []
    current_body = instructable_of(detail)
    bodies = revision_bodies(detail)
    in_force = bodies.get(accepted_rev(detail)) or current_body
    latest: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for event in sorted((e for e in events if isinstance(e, dict)), key=_seq_of):
        body = parse_answer(event)
        value = latest_answers([event]).get(body["step"]) if body is not None else None
        if value is None:
            continue
        rev = event_rev(event)
        answered = bodies.get(rev) or in_force
        step_id = body.get("id") if isinstance(body.get("id"), str) else None
        if step_id is None:
            step = _step_at(answered, body["step"])
            step_id = step.get("id") if step is not None and isinstance(step.get("id"), str) else None
        if step_id is None:
            latest[("path", body["step"])] = dict(value, rev=rev, id=None, step=body["step"],
                                                  auth=event.get("auth"), stale=False)
            continue
        asked = _question_of(answered, step_id)
        stale = asked is None or asked != _question_of(in_force, step_id)
        latest[("id", step_id)] = dict(value, rev=rev, id=step_id, step=body["step"],
                                       auth=event.get("auth"), stale=stale)
    current_ids = _steps_by_id(current_body)
    found: Dict[str, Dict[str, Any]] = {}
    earlier: List[Dict[str, Any]] = []
    for (kind, key), value in sorted(latest.items(), key=lambda kv: _seq_of(kv[1])):
        if kind == "path":
            found[key] = value
        elif key in current_ids:
            found[current_ids[key][0]] = value
        else:
            earlier.append(value)
    return found, earlier


def answers_with_state(detail: Any) -> Dict[str, Dict[str, Any]]:
    """The current half of answer_state: the owner's latest answer per step, keyed by the
    step's path in the current instructable."""
    return answer_state(detail)[0]


def open_questions(detail: Any, given: Optional[Dict[str, Dict[str, Any]]] = None) -> List[str]:
    """Paths of the current questions without a counted answer, in document order: an answer
    to an earlier question (stale) or to a step that is gone doesn't count."""
    given = answers_with_state(detail) if given is None else given
    return [path for path in questions(instructable_of(detail)) if path not in given or given[path]["stale"]]


def answer_value(answer: Dict[str, Any]) -> str:
    """An answer as one terminal line: picks joined with ', ', or the text."""
    if isinstance(answer.get("picked"), list):
        return one_line(", ".join(str(p) for p in answer["picked"]))
    return one_line(str(answer.get("text") or ""))


def unanswered(instructable: Any, events: Any) -> List[str]:
    """Paths of the questions with no answer yet, in document order."""
    answered = latest_answers(events)
    return [path for path in questions(instructable) if path not in answered]


def ensure_private_dir(path: pathlib.Path) -> None:
    """Creates a missing directory 0700. An existing one is left as it is, so a custom
    $RELAY_CONFIG in a shared folder never tightens that folder (only Relay and
    install.sh tighten their own directories)."""
    try:
        path.mkdir(mode=0o700, parents=True)
    except FileExistsError:
        return
    os.chmod(path, 0o700)   # mkdir's mode is masked by the umask


def private_write(path: pathlib.Path, data: bytes) -> None:
    """0700 parent, then an O_EXCL 0600 temp file in the same directory: write, fsync, rename."""
    path = pathlib.Path(path)
    ensure_private_dir(path.parent)
    check_trusted_dir(path.parent)
    check_trusted_file(path)
    tmp = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(str(tmp), str(path))
    except BaseException:
        try:
            os.unlink(str(tmp))
        except OSError:
            pass
        raise


def _launch(argv: List[str]) -> bool:
    try:
        done = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0


# --- client ---

class Client:
    """One configured source. Methods return the decoded JSON bodies of the API responses."""

    def __init__(self, cfg: Optional[Dict[str, Any]] = None, *, kind: str = "cli", autolaunch: bool = True,
                 timeout: float = 10.0, env: Optional[Mapping[str, str]] = None,
                 urlopen: Optional[Callable[..., Any]] = None,
                 launcher: Optional[Callable[[List[str]], bool]] = None,
                 sleep: Optional[Callable[[float], None]] = None,
                 monotonic: Optional[Callable[[], float]] = None) -> None:
        self.env = _env(env)
        self.source = resolve_source(load_config(self.env) if cfg is None else cfg)
        self.kind = kind
        self.autolaunch = autolaunch
        self.timeout = float(timeout)
        if urlopen is not None:
            self._urlopen = urlopen
        elif self.local:
            # Never through an HTTP proxy: a proxy from the environment or System Settings
            # would see 127.0.0.1 traffic, and the proof would fail on every call.
            self._urlopen = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect).open
        else:
            # The system proxy settings still apply to the mailbox.
            self._urlopen = urllib.request.build_opener(_NoRedirect).open
        self._launcher = launcher or _launch
        self._sleep = sleep or time.sleep
        self._monotonic = monotonic or time.monotonic
        self._launched = False
        # An absolute time on `monotonic` after which no exchange starts, and each one's
        # timeout is capped at what is left (the hook's total budget).
        self.deadline: Optional[float] = None
        if self.local:
            self.base = f"http://127.0.0.1:{self.source['port']}"
        else:
            self.base = self.source["url"].rstrip("/")

    @property
    def local(self) -> bool:
        return self.source["kind"] == "local"

    def source_key(self) -> str:
        if self.local:
            return "local"
        return "mailbox:" + hashlib.sha1(self.source["url"].encode("utf-8")).hexdigest()[:12]

    # public calls

    def health(self) -> Dict[str, Any]:
        if self.local:
            return self._with_launch(self._verify_server)[1]
        status, obj = self._transport("GET", "/health")
        if not isinstance(obj, dict):
            raise Unreachable(f"Pond at {self.base} answered HTTP {status} with a non-JSON body")
        return obj

    def pond_info(self) -> Optional[Tuple[relay_semver.Version, Optional[int]]]:
        """(effective Pond version, legacy protocol or None) from GET /version, through
        relay_semver.pond_version: an old dated Pond counts by its `protocol` (4 is 1.0.0),
        and no such route (404) is protocol 1, 0.1.0. None when the reply can't be read
        (a 200 with neither a semver `version` nor an integer `protocol`).
        In This Mac mode a 0.9.x Hook answers its own app version: its `protocol` counts too.
        Cached for PROTOCOL_CACHE_S per source, per process (an unreadable reply too)."""
        key = self.source_key() + "|" + self.base
        now = self._monotonic()
        hit = _ponds.get(key)
        if hit is not None and 0 <= now - hit[0] < PROTOCOL_CACHE_S:
            return hit[1]
        pond: Optional[Tuple[relay_semver.Version, Optional[int]]]
        try:
            info: Optional[Dict[str, Any]] = self._call("GET", "/version")
        except NotFound:
            info = None
        protocol = info.get("protocol") if info is not None else None
        has_protocol = isinstance(protocol, int) and not isinstance(protocol, bool) and protocol >= 1
        semver = relay_semver.parse_version(info.get("version")) if info is not None else None
        if info is not None and semver is None and not has_protocol:
            pond = None
        elif self.local and semver is not None and has_protocol:
            pond = (max(semver, relay_semver.legacy_version(protocol)), None)
        else:
            pond = relay_semver.pond_version(info)
        _ponds[key] = (now, pond)
        return pond

    def pond_version(self) -> Optional[relay_semver.Version]:
        """The effective Pond version (see pond_info), or None when it can't be read."""
        pond = self.pond_info()
        return pond[0] if pond is not None else None

    def check_pond(self, instructable: Dict[str, Any]) -> None:
        """Refuses (PondTooOld) an instructable with a key the Pond is too old for. An
        unreadable version posts as before and the server validates."""
        needed = keys_needing_pond(instructable)
        if not needed:
            return
        pond = self.pond_info()
        if pond is None:
            return
        order = [k for k, _ in KEY_MIN_POND] + [LINK_PATH_KEY]
        for key, needs in sorted(needed.items(), key=lambda kv: (_version_key(kv[1]), -order.index(kv[0])),
                                 reverse=True):
            if not relay_semver.at_least(pond[0], needs):
                raise PondTooOld(pond_display(pond), key, needs, local=self.local)

    def post(self, project: str, instructable: Dict[str, Any], *,
             edit_keys: Optional[EditKeys] = None) -> Dict[str, Any]:
        """POST /asks. On a Pond that takes corrections, an edit key is made first and only its
        hash is sent; the key is kept when the Pond says the ask is `editable`."""
        self.check_pond(instructable)
        body: Dict[str, Any] = {"project": project, "instructable": fill_from(instructable, self.env)}
        keys: Optional[EditKeys] = None
        title = str(instructable.get("title") or "")
        if not self.local:
            body["context"] = self.source["context"]
            pond = self.pond_info()
            if pond is not None and relay_semver.at_least(pond[0], AMEND_POND):
                keys = edit_keys if edit_keys is not None else EditKeys(self.env)
                body["editKeyHash"] = keys.pending(project, title)[1]
        resp = self._call("POST", "/asks", body)
        if keys is not None:
            item = resp.get("item") if isinstance(resp.get("item"), dict) else {}
            revision = resp.get("revision") if isinstance(resp.get("revision"), dict) else {}
            rev = revision.get("rev") if isinstance(revision.get("rev"), int) else 1
            hash_ = revision.get("hash") if isinstance(revision.get("hash"), str) else ""
            if resp.get("editable") is True and isinstance(item.get("id"), str):
                keys.commit(project, title, item["id"], rev, hash_, session_id(self.env), self.source_key())
            else:
                keys.drop_pending(project, title)
            keys.prune()
        return resp

    def amend(self, ask_id: str, reason: str, instructable: Dict[str, Any], base_rev: Optional[int] = None, *,
              edit_keys: Optional[EditKeys] = None) -> Dict[str, Any]:
        """POST /asks/{id}/amend with this Mac's edit key: a corrected version of an open ask.
        Without base_rev it corrects the newest version, and only when that is the one this
        Mac wrote last (else ChangedUnderneath). Adds `warning` when another session posted it."""
        ask_id = ask_id.strip()
        if self.local:
            raise LocalCantAmend(ask_id)
        pond = self.pond_info()
        if pond is not None and not relay_semver.at_least(pond[0], AMEND_POND):
            raise PondTooOld(pond_display(pond), "amend", AMEND_POND)
        keys = edit_keys if edit_keys is not None else EditKeys(self.env)
        record = keys.load(ask_id)
        if record is None or not isinstance(record.get("key"), str):
            raise NoEditKey(ask_id)
        detail = self.get(ask_id)
        current = revision_of(detail)
        last_hash = record.get("lastHash") if isinstance(record.get("lastHash"), str) else ""
        cur_rev = current["rev"] if current is not None else 1
        cur_hash = current["hash"] if current is not None else last_hash
        if base_rev is None:
            if current is not None and last_hash and current["hash"] != last_hash:
                raise ChangedUnderneath(ask_id, cur_rev)
            base_rev, base_hash = cur_rev, cur_hash
        else:
            base_hash = revision_hash_of(detail, base_rev) or cur_hash
        body = {"editKey": record["key"], "baseRev": base_rev, "baseHash": base_hash, "reason": reason,
                "instructable": instructable}
        try:
            resp = self._call("POST", "/asks/" + self._quote(ask_id) + "/amend", body,
                              not_found=f"no ask with id {ask_id}")
        except Refused as exc:
            if exc.status == 409 and exc.error == "corrections not enabled":
                raise CorrectionsOff(ask_id) from None
            raise
        revision = resp.get("revision") if isinstance(resp.get("revision"), dict) else {}
        if isinstance(revision.get("rev"), int) and isinstance(revision.get("hash"), str):
            keys.record_write(ask_id, revision["rev"], revision["hash"])
        poster = record.get("session") if isinstance(record.get("session"), str) else ""
        if poster and poster != session_id(self.env):
            resp = dict(resp, warning=f"ask {ask_id} was posted from another session; "
                                      "correct only the asks you posted")
        return resp

    def list(self, status: str = "open", days: int = 36500) -> List[Dict[str, Any]]:
        query = urllib.parse.urlencode({"status": status, "days": int(days)})
        items = self._call("GET", "/asks?" + query).get("items")
        return [i for i in items if isinstance(i, dict)] if isinstance(items, list) else []

    def get(self, ask_id: str) -> Dict[str, Any]:
        return self._call("GET", "/asks/" + self._quote(ask_id), not_found=f"no ask with id {ask_id}")

    def resolve(self, ask_id: str, verdict: str, note: Optional[str] = None) -> Dict[str, Any]:
        body: Dict[str, Any] = {"verdict": verdict, "actor": "session"}
        if note is not None:
            body["note"] = note
        return self._call("POST", "/asks/" + self._quote(ask_id) + "/resolve", body,
                          not_found=f"no ask with id {ask_id}")

    def events(self, after: int = 0, limit: int = 1000) -> Dict[str, Any]:
        query = urllib.parse.urlencode({"after": int(after), "limit": int(limit)})
        return self._call("GET", "/events?" + query)

    # plumbing

    @staticmethod
    def _quote(ask_id: str) -> str:
        return urllib.parse.quote(ask_id.strip(), safe="")

    def _call(self, method: str, path: str, body: Optional[Dict[str, Any]] = None,
              not_found: Optional[str] = None) -> Dict[str, Any]:
        def attempt() -> Tuple[int, Any]:
            token = self._verify_server()[0] if self.local else self._mailbox_token()
            return self._transport(method, path, body=body, auth=token)

        status, obj = self._with_launch(attempt) if self.local else attempt()
        return self._check(status, obj, not_found)

    def _check(self, status: int, obj: Any, not_found: Optional[str]) -> Dict[str, Any]:
        if 200 <= status < 300:
            if not isinstance(obj, dict):
                raise Unreachable(f"{self.base} answered HTTP {status} with a non-JSON body")
            return obj
        obj = obj if isinstance(obj, dict) else {}
        if status == 404:
            raise NotFound(not_found or "not found")
        error = obj.get("error") if isinstance(obj.get("error"), str) else f"HTTP {status}"
        details = obj.get("details") if isinstance(obj.get("details"), list) else []
        raise Refused(status, error, [str(d) for d in details])

    def _with_launch(self, fn: Callable[[], Any]) -> Any:
        try:
            return fn()
        except _Refused:
            if not self.autolaunch or self._launched:
                raise Unreachable(NOT_RUNNING) from None
        self._launched = True
        if not any(self._launcher(list(command)) for command in LAUNCH_COMMANDS):
            raise Unreachable(NO_APP)
        deadline = self._monotonic() + LAUNCH_WAIT_S
        while True:
            self._sleep(LAUNCH_POLL_S)
            try:
                return fn()
            except _Refused:
                if self._monotonic() >= deadline:
                    raise Unreachable(NOT_RUNNING) from None

    def _verify_server(self) -> Tuple[str, Dict[str, Any]]:
        """GET /health with a fresh nonce and no token; returns (token, health)."""
        nonce = secrets.token_hex(16)
        other = f"Something else is answering on 127.0.0.1:{self.source['port']}; not sending."
        status, obj = self._transport("GET", "/health", headers={"X-Relay-Nonce": nonce})
        if status != 200 or not isinstance(obj, dict) or obj.get("app") != "relay":
            raise Unreachable(other)
        if obj.get("source") != "local":
            raise Unreachable(NOT_THIS_MAC)
        token = self._local_token()
        # The proof is bound to the port this client connects to, so a
        # proof relayed from Relay's real listener doesn't verify on another port.
        port = self.source["port"]
        expected = hmac.new(token.encode("utf-8"), (PROOF_PREFIX + str(port) + "\n" + nonce).encode("utf-8"),
                            hashlib.sha256).hexdigest()
        proof = obj.get("proof")
        if not isinstance(proof, str) or not hmac.compare_digest(proof.encode("utf-8"), expected.encode("utf-8")):
            raise Unreachable(other)
        return token, obj

    def _local_token(self) -> str:
        path = config_dir(self.env) / "local-token"
        _check_trusted(path.parent, path)
        try:
            token = path.read_text(encoding="utf-8").strip()
        except OSError:
            token = ""
        if not token:
            raise Unreachable(f"Hook's local token at {path} is missing; open Hook in This Mac mode")
        return token

    def _mailbox_token(self) -> str:
        path = pathlib.Path(self.source["token_file"]).expanduser()
        try:
            token = path.read_text(encoding="utf-8").strip()
        except OSError:
            token = ""
        if not token:
            raise ConfigMissing(f"Pond token file unreadable at {path}")
        return token

    def _unreachable(self, reason: Any) -> Unreachable:
        if self.local:
            return Unreachable(f"Hook isn't reachable on 127.0.0.1:{self.source['port']}: {reason}")
        return Unreachable(f"Pond unreachable: {self.base}: {reason}")

    def _transport(self, method: str, path: str, *, body: Optional[Dict[str, Any]] = None,
                   headers: Optional[Dict[str, str]] = None, auth: Optional[str] = None) -> Tuple[int, Any]:
        """One HTTP exchange → (status, decoded JSON or None). Never raises on HTTP status."""
        hdrs = {"X-Relay-Client": f"{self.kind}/{VERSION}", "Accept": "application/json",
                PROTOCOL_HEADER: CLIENT_PROTOCOL}
        hdrs.update(headers or {})
        data = None
        if body is not None:
            # ASCII escapes: a lone surrogate from a "\ud800" escape can't crash the UTF-8
            # encode, and the server answers it with 400 invalid json.
            data = json.dumps(body).encode("utf-8")
            hdrs["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=hdrs, method=method)
        if auth is not None:
            # Unredirected: urllib drops it on any redirect it might still follow.
            req.add_unredirected_header("Authorization", "Bearer " + auth)
        timeout = self.timeout
        if self.deadline is not None:
            left = self.deadline - self._monotonic()
            if left <= 0:
                raise self._unreachable("timed out")
            timeout = min(timeout, left)
        try:
            with self._urlopen(req, timeout=timeout) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            try:
                raw = exc.read() or b""
            except OSError:
                raw = b""
        except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
            reason = getattr(exc, "reason", exc)
            if isinstance(reason, ConnectionRefusedError) and self.local:
                raise _Refused() from None
            raise self._unreachable(reason) from None
        if 300 <= status < 400:
            raise Unreachable(f"the server at {self.base} answered with a redirect ({status}); not following it")
        try:
            obj = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            obj = None
        return status, obj
