"""sure-ai-broker: an OpenAI-compatible tool-call shim.

Sure speaks OpenAI Chat Completions with ``tools``/``tool_calls``. The backends
available to it run their own server-side agent loop and will not hand back
client-defined function calls. This package bridges the two: it accepts a real
OpenAI tool-calling request, prompts a *text-only* backend with a strict JSON
protocol, validates whatever comes back against the caller's own tool
allowlist and schemas, and returns a standard chat completion.

The broker holds no financial data and no Sure credentials. Sure stays the only
financial authority: it authenticates the web user, decides which accounts are
in scope, and executes every function itself.
"""

from .broker import Broker, ClientError, TurnOutcome
from .config import Config, ConfigError, load_config, read_token_file
from .upstream import FakeUpstream, Upstream, UpstreamError, UpstreamOpenAICompat

__all__ = [
    "Broker",
    "ClientError",
    "Config",
    "ConfigError",
    "FakeUpstream",
    "TurnOutcome",
    "Upstream",
    "UpstreamError",
    "UpstreamOpenAICompat",
    "load_config",
    "read_token_file",
]

__version__ = "0.1.0"
