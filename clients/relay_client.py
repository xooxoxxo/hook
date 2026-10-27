"""Shared Hook client for the `relay` CLI and the MCP server.

Reads ~/.config/relay/config.json (or $RELAY_CONFIG) and talks to either source:
- local: Hook.app on 127.0.0.1:<port>. Every token-bearing call first checks the
  server proof on GET /health, so the token only ever goes to Hook itself.
- mailbox: the mailbox service at mailboxURL.
Tokens are read from disk on every call and never printed or logged.
Standard library only; runs on Python 3.9+.
"""
from __future__ import annotations

import hashlib
import hmac
import http.client
import json
import os
import pathlib
import secrets
import socket
import stat
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple

VERSION = "0.9.1"
DEFAULT_CONFIG = "~/.config/relay/config.json"
DEFAULT_PORT = 47823
DEFAULT_CONTEXT = "personal"
NO_CONFIG = "No Hook config; run scripts/install.sh"
MAILBOX_PROBLEM = "mailbox needs an http(s) mailboxURL and a tokenFile"
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
# Protocol levels a mailbox (or Hook's LocalAPI) can speak, as docs/mailbox-protocol.md defines them.
# An instructable key that needs more than level 1 is checked before it is posted.
KEY_LEVELS = (("optional", 4), ("file", 4), ("blocking", 3), ("warning", 3), ("question", 2))
LINK_PATH_KEY, LINK_PATH_LEVEL = "links[].path", 4   # a link's `path` (a local file)
PROTOCOL_CACHE_S = 300.0
_levels: Dict[str, Tuple[float, Optional[int]]] = {}   # per process: source -> (when checked, level or None)

# Owner event kinds as the CLI and the hook print them.
OWNER_LABELS = {"resolved": "done", "declined": "skipped", "reply": "reply", "reopened": "reopened"}


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


class ProtocolTooOld(Refused):
    """The mailbox (or, in This Mac mode, Hook itself) speaks a lower protocol level than the
    instructable's keys need."""

    def __init__(self, level: int, key: str, needs: int, local: bool = False) -> None:
        if local:
            message = (f"Hook speaks protocol {level}; `{key}` needs {needs}. "
                       "Update Hook (Check for Updates…).")
        else:
            message = (f"This mailbox speaks protocol {level}; `{key}` needs {needs}. "
                       "Ask the owner to update the mailbox (Hook › Update Mailbox…).")
        super().__init__(0, message)
        self.level, self.key, self.needs, self.local = level, key, needs, local


def keys_needing_levels(instructable: Any) -> Dict[str, int]:
    """{key: level} for the keys of steps and sub-steps (not verify) that need more than level 1,
    plus LINK_PATH_KEY when a link carries `path`."""
    found: Dict[str, int] = {}
    links = instructable.get("links") if isinstance(instructable, dict) else None
    if isinstance(links, list) and any(isinstance(link, dict) and "path" in link for link in links):
        found[LINK_PATH_KEY] = LINK_PATH_LEVEL
    steps = instructable.get("steps") if isinstance(instructable, dict) else None
    stack = [s for s in steps if isinstance(s, dict)] if isinstance(steps, list) else []
    while stack:
        step = stack.pop()
        for key, needs in KEY_LEVELS:
            if key in step:
                found[key] = needs
        subs = step.get("substeps")
        if isinstance(subs, list):
            stack.extend(s for s in subs if isinstance(s, dict))
    return found


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
            raise Unreachable(f"mailbox at {self.base} answered HTTP {status} with a non-JSON body")
        return obj

    def protocol_level(self) -> Optional[int]:
        """The protocol level the mailbox (or LocalAPI) reports on GET /version, or None when
        it is unknown: no such route (404), or a 200 without an integer `protocol` >= 1.
        Cached for PROTOCOL_CACHE_S per source, per process (an unknown level too)."""
        key = self.source_key() + "|" + self.base
        now = self._monotonic()
        hit = _levels.get(key)
        if hit is not None and 0 <= now - hit[0] < PROTOCOL_CACHE_S:
            return hit[1]
        level: Optional[int] = None
        try:
            protocol = self._call("GET", "/version").get("protocol")
            if isinstance(protocol, int) and not isinstance(protocol, bool) and protocol >= 1:
                level = protocol
        except NotFound:
            pass
        _levels[key] = (now, level)
        return level

    def check_protocol(self, instructable: Dict[str, Any]) -> None:
        """Refuses (ProtocolTooOld) an instructable whose keys need a higher level than the
        mailbox reports. An unknown level posts as before and the server validates; one
        without such keys makes no extra call."""
        needed = keys_needing_levels(instructable)
        if not needed:
            return
        level = self.protocol_level()
        if level is None:
            return
        for key, needs in sorted(needed.items(), key=lambda kv: -kv[1]):
            if level < needs:
                raise ProtocolTooOld(level, key, needs, local=self.local)

    def post(self, project: str, instructable: Dict[str, Any]) -> Dict[str, Any]:
        self.check_protocol(instructable)
        body: Dict[str, Any] = {"project": project, "instructable": fill_from(instructable, self.env)}
        if not self.local:
            body["context"] = self.source["context"]
        return self._call("POST", "/asks", body)

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
            raise ConfigMissing(f"mailbox token unreadable at {path}")
        return token

    def _unreachable(self, reason: Any) -> Unreachable:
        if self.local:
            return Unreachable(f"Hook isn't reachable on 127.0.0.1:{self.source['port']}: {reason}")
        return Unreachable(f"mailbox unreachable: {self.base}: {reason}")

    def _transport(self, method: str, path: str, *, body: Optional[Dict[str, Any]] = None,
                   headers: Optional[Dict[str, str]] = None, auth: Optional[str] = None) -> Tuple[int, Any]:
        """One HTTP exchange → (status, decoded JSON or None). Never raises on HTTP status."""
        hdrs = {"X-Relay-Client": f"{self.kind}/{VERSION}", "Accept": "application/json"}
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
