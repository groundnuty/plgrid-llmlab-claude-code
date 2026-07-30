# PLGrid Forge — observed performance, 2026-07-30

Measured incidentally while validating a Claude Code integration, not as a benchmark. Shared
because the numbers may be useful to the team operating the gateway. All figures come from a
local translating proxy (CLIProxyAPI 7.2.110) sitting between the client and
`https://llmlab.plgrid.pl/api/v1`, so they are upstream latency plus a negligible translation
hop on the same machine. Grant 94. Single client, no attempt to load-test.

**Please read the caveats before quoting any of this.**

## Request latency

`/v1/messages` here means one Anthropic-format request translated to one upstream
`/chat/completions` call.

| Endpoint | Status | n | Median | p90 | Max |
|---|---|---|---|---|---|
| `/v1/messages` | 200 | 128 | **4.32s** | **10.07s** | **152.0s** |
| `/v1/messages` | 400 | 13 | 0.62s | 3.69s | 7.35s |
| `/v1/messages` | 422 | 11 | 0.16s | 0.19s | 0.19s |
| `/v1/messages/count_tokens` | 200 | 246 | 0.01s | 0.02s | 0.04s |

`count_tokens` is answered locally by the proxy and never reaches PLGrid — included only so it is
not mistaken for a gateway measurement.

The 152s maximum is the number worth attention: **large-context requests on GLM-5.2-FP8 took
2m12s and 2m32s**. Both completed successfully. Requests at that size consistently ran two
orders of magnitude slower than the median, which made an interactive agent session feel stalled
— the client shows no progress indicator distinguishing "slow" from "hung".

## Per-model wall-clock on an identical task

One run each, same prompt, same proxy, sequential. The task requires a directory glob, three
parallel file reads, and a synthesis turn — so it measures an agentic loop end to end, not raw
token throughput. Correct answer was verifiable.

| Model | Wall clock | Answer correct? |
|---|---|---|
| `zai-org/GLM-5.2-FP8` | **11s** | yes |
| `zai-org/GLM-4.7-Flash` | 12s | **no** — reported 21 words instead of 3 |
| `Qwen/Qwen3.6-35B-A3B` | 14s | yes |
| `google/gemma-4-31B` | 16s | yes |
| `Qwen/Qwen3-Coder-30B-A3B-Instruct` | 28s | yes |
| `Qwen/Qwen3.6-27B` | **50s** | yes |

Two observations. **GLM-5.2-FP8 was both the fastest and the only one that was fastest *and*
correct** — an unusual combination, and it makes it the obvious default. **Qwen3.6-27B is ~4.5×
slower than GLM-5.2** on the same work despite being far smaller, which is worth checking on the
serving side; a 27B dense model trailing a 744B MoE by that margin suggests configuration rather
than capacity.

Client-reported throughput across all sessions ranged **5.4k–21.6k tokens/s**, varying with
context size rather than model.

## Availability observations

- **Grant 94 cannot reach three advertised models.** `GET /models` lists 17 entries, but
  `Qwen/Qwen3.5-397B-A17B-FP8`, `Qwen/Qwen3.5-122B-A10B` and `deepseek-ai/DeepSeek-V4-Flash`
  all return `400 … not available for grant '94'`. If the model list is intended to be
  grant-scoped, it currently is not — enumeration does not imply entitlement, which makes
  client-side model pickers list options that cannot work.
- **`Kimi K3` / Moonshot models are not yet present** (checked 2026-07-30).
- No 5xx originating from PLGrid was observed. The 502/503 responses in the logs were generated
  by the local proxy (unknown-model and credential-cooldown respectively), not by the gateway.

## Two API-surface notes

Neither is a defect, but both cost time to discover and may be worth documenting:

1. **`reasoning_effort` is rejected outright.** The gateway validates with `extra_forbidden`:
   ```json
   {"detail":[{"field":"body.reasoning_effort","message":"Extra inputs are not permitted",
               "type":"extra_forbidden"}]}
   ```
   Any OpenAI-dialect client that sets `reasoning_effort` for reasoning-capable models — which is
   normal for GLM and Qwen — fails with a bare `422` until the field is stripped. Silently
   ignoring unknown parameters, as OpenAI's own API does, would remove a sharp edge.

2. **Context-limit errors use three different wordings.** All are clear to a human; the variation
   matters only to clients that pattern-match:
   ```
   This model's maximum context length is 32768 tokens. However, your request has 66511 input
   tokens. Please reduce the length of the input messages. (parameter=input_tokens, value=66511)

   'max_tokens' or 'max_completion_tokens' is too large: 4096. This model's maximum context
   length is 32768 tokens and your request has 30850 input tokens (4096 > 32768 - 30850).

   max_tokens=500000 cannot be greater than max_model_len=max_total_tokens=393216. Please
   request fewer output tokens. (parameter=max_tokens, value=500000)
   ```
   Credit where due: all three state the real limit *and* the actual usage, which is more than
   most gateways provide and made automatic recovery possible downstream.

## Caveats

- Single client, single session, no concurrency beyond 30 parallel `count_tokens` calls (all 200).
- One run per model on the task table; no repetition, so treat the ordering as indicative and the
  absolute numbers as approximate.
- Measurements span roughly 12:00–14:30 local on one day; no view of diurnal load.
- Latency includes network from a laptop, not a colocated client.
- The GLM-4.7-Flash wrong answer was a single arithmetic slip on one trial, not a protocol
  failure. It should not be read as a capability verdict without repetition.
