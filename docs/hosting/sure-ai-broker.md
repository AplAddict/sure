# Sure AI broker (embedded AI with an OAuth-backed text model)

Sure is the only financial authority. The broker is a pure text-reasoning shim.

## Architecture

1. The signed-in Sure user chats in the web UI.
2. Sure's `Assistant::Builtin` runs the tool loop and executes every financial function itself,
   scoped to `chat.user.accessible_accounts`.
3. Sure calls the broker as a custom OpenAI-compatible provider (`OPENAI_URI_BASE`,
   `OPENAI_ACCESS_TOKEN`, `OPENAI_MODEL`). Sure sends `tools`, messages and an opaque
   `user` value: `sure-chat-<sha256(owner id)>`.
4. The broker prompts a text-only upstream model, validates its reply, and returns OpenAI
   `tool_calls` or a final message.
5. The upstream holds no Sure credentials, no tools, no MCP token and no cross-user memory.

`Assistant::External` stays disabled. Do not store a Sure OAuth/MCP token in the upstream.

## Required verification before enabling

Run each against the real Sure tool path and record the results:

1. Two-family isolation: as each of the two live users, ask for accounts and holdings; confirm
   neither sees the other's data, and the broker's upstream payloads contain only that user's data.
2. Forced tool call: a prompt that needs `get_accounts` produces a valid tool call and a grounded answer.
3. Unauthenticated and wrong-token requests to the broker return 401.
4. The broker listener is not reachable from the public internet or the LAN beyond the Sure containers.
5. Logs contain no message content or tokens.
6. Rollback: unsetting the provider env vars returns Sure to AI-disabled.

## Deployment variables

See `sure-ai-broker/README.md` and `sure-ai-broker/deploy/sure-ai-broker.service.example`.
Credential files must be mode 0600; never commit them.

## Threat model summary

Cross-user leakage is prevented by Sure-side tool scoping plus per-owner session keys at the
broker. Prompt injection through tool data cannot add tools: the broker accepts only names in the
request allowlist with schema-valid arguments. The broker cannot reach the network except the one
configured upstream.
