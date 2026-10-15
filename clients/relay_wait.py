"""`relay wait <id>`: block until the owner answers one ask, then print the answer and exit.

Meant to run in the background right after posting an ask the session's work waits on:
Claude Code wakes the session when the command exits. Only owner events count
(reply, resolved, declined) with a seq above --after. Exit 0 with the answer on
stdout; 3 when the timeout passes first. An unreachable Relay or mailbox, or a 5xx
answer, is retried every interval until the deadline; a missing ask or a missing
config ends the wait at once (exit 1 / 2, raised to the caller).
Standard library only; runs on Python 3.9+.
"""
from __future__ import annotations

import time
from typing import Any, Callable, Dict, List, Optional

from relay_client import Refused, Unreachable, one_line

DEFAULT_TIMEOUT_S = 28800.0       # 8 h
LOCAL_INTERVAL_S = 2.0            # 127.0.0.1 is cheap to poll
MAILBOX_INTERVAL_S = 20.0
MIN_INTERVAL_S = 1.0
TIMEOUT_EXIT = 3
OWNER_KINDS = ("reply", "resolved", "declined")


def _seq(event: Dict[str, Any]) -> int:
    try:
        return int(event.get("seq") or 0)
    except (TypeError, ValueError):
        return 0


def owner_answers(events: List[Any], after: int) -> List[Dict[str, Any]]:
    """Owner reply/resolved/declined events with seq > after, in log order."""
    return [e for e in events if isinstance(e, dict) and e.get("actor") == "owner"
            and e.get("kind") in OWNER_KINDS and _seq(e) > after]


def format_answer(detail: Dict[str, Any], ask_id: str, answers: List[Dict[str, Any]]) -> List[str]:
    """The same lines as any mailbox client: header, one line per answer, last seq."""
    item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
    events = detail.get("events") if isinstance(detail.get("events"), list) else []
    lines = [f"[{item.get('projectId') or ''}] {item.get('title') or ask_id}"]
    for event in answers:
        text = one_line(event.get("text") or "")
        head = f"  ↳ owner {event.get('kind')} {event.get('at') or ''}"
        lines.append(head + (f": {text}" if text else ""))
    lines.append(f"last seq: {max(_seq(e) for e in events if isinstance(e, dict))}")
    return lines


def run(client: Any, ask_id: str, *, timeout: float = DEFAULT_TIMEOUT_S, interval: Optional[float] = None,
        after: int = 0, out: Any, err: Any, sleep: Optional[Callable[[float], None]] = None,
        monotonic: Optional[Callable[[], float]] = None) -> int:
    """Poll client.get(ask_id) until an owner answer arrives (0) or `timeout` seconds pass (3).

    NotFound, ConfigMissing and 4xx Refused propagate as RelayError; the CLI prints them.
    """
    sleep = sleep or time.sleep
    monotonic = monotonic or time.monotonic
    if interval is None:
        interval = LOCAL_INTERVAL_S if client.local else MAILBOX_INTERVAL_S
    step = max(MIN_INTERVAL_S, float(interval))
    deadline = monotonic() + timeout
    noted = False
    while True:
        detail = None
        try:
            detail = client.get(ask_id)
        except Unreachable as exc:
            if not noted:
                err.write(f"relay wait: {exc}; retrying every {step:g} s\n")
                noted = True
        except Refused as exc:
            if exc.status < 500:
                raise
            if not noted:
                err.write(f"relay wait: {exc.error}; retrying every {step:g} s\n")
                noted = True
        if detail is not None:
            events = detail.get("events") if isinstance(detail.get("events"), list) else []
            answers = owner_answers(events, after)
            if answers:
                for line in format_answer(detail, ask_id, answers):
                    out.write(line + "\n")
                return 0
        if monotonic() >= deadline:
            err.write(f"no owner answer on {ask_id} within {timeout:g} s\n")
            return TIMEOUT_EXIT
        sleep(step)
