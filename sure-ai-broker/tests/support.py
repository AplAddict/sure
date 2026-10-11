"""Shared test helpers: temp token files, configs and a live loopback server.

All data here is obviously fake: no real accounts, people, hosts or secrets.
"""

from __future__ import annotations

import io
import json
import os
import socket
import tempfile
import threading
import urllib.error
import urllib.request
from dataclasses import replace

from sure_ai_broker.config import Config
from sure_ai_broker.server import AccessLog, build_server

# 32+ chars so it satisfies the minimum-length rule; obviously not a real token.
FAKE_CLIENT_TOKEN = "fake-client-token-0000000000000000000000"
FAKE_UPSTREAM_TOKEN = "fake-upstream-token-1111111111111111111111"

# Two fake tenants. 64 hex chars each, matching the shape Sure emits
# ("sure-chat-" + SHA256 of the chat owner's user id).
TENANT_A_SESSION = "sure-chat-" + "a1" * 32
TENANT_B_SESSION = "sure-chat-" + "b2" * 32

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_accounts",
            "description": "List the accounts the signed-in user may see.",
            "parameters": {
                "type": "object",
                "properties": {"include_inactive": {"type": "boolean"}},
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_transactions",
            "description": "Fetch transactions for a period.",
            "parameters": {
                "type": "object",
                "properties": {
                    "period": {"type": "string", "enum": ["last_30_days", "last_90_days"]},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                "required": ["period"],
                "additionalProperties": False,
            },
        },
    },
]


def write_secret_file(directory: str, name: str, value: str, *, mode: int = 0o600) -> str:
    """Write a fake secret to ``directory`` with an explicit mode."""
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(value + "\n")
    os.chmod(path, mode)
    return path


def temp_dir(test_case) -> str:
    """A directory cleaned up when ``test_case`` finishes."""
    holder = tempfile.TemporaryDirectory()
    test_case.addCleanup(holder.cleanup)
    return holder.name


def token_file(test_case, value: str = FAKE_CLIENT_TOKEN, *, mode: int = 0o600) -> str:
    """A fake client-token file for ``test_case``."""
    return write_secret_file(temp_dir(test_case), "client.token", value, mode=mode)


def make_config(test_case, **overrides) -> Config:
    """A valid test config, with a real token file, overridable per test."""
    base = Config(
        bind_host="127.0.0.1",
        bind_port=18713,
        token_file=token_file(test_case),
        model_id="sure-ai-broker-test",
        max_tool_rounds=6,
        max_tool_calls_per_turn=4,
    )
    return replace(base, **overrides)


def free_port() -> int:
    """An unused loopback port.

    There is an inherent race between probing and binding; the broker only ever
    binds loopback in tests, so a collision just fails the test run rather than
    doing anything unsafe.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def chat_request(
    *,
    messages=None,
    tools=None,
    tool_choice=None,
    user=None,
    model="client-chosen-model-should-be-ignored",
    extra=None,
) -> dict:
    """Build an OpenAI-style chat completions body."""
    payload: dict = {
        "model": model,
        "messages": messages
        if messages is not None
        else [{"role": "user", "content": "How much did I spend?"}],
    }
    if tools is not None:
        payload["tools"] = tools
    if tool_choice is not None:
        payload["tool_choice"] = tool_choice
    if user is not None:
        payload["user"] = user
    if extra:
        payload.update(extra)
    return payload


def call_reply(name: str, arguments: dict) -> str:
    """An upstream reply that asks for one tool call."""
    return json.dumps({"action": "call", "tool_calls": [{"name": name, "arguments": arguments}]})


def final_reply(content: str) -> str:
    """An upstream reply that ends the turn."""
    return json.dumps({"action": "final", "content": content})


class RunningBroker:
    """A broker listening on loopback for the duration of a test."""

    def __init__(self, test_case, *, config: Config, upstream, token: str | None = None):
        self.log_stream = io.StringIO()
        self.log = AccessLog(self.log_stream)
        port = free_port()
        self.config = replace(config, bind_port=port)
        self.server = build_server(
            self.config,
            upstream=upstream,
            token=FAKE_CLIENT_TOKEN if token is None else token,
            log=self.log,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05})
        self.thread.daemon = True
        self.thread.start()
        test_case.addCleanup(self.stop)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.config.bind_port}"

    def stop(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()

    def log_text(self) -> str:
        return self.log_stream.getvalue()

    def request(
        self,
        path: str,
        *,
        method: str = "POST",
        body: bytes | None = None,
        authorization: str | None = f"Bearer {FAKE_CLIENT_TOKEN}",
        headers: dict | None = None,
        content_length: str | None = None,
        timeout: float = 20.0,
    ) -> tuple[int, dict]:
        """Make one HTTP request and decode the JSON response.

        :return: ``(status, decoded_body)``; the body is ``{}`` when empty or
            not JSON
        """
        request = urllib.request.Request(self.base_url + path, data=body, method=method)
        if authorization is not None:
            request.add_header("Authorization", authorization)
        if body is not None:
            request.add_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        if content_length is not None:
            request.add_header("Content-Length", content_length)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = response.status
                raw = response.read()
        except urllib.error.HTTPError as error:
            status = error.code
            raw = error.read()
        try:
            decoded = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            decoded = {}
        return status, decoded

    def post_chat(self, payload: dict, **kwargs) -> tuple[int, dict]:
        """POST a chat completions request."""
        return self.request(
            "/v1/chat/completions",
            method="POST",
            body=json.dumps(payload).encode("utf-8"),
            **kwargs,
        )
