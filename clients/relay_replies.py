"""`relay replies`: new owner answers since this caller last looked, and the prompt hook.

Cursor file: replies-cursor.json next to config.json, under an flock on
replies-cursor.json.lock. With --hook it reads only `session_id` from the hook's stdin,
never auto-launches Relay, keeps to a 2 s budget and always exits 0 (exit 2 from a
UserPromptSubmit hook would block the prompt). Standard library only; Python 3.9+.
"""
from __future__ import annotations

import datetime
import fcntl
import json
import os
import pathlib
import select
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from relay_client import (OWNER_LABELS, NotFound, RelayError, check_trusted_dir, check_trusted_file, config_dir,
                          ensure_private_dir, one_line, private_write)

CURSOR_FILE = "replies-cursor.json"
HOOK_BUDGET_S = 2.0
HOOK_STDIN_LIMIT = 1024 * 1024
HOOK_STDIN_WAIT_S = 0.5
PAGE = 1000


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
    if item_id not in cache:
        _arm(client, deadline, clock)
        try:
            detail = client.get(item_id)
            item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
            cache[item_id] = f"{item.get('projectId') or '?'} · {item.get('title') or '?'}"
        except NotFound:
            cache[item_id] = "(removed)"
    return cache[item_id]


def _collect(client: Any, key: str, new: bool, deadline: Optional[float],
             clock: Callable[[], float]) -> Tuple[List[str], bool]:
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
        last = start
        for event in events:
            seq = event.get("seq")
            if not isinstance(seq, int) or isinstance(seq, bool):
                continue
            label = OWNER_LABELS.get(event.get("kind"))
            if not first_run and label is not None and event.get("actor") == "owner":
                item_id = str(event.get("itemId"))
                try:
                    where = _where(client, item_id, titles, deadline, clock)
                except _OutOfTime:
                    partial = True
                    break
                text = one_line(event.get("text") or "")
                lines.append(f"Relay: [{item_id}] {where} — {label}: {text}" if text
                             else f"Relay: [{item_id}] {where} — {label}")
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
        lines, partial = _collect(client, key, new, deadline, clock)
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
