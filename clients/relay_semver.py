"""Semver versions and npm-style ranges, for the Pond version gates.

The Pond is versioned by semver; a Hook release names the Pond range it needs, and each
feature gate names the first Pond version that has the feature. Old Ponds have a dated
`version` ("2026.10.27.1") and are read by their `protocol` integer instead.
The same rules as RelayCore's Semver.swift, held to Tests/RelayCoreTests/Fixtures/semver-vectors.json.
Not named semver.py, so it can't shadow an installed package. Standard library only; Python 3.9+.
"""
from __future__ import annotations

import re
from typing import Any, List, NamedTuple, Optional, Tuple

_NUM = r"(?:0|[1-9][0-9]*)"
_PRE_ID = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
_VERSION = re.compile(
    rf"({_NUM})\.({_NUM})\.({_NUM})(?:-({_PRE_ID}(?:\.{_PRE_ID})*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")
_COMPARATOR = re.compile(r"(\^|~|>=|>|<=|<|=)?(.*)", re.DOTALL)

FITS = ("satisfies", "below", "above", "newerMajor")


def _compare_pre(a: Tuple[str, ...], b: Tuple[str, ...]) -> int:
    """Semver 2.0.0 §11: no pre-release ranks above any; numeric ids compare numerically
    and below alphanumeric ones; a shorter list of equal ids ranks lower."""
    if not a or not b:
        return (len(b) > 0) - (len(a) > 0)
    for x, y in zip(a, b):
        if x == y:
            continue
        xn, yn = x.isdigit(), y.isdigit()
        if xn and yn:
            return -1 if int(x) < int(y) else 1
        if xn != yn:
            return -1 if xn else 1
        return -1 if x < y else 1
    return (len(a) > len(b)) - (len(a) < len(b))


class Version(NamedTuple):
    major: int
    minor: int
    patch: int
    prerelease: Tuple[str, ...] = ()

    def __str__(self) -> str:
        core = f"{self.major}.{self.minor}.{self.patch}"
        return core + ("-" + ".".join(self.prerelease) if self.prerelease else "")

    def __lt__(self, other: Any) -> bool:  # type: ignore[override]
        return compare(self, other) < 0

    def __le__(self, other: Any) -> bool:  # type: ignore[override]
        return compare(self, other) <= 0

    def __gt__(self, other: Any) -> bool:  # type: ignore[override]
        return compare(self, other) > 0

    def __ge__(self, other: Any) -> bool:  # type: ignore[override]
        return compare(self, other) >= 0


def compare(a: Version, b: Version) -> int:
    """-1, 0 or 1 by semver precedence (build metadata is already dropped)."""
    core_a, core_b = (a.major, a.minor, a.patch), (b.major, b.minor, b.patch)
    if core_a != core_b:
        return -1 if core_a < core_b else 1
    return _compare_pre(tuple(a.prerelease), tuple(b.prerelease))


def parse_version(text: Any) -> Optional[Version]:
    """A strict semver version, or None: MAJOR.MINOR.PATCH, an optional -pre.release and an
    optional +build (ignored). No leading zeros, no `v`, no partial versions, ASCII digits only."""
    if not isinstance(text, str):
        return None
    m = _VERSION.fullmatch(text)
    if m is None:
        return None
    pre = tuple(m.group(4).split(".")) if m.group(4) else ()
    return Version(int(m.group(1)), int(m.group(2)), int(m.group(3)), pre)


class Range:
    """Sets joined by ||; a set's comparators must all hold. Each comparator is (op, version),
    op one of >=, >, <=, <, =."""

    def __init__(self, text: str, sets: List[List[Tuple[str, Version]]]) -> None:
        self.text = text
        self.sets = sets

    def __repr__(self) -> str:
        return f"Range({self.text!r})"

    def __str__(self) -> str:
        return self.text

    @staticmethod
    def _holds(op: str, v: Version, bound: Version) -> bool:
        c = compare(v, bound)
        return {">=": c >= 0, ">": c > 0, "<=": c <= 0, "<": c < 0, "=": c == 0}[op]

    def _set_contains(self, comparators: List[Tuple[str, Version]], v: Version) -> bool:
        if not all(self._holds(op, v, bound) for op, bound in comparators):
            return False
        if not v.prerelease:
            return True
        # The npm rule: a pre-release only matches a set that names its MAJOR.MINOR.PATCH
        # with a pre-release, so ^1.1.0 never picks up 1.2.0-rc.1.
        return any(bound.prerelease and bound[:3] == v[:3] for _, bound in comparators)

    def contains(self, v: Version) -> bool:
        return any(self._set_contains(s, v) for s in self.sets)

    @staticmethod
    def _lower(comparators: List[Tuple[str, Version]]) -> Tuple[Version, bool]:
        """A set's lower bound (version, inclusive); 0.0.0 inclusive when it names none."""
        best, inclusive = Version(0, 0, 0), True
        for op, bound in comparators:
            if op not in (">=", ">", "="):
                continue
            c = compare(bound, best)
            if c > 0 or (c == 0 and op == ">"):
                best, inclusive = bound, op != ">"
        return best, inclusive

    def fit(self, v: Version) -> str:
        """satisfies; below (under every set's lower bound); newerMajor (a major above every set's
        lower-bound major); else above (same major, past an upper bound)."""
        if self.contains(v):
            return "satisfies"
        lows = [self._lower(s) for s in self.sets]
        if all(compare(v, low) < 0 or (compare(v, low) == 0 and not inclusive) for low, inclusive in lows):
            return "below"
        if all(v.major > low.major for low, _ in lows):
            return "newerMajor"
        return "above"


def _caret_upper(v: Version) -> Version:
    if v.major > 0:
        return Version(v.major + 1, 0, 0)
    if v.minor > 0:
        return Version(0, v.minor + 1, 0)
    return Version(0, 0, v.patch + 1)


def parse_range(text: Any) -> Range:
    """^V, ~V, >=V, >V, <=V, <V, =V or a bare V (exact), V strict; comparators separated by
    spaces, sets by ||. Partial versions, x-ranges, * and hyphen ranges are refused.
    Raises ValueError("invalid range: <the bad part>")."""
    if not isinstance(text, str):
        raise ValueError("invalid range: not a string")
    sets: List[List[Tuple[str, Version]]] = []
    for part in text.split("||"):
        tokens = [t for t in part.split(" ") if t]
        if not tokens:
            raise ValueError(f"invalid range: {text.strip() or 'empty'}")
        comparators: List[Tuple[str, Version]] = []
        for token in tokens:
            m = _COMPARATOR.fullmatch(token)
            v = parse_version(m.group(2)) if m else None
            if m is None or v is None:
                raise ValueError(f"invalid range: {token}")
            op = m.group(1)
            if op == "^":
                comparators += [(">=", v), ("<", _caret_upper(v))]
            elif op == "~":
                comparators += [(">=", v), ("<", Version(v.major, v.minor + 1, 0))]
            else:
                comparators.append((op or "=", v))
        sets.append(comparators)
    return Range(text, sets)


def _protocol(info: Any) -> int:
    value = info.get("protocol") if isinstance(info, dict) else None
    if isinstance(value, int) and not isinstance(value, bool) and value >= 1:
        return value
    return 1


def legacy_version(protocol: int) -> Version:
    """An old dated Pond by its protocol: 4 and above was what is now 1.0.0; N below 4 is 0.N.0."""
    return Version(1, 0, 0) if protocol >= 4 else Version(0, protocol, 0)


def pond_version(info: Optional[Any]) -> Tuple[Version, Optional[int]]:
    """(effective version, legacy protocol or None) from a GET /version reply. A strict semver
    `version` is used as it is; anything else is an old Pond read by its integer `protocol`
    (missing or not a whole number >= 1: 1). None, a Pond without /version, is protocol 1."""
    v = parse_version(info.get("version")) if isinstance(info, dict) else None
    if v is not None:
        return v, None
    protocol = _protocol(info)
    return legacy_version(protocol), protocol


def at_least(v: Version, minimum: str) -> bool:
    """For the feature gates: is `v` at or above `minimum`?"""
    return parse_range(">=" + minimum).contains(v)
