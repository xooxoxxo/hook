"""`relay replies`: new owner answers since this caller last looked, and the prompt hook.

Cursor file: replies-cursor.json next to config.json, under an flock on
replies-cursor.json.lock. With --hook it reads only `session_id` from the hook's stdin,
never auto-launches Hook, keeps to a 2 s budget and always exits 0 (exit 2 from a
UserPromptSubmit hook would block the prompt). With --hook, problem reports, accepted
versions and the owner's messages are printed only to the session that posted the ask (its
edit-key file says which); a hook that can't name its session hears none of them.
Everything the owner or an ask says is printed quoted on one line (session_text), so no title,
note or reply can pass for a line of its own. Standard library only; Python 3.9+.
"""
from __future__ import annotations

import datetime
import fcntl
import json
import os
import pathlib
import re
import select
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from relay_client import (OWNER_LABELS, EditKeys, NotFound, RelayError, answer_value, check_trusted_dir,
                          check_trusted_file, config_dir, ensure_private_dir, event_rev, message_line, parse_answer,
                          private_write, session_label, session_text, session_text_cut)

CURSOR_FILE = "replies-cursor.json"
HOOK_BUDGET_S = 2.0
HOOK_STDIN_LIMIT = 1024 * 1024
HOOK_STDIN_WAIT_S = 0.5
PAGE = 1000
# Owner text per event; past it the line says how much more `relay status <id> --json` has.
TEXT_CAP = 8000
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
POSTER_ONLY = ("problem", "accepted", "message")   # in hook mode, only for the session that posted the ask


class CursorStore:
    """{source_key: {"epoch"?, "head", "cursors": {key: {"after", "used"}}}}, used under its lock."""

    def __init__(self, path: Any, today: Optional[datetime.date] = None, lock_timeout: float = 2.0) -> None:
        self.path = pathlib.Path(path)
        self.lock_path = self.path.with_name(self.path.name + ".lock")
        self.today = today or datetime.datetime.now(datetime.timezone.utc).date()
        self.lock_timeout = lock_timeout
        self.data: Dict[str, Any] = {}
        self._fd: Optional[int] = None

    def __enter__(self) -> "CursorStore":
        ensure_private_dir(self.path.parent)
        check_trusted_dir(self.path.parent)
        check_trusted_file(self.path)
        fd = os.open(str(self.lock_path), os.O_RDWR | os.O_CREAT, 0o600)
        deadline = time.monotonic() + self.lock_timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(fd)
                    raise RelayError("the replies cursor is busy; try again") from None
                time.sleep(0.02)
        self._fd = fd
        self.data = self._load()
        return self

    def __exit__(self, *exc: Any) -> bool:
        if self._fd is not None:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None
        return False

    def _load(self) -> Dict[str, Any]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _entry(self, source_key: str) -> Dict[str, Any]:
        entry = self.data.get(source_key)
        if not isinstance(entry, dict):
            entry = {"head": 0, "cursors": {}}
            self.data[source_key] = entry
        if not isinstance(entry.get("cursors"), dict):
            entry["cursors"] = {}
        return entry

    @staticmethod
    def _int(value: Any) -> Optional[int]:
        return value if isinstance(value, int) and not isinstance(value, bool) else None

    def head(self, source_key: str) -> Optional[int]:
        entry = self.data.get(source_key)
        return self._int(entry.get("head")) if isinstance(entry, dict) else None

    def set_head(self, source_key: str, seq: int) -> None:
        entry = self._entry(source_key)
        entry["head"] = max(self.head(source_key) or 0, int(seq))

    def epoch(self, source_key: str) -> Optional[str]:
        entry = self.data.get(source_key)
        value = entry.get("epoch") if isinstance(entry, dict) else None
        return value if isinstance(value, str) else None

    def reset_epoch(self, source_key: str, epoch: str) -> None:
        entry = self._entry(source_key)
        entry["epoch"] = epoch
        entry["head"] = 0
        for cursor in entry["cursors"].values():
            if isinstance(cursor, dict):
                cursor["after"] = 0

    def cursor(self, source_key: str, key: str) -> Optional[int]:
        entry = self.data.get(source_key)
        cursors = entry.get("cursors") if isinstance(entry, dict) else None
        value = cursors.get(key) if isinstance(cursors, dict) else None
        return self._int(value.get("after")) if isinstance(value, dict) else None

    def set_cursor(self, source_key: str, key: str, after: int) -> None:
        self._entry(source_key)["cursors"][key] = {"after": int(after), "used": self.today.isoformat()}

    def prune(self, max_age_days: int = 7) -> None:
        """Drops cursors unused for max_age_days or more (and unreadable ones)."""
        for entry in self.data.values():
            cursors = entry.get("cursors") if isinstance(entry, dict) else None
            if not isinstance(cursors, dict):
                continue
            for key in list(cursors):
                try:
                    used = datetime.date.fromisoformat(cursors[key]["used"])
                except (TypeError, KeyError, ValueError):
                    del cursors[key]
                    continue
                if (self.today - used).days >= max_age_days:
                    del cursors[key]

    def save(self) -> None:
        private_write(self.path, (json.dumps(self.data, indent=1, sort_keys=True) + "\n").encode("utf-8"))


def _read_limited(stdin: Any, limit: int, wait_s: float) -> bytes:
    stream = getattr(stdin, "buffer", stdin)
    try:
        fd = stream.fileno()
    except (AttributeError, OSError, ValueError):
        fd = None
    if fd is None:
        data = stream.read(limit)
        return data.encode("utf-8") if isinstance(data, str) else (data or b"")
    chunks: List[bytes] = []
    total = 0
    end = time.monotonic() + wait_s
    while total < limit:
        left = end - time.monotonic()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            break
        chunk = os.read(fd, min(65536, limit - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def read_hook_session(stdin: Any) -> Optional[str]:
    """session_id from the hook's stdin JSON; None for a TTY, empty, oversized or non-JSON input.
    The rest of the payload (the prompt) is dropped at once."""
    if stdin is None:
        return None
    try:
        if stdin.isatty():
            return None
        raw = _read_limited(stdin, HOOK_STDIN_LIMIT + 1, HOOK_STDIN_WAIT_S)
    except (AttributeError, OSError, ValueError):
        return None
    if not raw or len(raw) > HOOK_STDIN_LIMIT:
        return None
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    del payload, raw
    return session_id.strip() if isinstance(session_id, str) and session_id.strip() else None


class _OutOfTime(Exception):
    pass


OutOfTime = _OutOfTime            # for relay_hook: the budget ran out before the first answer


def _arm(client: Any, deadline: Optional[float], clock: Callable[[], float]) -> None:
    """Before each call under a budget: give the client only the time that is left."""
    if deadline is None:
        return
    left = deadline - clock()
    if left <= 0:
        raise _OutOfTime()
    if hasattr(client, "timeout"):
        client.timeout = left
    if hasattr(client, "deadline"):
        # A call can make two exchanges (/health, then the request); each gets only
        # what is left of the budget, not `left` each.
        client.deadline = deadline


def _page(client: Any, after: int, deadline: Optional[float],
          clock: Callable[[], float]) -> Tuple[List[Dict[str, Any]], Optional[str], bool]:
    """Every event after `after` → (events, epoch, partial)."""
    events: List[Dict[str, Any]] = []
    epoch: Optional[str] = None
    first = True
    while True:
        try:
            _arm(client, deadline, clock)
        except _OutOfTime:
            if first:
                raise
            return events, epoch, True
        page = client.events(after=after, limit=PAGE)
        first = False
        batch = page.get("events") if isinstance(page.get("events"), list) else []
        if epoch is None and isinstance(page.get("epoch"), str):
            epoch = page["epoch"]
        events.extend(e for e in batch if isinstance(e, dict))
        nxt = page.get("next")
        if len(batch) < PAGE or not isinstance(nxt, int) or nxt <= after:
            return events, epoch, False
        after = nxt


def _where(client: Any, item_id: str, cache: Dict[str, str], deadline: Optional[float],
           clock: Callable[[], float]) -> str:
    """'<project> · "<title>"' for the line, or (removed); the title quoted by session_text."""
    if item_id not in cache:
        _arm(client, deadline, clock)
        try:
            detail = client.get(item_id)
            item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
            title = session_text(item["title"], 120) if item.get("title") else "?"
            cache[item_id] = f"{session_label(item.get('projectId') or '?', 60)} · {title}"
        except NotFound:
            cache[item_id] = "(removed)"
    return cache[item_id]


def _verdict(event: Dict[str, Any], label: str, body: Optional[Dict[str, Any]]) -> str:
    """The part after the em dash: `<label>: "<text>"`, every value through session_text, owner
    text cut at TEXT_CAP with the rest named (session_text_cut)."""
    ask = event.get("itemId")
    kind = event.get("kind")
    if kind == "answer":
        if body is None:
            text = event.get("text") or ""
            return f"answer: {session_text_cut(text, TEXT_CAP, ask)}" if text else "answer"
        return (f"answer {session_label(body['step'], 20)} (version {event_rev(event)}): "
                f"{session_text_cut(answer_value(body), TEXT_CAP, ask)}")
    if kind == "problem":
        try:
            report = json.loads(event.get("text") or "")
        except (TypeError, ValueError):
            report = None
        report = report if isinstance(report, dict) else {}
        return (f"owner problem on step {session_label(report.get('step') or '?', 20)} "
                f"(version {event_rev(event)}), quoted: {session_text_cut(report.get('note'), TEXT_CAP, ask)}")
    if kind == "accepted":
        return f"accepted version {event_rev(event)}"
    if kind == "message":
        return message_line(event, session_text_cut(event.get("text") or "", TEXT_CAP, ask))
    text = event.get("text") or ""
    return f"{label}: {session_text_cut(text, TEXT_CAP, ask)}" if text else label


def _posted_by(client: Any, item_id: str, session_id: Optional[str], cache: Dict[str, bool]) -> bool:
    """Did this session post the ask? Its edit-key file names the session; no file, another
    session or an empty one is no."""
    if item_id not in cache:
        try:
            record = EditKeys(getattr(client, "env", None)).load(item_id)
        except RelayError:
            record = None
        poster = record.get("session") if isinstance(record, dict) else None
        cache[item_id] = bool(session_id) and isinstance(poster, str) and bool(poster) and poster == session_id
    return cache[item_id]


def _label(event: Dict[str, Any]) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
    """(the verdict label, the parsed answer body); the label is None for a kind no session reads."""
    label = OWNER_LABELS.get(event.get("kind"))
    body = parse_answer(event)
    if event.get("kind") == "answer" and event.get("actor") == "owner":
        label = f"answer {body['step']}" if body else "answer"
    return label, body


def _valid_id(item_id: Any) -> bool:
    return isinstance(item_id, str) and UUID.fullmatch(item_id) is not None


def _line(client: Any, event: Dict[str, Any], label: str, body: Optional[Dict[str, Any]], titles: Dict[str, str],
          deadline: Optional[float], clock: Callable[[], float]) -> str:
    """One `Hook: [<id>] <project> · "<title>" — <verdict>` line; raises _OutOfTime."""
    item_id = event.get("itemId")
    valid = _valid_id(item_id)
    where = _where(client, item_id, titles, deadline, clock) if valid else "?"
    return f"Hook: [{item_id if valid else '(bad id)'}] {where} — {_verdict(event, label, body)}"


def _collect(client: Any, key: str, new: bool, deadline: Optional[float],
             clock: Callable[[], float], session_id: Optional[str] = None) -> Tuple[List[str], bool]:
    """The new owner lines. session_id is set in hook mode: problem, accepted and message lines
    then go only to the session that posted the ask."""
    source_key = client.source_key()
    path = config_dir(getattr(client, "env", None)) / CURSOR_FILE
    lock_wait = HOOK_BUDGET_S if deadline is None else max(0.05, deadline - clock())
    with CursorStore(path, lock_timeout=lock_wait) as store:
        store.prune()
        cursor = store.cursor(source_key, key)
        start = cursor if cursor is not None else (store.head(source_key) or 0)
        events, epoch, partial = _page(client, start, deadline, clock)
        if epoch is not None and epoch != store.epoch(source_key):
            store.reset_epoch(source_key, epoch)          # a new local queue: everything in it is new
            cursor = store.cursor(source_key, key)
            restart = cursor if cursor is not None else 0
            if restart != start:
                start = restart
                events, epoch, partial = _page(client, start, deadline, clock)
        first_run = cursor is None                         # silent: starts from head
        lines: List[str] = []
        titles: Dict[str, str] = {}
        posters: Dict[str, bool] = {}
        last = start
        for event in events:
            seq = event.get("seq")
            if not isinstance(seq, int) or isinstance(seq, bool):
                continue
            label, body = _label(event)
            if not first_run and label is not None and event.get("actor") == "owner":
                item_id = event.get("itemId")
                valid = _valid_id(item_id)
                if session_id is not None and event.get("kind") in POSTER_ONLY and \
                        not (valid and _posted_by(client, item_id, session_id, posters)):
                    last = max(last, seq)
                    continue
                try:
                    lines.append(_line(client, event, label, body, titles, deadline, clock))
                except _OutOfTime:
                    partial = True
                    break
            last = max(last, seq)
        store.set_head(source_key, last)
        store.set_cursor(source_key, key, last if (first_run or new) else (cursor or 0))
        store.save()
    return lines, partial


def run(client: Any, *, new: bool, hook: bool, session_id: Optional[str], out: Any, err: Any,
        budget_s: float = HOOK_BUDGET_S, monotonic: Optional[Callable[[], float]] = None) -> int:
    clock = monotonic or time.monotonic
    deadline = clock() + budget_s if hook else None
    try:
        if hook and not session_id:
            raise RelayError("no session_id on stdin")
        key = "session:" + session_id if hook and session_id else "cli"
        lines, partial = _collect(client, key, new, deadline, clock, session_id if hook else None)
    except _OutOfTime:
        err.write("relay replies: ran out of time\n")
        return 0
    except RelayError as exc:
        err.write(f"relay replies: {exc}\n")
        return 0 if hook else exc.exit_code
    except Exception as exc:  # noqa: BLE001 — the hook must never fail a prompt
        if not hook:
            raise
        err.write(f"relay replies: internal error: {type(exc).__name__}\n")
        return 0
    for line in lines:
        out.write(line + "\n")
    if partial:
        err.write("relay replies: stopped at the time budget; the rest shows next time\n")
    return 0


# --- for `relay hook replies` (relay_hook) ---------------------------------------------------

RECENT_HOURS = 24
RECENT_LIMIT = 10


def collect(client: Any, key: str, *, session_id: Optional[str], new: bool = True, budget_s: float = HOOK_BUDGET_S,
            monotonic: Optional[Callable[[], float]] = None) -> Tuple[List[str], bool]:
    """Prompt mode: the new owner lines for cursor `key`, under the budget → (lines, partial).
    session_id "" (no session named) leaves the poster-only kinds out. Raises OutOfTime."""
    clock = monotonic or time.monotonic
    return _collect(client, key, new, clock() + budget_s, clock, session_id)


def _at(value: Any) -> Optional[datetime.datetime]:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        at = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    return at if at.tzinfo is not None else at.replace(tzinfo=datetime.timezone.utc)


def _first_at(client: Any, after: int, deadline: Optional[float],
              clock: Callable[[], float]) -> Tuple[bool, Optional[datetime.datetime]]:
    """The first event after seq `after` → (there is one, its time or None)."""
    _arm(client, deadline, clock)
    page = client.events(after=after, limit=1)
    batch = page.get("events") if isinstance(page.get("events"), list) else []
    first = batch[0] if batch and isinstance(batch[0], dict) else None
    return first is not None, _at(first.get("at")) if first is not None else None


def _day_start(client: Any, cutoff: datetime.datetime, deadline: Optional[float],
               clock: Callable[[], float]) -> int:
    """A seq to read from so that every event from `cutoff` on comes after it, within a page:
    the events API pages by seq only, so this gallops forward and then halves, one event per
    probe. Seq order follows time; an event without a time counts as recent, so nothing recent
    is skipped. Raises OutOfTime."""
    lo, step = 0, PAGE
    while True:
        exists, at = _first_at(client, lo + step, deadline, clock)
        if not exists or at is None or at >= cutoff:
            hi = lo + step
            break
        lo, step = lo + step, step * 2
    while hi - lo > PAGE:
        mid = (lo + hi) // 2
        exists, at = _first_at(client, mid, deadline, clock)
        if not exists or at is None or at >= cutoff:
            hi = mid
        else:
            lo = mid
    return lo


def recent(client: Any, *, now: Optional[datetime.datetime] = None, hours: int = RECENT_HOURS,
           limit: int = RECENT_LIMIT, budget_s: float = HOOK_BUDGET_S,
           monotonic: Optional[Callable[[], float]] = None) -> Tuple[List[str], bool]:
    """Session-start mode: the owner's events from the last `hours`, the newest `limit`, as the
    same quoted lines, oldest first → (lines, partial). Only about the last `hours` of the log is
    read (`_day_start`), never the whole log from seq 0. Poster-only kinds are left out (no session
    is named at session start), and no cursor is read or written. Raises OutOfTime."""
    clock = monotonic or time.monotonic
    deadline = clock() + budget_s
    when = now or datetime.datetime.now(datetime.timezone.utc)
    cutoff = when - datetime.timedelta(hours=hours)
    events, _, partial = _page(client, _day_start(client, cutoff, deadline, clock), deadline, clock)
    picked: List[Tuple[Dict[str, Any], str, Optional[Dict[str, Any]]]] = []
    for event in events:
        seq = event.get("seq")
        if not isinstance(seq, int) or isinstance(seq, bool) or event.get("actor") != "owner" \
                or event.get("kind") in POSTER_ONLY:
            continue
        label, body = _label(event)
        at = _at(event.get("at"))
        if label is None or at is None or at < cutoff:
            continue
        picked.append((event, label, body))
    lines: List[str] = []
    titles: Dict[str, str] = {}
    for event, label, body in picked[-limit:] if limit > 0 else []:
        try:
            lines.append(_line(client, event, label, body, titles, deadline, clock))
        except _OutOfTime:
            partial = True
            break
    return lines, partial
