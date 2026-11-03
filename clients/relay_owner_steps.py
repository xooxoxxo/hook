"""Owner-only steps of `relay integrations`, posted to the owner's Hook queue as instructables.
Standard library only (Python 3.9).

Some steps only the owner can do: trust a hook in Codex, reload Cursor, paste a rule into Warp.
The harness table lists them per entry (`owner_steps`), each with `when`:
    after:<piece>   posted after Hook wrote or changed that piece (or the plugin)
    always          posted once, at setup
A sync also bundles the files it skipped because the owner edited them into one ask, a
"Keep mine" / "Use Hook's" question per file (rule 17); the answers run the same paths as
`accept` and `reinstall --force --piece` at the next sync.

Asks go out through relay_client.Client.post, exactly as `relay post` does: the client reads
its own config and token, and this module never opens a file under ~/.config/relay. The manifest
keeps asks[<step id>] = {askId, title, posted, state, harness}; state is pending (not posted
yet: Hook was unreachable, or --no-asks), open, done or skipped. A step is posted again only
when it fires again and its previous ask is closed; the queue's 24 h title dedupe also applies.

Every instructable is checked with relay_lint and the v1 schema before it is posted. Asks name
paths only, never a value from a harness config.
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Set

import relay_bundle as rb
import relay_client
import relay_jsonschema
import relay_lint

PROJECT = "Hook"
HERE = Path(__file__).resolve().parent.parent
SCHEMA_PATH = HERE / "schema" / "instructable.v1.json"
POST_TIMEOUT = 5.0
REFRESH_BUDGET = 2.0
DRIFT = "drift"
KEEP, USE = "Keep mine", "Use Hook's"
MAX_DRIFT_STEPS = 20
PIECE_LABELS = {"mcp": "MCP server entry", "skill": "skill", "instructions": "instructions",
                "replies": "prompt hook", "plugin": "plugin"}
OPEN_STATES = ("open", "pending")


class InvalidAsk(Exception):
    """An instructable Hook built is invalid: a bug in the table or in this module."""


_schema_cache: Dict[str, Any] = {}


def _schema() -> Optional[Dict[str, Any]]:
    if "v1" not in _schema_cache:
        try:
            _schema_cache["v1"] = json.loads(SCHEMA_PATH.read_text("utf-8"))
        except (OSError, ValueError):
            _schema_cache["v1"] = None
    return _schema_cache["v1"]


def validate(instructable: Dict[str, Any]) -> None:
    """Raise InvalidAsk when the instructable fails relay_lint or the v1 schema."""
    problems = relay_lint.lint_details(instructable)
    schema = _schema()
    if schema is not None:
        problems += relay_jsonschema.validate(instructable, schema)
    if problems:
        raise InvalidAsk(f"{instructable.get('title')!r}: " + "; ".join(problems[:5]))


def _iso(now: datetime) -> str:
    return now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _tilde(text: str, home: Path) -> str:
    root = str(home).rstrip("/")
    return "~/" + text[len(root) + 1:] if text.startswith(root + "/") else text


def _fill(value: Any, ph: Mapping[str, str], home: Path, key: str = "") -> Any:
    if isinstance(value, str):
        text = rb.render_text(value, ph, json_escape=False)
        return _tilde(text, home) if key == "file" else text
    if isinstance(value, list):
        return [_fill(v, ph, home) for v in value]
    if isinstance(value, dict):
        return {k: _fill(v, ph, home, k) for k, v in value.items()}
    return value


# --- table steps ---------------------------------------------------------------------------

def render_step(entry: Dict[str, Any], step: Dict[str, Any], values: Any) -> Dict[str, Any]:
    """The table step as a v1 instructable, its placeholders filled for this Mac."""
    import relay_integrations as ri
    ph = ri.placeholders(values, entry)
    doc: Dict[str, Any] = {"v": 1, "title": step["title"], "why": step["why"], "urgency": "today",
                           "steps": _fill(step["steps"], ph, values.home)}
    if step.get("verify"):
        doc["verify"] = _fill(step["verify"], ph, values.home)
    validate(doc)
    return doc


def due_steps(entry: Dict[str, Any], manifest: Any, applied: Set[str]) -> List[Dict[str, Any]]:
    """The entry's steps to post now: an after:<piece> step that fired (Hook changed that piece
    in this run) whose previous ask is closed, an always step never posted, and any step still
    pending from an earlier run."""
    asks = manifest.data.get("asks") or {}
    out = []
    for step in entry.get("owner_steps") or []:
        state = (asks.get(step["id"]) or {}).get("state")
        when = step["when"]
        if state == "pending":
            due = True
        elif when == "always":
            due = state is None
        else:
            due = when.split(":", 1)[1] in applied and state not in OPEN_STATES
        if due:
            out.append(step)
    return out


# --- posting -------------------------------------------------------------------------------

def _client(client_factory: Callable[..., Any], timeout: float) -> Optional[Any]:
    try:
        return client_factory(autolaunch=False, timeout=timeout)
    except relay_client.RelayError:
        return None


def _post(client: Any, instructable: Dict[str, Any]) -> Optional[str]:
    """The new (or deduped) ask's id; None when Hook can't be reached."""
    resp = client.post(PROJECT, instructable)
    item = resp.get("item") if isinstance(resp, dict) and isinstance(resp.get("item"), dict) else {}
    ask_id = item.get("id")
    return ask_id if isinstance(ask_id, str) and ask_id else None


class Poster:
    """One client for one run, made on first use. After Hook turns out to be unreachable, the
    rest of the run records asks as pending without waiting again."""

    def __init__(self, client_factory: Optional[Callable[..., Any]], *, no_asks: bool) -> None:
        self.factory = client_factory
        self.no_asks = no_asks or client_factory is None
        self.client: Optional[Any] = None
        self.down = False
        self.errors: List[str] = []

    def post(self, instructable: Dict[str, Any]) -> Optional[str]:
        validate(instructable)
        if self.no_asks or self.down:
            return None
        if self.client is None:
            self.client = _client(self.factory, POST_TIMEOUT)
            if self.client is None:
                self.down = True
                return None
        try:
            return _post(self.client, instructable)
        except relay_client.Unreachable:
            self.down = True
            return None
        except relay_client.RelayError as exc:
            # Refused (a Pond too old for a key, a full queue): kept pending, tried next sync.
            self.errors.append(f"{instructable.get('title')}: {exc}")
            return None

    def resolve(self, ask_id: str, note: str) -> bool:
        if self.no_asks or self.down:
            return False
        if self.client is None:
            self.client = _client(self.factory, POST_TIMEOUT)
            if self.client is None:
                self.down = True
                return False
        try:
            self.client.resolve(ask_id, "resolved", note)
            return True
        except relay_client.NotFound:
            return True
        except relay_client.RelayError:
            return False


def post_due(steps: List[Dict[str, Any]], manifest: Any, client_factory: Optional[Callable[..., Any]], *,
             no_asks: bool, now: datetime, poster: Optional[Poster] = None) -> List[Dict[str, Any]]:
    """Post each rendered step ({id, title, harness, instructable}); record it in the manifest.
    Returns [{id, title, askId|None, state}]."""
    poster = poster or Poster(client_factory, no_asks=no_asks)
    asks = manifest.data.setdefault("asks", {})
    out = []
    for step in steps:
        ask_id = poster.post(step["instructable"])
        rec = {"askId": ask_id, "title": step["title"], "posted": _iso(now) if ask_id else None,
               "state": "open" if ask_id else "pending", "harness": step["harness"]}
        asks[step["id"]] = rec
        out.append({"id": step["id"], "title": step["title"], "askId": ask_id, "state": rec["state"]})
    return out


# --- reading answers -----------------------------------------------------------------------

def _owner_answers(detail: Dict[str, Any], local: bool, ignore_seq: int) -> Dict[str, str]:
    """{step path: the first pick} of the owner's current answers. On a Pond only an answer
    signed with the owner's key counts; in This Mac mode only the app records answers."""
    out: Dict[str, str] = {}
    for path, value in relay_client.answers_with_state(detail).items():
        if not (local or relay_client.is_verified(value)) or value.get("stale"):
            continue
        try:
            seq = int(value.get("seq") or 0)
        except (TypeError, ValueError):
            seq = 0
        if seq <= ignore_seq:
            continue
        picked = value.get("picked")
        if isinstance(picked, list) and picked:
            out[path] = str(picked[0])
    return out


def waiting(manifest: Any) -> bool:
    """True while an ask Hook posted waits on the owner (so a sync should read it)."""
    return bool(_records(manifest))


def _records(manifest: Any) -> List[Dict[str, Any]]:
    """Every record that may wait on an open ask: owner steps, the drift ask, migrations."""
    recs = [r for r in (manifest.data.get("asks") or {}).values() if isinstance(r, dict)]
    recs += [m for m in manifest.data.get("migrations") or [] if isinstance(m, dict)]
    return [r for r in recs if _waiting(r)]


def _waiting(rec: Dict[str, Any]) -> bool:
    if not rec.get("askId"):
        return False
    if rec.get("state") == "proposed":
        return rec.get("askState", "open") == "open"
    return rec.get("state") == "open"


def refresh(manifest: Any, client_factory: Optional[Callable[..., Any]], budget_s: float = REFRESH_BUDGET, *,
            clock: Callable[[], float] = time.monotonic) -> None:
    """Read each open ask within the budget: done by the owner gives done, skipped gives
    skipped, and the owner's answers are kept on the record. On a timeout or an unreachable
    Hook the last known state stays."""
    recs = _records(manifest)
    if not recs or client_factory is None:
        return
    start = clock()
    client = _client(client_factory, budget_s)
    if client is None:
        return
    local = bool(getattr(client, "local", False))
    for rec in recs:
        left = budget_s - (clock() - start)
        if left <= 0:
            return
        if hasattr(client, "timeout"):
            client.timeout = max(0.1, min(float(client.timeout), left))
        try:
            detail = client.get(rec["askId"])
        except relay_client.NotFound:
            _closed(rec, "skipped", "the ask is gone")
            continue
        except relay_client.RelayError:
            return
        item = detail.get("item") if isinstance(detail, dict) and isinstance(detail.get("item"), dict) else {}
        answers = _owner_answers(detail, local, int(rec.get("ignoreSeq") or 0))
        if answers:
            rec["answers"] = answers
        status = item.get("status")
        if status == "resolved":
            _closed(rec, "done", None)
        elif status == "declined":
            _closed(rec, "skipped", "skipped by you")


def _closed(rec: Dict[str, Any], state: str, note: Optional[str]) -> None:
    if rec.get("state") == "proposed":        # a migration keeps its own state
        rec["askState"] = state
    else:
        rec["state"] = state
    if note:
        rec["note"] = note


# --- the drift ask -------------------------------------------------------------------------

def drift_title(n: int) -> str:
    return f"Choose what to keep in files Hook manages ({n})"


def _short(path: str, cap: int = 240) -> str:
    return path if len(path) <= cap else "…" + path[-(cap - 1):]


def drift_ask(items: List[Dict[str, Any]], values: Any) -> Dict[str, Any]:
    """One ask for the edited files a sync left alone: per file, the file to read and a
    question, Keep mine or Use Hook's. items: [{harness, name, piece, path (~/), file (~/ or
    None), diffable}]."""
    steps = []
    for it in items[:MAX_DRIFT_STEPS]:
        label = PIECE_LABELS.get(it["piece"], it["piece"])
        step: Dict[str, Any] = {
            "do": f"Choose for {it['name']}'s {label}",
            "detail": "You edited this file, so Hook left it alone. Use Hook's keeps a .bak copy of your version.",
            "question": {"prompt": f"{_short(it['path'])}: keep your edit or use Hook's?", "choices": [KEEP, USE]},
        }
        if it.get("file"):
            step["file"] = it["file"]
        if it.get("diffable"):
            step["detail"] += " To see the difference, run the command below in Terminal."
            step["code"] = f"relay integrations diff --harness {it['harness']} --piece {it['piece']}"
            step["lang"] = "bash"
            step["where"] = "Mac terminal"
        steps.append(step)
    doc = {"v": 1, "title": drift_title(len(steps)),
           "why": "Hook updates the files it manages, but it never overwrites an edit of yours without asking.",
           "urgency": "whenever", "steps": steps}
    validate(doc)
    return doc


def drift_items_due(drifted: List[Dict[str, Any]], manifest: Any) -> List[Dict[str, Any]]:
    """The drifted items to ask about now: those not asked about before with the same
    content. Nothing while an earlier drift ask still waits on an answer."""
    rec = (manifest.data.get("asks") or {}).get(DRIFT) or {}
    if rec.get("state") == "open" and any(not it.get("done") for it in rec.get("items") or []):
        return []
    asked = rec.get("asked") or {}
    return [d for d in drifted if asked.get(d["key"]) != d["disk"]][:MAX_DRIFT_STEPS]


def post_drift(items: List[Dict[str, Any]], manifest: Any, values: Any, poster: Poster, now: datetime) -> Optional[Dict[str, Any]]:
    """Post the drift ask for items and record it; None when nothing was posted."""
    if not items:
        return None
    doc = drift_ask(items, values)
    asks = manifest.data.setdefault("asks", {})
    old = asks.get(DRIFT) or {}
    if old.get("state") == "open" and old.get("askId"):
        poster.resolve(old["askId"], "Hook asks again about the files that changed since.")
    ask_id = poster.post(doc)
    if ask_id is None:
        return None
    asked = dict(old.get("asked") or {})
    rows = []
    for k, it in enumerate(items[:MAX_DRIFT_STEPS]):
        asked[it["key"]] = it["disk"]
        rows.append({"step": str(k + 1), "harness": it["harness"], "piece": it["piece"], "key": it["key"],
                     "disk": it["disk"], "path": it["path"]})
    asks[DRIFT] = {"askId": ask_id, "title": doc["title"], "posted": _iso(now), "state": "open",
                   "harness": None, "items": rows, "asked": asked}
    return asks[DRIFT]


def drift_choices(manifest: Any) -> List[Dict[str, Any]]:
    """The answered, not yet applied items of the drift ask: [{row, choice}]."""
    rec = (manifest.data.get("asks") or {}).get(DRIFT) or {}
    answers = rec.get("answers") or {}
    out = []
    for row in rec.get("items") or []:
        choice = answers.get(row["step"])
        if choice in (KEEP, USE) and not row.get("done"):
            out.append({"row": row, "choice": choice})
    return out


def finish_drift(manifest: Any, poster: Poster) -> None:
    """Close the drift ask once Hook applied an answer to every file in it."""
    rec = (manifest.data.get("asks") or {}).get(DRIFT) or {}
    rows = rec.get("items") or []
    if rec.get("state") == "open" and rows and all(r.get("done") for r in rows):
        if poster.resolve(rec["askId"], "Hook applied your choices."):
            rec["state"] = "done"
