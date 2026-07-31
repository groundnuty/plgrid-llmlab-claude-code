# Client-compatibility notes for LLMLab

Written for the ACK Cyfronet LLMLab team. Context: we run the Claude Code CLI against LLMLab models
through a translating proxy ([CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), our fork at
[groundnuty/CLIProxyAPI](https://github.com/groundnuty/CLIProxyAPI)). Claude Code speaks the Anthropic
Messages dialect; LLMLab serves OpenAI-compatible endpoints, so something has to translate.

Three changes were needed, plus one configuration workaround. **None of them require anything from
you** — they are all client-side, and are recorded here because you asked, and because two of them
are worth knowing when other teams hit the same walls. Two genuine issues on your side are listed at
the end.

Everything below was measured on grant 94 between 2026-07-30 and 2026-07-31.

## 1. The reasoning field has two spellings

**The single highest-impact difference.** Chain-of-thought is returned under different keys depending
on the backend:

| Backend | Field |
|---|---|
| vLLM's OpenAI-compatible server (and gateways on top of it) | `reasoning` |
| DeepSeek-style backends | `reasoning_content` |

Our proxy read only `reasoning_content`. The result was not an error — it was **silent total loss of
reasoning**. Three of the four reasoning models we tested returned no thinking content at all, and
for reasoning-first models the visible answer could arrive empty because the entire response had gone
into a field nobody read.

Measured before and after the fix, same prompt and model:

| Model | Reasoning chunks before | After |
|---|---|---|
| GLM-5.2-FP8 | 0 | 42 |
| Qwen3.6-27B | 0 | 120 |

The fix is three lines — accept either spelling, preferring `reasoning_content`:

```go
func openAIReasoningNode(container gjson.Result, prefix string) gjson.Result {
	if node := container.Get(prefix + "reasoning_content"); node.Exists() {
		return node
	}
	return container.Get(prefix + "reasoning")
}
```

**Worth flagging to other users of the gateway.** Any client written against a DeepSeek-style backend
will lose reasoning from your vLLM-served models without reporting anything wrong. It looks like the
model simply does not reason.

## 2. Errors arrive under `detail`, not `message`

FastAPI-based upstreams — vLLM and SGLang, and gateways fronting them — report errors as:

```json
{"detail": "..."}
```

where the OpenAI dialect specifies `{"error": {"message": "..."}}`. A client reading `message` finds
nothing and typically passes the whole JSON blob through as the error text. We now read `detail` as a
fallback.

This is a deviation from the OpenAI spec that originates upstream in vLLM, not in your deployment.

## 3. Context-limit errors are phrased differently, which breaks auto-compaction

This one had a disproportionate effect: **sessions died instead of recovering.**

Claude Code decides whether an over-length prompt is recoverable by matching the upstream error text
against roughly `prompt is too long[^0-9]*(\d+)\s*tokens?\s*>\s*(\d+)`. On a match it compacts the
conversation and retries. On no match, the error reaches the user and the session ends.

vLLM describes the identical condition in its own words:

```
This model's maximum context length is 32768 tokens. However, your request has
66511 input tokens. Please reduce the length of the input messages.
```

Semantically the same, lexically unrecognisable. We now rewrite such messages into the phrasing the
client matches, preserving the original text so no diagnostic detail is lost. After the fix,
compaction fires and sessions survive.

This is not something you should change — your message is clearer than the one the client expects.
It is a translation problem, and the translator is the right place to solve it.

## 4. Configuration workaround: `reasoning_effort`

Anthropic-dialect clients send a `reasoning_effort` parameter that vLLM does not accept. We strip it
for the LLMLab leg only:

```yaml
payload:
  filter:
    - models:
        - name: "*"
          protocol: "openai"
      params:
        - "reasoning_effort"
```

No code change; purely configuration.

## What we did *not* need

Worth stating, because we expected to and did not:

- **No changes for vLLM version skew as such.** We were told GLM runs vLLM 0.24 while other models
  run whatever version was current at their launch. We found no version-dependent behaviour that
  needed handling beyond the field-name difference in §1, which is a spelling variation rather than a
  version break.
- **No tool-calling workarounds.** Tool calls round-trip correctly. We specifically tested the
  hypothesis that GLM was truncating multi-step tool sequences: it was not. Raw API, 5/5 tool calls
  in both streaming and non-streaming; through the full client, `tool_use=5, tool_result=5`.
  vLLM issue #39757 does not reproduce on 0.24.
- **No streaming changes.** SSE framing is correct.

## Two things that would help, on your side

**1. `tool_choice: "required"` returns 500 on GLM-4.7-Flash.** Other models on the gateway return 200
for the same request. This is latent for us — Claude Code never sends it — but it will bite anyone
using constrained tool calling. Reproduces consistently.

**2. `GET /models` lists models the grant cannot use.** Grant 94 sees `Qwen3.5-397B`,
`Qwen3.5-122B` and `DeepSeek-V4-Flash` in the catalogue, but requests against them fail on
entitlement. A client that trusts the catalogue will offer users models that cannot work. If the
listing could reflect per-grant entitlement, or if the failure named entitlement explicitly, that
would be much easier to handle.

## Reference

Fork with all three fixes, tests, and measurements:
[groundnuty/CLIProxyAPI](https://github.com/groundnuty/CLIProxyAPI) — commits `52c580d3` (reasoning
field) and `b2d2dc47` (error normalisation). Neither is upstream yet. The reasoning-field fix applies
to any vLLM-backed gateway, so it is the one we would most like to contribute back.

Setup and full measurements:
[groundnuty/plgrid-llmlab-claude-code](https://github.com/groundnuty/plgrid-llmlab-claude-code).
