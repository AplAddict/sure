"""The JSON Schema subset validator."""

from __future__ import annotations

import unittest

from sure_ai_broker import schema


class TypeTest(unittest.TestCase):
    def test_accepts_matching_simple_types(self):
        cases = [
            ({"type": "string"}, "hello"),
            ({"type": "integer"}, 7),
            ({"type": "number"}, 7.5),
            ({"type": "number"}, 7),
            ({"type": "boolean"}, True),
            ({"type": "null"}, None),
            ({"type": "array"}, []),
            ({"type": "object"}, {}),
        ]
        for spec, value in cases:
            with self.subTest(spec=spec, value=value):
                self.assertEqual(schema.validate(spec, value), [])

    def test_rejects_mismatched_simple_types(self):
        cases = [
            ({"type": "string"}, 1),
            ({"type": "integer"}, "1"),
            ({"type": "integer"}, 1.5),
            ({"type": "number"}, "1"),
            ({"type": "boolean"}, "true"),
            ({"type": "object"}, []),
            ({"type": "array"}, {}),
            ({"type": "null"}, 0),
        ]
        for spec, value in cases:
            with self.subTest(spec=spec, value=value):
                self.assertTrue(schema.validate(spec, value))

    def test_booleans_are_not_integers(self):
        self.assertTrue(schema.validate({"type": "integer"}, True))
        self.assertTrue(schema.validate({"type": "number"}, False))

    def test_union_types(self):
        spec = {"type": ["string", "null"]}
        self.assertEqual(schema.validate(spec, "x"), [])
        self.assertEqual(schema.validate(spec, None), [])
        self.assertTrue(schema.validate(spec, 3))

    def test_unknown_type_name_fails_closed(self):
        self.assertTrue(schema.validate({"type": "money"}, "whatever"))
        self.assertIsNotNone(schema.unsupported_reason({"type": "money"}))

    def test_one_of_requires_exactly_one_match(self):
        spec = {"oneOf": [{"type": "integer"}, {"type": "number"}]}
        self.assertTrue(schema.validate(spec, 3))
        self.assertEqual(schema.validate(spec, 2.5), [])

    def test_unique_items_enforced(self):
        spec = {"type": "array", "uniqueItems": True}
        self.assertEqual(schema.validate(spec, [1, 2]), [])
        self.assertTrue(schema.validate(spec, [1, 1]))
        self.assertEqual(schema.validate(spec, [1, True]), [])

    def test_any_of_bomb_is_bounded(self):
        import time

        node = {"type": "string"}
        for _ in range(11):
            node = {"anyOf": [node, node, node]}
        started = time.monotonic()
        errors = schema.validate(node, 1)
        self.assertTrue(errors)
        self.assertLess(time.monotonic() - started, 2.0)

    def test_non_dict_schema_accepts_anything(self):
        self.assertEqual(schema.validate("not-a-schema", {"a": 1}), [])
        self.assertEqual(schema.validate(True, 123), [])
        self.assertTrue(schema.validate(False, 123))


class ObjectTest(unittest.TestCase):
    SPEC = {
        "type": "object",
        "properties": {
            "period": {"type": "string", "enum": ["last_30_days", "last_90_days"]},
            "limit": {"type": "integer", "minimum": 1, "maximum": 100},
        },
        "required": ["period"],
        "additionalProperties": False,
    }

    def test_valid_object(self):
        self.assertEqual(schema.validate(self.SPEC, {"period": "last_30_days", "limit": 5}), [])

    def test_missing_required_property(self):
        errors = schema.validate(self.SPEC, {"limit": 5})
        self.assertTrue(any("required" in error for error in errors))

    def test_additional_property_rejected(self):
        errors = schema.validate(self.SPEC, {"period": "last_30_days", "family_id": 42})
        self.assertTrue(any("family_id" in error for error in errors))

    def test_enum_violation(self):
        self.assertTrue(schema.validate(self.SPEC, {"period": "all_time"}))

    def test_bounds(self):
        self.assertTrue(schema.validate(self.SPEC, {"period": "last_30_days", "limit": 0}))
        self.assertTrue(schema.validate(self.SPEC, {"period": "last_30_days", "limit": 101}))

    def test_additional_properties_as_schema(self):
        spec = {"type": "object", "additionalProperties": {"type": "string"}}
        self.assertEqual(schema.validate(spec, {"a": "x"}), [])
        self.assertTrue(schema.validate(spec, {"a": 1}))

    def test_nested_objects(self):
        spec = {
            "type": "object",
            "properties": {
                "filter": {
                    "type": "object",
                    "properties": {"kind": {"type": "string"}},
                    "required": ["kind"],
                    "additionalProperties": False,
                }
            },
        }
        self.assertEqual(schema.validate(spec, {"filter": {"kind": "expense"}}), [])
        self.assertTrue(schema.validate(spec, {"filter": {"kind": 1}}))
        self.assertTrue(schema.validate(spec, {"filter": {}}))


class ArrayAndStringTest(unittest.TestCase):
    def test_items_schema(self):
        spec = {"type": "array", "items": {"type": "string"}}
        self.assertEqual(schema.validate(spec, ["a", "b"]), [])
        self.assertTrue(schema.validate(spec, ["a", 2]))

    def test_tuple_items(self):
        spec = {"type": "array", "items": [{"type": "string"}, {"type": "integer"}]}
        self.assertEqual(schema.validate(spec, ["a", 1]), [])
        self.assertTrue(schema.validate(spec, ["a", "b"]))

    def test_item_counts(self):
        spec = {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 2}
        self.assertEqual(schema.validate(spec, ["a"]), [])
        self.assertTrue(schema.validate(spec, []))
        self.assertTrue(schema.validate(spec, ["a", "b", "c"]))

    def test_string_lengths(self):
        spec = {"type": "string", "minLength": 2, "maxLength": 4}
        self.assertEqual(schema.validate(spec, "abc"), [])
        self.assertTrue(schema.validate(spec, "a"))
        self.assertTrue(schema.validate(spec, "abcde"))

    def test_exclusive_bounds(self):
        spec = {"type": "number", "exclusiveMinimum": 0, "exclusiveMaximum": 10}
        self.assertEqual(schema.validate(spec, 5), [])
        self.assertTrue(schema.validate(spec, 0))
        self.assertTrue(schema.validate(spec, 10))

    def test_const_and_any_of(self):
        self.assertEqual(schema.validate({"const": "x"}, "x"), [])
        self.assertTrue(schema.validate({"const": "x"}, "y"))
        spec = {"anyOf": [{"type": "string"}, {"type": "integer"}]}
        self.assertEqual(schema.validate(spec, "a"), [])
        self.assertEqual(schema.validate(spec, 1), [])
        self.assertTrue(schema.validate(spec, 1.5))


class RobustnessTest(unittest.TestCase):
    def test_deeply_nested_instance_does_not_recurse_forever(self):
        spec: dict = {"type": "object"}
        node = spec
        for _ in range(40):
            node["properties"] = {"child": {"type": "object"}}
            node = node["properties"]["child"]

        instance: dict = {}
        node_instance = instance
        for _ in range(40):
            node_instance["child"] = {}
            node_instance = node_instance["child"]

        errors = schema.validate(spec, instance)
        self.assertTrue(any("too deep" in error for error in errors))

    def test_error_count_is_capped(self):
        spec = {"type": "object", "additionalProperties": False, "properties": {}}
        instance = {f"key{index}": index for index in range(50)}
        self.assertLessEqual(len(schema.validate(spec, instance)), schema.MAX_ERRORS)


if __name__ == "__main__":
    unittest.main()
