"""Configuration loading and fail-closed validation for the broker.

Configuration comes from the environment (``BROKER_*``) and, optionally, a JSON
file named by ``BROKER_CONFIG_FILE``. Environment values win over file values,
which win over the defaults below.

Secrets are never accepted on the command line or in the configuration itself:
the client token and the upstream token are read from files whose paths are
configured, and their contents never appear in log output or exceptions.
"""

from __future__ import annotations

import json
import os
import stat
from dataclasses import asdict, dataclass, fields
from urllib.parse import urlparse

MIN_TOKEN_CHARS = 32

# Hosts that would expose the broker beyond the private interface it is meant
# to live on. Binding to one of these requires an explicit opt-in.
WILDCARD_BIND_HOSTS = frozenset({"", "0.0.0.0", "::", "[::]", "*", "::0", "0"})

LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1", "[::1]"})


class ConfigError(Exception):
    """Raised for any configuration problem that must stop startup."""


@dataclass(frozen=True)
class Config:
    """Effective broker configuration.

    All limits are enforced before any upstream call is made.
    """

    # Listener
    bind_host: str = "127.0.0.1"
    bind_port: int = 8713
    allow_wildcard_bind: bool = False

    # Client-facing auth
    token_file: str = ""

    # The model id echoed back to clients. The client never selects a model.
    model_id: str = "sure-ai-broker"

    # Fixed, server-side-only upstream
    upstream_base_url: str = ""
    upstream_token_file: str = ""
    upstream_model: str = "default"
    upstream_timeout: float = 120.0
    allow_insecure_upstream: bool = False

    # Request limits
    max_body_bytes: int = 1_048_576
    max_messages: int = 200
    max_tools: int = 64
    max_message_chars: int = 200_000

    # Shim behaviour
    max_tool_calls_per_turn: int = 4
    max_tool_rounds: int = 6
    max_repair_attempts: int = 2

    # Optional append-only log file; stderr is used when unset.
    log_file: str = ""

    def validate(self) -> None:
        """Validate everything that must hold before the listener opens.

        Upstream settings are validated separately by :func:`validate_upstream`
        so a broker running against an injected upstream (tests) does not need
        them.
        """
        validate_bind_host(self.bind_host, allow_wildcard=self.allow_wildcard_bind)

        if not 1 <= self.bind_port <= 65535:
            raise ConfigError("bind port must be between 1 and 65535")

        if not self.token_file:
            raise ConfigError("BROKER_TOKEN_FILE is required")

        if not self.model_id:
            raise ConfigError("model id must not be empty")

        positive_ints = (
            "max_body_bytes",
            "max_messages",
            "max_tools",
            "max_message_chars",
            "max_tool_calls_per_turn",
            "max_tool_rounds",
        )
        for name in positive_ints:
            if getattr(self, name) < 1:
                raise ConfigError(f"{name} must be >= 1")

        if self.max_repair_attempts < 0:
            raise ConfigError("max_repair_attempts must be >= 0")

        if self.upstream_timeout <= 0:
            raise ConfigError("upstream_timeout must be > 0")

    def validate_upstream(self) -> None:
        """Validate the fixed upstream endpoint settings."""
        if not self.upstream_base_url:
            raise ConfigError("BROKER_UPSTREAM_BASE_URL is required")

        parsed = urlparse(self.upstream_base_url)
        if parsed.scheme not in ("http", "https"):
            raise ConfigError("upstream base URL must be http or https")
        if not parsed.hostname:
            raise ConfigError("upstream base URL must include a host")

        if (
            parsed.scheme == "http"
            and parsed.hostname not in LOOPBACK_HOSTS
            and not self.allow_insecure_upstream
        ):
            raise ConfigError(
                "refusing plaintext http upstream to a non-loopback host; "
                "set BROKER_ALLOW_INSECURE_UPSTREAM=1 to override"
            )

        if not self.upstream_token_file:
            raise ConfigError("BROKER_UPSTREAM_TOKEN_FILE is required")

        if not self.upstream_model:
            raise ConfigError("upstream model must not be empty")

    def redacted(self) -> dict:
        """A dict form safe to log: paths are kept, secrets are never here."""
        return asdict(self)


def validate_bind_host(host: str, *, allow_wildcard: bool) -> None:
    """Refuse wildcard binds unless explicitly allowed.

    :param host: configured bind address
    :param allow_wildcard: value of ``BROKER_ALLOW_WILDCARD_BIND``
    :raises ConfigError: when the host would expose the broker publicly
    """
    normalized = (host or "").strip().lower()
    if normalized in WILDCARD_BIND_HOSTS and not allow_wildcard:
        raise ConfigError(
            "refusing to bind to a wildcard address; the broker must listen on a "
            "private address (set BROKER_ALLOW_WILDCARD_BIND=1 only when the "
            "listener is firewalled)"
        )


def read_token_file(path: str, *, label: str = "token", min_chars: int = MIN_TOKEN_CHARS) -> str:
    """Read a secret from ``path`` with fail-closed permission checks.

    The secret's contents never appear in raised messages.

    :param path: filesystem path to a regular file holding the secret
    :param label: name used in error messages (never the value)
    :param min_chars: minimum length of the stripped secret
    :return: the stripped secret
    :raises ConfigError: when missing, group/world accessible, or too short
    """
    if not path:
        raise ConfigError(f"{label} file path is not configured")

    try:
        info = os.stat(path)
    except OSError:
        raise ConfigError(f"{label} file is missing or unreadable: {path}") from None

    if not stat.S_ISREG(info.st_mode):
        raise ConfigError(f"{label} file is not a regular file: {path}")

    if info.st_mode & 0o077:
        raise ConfigError(
            f"{label} file is group/world accessible: {path} (require mode 0600 or 0400)"
        )

    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read(min_chars * 64 + 4096)
    except OSError:
        raise ConfigError(f"{label} file is missing or unreadable: {path}") from None

    token = raw.strip()
    if len(token) < min_chars:
        raise ConfigError(f"{label} file must contain at least {min_chars} characters")

    return token


def _as_bool(value) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _coerce(name: str, value, target_type):
    """Coerce a config value to its declared type.

    ``from __future__ import annotations`` makes dataclass field types plain
    strings, so match on the type name rather than the object.
    """
    type_name = target_type if isinstance(target_type, str) else getattr(
        target_type, "__name__", str(target_type)
    )
    try:
        if type_name == "bool":
            return _as_bool(value)
        if type_name == "int":
            return int(str(value).strip(), 10)
        if type_name == "float":
            return float(str(value).strip())
        return str(value)
    except (TypeError, ValueError):
        raise ConfigError(f"invalid value for {name}") from None


def load_config(env: dict | None = None) -> Config:
    """Build a :class:`Config` from a JSON config file plus environment.

    :param env: environment mapping; ``os.environ`` when omitted
    :return: an unvalidated config (call :meth:`Config.validate`)
    """
    environ = os.environ if env is None else env
    values: dict = {}

    config_path = environ.get("BROKER_CONFIG_FILE", "").strip()
    if config_path:
        try:
            with open(config_path, "r", encoding="utf-8") as handle:
                parsed = json.load(handle)
        except OSError:
            raise ConfigError(f"config file is missing or unreadable: {config_path}") from None
        except json.JSONDecodeError:
            raise ConfigError(f"config file is not valid JSON: {config_path}") from None
        if not isinstance(parsed, dict):
            raise ConfigError("config file must contain a JSON object")
        known = {field.name for field in fields(Config)}
        unknown = sorted(set(parsed) - known)
        if unknown:
            raise ConfigError(f"unknown config keys: {', '.join(unknown)}")
        values.update(parsed)

    for field in fields(Config):
        env_key = f"BROKER_{field.name.upper()}"
        if env_key in environ and str(environ[env_key]).strip() != "":
            values[field.name] = environ[env_key]

    coerced = {}
    for field in fields(Config):
        if field.name in values:
            coerced[field.name] = _coerce(field.name, values[field.name], field.type)

    return Config(**coerced)
