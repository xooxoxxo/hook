"""`relay wait <id>`: block until the owner answers one ask, then print the answer and exit.

Meant to run in the background right after posting an ask the session's work waits on:
Claude Code wakes the session when the command exits. Only owner events count
(reply, resolved, declined, reopened, answer) with a seq above --after. Exit 0 with the answer on
stdout; 3 when the timeout passes first. An unreachable Hook or mailbox, or a 5xx
answer, is retried every interval until the deadline; a missing ask or a missing
config ends the wait at once (exit 1 / 2, raised to the caller).
A step answer starts a 10 s settle: the wait exits once 10 s pass with no newer answer, so a burst
of taps wakes the session once; reply/resolved/declined/reopened exit at once.
Standard library only; runs on Python 3.9+.
"""
from __future__ import annotations

import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from relay_client import (Refused, Unreachable, answer_value, instructable_of, latest_answers, one_line,
                          parse_answer, questions, unanswered)

DEFAULT_TIMEOUT_S = 28800.0       # 8 h
LOCAL_INTERVAL_S = 2.0            # 127.0.0.1 is cheap to poll
MAILBOX_INTERVAL_S = 20.0
MIN_INTERVAL_S = 1.0
TIMEOUT_EXIT = 3
SETTLE_S = 10.0                   # after an answer, wait this long for the next one
SETTLE_INTERVAL_S = 2.0           # poll at least this often while settling
OWNER_KINDS = ("reply", "resolved", "declined", "reopened", "answer")


def _seq(event: Dict[str, Any]) -> int:
    try:
        return int(event.get("seq") or 0)
    except (TypeError, ValueError):
        return 0


def owner_answers(events: List[Any], after: int) -> List[Dict[str, Any]]:
    """Owner reply/resolved/declined/reopened/answer events with seq > after, in log order."""
    return [e for e in events if isinstance(e, dict) and e.get("actor") == "owner"
            and e.get("kind") in OWNER_KINDS and _seq(e) > after]


def format_answer(detail: Dict[str, Any], ask_id: str, answers: List[Dict[str, Any]]) -> List[str]:
    """The same lines as any mailbox client: header, one line per answer, last seq."""
    item = detail.get("item") if isinstance(detail.get("item"), dict) else {}
    events = detail.get("events") if isinstance(detail.get("events"), list) else []
    lines = [f"[{item.get('projectId') or ''}] {item.get('title') or ask_id}"]
    for event in answers:
        if event.get("kind") == "answer":
            body = parse_answer(event)
            if body is not None:
                value = answer_value(body)
                lines.append(f"  ↳ owner answer {body['step']}: {value}" if value else f"  ↳ owner answer {body['step']}")
                continue
        text = one_line(event.get("text") or "")
        head = f"  ↳ owner {event.get('kind')} {event.get('at') or ''}"
        lines.append(head + (f": {text}" if text else ""))
    asked = questions(instructable_of(detail))
    if asked:
        open_paths = unanswered(instructable_of(detail), events)
        summary = f"answered {len(asked) - len(open_paths)} of {len(asked)}"
        lines.append(summary + (f"; open: {', '.join(open_paths)}" if open_paths else ""))
    lines.append(f"last seq: {max(_seq(e) for e in events if isinstance(e, dict))}")
    return lines


def _finish(detail: Dict[str, Any], ask_id: str, answers: List[Dict[str, Any]], out: Any) -> int:
    for line in format_answer(detail, ask_id, answers):
        out.write(line + "\n")
    return 0


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
    settling_since: Optional[float] = None     # when the newest answer was first seen
    newest_answer = 0
    last_answers: Optional[Tuple[Dict[str, Any], List[Dict[str, Any]]]] = None
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
                answer_seqs = [_seq(e) for e in answers if e.get("kind") == "answer"]
                if len(answer_seqs) < len(answers):         # reply/resolved/declined/reopened: at once
                    return _finish(detail, ask_id, answers, out)
                if max(answer_seqs) > newest_answer:        # a new answer: the settle starts over
                    newest_answer = max(answer_seqs)
                    settling_since = monotonic()
                last_answers = (detail, answers)
        settled = settling_since is not None and monotonic() - settling_since >= SETTLE_S
        if last_answers is not None and (settled or monotonic() >= deadline):
            return _finish(last_answers[0], ask_id, last_answers[1], out)   # quiet for 10 s, or out of time
        if monotonic() >= deadline:
            err.write(f"no owner answer on {ask_id} within {timeout:g} s\n")
            return TIMEOUT_EXIT
        sleep(min(step, SETTLE_INTERVAL_S) if settling_since is not None else step)
