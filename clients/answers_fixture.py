"""The shared step-answers test instructable and event helpers. Test support only."""
from __future__ import annotations

import json
from pathlib import Path

ASK_ID = "0b8f3f0e-6c1a-4e0b-9a51-2f4f1d9c7a10"

# The instructable the app's Swift tests and the mailbox share (answers-vectors.json), so the
# clients are tested against the same questions.
_VECTORS = Path(__file__).resolve().parent.parent / "Tests" / "RelayCoreTests" / "Fixtures" / "answers-vectors.json"
INSTRUCTABLE = json.loads(_VECTORS.read_text("utf-8"))["instructable"]

ITEM = {"id": ASK_ID, "projectId": "Acme", "title": "Ship the Atlas release", "status": "open",
        "payload": {"instructable": INSTRUCTABLE}}


def answer(seq, step, picked=None, text=None, actor="owner"):
    body = {"step": step}
    body.update({"picked": picked} if picked is not None else {"text": text})
    return {"seq": seq, "itemId": ASK_ID, "kind": "answer", "actor": actor,
            "text": json.dumps(body, ensure_ascii=False, separators=(",", ":")),
            "at": f"2026-10-11T09:{seq:02d}:00+00:00"}


def event(seq, kind, actor, text=None):
    return {"seq": seq, "itemId": ASK_ID, "kind": kind, "actor": actor, "text": text,
            "at": f"2026-10-11T09:{seq:02d}:00+00:00"}


def detail(*events):
    return {"item": dict(ITEM), "events": list(events)}
