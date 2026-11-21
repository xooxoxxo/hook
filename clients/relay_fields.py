"""A step's `fields` (a settings table) for a Pond that can't take it.

A Pond that lists `fields` in GET /version's `features` takes a step's settings table as it
is: rows of {"label", "value", "copy"?} that Hook shows under the step's `do`. An older Pond
refuses the key, so before sending, relay post, amend and append (and the MCP tools) turn
each row into a sub-step instead: the label as `do`, the value as `code`, `lang` "text".
Nothing is lost: every value stays copyable.

Where the rows go:
- On a step, they come first among its sub-steps, in order, before any it already has.
- On a sub-step (which can't have sub-steps), they come right after it, as its siblings.

Step ids stay stable. A step or sub-step keeps the id it was given. When a post gives no ids
at all, every step first gets the id the Pond would give it by position (s1, s3.1), so the
rows don't shift them. A row's sub-step is "<id of its step>-f<n>" (n from 1), or, when
that is taken or longer than 24 characters, the first free "f<k>". A row of a step with no
id (a new step in a correction or an append) gets no id, and the Pond names it.

Standard library only, Python 3.9+.
"""
from __future__ import annotations

import copy
import re
from typing import Any, Dict, List, Optional, Set, Tuple

FIELDS_FEATURE = "fields"
MAX_SUBSTEPS = 10
_ID = re.compile(r"[a-z0-9][a-z0-9.-]{0,23}")
NOTE = ("the Pond doesn't list the fields feature: {where} sent as sub-steps "
        "(label as do, value as code)")


class FieldsDontFit(ValueError):
    """The rows, as sub-steps, would give a step more than MAX_SUBSTEPS sub-steps."""

    def __init__(self, path: str, count: int):
        self.path, self.count = path, count
        super().__init__(f"{path}.fields: the Pond doesn't list the fields feature, and as sub-steps "
                         f"these rows would give the step {count} sub-steps (at most {MAX_SUBSTEPS}): "
                         "split the step, or put fewer rows on it")


def has_fields(holder: Any) -> bool:
    """Does any step or sub-step of holder ({"steps": [...]}) carry a non-null `fields`?"""
    steps = holder.get("steps") if isinstance(holder, dict) else None
    for step in steps if isinstance(steps, list) else []:
        if not isinstance(step, dict):
            continue
        if step.get("fields") is not None:
            return True
        subs = step.get("substeps")
        if isinstance(subs, list) and any(isinstance(s, dict) and s.get("fields") is not None for s in subs):
            return True
    return False


def _rows(fields: Any) -> List[Dict[str, Any]]:
    return [row for row in fields if isinstance(row, dict)] if isinstance(fields, list) else []


def _every_id(steps: List[Any]) -> Set[str]:
    found: Set[str] = set()
    for step in steps:
        if not isinstance(step, dict):
            continue
        if isinstance(step.get("id"), str):
            found.add(step["id"])
        for sub in step.get("substeps") if isinstance(step.get("substeps"), list) else []:
            if isinstance(sub, dict) and isinstance(sub.get("id"), str):
                found.add(sub["id"])
    return found


def _no_ids(steps: List[Any]) -> bool:
    """No step or sub-step has an id (null counts as none)."""
    for step in steps:
        if not isinstance(step, dict):
            continue
        subs = step.get("substeps") if isinstance(step.get("substeps"), list) else []
        if any(isinstance(node, dict) and node.get("id") is not None for node in [step, *subs]):
            return False
    return True


def _number(steps: List[Any]) -> None:
    """Give every step and sub-step the id the Pond gives by position: s1, s3.1."""
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        step["id"] = f"s{i + 1}"
        subs = step.get("substeps")
        for j, sub in enumerate(subs if isinstance(subs, list) else []):
            if isinstance(sub, dict):
                sub["id"] = f"s{i + 1}.{j + 1}"


def _row_id(host: Any, n: int, taken: Set[str]) -> Optional[str]:
    if not isinstance(host, str):
        return None
    candidate = f"{host}-f{n}"
    if _ID.fullmatch(candidate) and candidate not in taken:
        taken.add(candidate)
        return candidate
    k = 1
    while f"f{k}" in taken:
        k += 1
    taken.add(f"f{k}")
    return f"f{k}"


def _row_step(row: Dict[str, Any], row_id: Optional[str]) -> Dict[str, Any]:
    out: Dict[str, Any] = {"do": row.get("label"), "code": row.get("value"), "lang": "text"}
    if row_id is not None:
        out["id"] = row_id
    return out


def rows_as_substeps(holder: Dict[str, Any], *, number: bool = False) -> Tuple[Dict[str, Any], List[str]]:
    """A copy of holder ({"steps": [...]} or a whole instructable) with every `fields` turned
    into sub-steps as the module docstring says, and the paths of the steps whose rows moved
    ("steps[0]", "steps[2].substeps[1]"). `number`: this is a post, so when no step has an id,
    every step first gets its positional id. A step whose rows don't fit raises FieldsDontFit.
    The input is never mutated; a `fields` of null is dropped."""
    out = copy.deepcopy(holder)
    steps = out.get("steps") if isinstance(out.get("steps"), list) else []
    if not has_fields(out):
        return out, []
    if number and _no_ids(steps):
        _number(steps)
    taken = _every_id(steps)
    moved: List[str] = []
    for i, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        path = f"steps[{i}]"
        subs = step.get("substeps") if isinstance(step.get("substeps"), list) else None
        new_subs: List[Any] = []
        own = _rows(step.pop("fields", None))
        if own:
            moved.append(path)
            new_subs += [_row_step(row, _row_id(step.get("id"), n, taken)) for n, row in enumerate(own, 1)]
        for j, sub in enumerate(subs or []):
            new_subs.append(sub)
            if not isinstance(sub, dict):
                continue
            rows = _rows(sub.pop("fields", None))
            if rows:
                moved.append(f"{path}.substeps[{j}]")
                new_subs += [_row_step(row, _row_id(sub.get("id"), n, taken)) for n, row in enumerate(rows, 1)]
        if subs is None and not own:
            continue
        if len(new_subs) > MAX_SUBSTEPS:
            raise FieldsDontFit(path, len(new_subs))
        step["substeps"] = new_subs
    return out, moved


def fallback_note(moved: List[str]) -> str:
    """The note relay post, amend and append print when rows were sent as sub-steps."""
    where = (f"the settings of {moved[0]} were" if len(moved) == 1
             else "the settings of " + ", ".join(moved) + " were")
    return NOTE.format(where=where)
