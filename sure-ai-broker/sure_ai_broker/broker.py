"""The tool-call shim itself: OpenAI request in, OpenAI response out.

The broker owns every decision the client is not allowed to make. In
particular:

* the upstream model, endpoint, headers and routing are server-side config; a
  client-supplied ``model`` (or any URL-ish field) is ignored, never forwarded;
* tool names must appear in the ``tools`` the same request supplied, and
  arguments must validate against that tool's schema;
* the opaque ``user`` field is the only continuity hint accepted, and only when
  it matches the exact shape Sure emits; anything else gets a fresh random key,
  so one tenant can never land on another tenant's upstream session.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import time
from dataclasses import dataclass

from . import protocol, schema
from .config import Config
from .schema import unsupported_reason
from .protocol import (
    ACTION_CALL,
    ACTION_FINAL,
    MODE_AUTO,
    MODE_FUNCTION_PREFIX,
    MODE_NONE,
    MODE_REQUIRED,
    Action,
    ProtocolError,
)
from .upstream import Upstream, UpstreamError, new_session_key

# Sure sends "sure-chat-" + SHA256(chat.user_id). Nothing else is accepted as a
# session identity.
SESSION_ID_RE = re.compile(r"sure-chat-[0-9a-f]{64}")

GENERIC_FAILURE_TEXT = (
    "I wasn't able to complete that request just now. Please try asking again, "
    "or rephrase what you need."
)


class ClientError(Exception):
    """A request-level rejection rendered in the OpenAI error shape."""

    def __init__(self, status: int, message: str, *, code: str, error_type: str = "invalid_request_error"):
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code
        self.error_type = error_type

    def to_payload(self) -> dict:
        return {
            "error": {
                "message": self.message,
                "type": self.error_type,
                "code": self.code,
                "param": None,
            }
        }


@dataclass
class TurnOutcome:
    """What the broker decided for one turn, plus log-safe facts about it."""

    status: int
    payload: dict
    tool_count: int = 0
    upstream_attempts: int = 0
    outcome: str = "ok"
    # Short hash of the session key, for correlation without identifying anyone.
    session_hash: str = ""


def _error(status: int, message: str, code: str, error_type: str = "invalid_request_error") -> ClientError:
    return ClientError(status, message, code=code, error_type=error_type)


def _content_to_text(content) -> str:
    """Flatten OpenAI message content into text."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                parts.append(part["text"])
            elif isinstance(part, str):
                parts.append(part)
            else:
                parts.append("[unsupported content part]")
        return "\n".join(parts)
    raise _error(400, "message content must be a string or an array of parts", "invalid_content")


def normalize_tools(raw_tools, config: Config) -> list[dict]:
    """Validate and flatten the client's ``tools`` array.

    :param raw_tools: value of the request's ``tools`` key
    :param config: effective config (supplies the count limit)
    :return: list of ``{"name", "description", "parameters"}``
    :raises ClientError: on shape or limit violations
    """
    if raw_tools in (None, []):
        return []
    if not isinstance(raw_tools, list):
        raise _error(400, "'tools' must be an array", "invalid_tools")
    if len(raw_tools) > config.max_tools:
        raise _error(400, f"too many tools: limit is {config.max_tools}", "too_many_tools")

    tools: list[dict] = []
    seen: set[str] = set()
    for entry in raw_tools:
        if not isinstance(entry, dict):
            raise _error(400, "each tool must be an object", "invalid_tools")
        if entry.get("type") not in (None, "function"):
            raise _error(400, "only function tools are supported", "unsupported_tool_type")
        function = entry.get("function")
        if not isinstance(function, dict):
            raise _error(400, "each tool needs a 'function' object", "invalid_tools")
        name = function.get("name")
        if not isinstance(name, str) or not name.strip():
            raise _error(400, "each tool needs a non-empty name", "invalid_tools")
        name = name.strip()
        if name in seen:
            raise _error(400, "tool names must be unique", "duplicate_tool")
        seen.add(name)

        parameters = function.get("parameters")
        if parameters is None:
            parameters = {"type": "object", "properties": {}}
        if not isinstance(parameters, dict):
            raise _error(400, f"parameters for '{name}' must be an object", "invalid_tools")
        reason = unsupported_reason(parameters)
        if reason:
            raise _error(400, f"parameters for '{name}' cannot be enforced: {reason}", "unsupported_schema")

        description = function.get("description")
        tools.append(
            {
                "name": name,
                "description": description if isinstance(description, str) else "",
                "parameters": parameters,
            }
        )
    return tools


def normalize_messages(raw_messages, config: Config) -> list[dict]:
    """Validate and flatten the client's ``messages`` array.

    :raises ClientError: on shape or limit violations
    """
    if not isinstance(raw_messages, list) or not raw_messages:
        raise _error(400, "'messages' must be a non-empty array", "invalid_messages")
    if len(raw_messages) > config.max_messages:
        raise _error(400, f"too many messages: limit is {config.max_messages}", "too_many_messages")

    messages: list[dict] = []
    for entry in raw_messages:
        if not isinstance(entry, dict):
            raise _error(400, "each message must be an object", "invalid_messages")
        role = entry.get("role")
        if role not in ("system", "developer", "user", "assistant", "tool"):
            raise _error(400, "unsupported message role", "invalid_role")
        if role == "developer":
            role = "system"

        content = _content_to_text(entry.get("content"))
        if len(content) > config.max_message_chars:
            raise _error(
                413,
                f"a message exceeds the {config.max_message_chars} character limit",
                "message_too_large",
            )

        message: dict = {"role": role, "content": content}

        if role == "assistant":
            raw_calls = entry.get("tool_calls")
            if raw_calls is not None:
                if not isinstance(raw_calls, list):
                    raise _error(400, "'tool_calls' must be an array", "invalid_tool_calls")
                calls = []
                for call in raw_calls:
                    if not isinstance(call, dict):
                        raise _error(400, "each tool call must be an object", "invalid_tool_calls")
                    function = call.get("function")
                    if not isinstance(function, dict):
                        raise _error(
                            400, "each tool call needs a 'function' object", "invalid_tool_calls"
                        )
                    arguments = function.get("arguments")
                    if arguments is not None and not isinstance(arguments, (str, dict)):
                        raise _error(
                            400,
                            "tool call arguments must be a JSON string or object",
                            "invalid_tool_calls",
                        )
                    if isinstance(arguments, str) and len(arguments) > config.max_message_chars:
                        raise _error(
                            413,
                            f"tool call arguments exceed the {config.max_message_chars} "
                            "character limit",
                            "message_too_large",
                        )
                    calls.append(
                        {
                            "id": str(call.get("id") or ""),
                            "function": {
                                "name": str(function.get("name") or ""),
                                "arguments": arguments,
                            },
                        }
                    )
                message["tool_calls"] = calls

        if role == "tool":
            call_id = entry.get("tool_call_id")
            if call_id is not None and not isinstance(call_id, str):
                raise _error(400, "'tool_call_id' must be a string", "invalid_messages")
            message["tool_call_id"] = call_id or ""

        messages.append(message)

    return messages


def normalize_tool_choice(raw_choice, tools: list[dict]) -> str:
    """Translate ``tool_choice`` into an internal mode string.

    :raises ClientError: when a named function is not in ``tools``
    """
    names = {tool["name"] for tool in tools}

    if raw_choice in (None, "", "auto"):
        return MODE_AUTO
    if raw_choice == "none":
        return MODE_NONE
    if raw_choice in ("required", "any"):
        if not tools:
            raise _error(400, "'tool_choice' requires a tool but none were supplied", "invalid_tool_choice")
        return MODE_REQUIRED
    if isinstance(raw_choice, dict):
        if raw_choice.get("type") not in (None, "function"):
            raise _error(400, "unsupported tool_choice type", "invalid_tool_choice")
        function = raw_choice.get("function")
        if not isinstance(function, dict):
            raise _error(400, "tool_choice needs a 'function' object", "invalid_tool_choice")
        name = function.get("name")
        if not isinstance(name, str) or name.strip() not in names:
            raise _error(400, "tool_choice names a function that was not supplied", "unknown_tool_choice")
        return MODE_FUNCTION_PREFIX + name.strip()

    raise _error(400, "unsupported 'tool_choice' value", "invalid_tool_choice")


def session_key_for(raw_user, secret: bytes = b"") -> tuple[str, bool]:
    """Derive the upstream session key from the opaque ``user`` field.

    :param raw_user: the request's ``user`` value
    :return: ``(session_key, validated)``; an unvalidated value yields a fresh
        random key that is never reused for another request
    """
    if isinstance(raw_user, str) and SESSION_ID_RE.fullmatch(raw_user) and secret:
        # Never forward a caller-asserted value: bind it to a per-process server secret
        # so upstream session keys are unguessable and stable only within this process.
        digest = hmac.new(secret, raw_user.encode("utf-8"), hashlib.sha256).hexdigest()
        return f"sure-chat-{digest}", True
    return new_session_key(), False


def session_fingerprint(session_key: str, secret: bytes = b"") -> str:
    """A short, non-reversible tag for logs.

    The session key itself is never logged; only these 8 hex characters of its
    digest, which are enough to correlate retries and far too short to be worth
    attacking back to a user id.
    """
    return hmac.new(secret or b"unsalted", session_key.encode("utf-8"), hashlib.sha256).hexdigest()[:16]


def _estimate_tokens(text: str) -> int:
    return max(0, len(text) // 4)


class Broker:
    """Turns OpenAI tool-calling requests into text prompts and back."""

    def __init__(self, config: Config, upstream: Upstream, *, secret: bytes | None = None):
        self._config = config
        self._upstream = upstream
        self._secret = secret if secret else secrets.token_bytes(32)

    # -- public API ------------------------------------------------------

    def handle(self, payload: dict) -> TurnOutcome:
        """Process one ``/v1/chat/completions`` request body.

        :param payload: decoded request body
        :return: a :class:`TurnOutcome` with the response payload and status
        :raises ClientError: for request-level rejections
        """
        if not isinstance(payload, dict):
            raise _error(400, "request body must be a JSON object", "invalid_body")

        if payload.get("stream"):
            # Fail closed: a half-supported stream is worse than none.
            raise _error(400, "streaming is not supported by this endpoint", "stream_unsupported")

        tools = normalize_tools(payload.get("tools"), self._config)
        messages = normalize_messages(payload.get("messages"), self._config)
        mode = normalize_tool_choice(payload.get("tool_choice"), tools)
        session_key, _validated = session_key_for(payload.get("user"), self._secret)

        if not tools:
            mode = MODE_NONE

        rounds = sum(1 for message in messages if message.get("tool_calls"))
        loop_capped = rounds > self._config.max_tool_rounds
        if loop_capped:
            # Safety control: terminate the loop with a normal answer even if the
            # client asked for a forced call.
            mode = MODE_NONE

        outcome = self._run_turn(
            messages=messages,
            tools=tools,
            mode=mode,
            session_key=session_key,
            loop_capped=loop_capped,
        )
        outcome.session_hash = session_fingerprint(session_key, self._secret)
        return outcome

    # -- turn execution --------------------------------------------------

    def _run_turn(self, *, messages, tools, mode, session_key, loop_capped) -> TurnOutcome:
        tools_by_name = {tool["name"]: tool for tool in tools}
        names_by_call_id = self._tool_names_by_call_id(messages)
        host_instructions = [
            message["content"] for message in messages if message["role"] == "system"
        ]
        system = protocol.build_system_prompt(
            tools=tools,
            mode=mode,
            max_tool_calls=self._config.max_tool_calls_per_turn,
            host_instructions=host_instructions,
        )

        corrections: list[str] = []
        attempts = 0
        max_attempts = 1 + max(0, self._config.max_repair_attempts)

        while attempts < max_attempts:
            transcript = protocol.render_transcript(
                messages,
                max_chars_per_message=self._config.max_message_chars,
                corrections=corrections,
                tool_names_by_call_id=names_by_call_id,
            )
            attempts += 1
            try:
                reply = self._upstream.complete(system, transcript, session_key=session_key)
            except UpstreamError:
                raise _error(
                    502,
                    "the reasoning backend is unavailable",
                    "upstream_unavailable",
                    error_type="api_error",
                ) from None

            try:
                action = protocol.parse_action(
                    reply, max_tool_calls=self._config.max_tool_calls_per_turn
                )
                action = self._enforce_mode(action, mode)
                if action.kind == ACTION_CALL:
                    self._validate_tool_calls(action, tools_by_name, mode)
            except ProtocolError as problem:
                corrections.append(str(problem))
                continue

            if action.kind == ACTION_CALL:
                return TurnOutcome(
                    status=200,
                    payload=self._tool_calls_response(action, system, transcript),
                    tool_count=len(action.tool_calls),
                    upstream_attempts=attempts,
                    outcome="tool_calls",
                )

            return TurnOutcome(
                status=200,
                payload=self._message_response(action.content, system, transcript),
                upstream_attempts=attempts,
                outcome="final_capped" if loop_capped else "final",
            )

        return self._exhausted(mode, system, attempts)

    def _exhausted(self, mode: str, system: str, attempts: int) -> TurnOutcome:
        """Give up after the repair attempts are spent.

        A forced tool call fails closed with an error rather than a fabricated
        call. Otherwise the client gets a safe, generic assistant message; the
        model's raw output is never echoed.
        """
        if mode == MODE_REQUIRED or mode.startswith(MODE_FUNCTION_PREFIX):
            raise _error(
                502,
                "the reasoning backend did not produce a valid tool call",
                "tool_call_unavailable",
                error_type="api_error",
            )
        return TurnOutcome(
            status=200,
            payload=self._message_response(GENERIC_FAILURE_TEXT, system, ""),
            upstream_attempts=attempts,
            outcome="protocol_failure",
        )

    def _enforce_mode(self, action: Action, mode: str) -> Action:
        """Reject replies that ignore the turn's forced mode."""
        if mode == MODE_NONE and action.kind == ACTION_CALL:
            raise ProtocolError('tool calls are not allowed this turn; reply with "final"')
        if mode == MODE_REQUIRED and action.kind == ACTION_FINAL:
            raise ProtocolError('this turn requires a tool call; reply with "call"')
        if mode.startswith(MODE_FUNCTION_PREFIX):
            required_name = mode[len(MODE_FUNCTION_PREFIX) :]
            if action.kind == ACTION_FINAL:
                raise ProtocolError(
                    f'this turn requires calling "{required_name}"; reply with "call"'
                )
            if len(action.tool_calls) != 1 or action.tool_calls[0].name != required_name:
                raise ProtocolError(f'this turn must call exactly "{required_name}"')
        return action

    def _validate_tool_calls(self, action: Action, tools_by_name: dict, mode: str) -> None:
        """Enforce the allowlist and the per-tool JSON schema.

        :raises ProtocolError: when a name is unknown or arguments are invalid
        """
        if len(action.tool_calls) > self._config.max_tool_calls_per_turn:
            raise ProtocolError(
                f"at most {self._config.max_tool_calls_per_turn} tool call(s) are allowed"
            )

        for call in action.tool_calls:
            tool = tools_by_name.get(call.name)
            if tool is None:
                allowed = ", ".join(sorted(tools_by_name)) or "(none)"
                raise ProtocolError(
                    f"'{call.name}' is not an available function; choose from: {allowed}"
                )
            errors = schema.validate(tool["parameters"], call.arguments)
            if errors:
                raise ProtocolError(
                    f"arguments for '{call.name}' are invalid: " + "; ".join(errors)
                )

    # -- response shaping ------------------------------------------------

    def _tool_names_by_call_id(self, messages: list[dict]) -> dict[str, str]:
        mapping: dict[str, str] = {}
        for message in messages:
            for call in message.get("tool_calls") or []:
                call_id = call.get("id")
                name = (call.get("function") or {}).get("name")
                if call_id and name:
                    mapping[call_id] = name
        return mapping

    def _usage(self, system: str, transcript: str, completion: str) -> dict:
        prompt_tokens = _estimate_tokens(system) + _estimate_tokens(transcript)
        completion_tokens = _estimate_tokens(completion)
        return {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        }

    def _envelope(self, message: dict, finish_reason: str, usage: dict) -> dict:
        return {
            "id": f"chatcmpl-{secrets.token_hex(12)}",
            "object": "chat.completion",
            "created": int(time.time()),
            # Fixed, server-side model id: the client never chose it.
            "model": self._config.model_id,
            "choices": [
                {"index": 0, "message": message, "finish_reason": finish_reason, "logprobs": None}
            ],
            "usage": usage,
        }

    def _tool_calls_response(self, action: Action, system: str, transcript: str) -> dict:
        tool_calls = []
        serialized = []
        for call in action.tool_calls:
            arguments = json.dumps(call.arguments, separators=(",", ":"), sort_keys=True)
            serialized.append(arguments)
            tool_calls.append(
                {
                    "id": f"call_{secrets.token_hex(12)}",
                    "type": "function",
                    "function": {"name": call.name, "arguments": arguments},
                }
            )
        message = {"role": "assistant", "content": None, "tool_calls": tool_calls}
        return self._envelope(message, "tool_calls", self._usage(system, transcript, "".join(serialized)))

    def _message_response(self, content: str, system: str, transcript: str) -> dict:
        message = {"role": "assistant", "content": content}
        return self._envelope(message, "stop", self._usage(system, transcript, content))
