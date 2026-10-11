"""HTTP front end: authentication, limits, routing and log-safe access logs.

Everything in this module is deliberately boring. It accepts exactly two
routes, authenticates with a constant-time comparison against a token read from
a mode-checked file, enforces byte limits before parsing, and hands the decoded
body to :class:`sure_ai_broker.broker.Broker`.

What it must never do: log message content, tool results, tokens, headers, or
the opaque session id. The access log carries only method, path, status,
latency, request size, tool count, a sanitized outcome/error code and a short
hash prefix of the session key.
"""

from __future__ import annotations

import hmac
import json
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .broker import Broker, ClientError
from .config import Config, ConfigError, load_config, read_token_file
from .upstream import Upstream, UpstreamOpenAICompat

CHAT_PATH = "/v1/chat/completions"
HEALTH_PATH = "/healthz"

SERVER_TOKEN = "sure-ai-broker"


class AccessLog:
    """One-line-per-request structured log with no message content in it.

    :param stream: where to write; defaults to ``sys.stderr``
    """

    def __init__(self, stream=None):
        self._stream = stream if stream is not None else sys.stderr
        self._lock = threading.Lock()

    def record(self, **fields) -> None:
        """Write one log record.

        Only the explicit fields passed by callers are written. There is no
        passthrough of request data, so a future caller cannot accidentally
        widen what is logged without editing its own call site.
        """
        entry = {"ts": round(time.time(), 3)}
        entry.update({key: value for key, value in fields.items() if value is not None})
        line = json.dumps(entry, separators=(",", ":"), sort_keys=True)
        with self._lock:
            try:
                self._stream.write(line + "\n")
                self._stream.flush()
            except (OSError, ValueError):
                # A broken log stream must not take the listener down.
                pass


def open_log(config: Config) -> AccessLog:
    """Open the configured log sink.

    :param config: effective config; ``log_file`` empty means stderr
    :raises ConfigError: when the log file cannot be appended to
    """
    if not config.log_file:
        return AccessLog(sys.stderr)
    try:
        handle = open(config.log_file, "a", encoding="utf-8")
    except OSError:
        raise ConfigError(f"log file is not writable: {config.log_file}") from None
    return AccessLog(handle)


def _safe_path(raw_path: str) -> str:
    """Strip the query string and cap the length before a path is logged."""
    path = (raw_path or "").split("?", 1)[0].split("#", 1)[0]
    return path[:64]


def make_handler(*, config: Config, broker: Broker, token: str, log: AccessLog):
    """Build the request handler class bound to this process's dependencies.

    :param config: effective config (limits, model id)
    :param broker: the shim that executes a turn
    :param token: expected bearer token value (never logged)
    :param log: access log sink
    :return: a :class:`BaseHTTPRequestHandler` subclass
    """

    class Handler(BaseHTTPRequestHandler):
        server_version = SERVER_TOKEN
        sys_version = ""
        protocol_version = "HTTP/1.1"
        # Per-connection socket timeout: a slow or stalled client cannot pin a
        # worker thread (the server-level ``timeout`` does not cover this).
        timeout = 30

        # -- plumbing ----------------------------------------------------

        def log_message(self, format, *args):  # noqa: A002 - base class signature
            """Suppress the base class's stderr logging.

            Its default format includes the full request line; all logging goes
            through :class:`AccessLog` instead.
            """

        def _respond(self, status: int, payload: dict | None, *, body: bytes | None = None) -> int:
            if body is None:
                body = b"" if payload is None else json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if status >= 400:
                # Request bodies may be unread on early rejections; closing the
                # connection prevents leftover bytes being parsed as a new request.
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return status

        def _error(self, status: int, message: str, code: str, error_type: str) -> int:
            return self._respond(
                status,
                {"error": {"message": message, "type": error_type, "code": code, "param": None}},
            )

        def _unauthorized(self) -> int:
            # No detail: a caller learns only that it is not authenticated.
            return self._error(401, "unauthorized", "unauthorized", "invalid_request_error")

        def _authenticated(self) -> bool:
            header = self.headers.get("Authorization", "")
            scheme, _, value = header.partition(" ")
            if scheme.lower() != "bearer":
                return False
            # Compare as bytes: str inputs make compare_digest raise on non-ASCII
            # header text, which must be a plain 401 rather than a 500.
            return hmac.compare_digest(
                value.strip().encode("utf-8", "surrogateescape"), token.encode("utf-8")
            )

        def _read_body(self) -> tuple[bytes | None, int]:
            """Read the request body, enforcing the byte limit.

            :return: ``(body, status)``; ``body`` is ``None`` when a response
                has already been sent
            """
            raw_length = self.headers.get("Content-Length")
            if raw_length is None:
                if (self.headers.get("Transfer-Encoding") or "").strip():
                    return None, self._error(
                        411,
                        "a Content-Length is required; chunked bodies are not accepted",
                        "length_required",
                        "invalid_request_error",
                    )
                return None, self._error(
                    411, "a Content-Length is required", "length_required", "invalid_request_error"
                )
            try:
                length = int(raw_length)
            except ValueError:
                return None, self._error(
                    400, "invalid Content-Length", "invalid_request", "invalid_request_error"
                )
            if length < 0:
                return None, self._error(
                    400, "invalid Content-Length", "invalid_request", "invalid_request_error"
                )
            if length > config.max_body_bytes:
                return None, self._error(
                    413,
                    f"request body exceeds the {config.max_body_bytes} byte limit",
                    "body_too_large",
                    "invalid_request_error",
                )
            try:
                body = self.rfile.read(length)
            except (OSError, ValueError):
                return None, self._error(
                    400, "could not read the request body", "invalid_request", "invalid_request_error"
                )
            if len(body) != length:
                return None, self._error(
                    400, "request body was truncated", "invalid_request", "invalid_request_error"
                )
            return body, 0

        # -- routes ------------------------------------------------------

        def do_GET(self):  # noqa: N802 - base class signature
            self._dispatch("GET")

        def do_HEAD(self):  # noqa: N802
            self._dispatch("HEAD")

        def do_POST(self):  # noqa: N802
            self._dispatch("POST")

        def _dispatch(self, method: str) -> None:
            started = time.monotonic()
            path = _safe_path(self.path)
            fields: dict = {}
            try:
                status = self._route(method, path, fields)
            except Exception:  # noqa: BLE001 - never leak a traceback to a client
                fields["code"] = "internal_error"
                try:
                    status = self._error(
                        500, "internal error", "internal_error", "api_error"
                    )
                except OSError:
                    status = 500
            latency_ms = round((time.monotonic() - started) * 1000, 2)
            log.record(
                method=method,
                path=path,
                status=status,
                latency_ms=latency_ms,
                **fields,
            )

        def _route(self, method: str, path: str, fields: dict) -> int:
            if path == HEALTH_PATH:
                if method not in ("GET", "HEAD"):
                    return self._error(
                        405, "method not allowed", "method_not_allowed", "invalid_request_error"
                    )
                return self._respond(200, {"status": "ok", "service": SERVER_TOKEN})

            if path != CHAT_PATH:
                return self._error(404, "not found", "not_found", "invalid_request_error")

            if method != "POST":
                return self._error(
                    405, "method not allowed", "method_not_allowed", "invalid_request_error"
                )

            # Authenticate before reading or parsing anything.
            if not self._authenticated():
                fields["code"] = "unauthorized"
                return self._unauthorized()

            body, early_status = self._read_body()
            if body is None:
                fields["code"] = "limits"
                return early_status
            fields["req_bytes"] = len(body)

            try:
                payload = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                fields["code"] = "invalid_json"
                return self._error(
                    400, "request body must be valid JSON", "invalid_json", "invalid_request_error"
                )

            if isinstance(payload, dict) and isinstance(payload.get("tools"), list):
                fields["tools"] = len(payload["tools"])

            try:
                outcome = broker.handle(payload)
            except ClientError as rejection:
                fields["code"] = rejection.code
                return self._respond(rejection.status, rejection.to_payload())

            fields["code"] = outcome.outcome
            fields["tool_calls"] = outcome.tool_count
            fields["upstream_attempts"] = outcome.upstream_attempts
            fields["session"] = outcome.session_hash
            return self._respond(outcome.status, outcome.payload)

    return Handler


class BrokerServer(ThreadingHTTPServer):
    """A threading HTTP server that is explicit about IPv6 and reuse."""

    daemon_threads = True
    allow_reuse_address = True
    # A slow or hostile client must not be able to pin a worker thread forever.
    timeout = 30

    def __init__(self, address, handler_class, *, dual_stack_host: str = ""):
        if ":" in dual_stack_host:
            self.address_family = socket.AF_INET6
        super().__init__(address, handler_class)


def build_server(
    config: Config,
    *,
    upstream: Upstream | None = None,
    token: str | None = None,
    log: AccessLog | None = None,
) -> BrokerServer:
    """Validate the configuration and build a listening server.

    The order matters: every fail-closed check runs *before* the socket opens.

    :param config: effective config
    :param upstream: injected upstream; the configured one is built when omitted
    :param token: injected client token; read from ``token_file`` when omitted
    :param log: injected access log; built from config when omitted
    :return: a bound, not-yet-serving :class:`BrokerServer`
    :raises ConfigError: on any configuration or secret-hygiene problem
    """
    config.validate()
    effective_token = token if token is not None else read_token_file(
        config.token_file, label="client token"
    )
    effective_upstream = upstream if upstream is not None else UpstreamOpenAICompat(config)
    effective_log = log if log is not None else open_log(config)

    broker = Broker(config, effective_upstream)
    handler = make_handler(
        config=config, broker=broker, token=effective_token, log=effective_log
    )
    server = BrokerServer(
        (config.bind_host, config.bind_port), handler, dual_stack_host=config.bind_host
    )
    effective_log.record(
        event="listening",
        bind_host=config.bind_host,
        bind_port=server.server_address[1],
        model=config.model_id,
        max_tool_calls=config.max_tool_calls_per_turn,
        max_tool_rounds=config.max_tool_rounds,
    )
    return server


def serve(config: Config) -> int:
    """Run the broker until a termination signal arrives.

    :param config: effective config
    :return: a process exit status
    """
    try:
        server = build_server(config)
    except ConfigError as problem:
        # Configuration messages name paths and limits, never secret values.
        sys.stderr.write(f"sure-ai-broker: {problem}\n")
        return 2

    def _stop(signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    for signal_name in ("SIGINT", "SIGTERM"):
        handler = getattr(signal, signal_name, None)
        if handler is not None:
            signal.signal(handler, _stop)

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point. Takes no arguments: all configuration is env/file based.

    Secrets are never accepted on the command line, so any argument is an error.
    """
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments:
        sys.stderr.write(
            "sure-ai-broker: this server takes no arguments; configure it with "
            "BROKER_* environment variables or BROKER_CONFIG_FILE\n"
        )
        return 2
    try:
        config = load_config()
    except ConfigError as problem:
        sys.stderr.write(f"sure-ai-broker: {problem}\n")
        return 2
    return serve(config)
