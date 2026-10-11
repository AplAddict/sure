"""A small, dependency-free JSON Schema subset validator.

Only the keywords actually used by Sure's function schemas are implemented:
``type``, ``required``, ``enum``, ``const``, ``properties``,
``additionalProperties``, ``items``, ``minimum``/``maximum`` (and their
exclusive forms), ``minLength``/``maxLength``, ``minItems``/``maxItems`` and
``anyOf``/``oneOf`` as a plain "matches at least one" check.

Unknown keywords are ignored, matching JSON Schema's own rule, so a schema the
validator does not fully understand can never *loosen* the allowlist check that
happens before it: the tool name must already be one the client supplied.
"""

from __future__ import annotations

MAX_ERRORS = 10
MAX_DEPTH = 12
MAX_STEPS = 10_000
MAX_SCHEMA_NODES = 5_000

# Keywords the validator enforces, plus pure annotations that never constrain a value.
ENFORCED_KEYWORDS = frozenset({
    "type", "required", "enum", "const", "properties", "additionalProperties", "items",
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength",
    "minItems", "maxItems", "uniqueItems", "anyOf", "oneOf",
})
ANNOTATION_KEYWORDS = frozenset({"description", "title", "default", "examples", "$schema", "$comment"})
KNOWN_TYPES = frozenset({"object", "array", "string", "boolean", "null", "integer", "number"})


def unsupported_reason(schema) -> str | None:
    """Return why ``schema`` cannot be enforced exactly, or ``None`` if it can.

    The broker fails closed on schemas it cannot fully enforce (``$ref``, ``allOf``,
    ``not``, ``pattern`` ...), on over-deep or over-large schemas, and on unknown
    type names, so a tool is never left with weaker argument checks than declared.
    """
    budget = [MAX_SCHEMA_NODES]
    return _unsupported(schema, 0, budget)


def _unsupported(schema, depth: int, budget: list[int]) -> str | None:
    budget[0] -= 1
    if budget[0] < 0:
        return "schema is too large"
    if depth > MAX_DEPTH:
        return "schema is nested too deeply"
    if schema is True or schema is None or schema is False:
        return None
    if not isinstance(schema, dict):
        return "schema must be an object"
    for keyword in schema:
        if keyword not in ENFORCED_KEYWORDS and keyword not in ANNOTATION_KEYWORDS:
            return f"unsupported schema keyword '{keyword}'"
    declared = schema.get("type")
    names = [declared] if isinstance(declared, str) else declared if isinstance(declared, list) else []
    if any(name not in KNOWN_TYPES for name in names):
        return "unknown schema type"
    properties = schema.get("properties")
    if isinstance(properties, dict):
        for child in properties.values():
            reason = _unsupported(child, depth + 1, budget)
            if reason:
                return reason
    additional = schema.get("additionalProperties")
    if isinstance(additional, dict):
        reason = _unsupported(additional, depth + 1, budget)
        if reason:
            return reason
    items = schema.get("items")
    for child in (items if isinstance(items, list) else [items] if items is not None else []):
        reason = _unsupported(child, depth + 1, budget)
        if reason:
            return reason
    for keyword in ("anyOf", "oneOf"):
        branches = schema.get(keyword)
        if isinstance(branches, list):
            for child in branches:
                reason = _unsupported(child, depth + 1, budget)
                if reason:
                    return reason
    return None

_SIMPLE_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "null": type(None),
}


def json_key(value) -> str:
    """Canonical string for comparing JSON values (1 != true, key order ignored)."""
    import json

    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _type_matches(expected: str, value) -> bool:
    if expected == "integer":
        # bool is a subclass of int in Python; JSON Schema treats them apart.
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    python_type = _SIMPLE_TYPES.get(expected)
    if python_type is None:
        # Unknown type names are rejected up front by ``unsupported_reason``;
        # reaching here means an unreadable schema, so fail closed.
        return False
    return isinstance(value, python_type)


def validate(schema, instance, *, path: str = "arguments") -> list[str]:
    """Validate ``instance`` against ``schema``.

    :param schema: JSON-Schema-ish dict (a non-dict schema validates anything)
    :param instance: decoded JSON value
    :param path: dotted path used in error messages
    :return: a list of human-readable errors, empty when valid
    """
    errors: list[str] = []
    budget = [MAX_STEPS]
    _validate(schema, instance, path, errors, 0, budget)
    return errors[:MAX_ERRORS]


def _validate(schema, instance, path: str, errors: list[str], depth: int, budget: list[int]) -> None:
    budget[0] -= 1
    if budget[0] < 0:
        if not errors or errors[-1] != "arguments: schema too complex":
            errors.append("arguments: schema too complex")
        return
    if len(errors) >= MAX_ERRORS:
        return
    if depth > MAX_DEPTH:
        errors.append(f"{path}: schema nesting too deep")
        return
    if schema is True or schema is None:
        return
    if schema is False:
        errors.append(f"{path}: value is not allowed")
        return
    if not isinstance(schema, dict):
        return

    expected_type = schema.get("type")
    if isinstance(expected_type, str):
        if not _type_matches(expected_type, instance):
            errors.append(f"{path}: expected type {expected_type}")
            return
    elif isinstance(expected_type, list) and expected_type:
        if not any(_type_matches(candidate, instance) for candidate in expected_type):
            errors.append(f"{path}: expected one of types {', '.join(map(str, expected_type))}")
            return

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: value must equal the schema constant")

    choices = schema.get("enum")
    if isinstance(choices, list) and choices:
        if not any(instance == choice for choice in choices):
            errors.append(f"{path}: value is not one of the allowed options")

    for keyword in ("anyOf", "oneOf"):
        branches = schema.get(keyword)
        if isinstance(branches, list) and branches:
            matches = 0
            for branch in branches:
                if not _branch_errors(branch, instance, path, depth, budget):
                    matches += 1
                if budget[0] < 0:
                    break
            if matches == 0 or (keyword == "oneOf" and matches != 1):
                errors.append(f"{path}: value does not match the allowed schema")

    if isinstance(instance, dict):
        _validate_object(schema, instance, path, errors, depth, budget)
    elif isinstance(instance, list):
        _validate_array(schema, instance, path, errors, depth, budget)
    elif isinstance(instance, str):
        _validate_string(schema, instance, path, errors)
    elif isinstance(instance, (int, float)) and not isinstance(instance, bool):
        _validate_number(schema, instance, path, errors)


def _branch_errors(branch, instance, path: str, depth: int, budget: list[int]) -> list[str]:
    nested: list[str] = []
    _validate(branch, instance, path, nested, depth + 1, budget)
    return nested


def _validate_object(schema, instance: dict, path: str, errors: list[str], depth: int, budget: list[int]) -> None:
    required = schema.get("required")
    if isinstance(required, list):
        for name in required:
            if isinstance(name, str) and name not in instance:
                errors.append(f"{path}: missing required property '{name}'")

    properties = schema.get("properties")
    properties = properties if isinstance(properties, dict) else {}

    additional = schema.get("additionalProperties", True)
    if additional is False:
        unexpected = sorted(set(instance) - set(properties))
        for name in unexpected:
            errors.append(f"{path}: unexpected property '{name}'")

    for name, value in instance.items():
        if len(errors) >= MAX_ERRORS:
            return
        child_path = f"{path}.{name}"
        if name in properties:
            _validate(properties[name], value, child_path, errors, depth + 1, budget)
        elif isinstance(additional, dict):
            _validate(additional, value, child_path, errors, depth + 1, budget)


def _validate_array(schema, instance: list, path: str, errors: list[str], depth: int, budget: list[int]) -> None:
    min_items = schema.get("minItems")
    if isinstance(min_items, int) and len(instance) < min_items:
        errors.append(f"{path}: expected at least {min_items} items")
    max_items = schema.get("maxItems")
    if isinstance(max_items, int) and len(instance) > max_items:
        errors.append(f"{path}: expected at most {max_items} items")

    if schema.get("uniqueItems") is True:
        seen = [json_key(value) for value in instance]
        if len(set(seen)) != len(seen):
            errors.append(f"{path}: items must be unique")

    items = schema.get("items")
    if isinstance(items, list):
        for index, (item_schema, value) in enumerate(zip(items, instance)):
            _validate(item_schema, value, f"{path}[{index}]", errors, depth + 1, budget)
    elif items is not None:
        for index, value in enumerate(instance):
            if len(errors) >= MAX_ERRORS:
                return
            _validate(items, value, f"{path}[{index}]", errors, depth + 1, budget)


def _validate_string(schema, instance: str, path: str, errors: list[str]) -> None:
    min_length = schema.get("minLength")
    if isinstance(min_length, int) and len(instance) < min_length:
        errors.append(f"{path}: expected at least {min_length} characters")
    max_length = schema.get("maxLength")
    if isinstance(max_length, int) and len(instance) > max_length:
        errors.append(f"{path}: expected at most {max_length} characters")


def _validate_number(schema, instance, path: str, errors: list[str]) -> None:
    minimum = schema.get("minimum")
    if isinstance(minimum, (int, float)) and not isinstance(minimum, bool):
        if instance < minimum:
            errors.append(f"{path}: must be >= {minimum}")
    maximum = schema.get("maximum")
    if isinstance(maximum, (int, float)) and not isinstance(maximum, bool):
        if instance > maximum:
            errors.append(f"{path}: must be <= {maximum}")
    exclusive_min = schema.get("exclusiveMinimum")
    if isinstance(exclusive_min, (int, float)) and not isinstance(exclusive_min, bool):
        if instance <= exclusive_min:
            errors.append(f"{path}: must be > {exclusive_min}")
    exclusive_max = schema.get("exclusiveMaximum")
    if isinstance(exclusive_max, (int, float)) and not isinstance(exclusive_max, bool):
        if instance >= exclusive_max:
            errors.append(f"{path}: must be < {exclusive_max}")
