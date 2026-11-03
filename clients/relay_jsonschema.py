"""A small JSON Schema validator for the subset Hook's own schemas use. Standard library only.

Supported: $ref (to "#" or "#/$defs/<name>"), $defs, type (a name or a list of names), const,
enum, properties, required, additionalProperties (false or a schema), items, minItems,
maxItems, uniqueItems, oneOf, anyOf, pattern, minLength and maxLength. Annotations ($schema,
$id, $comment, title, description, default, examples) are ignored. Any other keyword raises
SchemaError, so a schema never asks for a check this validator would silently skip.

    validate(value, schema) -> ["$.path: message", ...]     # [] when value is valid
"""
from __future__ import annotations

import json
import re
from typing import Any, Dict, List

ANNOTATIONS = frozenset({"$schema", "$id", "$comment", "$defs", "title", "description", "default", "examples"})
ASSERTIONS = frozenset({
    "$ref", "type", "const", "enum", "properties", "required", "additionalProperties", "items",
    "minItems", "maxItems", "uniqueItems", "oneOf", "anyOf", "pattern", "minLength", "maxLength",
})


class SchemaError(Exception):
    """The schema itself uses something this validator doesn't support."""


def _is_type(value: Any, kind: str) -> bool:
    if kind == "null":
        return value is None
    if kind == "boolean":
        return isinstance(value, bool)
    if kind == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if kind == "string":
        return isinstance(value, str)
    if kind == "array":
        return isinstance(value, list)
    if kind == "object":
        return isinstance(value, dict)
    raise SchemaError(f"unknown type {kind!r}")


def _canonical(value: Any) -> str:
    """A form in which equal JSON values compare equal and true never equals 1."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _equal(a: Any, b: Any) -> bool:
    return _canonical(a) == _canonical(b)


def _resolve(ref: str, root: Dict[str, Any]) -> Dict[str, Any]:
    if ref == "#":
        return root
    prefix = "#/$defs/"
    if not ref.startswith(prefix) or ref[len(prefix):] not in root.get("$defs", {}):
        raise SchemaError(f"unsupported or unknown $ref {ref!r}")
    return root["$defs"][ref[len(prefix):]]


def _tag_matches(value: Any, option: Any, root: Dict[str, Any]) -> bool:
    """True when option (through a $ref) has const properties and value carries every one."""
    while isinstance(option, dict) and set(option) - ANNOTATIONS == {"$ref"}:
        option = _resolve(option["$ref"], root)
    if not isinstance(value, dict) or not isinstance(option, dict):
        return False
    consts = {k: s["const"] for k, s in option.get("properties", {}).items() if isinstance(s, dict) and "const" in s}
    return bool(consts) and all(k in value and _equal(value[k], c) for k, c in consts.items())


def _check(value: Any, schema: Any, root: Dict[str, Any], path: str, errors: List[str]) -> None:
    if schema is True:
        return
    if schema is False:
        errors.append(f"{path}: not allowed")
        return
    if not isinstance(schema, dict):
        raise SchemaError(f"a schema must be an object or a boolean, not {schema!r}")
    unknown = set(schema) - ANNOTATIONS - ASSERTIONS
    if unknown:
        raise SchemaError(f"unsupported keyword(s) {sorted(unknown)}")

    if "$ref" in schema:
        _check(value, _resolve(schema["$ref"], root), root, path, errors)
    if "type" in schema:
        kinds = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, k) for k in kinds):
            errors.append(f"{path}: must be {' or '.join(kinds)}")
            return
    if "const" in schema and not _equal(value, schema["const"]):
        errors.append(f"{path}: must be {json.dumps(schema['const'])}")
    if "enum" in schema and not any(_equal(value, option) for option in schema["enum"]):
        errors.append(f"{path}: must be one of {json.dumps(schema['enum'])}")

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}.{key}: required")
        extra = schema.get("additionalProperties", True)
        for key, sub in value.items():
            if key in props:
                _check(sub, props[key], root, f"{path}.{key}", errors)
            elif extra is False:
                errors.append(f"{path}.{key}: unknown key")
            elif extra is not True:
                _check(sub, extra, root, f"{path}.{key}", errors)

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: at least {schema['minItems']} item(s)")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path}: at most {schema['maxItems']} item(s)")
        if schema.get("uniqueItems") and len({_canonical(v) for v in value}) != len(value):
            errors.append(f"{path}: items must be unique")
        if "items" in schema:
            for i, item in enumerate(value):
                _check(item, schema["items"], root, f"{path}[{i}]", errors)

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: at least {schema['minLength']} character(s)")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: at most {schema['maxLength']} character(s)")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: must match {schema['pattern']}")

    for keyword in ("oneOf", "anyOf"):
        if keyword not in schema:
            continue
        trials = []
        for option in schema[keyword]:
            trial: List[str] = []
            _check(value, option, root, path, trial)
            trials.append(trial)
        matches = sum(1 for t in trials if not t)
        if keyword == "oneOf" and matches > 1:
            errors.append(f"{path}: matches {matches} of oneOf, must match exactly one")
        elif matches == 0:
            # The closest option's errors say what to fix: for a tagged union (options told
            # apart by a const property), the option whose tag the value carries.
            errors.append(f"{path}: matches none of {keyword}")
            tagged = [t for option, t in zip(schema[keyword], trials) if _tag_matches(value, option, root)]
            errors.extend(min(tagged or trials, key=len))


def validate(value: Any, schema: Dict[str, Any]) -> List[str]:
    """The error paths of value against schema, as "$.a[0].b: message" lines; [] when valid."""
    errors: List[str] = []
    _check(value, schema, schema, "$", errors)
    return errors
