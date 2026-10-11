# Sure AI broker

A small, stdlib-only, OpenAI-compatible shim that lets Sure's native tool loop use a
**text-only** OAuth-backed model.

## Why it exists

Sure executes all financial functions itself, scoped to the signed-in chat owner's
`accessible_accounts`. Generic agent gateways (Hermes API server, OpenClaw gateway) run their
own server-side agent loop and do not return client-defined `tool_calls`, so they cannot drive
Sure's tool loop. The broker prompts a plain text model with a strict JSON protocol, validates
the reply, and returns standard OpenAI `tool_calls` to Sure.

## Guarantees

- Auth: bearer token from a mode-0600 file (>= 32 chars); constant-time comparison.
- Private bind only; wildcard bind needs an explicit override.
- Clients cannot choose model, URL, headers or routing; the upstream is fixed server-side.
- The upstream receives no `tools` field; it is only ever sent plain messages.
- Tool names must be in the request's allowlist; arguments are schema-validated; call count is capped.
- Tool results are wrapped as untrusted data with neutralised delimiters.
- Session keys must match `sure-chat-<64 hex>` (full match); otherwise a fresh random key per request.
- Logs never contain message content, tool output, tokens or headers.

## Configuration

Environment variables (`BROKER_*`) or a JSON file named by `BROKER_CONFIG_FILE`
(environment wins). Required: `BROKER_TOKEN_FILE`, `BROKER_UPSTREAM_BASE_URL`,
`BROKER_UPSTREAM_TOKEN_FILE`. See `sure_ai_broker/config.py` for all options and limits.

## Run tests

```
cd sure-ai-broker
python3 -m unittest discover -v tests
```

## Limitations

`UpstreamOpenAICompat` is written against the generic OpenAI chat-completions spec and has not
been verified against any specific gateway. Streaming is rejected (fail closed).
