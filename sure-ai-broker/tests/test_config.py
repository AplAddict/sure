"""Configuration, bind refusal and token-file hygiene."""

from __future__ import annotations

import json
import os
import unittest
from dataclasses import replace

from sure_ai_broker.config import (
    Config,
    ConfigError,
    load_config,
    read_token_file,
    validate_bind_host,
)

import support


class BindRefusalTest(unittest.TestCase):
    def test_wildcard_hosts_are_refused_by_default(self):
        for host in ("0.0.0.0", "::", "[::]", "", "*"):
            with self.subTest(host=host):
                with self.assertRaises(ConfigError):
                    validate_bind_host(host, allow_wildcard=False)

    def test_wildcard_host_allowed_only_with_explicit_opt_in(self):
        validate_bind_host("0.0.0.0", allow_wildcard=True)

    def test_private_hosts_are_accepted(self):
        for host in ("127.0.0.1", "::1", "10.1.2.3", "192.168.5.6"):
            with self.subTest(host=host):
                validate_bind_host(host, allow_wildcard=False)

    def test_config_validate_refuses_wildcard_bind(self):
        config = support.make_config(self, bind_host="0.0.0.0")
        with self.assertRaises(ConfigError):
            config.validate()

    def test_config_validate_accepts_wildcard_with_flag(self):
        config = support.make_config(self, bind_host="0.0.0.0", allow_wildcard_bind=True)
        config.validate()

    def test_port_must_be_in_range(self):
        for port in (0, 70000):
            with self.subTest(port=port):
                with self.assertRaises(ConfigError):
                    support.make_config(self, bind_port=port).validate()

    def test_token_file_is_required(self):
        with self.assertRaises(ConfigError):
            replace(support.make_config(self), token_file="").validate()


class TokenFileTest(unittest.TestCase):
    def test_reads_a_mode_600_file(self):
        path = support.token_file(self)
        self.assertEqual(read_token_file(path), support.FAKE_CLIENT_TOKEN)

    def test_missing_file_is_refused(self):
        missing = os.path.join(support.temp_dir(self), "nope.token")
        with self.assertRaises(ConfigError):
            read_token_file(missing)

    def test_group_or_world_accessible_file_is_refused(self):
        for mode in (0o644, 0o640, 0o604, 0o666):
            with self.subTest(mode=oct(mode)):
                path = support.token_file(self, mode=mode)
                with self.assertRaises(ConfigError):
                    read_token_file(path)

    def test_short_token_is_refused(self):
        path = support.token_file(self, "too-short")
        with self.assertRaises(ConfigError):
            read_token_file(path)

    def test_directory_is_refused(self):
        with self.assertRaises(ConfigError):
            read_token_file(support.temp_dir(self))

    def test_empty_path_is_refused(self):
        with self.assertRaises(ConfigError):
            read_token_file("")

    def test_error_message_never_contains_the_secret(self):
        path = support.token_file(self, "short-but-present")
        with self.assertRaises(ConfigError) as caught:
            read_token_file(path)
        self.assertNotIn("short-but-present", str(caught.exception))


class LoadConfigTest(unittest.TestCase):
    def test_defaults_are_private_and_fail_closed(self):
        config = load_config(env={})
        self.assertEqual(config.bind_host, "127.0.0.1")
        self.assertFalse(config.allow_wildcard_bind)
        self.assertEqual(config.token_file, "")
        self.assertEqual(config.max_tool_calls_per_turn, 4)
        self.assertEqual(config.max_tool_rounds, 6)

    def test_environment_overrides_and_coerces(self):
        config = load_config(
            env={
                "BROKER_BIND_PORT": "9001",
                "BROKER_ALLOW_WILDCARD_BIND": "1",
                "BROKER_UPSTREAM_TIMEOUT": "12.5",
                "BROKER_MODEL_ID": "sure-ai-broker",
            }
        )
        self.assertEqual(config.bind_port, 9001)
        self.assertTrue(config.allow_wildcard_bind)
        self.assertAlmostEqual(config.upstream_timeout, 12.5)
        self.assertEqual(config.model_id, "sure-ai-broker")

    def test_bad_integer_is_refused(self):
        with self.assertRaises(ConfigError):
            load_config(env={"BROKER_BIND_PORT": "not-a-port"})

    def test_config_file_is_read_and_environment_wins(self):
        directory = support.temp_dir(self)
        path = os.path.join(directory, "broker.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"bind_port": 9100, "upstream_model": "fake-text-model"}, handle)
        config = load_config(env={"BROKER_CONFIG_FILE": path, "BROKER_BIND_PORT": "9200"})
        self.assertEqual(config.bind_port, 9200)
        self.assertEqual(config.upstream_model, "fake-text-model")

    def test_unknown_config_keys_are_refused(self):
        directory = support.temp_dir(self)
        path = os.path.join(directory, "broker.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"upstream_api_key": "nope"}, handle)
        with self.assertRaises(ConfigError):
            load_config(env={"BROKER_CONFIG_FILE": path})

    def test_missing_config_file_is_refused(self):
        with self.assertRaises(ConfigError):
            load_config(env={"BROKER_CONFIG_FILE": "/nonexistent/broker.json"})


class UpstreamConfigTest(unittest.TestCase):
    def _config(self, **overrides) -> Config:
        directory = support.temp_dir(self)
        return support.make_config(
            self,
            upstream_base_url="https://reasoner.invalid/v1",
            upstream_token_file=support.write_secret_file(
                directory, "upstream.token", support.FAKE_UPSTREAM_TOKEN
            ),
            **overrides,
        )

    def test_valid_upstream_config(self):
        self._config().validate_upstream()

    def test_base_url_is_required(self):
        with self.assertRaises(ConfigError):
            replace(self._config(), upstream_base_url="").validate_upstream()

    def test_non_http_scheme_is_refused(self):
        with self.assertRaises(ConfigError):
            replace(self._config(), upstream_base_url="file:///etc/passwd").validate_upstream()

    def test_plaintext_http_to_remote_host_is_refused(self):
        with self.assertRaises(ConfigError):
            replace(self._config(), upstream_base_url="http://reasoner.invalid/v1").validate_upstream()

    def test_plaintext_http_to_loopback_is_allowed(self):
        replace(self._config(), upstream_base_url="http://127.0.0.1:9999/v1").validate_upstream()

    def test_upstream_token_file_is_required(self):
        with self.assertRaises(ConfigError):
            replace(self._config(), upstream_token_file="").validate_upstream()


if __name__ == "__main__":
    unittest.main()
