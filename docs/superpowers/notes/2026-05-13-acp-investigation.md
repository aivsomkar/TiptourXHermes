# ACP adapter investigation — 2026-05-13

## Entrypoint

Module name or binary to launch: `acp_adapter` (also exposed as console scripts `hermes-acp` and `hermes acp` after `pip install hermes-agent[acp]`).

Exact invocation: `python -m acp_adapter`

Notes:
- `acp_adapter/__main__.py` calls `acp_adapter.entry.main()`.
- `entry.py` routes all `logging` to **stderr** so stdout is clean for JSON-RPC.
- Hermes loads env vars from `~/.hermes/.env` at startup; per-process env vars (e.g. `GEMINI_API_KEY`) are still respected.
- The pyproject extra needed is `[acp]` (pulls `agent-client-protocol==0.9.0`). It is included in `hermes-agent[all]` per `pyproject.toml:177-210`, so our bundler's `[all]` install covers it.

## Protocol

This is **not a hand-rolled JSON-RPC schema.** The adapter implements the standard [Agent Client Protocol (ACP)](https://github.com/zed-industries/agent-client-protocol) from Zed, via the `acp` Python library. `acp_adapter/server.py:445` defines `class HermesACPAgent(acp.Agent)` and overrides the protocol's standard methods.

Wire framing: **newline-delimited JSON-RPC over stdio** (one JSON object per line). To be confirmed empirically in Task 5 — if our smoke test sees `Content-Length` headers in stdout instead, we'll switch to LSP-style framing.

## Methods supported (Swift → Hermes)

The full ACP method surface, taken from override sites in `acp_adapter/server.py`:

- `initialize` — protocol handshake. Client sends its `ClientCapabilities`; agent responds with its `AgentCapabilities`, supported `auth_methods`, and `ModelInfo`. (server.py:737)
- `authenticate` — provider auth. `params.method_id` must equal the agent's configured provider name. (server.py:780)
- `new_session` — create a fresh session. Params can include MCP server registrations (`McpServerStdio` / `McpServerHttp` / `McpServerSse`). Returns `NewSessionResponse` with the new `session_id`. (server.py:930)
- `load_session` — load an existing session by id. (server.py:958)
- `resume_session` — resume a previously created session. (server.py:976)
- `cancel` — cancel the active turn in `session_id`. (server.py:994)
- `fork_session` — fork an existing session. (server.py:1008)
- `list_sessions` — enumerate sessions. (server.py:1024)
- `prompt` — **this is the "send a user message" method.** Takes `session_id` plus a `prompt: list[TextContentBlock | ImageContentBlock | AudioContentBlock | ResourceContentBlock | EmbeddedResourceContentBlock]`. Returns `PromptResponse(stop_reason=...)` **when the turn completes**. Streamed output arrives via `session/update` notifications during execution. (server.py:1071)
- `set_session_model` — switch model mid-session. (server.py:1651)
- `set_session_mode` — switch agent mode. (server.py:1685)
- `set_config_option` — set a session config knob. (server.py:1698)

## Notifications emitted (Hermes → Swift)

ACP uses a single notification method, `session/update`, multiplexed over an `update` payload whose `sessionUpdate` discriminator selects the variant:

- `session/update` with `AgentMessageChunk` — streamed agent text. (events.py, via `conn.session_update(...)`)
- `session/update` with `UserMessageChunk` — echoed/streamed user content.
- `session/update` with `ToolCallStart` (`acp_adapter/tools.py:931` produces these) — agent has begun a tool call. Carries `tool_call_id`, name, args, and `ToolCallLocation` for UI hinting.
- `session/update` with `ToolCallProgress` — incremental updates to an in-flight tool call.
- `session/update` with `ToolCallEnd` — tool call completed (used inside the events pipeline at events.py:162 via `tool_call_meta.pop`).
- `session/update` with `AvailableCommandsUpdate` — the agent's slash-command palette changed.
- `session/update` with `UsageUpdate` — token/cost usage delta.

Plus one **server → client REQUEST** (not a notification — expects a response):

- `session/request_permission` — agent is asking the user to approve a destructive/expensive action. The client must reply with the user's choice. The adapter wires this up at server.py:1188 via `make_approval_callback(conn.request_permission, ...)` and the implementation in `acp_adapter/permissions.py:27`.

## End-of-turn signal

There is **no `agent.done` notification.** End-of-turn is the JSON-RPC **response** to the originating `prompt` request, carrying `stop_reason ∈ {"end_turn", "max_tokens", "refusal", "cancelled", ...}` (`PromptResponse`).

This invalidates the smoke-test skeleton in Plan 1 Task 5, which polls notifications for `DONE_NOTIFICATION_METHOD = "agent.done"`. The corrected smoke test must:
1. Send `initialize` → await response.
2. Send `new_session` → await response, capture `session_id`.
3. Send `prompt` → consume `session/update` notifications until the `prompt` **response** itself arrives.

Both the Python smoke test (Task 5) and the Swift `testBundledRuntimeAcceptsJSONOverStdio` (Task 7) will be rewritten against this flow.

## Gaps vs. our spec

| Our spec concept | ACP equivalent | Status |
|---|---|---|
| `user.message` | `prompt(session_id, [TextContentBlock(text=…)])` | ✓ present |
| `agent.message` (streamed) | `session/update` w/ `AgentMessageChunk`; `PromptResponse` for end-of-turn | ✓ present |
| `tool.call` / `tool.result` | `session/update` w/ `ToolCallStart` → `ToolCallProgress` → `ToolCallEnd` | ✓ present, but **tools execute inside the Hermes process** |
| `approval.request` / `approval.response` | `session/request_permission` (server→client REQUEST, awaits response) | ✓ present |
| `tool.call` with `destination: "local"` (Mac-side tool execution) | **Not a first-class concept in ACP.** Workaround: have Swift expose Mac tools as an **MCP server** and register it in `new_session` params via `McpServerStdio`/`McpServerHttp`/`McpServerSse`. Hermes will then call those tools the same way it calls any other MCP tool. | ⚠ no direct match — MCP bridge is the path forward |

## Conclusion

- [x] **Use ACP adapter as-is with a small caveat (no Hermes fork needed).**
- [ ] Use ACP adapter with a small Hermes plugin we own (list gaps)
- [ ] Skip ACP, write our own JSON protocol over stdio (recommend if 3+ critical gaps)

**Caveat:** Mac-side tool execution (the "destination: local" idea from our spec) must be implemented as an MCP server inside the Swift app rather than as a custom ACP method. This is a Plan 2/3 concern — Plan 1's smoke tests do not need it.

**Plan 1 deltas:**
- Task 3 `Build/bundle-hermes.sh` entrypoint: substitute `<ACP_ENTRYPOINT_MODULE>` with `acp_adapter` (so the runtime script execs `python -m acp_adapter`).
- Task 5 Python smoke test: rewrite from the `user.message` / `agent.done` placeholder to a real ACP `initialize` → `new_session` → `prompt` flow that asserts on the `PromptResponse`.
- Task 7 Swift smoke test: same rewrite — at minimum send `initialize` so we get *any* JSON-RPC frame back; ideally do the full flow.
