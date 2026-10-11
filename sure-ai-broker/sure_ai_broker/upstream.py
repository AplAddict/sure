"""Text-only upstream backends.

An upstream is deliberately narrow: given a system prompt and a rendered
transcript it returns text. It is never handed tool schemas, never told which
model or route to use by the client, and never given anything from the client
other than message text and an opaque session key that the broker has already
validated.
"""

from __future__ import annotations

import json
import secrets
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from urllib.parse import urlsplit, urlunsplit

from .config import Config, read_token_file

SESSION_HEADER = "x-session-key"


MAX_UPSTREAM_BYTES = 2_000_000


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse redirects so the bearer token is never re-sent to another host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


class UpstreamError(Exception):
    """The upstream could not produce a reply."""


class Upstream:
    """Interface for text-only backends."""

    def complete(self, system: str, transcript: str, *, session_key: str | None = None) -> str:
        """Return the backend's reply text.

        :param system: system prompt
        :param transcript: rendered conversation
        :param session_key: validated opaque session identifier, if any
        :return: reply text
        :raises UpstreamError: on transport, status or shape problems
        """
        raise NotImplementedError


def _join_url(base: str, path: str) -> str:
    """Join ``path`` onto ``base`` without letting ``base`` lose its prefix."""
    parts = urlsplit(base)
    merged = parts.path.rstrip("/") + "/" + path.lstrip("/")
    return urlunsplit((parts.scheme, parts.netloc, merged, "", ""))


def _extract_content(payload: dict) -> str:
    """Pull assistant text out of an OpenAI-shaped chat completion."""
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise UpstreamError("upstream reply had no choices")
    message = choices[0].get("message") if isinstance(choices[0], dict) else None
    if not isinstance(message, dict):
        raise UpstreamError("upstream reply had no message")

    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        # Some servers return content parts rather than a plain string.
        parts = [
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and part.get("type") in (None, "text", "output_text")
        ]
        joined = "".join(text for text in parts if isinstance(text, str))
        if joined:
            return joined
    # ``reasoning_content`` is deliberately never used as an answer: chain of
    # thought must not be surfaced to a user or parsed as a tool call.
    raise UpstreamError("upstream reply had no textual content")


class UpstreamOpenAICompat(Upstream):
    """Calls one fixed OpenAI-compatible ``/chat/completions`` endpoint.

    Only plain chat messages are sent. In particular no ``tools``,
    ``tool_choice``, ``functions`` or client-provided model is ever forwarded:
    the model id comes from server-side configuration.

    Written against the public OpenAI chat-completions request/response shape.
    It has **not** been verified against any specific server implementation.
    """

    def __init__(self, config: Config, *, opener=None):
        config.validate_upstream()
        self._url = _join_url(config.upstream_base_url, "chat/completions")
        self._model = config.upstream_model
        self._timeout = config.upstream_timeout
        self._token = read_token_file(config.upstream_token_file, label="upstream token")
        self._opener = opener or urllib.request.build_opener(
            urllib.request.HTTPSHandler(), urllib.request.HTTPHandler(), _NoRedirect()
        )

    def complete(self, system: str, transcript: str, *, session_key: str | None = None) -> str:
        body = json.dumps(
            {
                "model": self._model,
                "stream": False,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": transcript},
                ],
            }
        ).encode("utf-8")

        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {self._token}",
        }
        # A session key is only attached when the broker validated it; otherwise
        # the backend gets no continuity hint at all.
        if session_key:
            headers[SESSION_HEADER] = session_key

        request = urllib.request.Request(self._url, data=body, headers=headers, method="POST")

        try:
            with self._opener.open(request, timeout=self._timeout) as response:
                raw = response.read(MAX_UPSTREAM_BYTES + 1)
        except urllib.error.HTTPError as error:
            # Upstream error bodies may quote the prompt; never surface them.
            raise UpstreamError(f"upstream returned HTTP {error.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise UpstreamError("upstream request failed") from None

        if len(raw) > MAX_UPSTREAM_BYTES:
            raise UpstreamError("upstream reply was too large")
        try:
            payload = json.loads(raw.decode("utf-8", errors="replace"))
        except (json.JSONDecodeError, RecursionError):
            raise UpstreamError("upstream reply was not JSON") from None
        if not isinstance(payload, dict):
            raise UpstreamError("upstream reply was not a JSON object")

        return _extract_content(payload)


@dataclass
class FakeUpstream(Upstream):
    """Scripted upstream for tests.

    ``replies`` is consumed in order; when exhausted the last reply repeats.
    ``responder`` takes precedence when set and is called with
    ``(system, transcript, session_key)``.
    """

    replies: list[str] = field(default_factory=list)
    responder: object | None = None
    calls: list[dict] = field(default_factory=list)
    error: Exception | None = None

    def complete(self, system: str, transcript: str, *, session_key: str | None = None) -> str:
        self.calls.append(
            {"system": system, "transcript": transcript, "session_key": session_key}
        )
        if self.error is not None:
            raise self.error
        if self.responder is not None:
            return self.responder(system, transcript, session_key)
        if not self.replies:
            raise UpstreamError("FakeUpstream has no scripted replies")
        index = min(len(self.calls) - 1, len(self.replies) - 1)
        return self.replies[index]


def new_session_key() -> str:
    """A fresh, single-request session key with no tenant meaning."""
    return f"broker-ephemeral-{secrets.token_hex(16)}"
