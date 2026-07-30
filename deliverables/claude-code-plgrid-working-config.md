# Claude Code against PLGrid Forge — verified working configuration

**Status: verified end-to-end on 2026-07-30.** Claude Code **2.1.220** → CLIProxyAPI
**7.2.110** → PLGrid Forge (`https://llmlab.plgrid.pl/api/v1`) → `zai-org/GLM-5.2-FP8`,
completing a multi-turn agentic loop with parallel tool calls and a correct answer.

This is above the Claude Code version where the mid-conversation system-role regression
appears (vLLM #48874, observed at 2.1.207), and no equivalent configuration was published
anywhere as of 2026-07-30 — see `../research/claude-code-openai-compatible-proxies.md`.

---

## Why a proxy is required here

PLGrid Forge is a **hosted OpenAI-compatible gateway**. You do not control the serving stack,
so chat-template edits, vLLM version pins and server-side patches are all unavailable. Probed
directly (2026-07-30, authenticated):

| Endpoint | Result |
|---|---|
| `POST /api/v1/messages` (Anthropic Messages) | **404** |
| `POST /api/v1/chat/completions` | **200** |
| `POST /api/v1/responses` (OpenAI Responses) | **404** |

Claude Code speaks Anthropic dialect only, so translation is mandatory. And because
`/responses` is absent, **LiteLLM and Bifrost fail out of the box** — both route the Anthropic
`/v1/messages` path to the upstream's Responses API by default.

CLIProxyAPI targets `/chat/completions` directly
(`internal/runtime/executor/openai_compat_executor.go`), which is why it is the right tool.

## Why it survives the system-role regression

Claude Code ≥ ~2.1.154 sends its agent-registry context as a `{"role":"system"}` entry **inside**
`messages[]`, after the user turn, leaving the prompt ending on a system block. CLIProxyAPI
coerces it to `user` **in place** (`internal/translator/openai/claude/openai_claude_request.go`):

```go
if role == "system" {
    if reminderText, ok := translatorcommon.ClaudeMessageSystemReminderText(contentResult); ok {
        msgJSON := []byte(`{"role":"user","content":[{"type":"text","text":""}]}`)
        msgJSON, _ = sjson.SetBytes(msgJSON, "content.0.text", reminderText)
        messageItems = append(messageItems, msgJSON)
    }
    return true
}
```

In place, not hoisted — so the leading prefix is unchanged and prefix caching is preserved.
That is the both-ways-correct outcome that neither vLLM nor SGLang currently manages.

Observed on the wire, from the proxy's own request log:

```
IN  (Anthropic, from Claude Code): ['user(text)', 'system(text)']
OUT (OpenAI, to PLGrid)          : ['system(text)', 'user(text)', 'user(text)']
```

And the full loop, third request:

```
IN  : ['user(text)','system','assistant(tool_use)','user(tool_result)',
       'assistant(tool_use)','user(tool_result)']
OUT : ['system(text)','user(text)','user(text)','assistant(tool_calls)','tool',
       'assistant(tool_calls)','tool','tool','tool']
```

Three assistant turns, parallel tool calls translated correctly, correct final answer.

## The one gotcha: PLGrid rejects `reasoning_effort`

First attempt failed with `API Error: 422 Request validation failed`. The upstream detail:

```json
{"message":"Request validation failed.",
 "detail":[{"field":"body.reasoning_effort",
            "message":"Extra inputs are not permitted","type":"extra_forbidden"}]}
```

PLGrid's gateway validates strictly (`extra_forbidden`). CLIProxyAPI sends `reasoning_effort`
for reasoning-capable models; PLGrid does not accept it. Fixed with a `payload.filter` rule
that strips the field. **This is the single non-obvious step** — without it nothing works, and
the error surfaces to the user only as a bare `422`.

---

## Configuration

`config.yaml` — replace `<PLGRID_API_KEY>` with your grant key from
llmlab.plgrid.pl → Grants → Generate API Key. Keep the file at mode `600`; it holds a secret.

```yaml
# Bound to loopback and api-keys populated deliberately: the shipped defaults are
# host:"" (all interfaces) with fail-open auth, i.e. an open relay to your key.
host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
debug: false
request-log: true          # writes <auth-dir>/logs/*.log — invaluable for diagnosis

api-keys:
  - "local-test-key"       # what Claude Code presents as ANTHROPIC_AUTH_TOKEN

openai-compatibility:
  - name: "plgrid"
    base-url: "https://llmlab.plgrid.pl/api/v1"
    api-key-entries:
      - api-key: "<PLGRID_API_KEY>"
    models:
      - name: "zai-org/GLM-5.2-FP8"
        alias: "glm-5.2"
        display-name: "GLM-5.2 FP8 (PLGrid)"
      - name: "Qwen/Qwen3.6-27B"
        alias: "qwen3.6-27b"
      - name: "google/gemma-4-31B"
        alias: "gemma-4-31b"

# PLGrid's gateway is strict (extra_forbidden) and rejects reasoning_effort,
# which CLIProxyAPI sends for reasoning-capable models. Strip it.
payload:
  filter:
    - models:
        - name: "*"
          protocol: "openai"
      params:
        - "reasoning_effort"
```

Run it:

```bash
./cli-proxy-api --config config.yaml
```

Launch Claude Code:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8317
export ANTHROPIC_AUTH_TOKEN=local-test-key
export ANTHROPIC_MODEL=glm-5.2
export ANTHROPIC_DEFAULT_HAIKU_MODEL=gemma-4-31b   # keeps compaction off the big model
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=32768         # PLGrid caps output at 32768
export CLAUDE_CODE_ATTRIBUTION_HEADER=0            # per-request hash defeats prefix caching
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
claude
```

### Why each Claude Code variable is there

- **`ANTHROPIC_DEFAULT_HAIKU_MODEL=gemma-4-31b`** — Claude Code runs *conversation
  summarization* (i.e. compaction) and background tasks on the haiku tier. Left unset it
  defaults to the primary model, putting every compaction on GLM-5.2. Gemma-4-31B is the right
  model for this job: cheap, and its weaknesses matter less for summarization.
- **`CLAUDE_CODE_MAX_OUTPUT_TOKENS=32768`** — PLGrid enforces `input + max_tokens <= context`
  and caps output at 32768. Claude Code otherwise sends `max_tokens: 128000` (observed).
- **`CLAUDE_CODE_ATTRIBUTION_HEADER=0`** — Claude Code prepends a per-request hash to the
  system prompt, so the KV prefix misses every turn. Unsloth measures the cost as "90% slower
  with local models".

## Model notes for this gateway

Measured limits from the OpenCode plugin (`.opencode/plugins/plgrid.js`), which took them from
the gateway's own error messages and `function_calling_supported` field:

| Model | Context | Output cap | Tool calling | Reasoning |
|---|---|---|---|---|
| `zai-org/GLM-5.2-FP8` | 393,216 | 32,768 | yes | `reasoning_content` |
| `Qwen/Qwen3.6-27B` | 262,144 | 32,768 | yes | `reasoning_content` |
| `google/gemma-4-31B` | 262,144 | 32,768 | yes | none |
| `zai-org/GLM-4.7-Flash` | 202,752 | 32,768 | yes | `reasoning_content` |
| `Qwen/Qwen3.6-35B-A3B` | 262,144 | 32,768 | yes | `reasoning_content` |

Note GLM-5.2's context here is **393,216, not the 1M the model card advertises** — PLGrid caps
it. Do not set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000` as Z.ai's own guide suggests.

Unusable for Claude Code (no function calling): `Qwen/QwQ-32B`, `Qwen/Qwen3-VL-8B-Instruct`,
`speakleash/Bielik-11B-v2.6-Instruct`, `CYFRAGOVPL/Llama-PLLuM-70B-chat-250801`,
`CYFRAGOVPL/pllum-12b-nc-chat-250715`, `meta-llama/Llama-3.3-70B-Instruct`.

`GET /models` also returns **`deepseek-ai/DeepSeek-V4-Flash`**, which the OpenCode plugin's
model map does not list — worth adding there.

## Caveats worth stating

- **CLIProxyAPI is dual-purpose.** The BYOK `openai-compatibility` path used here is clean
  plain-API-key code, but the same binary contains uTLS Cloudflare-fingerprint evasion
  (`internal/auth/claude/utls_transport.go`) and a `disable-claude-cloak-mode` flag for
  impersonating the Claude Code CLI. None of it is exercised by this config. Decide whether
  shipping that binary is acceptable in your environment.
- **Defaults are unsafe.** `host: ""` binds all interfaces and auth is fail-open when
  `api-keys` is empty — an unauthenticated relay to your grant key. Both are overridden above.
- **Release churn is extreme** — 100+ releases in 60 days, module path at `/v7`. Pin the
  version and read release notes before upgrading.
- **Anthropic does not support this.** "Anthropic doesn't endorse, maintain, or audit
  third-party gateway products, and doesn't support routing Claude Code to non-Claude models
  through any gateway." Expect no vendor help when a Claude Code release breaks translation.
- **Not yet exercised here:** subagents, `/compact` on a long session, images, and MCP tools.
  Subagent model routing is broken upstream in Claude Code regardless
  (anthropics/claude-code#43869), and subagent prompt caching is hardcoded off (#29966).

## Reproducing the verification

```bash
cd <workspace-with-a-few-txt-files>
claude -p "Use the Read tool to read every .txt file in this directory, then reply with one
line: the filenames in alphabetical order followed by the total word count." \
  --strict-mcp-config --allowedTools Read Glob
```

Expected: a correct single-line answer. Then inspect `<auth-dir>/logs/v1-messages-*.log` and
confirm the outgoing message array ends on a `user` turn rather than a `system` one, and that
`assistant(tool_calls)` / `tool` pairs appear across multiple requests. A text-only reply with
`stop_reason: end_turn` and no tool calls is the #48874 signature.
