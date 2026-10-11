"""The HTTP front end: auth, limits, routing, logging and tenant isolation."""

from __future__ import annotations

import io
import json
import socket
import threading
import unittest
from dataclasses import replace

from sure_ai_broker.config import ConfigError
from sure_ai_broker.server import AccessLog, build_server, main, open_log, serve
from sure_ai_broker.upstream import FakeUpstream

import support


def raw_request(host: str, port: int, payload: bytes, *, timeout: float = 10.0) -> str:
    """Send a hand-built request and return the response status line."""
    with socket.create_connection((host, port), timeout=timeout) as connection:
        connection.sendall(payload)
        chunks = []
        while b"\r\n" not in b"".join(chunks):
            chunk = connection.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks).split(b"\r\n", 1)[0].decode("latin-1")


class StartupRefusalTest(unittest.TestCase):
    def _build(self, config):
        return build_server(
            config, upstream=FakeUpstream(replies=["{}"]), log=AccessLog(io.StringIO())
        )

    def test_wildcard_bind_is_refused_before_the_socket_opens(self):
        config = support.make_config(self, bind_host="0.0.0.0", bind_port=support.free_port())
        with self.assertRaises(ConfigError):
            self._build(config)

    def test_ipv6_wildcard_bind_is_refused(self):
        config = support.make_config(self, bind_host="::", bind_port=support.free_port())
        with self.assertRaises(ConfigError):
            self._build(config)

    def test_world_readable_token_file_is_refused(self):
        config = support.make_config(
            self, token_file=support.token_file(self, mode=0o644), bind_port=support.free_port()
        )
        with self.assertRaises(ConfigError):
            self._build(config)

    def test_short_token_file_is_refused(self):
        config = support.make_config(
            self, token_file=support.token_file(self, "tiny"), bind_port=support.free_port()
        )
        with self.assertRaises(ConfigError):
            self._build(config)

    def test_missing_token_file_is_refused(self):
        config = support.make_config(
            self, token_file="/nonexistent/client.token", bind_port=support.free_port()
        )
        with self.assertRaises(ConfigError):
            self._build(config)

    def test_unwritable_log_file_is_refused(self):
        config = support.make_config(self, log_file="/nonexistent/dir/broker.log")
        with self.assertRaises(ConfigError):
            open_log(config)

    def test_serve_reports_a_configuration_failure(self):
        config = support.make_config(self, bind_host="0.0.0.0")
        self.assertEqual(serve(config), 2)

    def test_main_takes_no_arguments(self):
        self.assertEqual(main(["--token", "fake"]), 2)


class ServerTestCase(unittest.TestCase):
    def start(self, replies=None, *, responder=None, token=None, **config_overrides):
        upstream = FakeUpstream(replies=list(replies or []), responder=responder)
        config = support.make_config(self, **config_overrides)
        running = support.RunningBroker(self, config=config, upstream=upstream, token=token)
        return running, upstream


class HealthTest(ServerTestCase):
    def test_healthz_needs_no_credentials(self):
        running, _ = self.start([support.final_reply("hi")])
        status, body = running.request("/healthz", method="GET", authorization=None)
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")

    def test_healthz_rejects_post(self):
        running, _ = self.start([support.final_reply("hi")])
        status, _ = running.request("/healthz", method="POST", body=b"{}")
        self.assertEqual(status, 405)

    def test_unknown_paths_are_404(self):
        running, _ = self.start([support.final_reply("hi")])
        for path in ("/v1/models", "/", "/v1/embeddings", "/admin"):
            with self.subTest(path=path):
                status, _ = running.request(path, method="GET")
                self.assertEqual(status, 404)

    def test_get_on_the_chat_path_is_405(self):
        running, _ = self.start([support.final_reply("hi")])
        status, _ = running.request("/v1/chat/completions", method="GET")
        self.assertEqual(status, 405)


class AuthTest(ServerTestCase):
    def test_valid_token_is_accepted(self):
        running, _ = self.start([support.final_reply("hello there")])
        status, body = running.post_chat(support.chat_request(tools=support.TOOLS))
        self.assertEqual(status, 200)
        self.assertEqual(body["choices"][0]["message"]["content"], "hello there")

    def test_missing_authorization_is_401(self):
        running, upstream = self.start([support.final_reply("hi")])
        status, body = running.post_chat(support.chat_request(), authorization=None)
        self.assertEqual(status, 401)
        self.assertEqual(body["error"]["code"], "unauthorized")
        self.assertEqual(upstream.calls, [])

    def test_wrong_token_is_401(self):
        running, upstream = self.start([support.final_reply("hi")])
        for header in (
            "Bearer wrong-token-0000000000000000000000000",
            "Bearer ",
            "Basic " + support.FAKE_CLIENT_TOKEN,
            support.FAKE_CLIENT_TOKEN,
            "Bearer " + support.FAKE_CLIENT_TOKEN[:-1],
            "Bearer " + support.FAKE_CLIENT_TOKEN + "x",
        ):
            with self.subTest(header=header[:12]):
                status, body = running.post_chat(
                    support.chat_request(), authorization=header
                )
                self.assertEqual(status, 401)
                self.assertEqual(body["error"]["message"], "unauthorized")
        self.assertEqual(upstream.calls, [])

    def test_unauthorized_response_carries_no_detail(self):
        running, _ = self.start([support.final_reply("hi")])
        _, body = running.post_chat(support.chat_request(), authorization="Bearer nope")
        self.assertEqual(
            body["error"], {"message": "unauthorized", "type": "invalid_request_error",
                            "code": "unauthorized", "param": None}
        )


class LimitTest(ServerTestCase):
    def test_oversized_body_is_413(self):
        running, upstream = self.start([support.final_reply("hi")], max_body_bytes=600)
        payload = support.chat_request(
            messages=[{"role": "user", "content": "x" * 2000}]
        )
        status, body = running.post_chat(payload)
        self.assertEqual(status, 413)
        self.assertEqual(body["error"]["code"], "body_too_large")
        self.assertEqual(upstream.calls, [])

    def test_body_within_the_limit_is_accepted(self):
        running, _ = self.start([support.final_reply("hi")], max_body_bytes=100_000)
        status, _ = running.post_chat(support.chat_request(tools=support.TOOLS))
        self.assertEqual(status, 200)

    def test_invalid_json_is_400(self):
        running, _ = self.start([support.final_reply("hi")])
        status, body = running.request(
            "/v1/chat/completions", method="POST", body=b"{not json"
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "invalid_json")

    def test_streaming_is_rejected_with_400(self):
        running, upstream = self.start([support.final_reply("hi")])
        status, body = running.post_chat(
            support.chat_request(tools=support.TOOLS, extra={"stream": True})
        )
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "stream_unsupported")
        self.assertEqual(upstream.calls, [])

    def test_too_many_messages_is_rejected(self):
        running, _ = self.start([support.final_reply("hi")], max_messages=2)
        payload = support.chat_request(
            messages=[{"role": "user", "content": "a"} for _ in range(3)]
        )
        status, body = running.post_chat(payload)
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "too_many_messages")

    def test_too_many_tools_is_rejected(self):
        running, _ = self.start([support.final_reply("hi")], max_tools=1)
        status, body = running.post_chat(support.chat_request(tools=support.TOOLS))
        self.assertEqual(body["error"]["code"], "too_many_tools")
        self.assertEqual(status, 400)

    def test_missing_content_length_is_411(self):
        running, _ = self.start([support.final_reply("hi")])
        request = (
            b"POST /v1/chat/completions HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Authorization: Bearer " + support.FAKE_CLIENT_TOKEN.encode() + b"\r\n"
            b"Connection: close\r\n\r\n"
        )
        status_line = raw_request("127.0.0.1", running.config.bind_port, request)
        self.assertIn("411", status_line)

    def test_unparsable_content_length_is_400(self):
        running, _ = self.start([support.final_reply("hi")])
        request = (
            b"POST /v1/chat/completions HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Authorization: Bearer " + support.FAKE_CLIENT_TOKEN.encode() + b"\r\n"
            b"Content-Length: not-a-number\r\n"
            b"Connection: close\r\n\r\n"
        )
        status_line = raw_request("127.0.0.1", running.config.bind_port, request)
        self.assertIn("400", status_line)


class ClientControlOverHttpTest(ServerTestCase):
    def test_client_model_is_replaced_by_the_configured_one(self):
        running, upstream = self.start([support.final_reply("hi")])
        _, body = running.post_chat(
            support.chat_request(tools=support.TOOLS, model="gpt-9-omniscient")
        )
        self.assertEqual(body["model"], "sure-ai-broker-test")
        self.assertNotIn("gpt-9-omniscient", json.dumps(upstream.calls))

    def test_client_cannot_redirect_the_upstream(self):
        running, upstream = self.start([support.final_reply("hi")])
        running.post_chat(
            support.chat_request(
                tools=support.TOOLS,
                extra={
                    "base_url": "http://attacker.invalid/v1",
                    "extra_headers": {"x-session-key": support.TENANT_B_SESSION},
                },
            )
        )
        blob = json.dumps(upstream.calls)
        self.assertNotIn("attacker.invalid", blob)
        self.assertNotIn(support.TENANT_B_SESSION, blob)

    def test_client_headers_are_not_forwarded_as_routing(self):
        running, upstream = self.start([support.final_reply("hi")])
        running.post_chat(
            support.chat_request(tools=support.TOOLS, user=support.TENANT_A_SESSION),
            headers={"X-Session-Key": support.TENANT_B_SESSION, "X-Agent": "other-tenant"},
        )
        self.assertNotIn(upstream.calls[0]["session_key"], (support.TENANT_A_SESSION, support.TENANT_B_SESSION))
        self.assertRegex(upstream.calls[0]["session_key"], r"\Asure-chat-[0-9a-f]{64}\Z")
        self.assertNotIn("other-tenant", json.dumps(upstream.calls))


class LoggingTest(ServerTestCase):
    SECRET_MEMO = "PRIVATE-MEMO-DO-NOT-LOG-37281"
    SECRET_RESULT = "PRIVATE-BALANCE-DO-NOT-LOG-99813"

    def test_access_log_has_the_operational_fields(self):
        running, _ = self.start([support.final_reply("hi")])
        running.post_chat(support.chat_request(tools=support.TOOLS))
        lines = [json.loads(line) for line in running.log_text().strip().splitlines()]
        request_lines = [line for line in lines if line.get("path") == "/v1/chat/completions"]
        self.assertEqual(len(request_lines), 1)
        entry = request_lines[0]
        self.assertEqual(entry["method"], "POST")
        self.assertEqual(entry["status"], 200)
        self.assertEqual(entry["tools"], 2)
        self.assertIn("latency_ms", entry)
        self.assertIn("req_bytes", entry)
        self.assertEqual(entry["code"], "final")

    def test_log_never_contains_message_content_or_session_ids(self):
        messages = [
            {"role": "user", "content": self.SECRET_MEMO},
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "get_accounts", "arguments": "{}"},
                    }
                ],
            },
            {"role": "tool", "tool_call_id": "call_1", "content": self.SECRET_RESULT},
        ]
        running, _ = self.start([support.final_reply(f"Your memo says {self.SECRET_MEMO}")])
        status, _ = running.post_chat(
            support.chat_request(
                messages=messages, tools=support.TOOLS, user=support.TENANT_A_SESSION
            )
        )
        self.assertEqual(status, 200)

        log = running.log_text()
        for forbidden in (
            self.SECRET_MEMO,
            self.SECRET_RESULT,
            support.TENANT_A_SESSION,
            support.TENANT_A_SESSION[len("sure-chat-"):],
            support.FAKE_CLIENT_TOKEN,
            "Authorization",
            "get_accounts",
        ):
            with self.subTest(forbidden=forbidden[:20]):
                self.assertNotIn(forbidden, log)

    def test_query_strings_and_long_paths_are_truncated_in_logs(self):
        running, _ = self.start([support.final_reply("hi")])
        running.request(
            "/healthz?token=" + self.SECRET_MEMO + "&x=" + "y" * 200, method="GET"
        )
        log = running.log_text()
        self.assertNotIn(self.SECRET_MEMO, log)
        self.assertIn('"path":"/healthz"', log)

    def test_rejected_requests_log_only_a_sanitized_code(self):
        running, _ = self.start([support.final_reply("hi")])
        running.post_chat(
            support.chat_request(messages=[{"role": "user", "content": self.SECRET_MEMO}]),
            authorization="Bearer wrong",
        )
        log = running.log_text()
        self.assertNotIn(self.SECRET_MEMO, log)
        self.assertIn('"code":"unauthorized"', log)
        self.assertIn('"status":401', log)

    def test_session_hash_prefix_is_logged_not_the_session(self):
        running, _ = self.start([support.final_reply("hi")])
        running.post_chat(
            support.chat_request(tools=support.TOOLS, user=support.TENANT_A_SESSION)
        )
        entries = [
            json.loads(line)
            for line in running.log_text().strip().splitlines()
            if '"session"' in line
        ]
        self.assertEqual(len(entries), 1)
        self.assertEqual(len(entries[0]["session"]), 16)


class TwoTenantIsolationTest(ServerTestCase):
    """Two tenants in flight at once must not see each other's data."""

    TENANT_A_MEMO = "TENANT-A-ONLY-ACCOUNT-11110000"
    TENANT_B_MEMO = "TENANT-B-ONLY-ACCOUNT-22220000"

    def _payload(self, session: str, memo: str) -> dict:
        messages = [
            {"role": "user", "content": f"What is in {memo}?"},
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "get_accounts", "arguments": "{}"},
                    }
                ],
            },
            {"role": "tool", "tool_call_id": "call_1", "content": f"accounts: {memo}"},
        ]
        return support.chat_request(messages=messages, tools=support.TOOLS, user=session)

    def test_concurrent_tenants_are_never_mixed_upstream(self):
        # Both requests are held inside the upstream at the same time, so any
        # shared state between them would show up here.
        barrier = threading.Barrier(2, timeout=15)
        captured: list[dict] = []
        lock = threading.Lock()

        def responder(system, transcript, session_key):
            with lock:
                captured.append(
                    {"system": system, "transcript": transcript, "session_key": session_key}
                )
            barrier.wait()
            return support.final_reply("done")

        running, _ = self.start(responder=responder)

        results: dict[str, tuple] = {}

        def run(name: str, session: str, memo: str):
            results[name] = running.post_chat(self._payload(session, memo))

        threads = [
            threading.Thread(
                target=run, args=("a", support.TENANT_A_SESSION, self.TENANT_A_MEMO)
            ),
            threading.Thread(
                target=run, args=("b", support.TENANT_B_SESSION, self.TENANT_B_MEMO)
            ),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=25)
            self.assertFalse(thread.is_alive())

        self.assertEqual({status for status, _ in results.values()}, {200})
        self.assertEqual(len(captured), 2)

        keys = {call["session_key"] for call in captured}
        self.assertEqual(len(keys), 2)
        self.assertFalse(keys & {support.TENANT_A_SESSION, support.TENANT_B_SESSION})

        tenant_a = next(call for call in captured if self.TENANT_A_MEMO in call["transcript"])
        tenant_b = next(call for call in captured if self.TENANT_B_MEMO in call["transcript"])
        self.assertNotEqual(tenant_a["session_key"], tenant_b["session_key"])

        self.assertIn(self.TENANT_A_MEMO, tenant_a["transcript"])
        self.assertNotIn(self.TENANT_B_MEMO, tenant_a["transcript"])
        self.assertNotIn(self.TENANT_B_MEMO, tenant_a["system"])

        self.assertIn(self.TENANT_B_MEMO, tenant_b["transcript"])
        self.assertNotIn(self.TENANT_A_MEMO, tenant_b["transcript"])
        self.assertNotIn(self.TENANT_A_MEMO, tenant_b["system"])

    def test_sequential_tenants_do_not_share_a_session_key(self):
        running, upstream = self.start([support.final_reply("done")] * 4)
        for session, memo in (
            (support.TENANT_A_SESSION, self.TENANT_A_MEMO),
            (support.TENANT_B_SESSION, self.TENANT_B_MEMO),
        ):
            status, _ = running.post_chat(self._payload(session, memo))
            self.assertEqual(status, 200)

        keys = [call["session_key"] for call in upstream.calls]
        self.assertEqual(len(set(keys)), 2)
        self.assertFalse(set(keys) & {support.TENANT_A_SESSION, support.TENANT_B_SESSION})
        self.assertNotIn(self.TENANT_B_MEMO, upstream.calls[0]["transcript"])
        self.assertNotIn(self.TENANT_A_MEMO, upstream.calls[1]["transcript"])

    def test_tenant_without_a_valid_identifier_gets_a_fresh_key_each_time(self):
        running, upstream = self.start([support.final_reply("done")] * 4)
        for _ in range(2):
            running.post_chat(
                support.chat_request(tools=support.TOOLS, user="tenant-b-session-please")
            )
        keys = [call["session_key"] for call in upstream.calls]
        self.assertEqual(len(set(keys)), 2)
        for key in keys:
            self.assertTrue(key.startswith("broker-ephemeral-"))


class ErrorShapeTest(ServerTestCase):
    def test_forced_tool_call_failure_is_an_openai_error(self):
        running, _ = self.start([support.final_reply("I would rather not")] * 3)
        status, body = running.post_chat(
            support.chat_request(tools=support.TOOLS, tool_choice="required")
        )
        self.assertEqual(status, 502)
        self.assertEqual(body["error"]["type"], "api_error")
        self.assertEqual(body["error"]["code"], "tool_call_unavailable")

    def test_upstream_outage_is_an_openai_error(self):
        running, upstream = self.start([])
        status, body = running.post_chat(support.chat_request(tools=support.TOOLS))
        self.assertEqual(status, 502)
        self.assertEqual(body["error"]["code"], "upstream_unavailable")
        self.assertNotIn("FakeUpstream", json.dumps(body))

    def test_tool_call_round_trip_over_http(self):
        running, _ = self.start(
            [support.call_reply("get_transactions", {"period": "last_90_days", "limit": 5})]
        )
        status, body = running.post_chat(
            support.chat_request(tools=support.TOOLS, user=support.TENANT_A_SESSION)
        )
        self.assertEqual(status, 200)
        choice = body["choices"][0]
        self.assertEqual(choice["finish_reason"], "tool_calls")
        call = choice["message"]["tool_calls"][0]
        self.assertEqual(call["function"]["name"], "get_transactions")
        self.assertEqual(
            json.loads(call["function"]["arguments"]),
            {"limit": 5, "period": "last_90_days"},
        )


if __name__ == "__main__":
    unittest.main()
