# Claude Code on PLGrid Forge

Run the Claude Code CLI against PLGrid Forge (ACK Cyfronet) models. Verified end-to-end on
2026-07-30 with Claude Code **2.1.220** and CLIProxyAPI **7.2.110** plus two local fixes.

Files here: `cli-proxy-api.config.yaml` (proxy), `claude-settings.json` (project settings,
GLM-5.2 primary), `claude-settings-qwen-primary.json` (same with Qwen3.6-27B primary),
`statusline.sh` (context display). Investigation history and evidence:
`../claude-code-plgrid-working-config.md`. Gateway performance notes for the operators:
`../plgrid-forge-observed-performance.md`.

---

## Why a proxy is needed

PLGrid Forge is a hosted OpenAI-compatible gateway. Probed directly:

| Endpoint | Result |
|---|---|
| `POST /api/v1/chat/completions` | **200** |
| `POST /api/v1/messages` (Anthropic) | 404 |
| `POST /api/v1/responses` (OpenAI Responses) | 404 |

Claude Code speaks Anthropic dialect only, so translation is mandatory. Because `/responses` is
absent, **LiteLLM and Bifrost fail out of the box** — both default the Anthropic path to the
upstream's Responses API. CLIProxyAPI targets `/chat/completions` directly, which is why it is the
right tool here.

## Install

```bash
# 1. Proxy, built from the fork — main carries both required fixes (needs Go 1.26)
git clone https://github.com/groundnuty/CLIProxyAPI && cd CLIProxyAPI
go build -o cli-proxy-api ./cmd/server

# 2. Config, with your grant key from llmlab.plgrid.pl -> Grants -> Generate API Key
mkdir -p ~/.cli-proxy-api
cp <this-dir>/cli-proxy-api.config.yaml ~/.cli-proxy-api/config.yaml
$EDITOR ~/.cli-proxy-api/config.yaml          # replace PLGRID_API_KEY
chmod 600 ~/.cli-proxy-api/config.yaml        # it holds a secret

# 3. Per-project Claude Code config
mkdir -p <project>/.claude
cp <this-dir>/claude-settings.json <project>/.claude/settings.json
cp <this-dir>/statusline.sh        <project>/.claude/statusline.sh
chmod +x                           <project>/.claude/statusline.sh

# 4. Run
./cli-proxy-api --config ~/.cli-proxy-api/config.yaml    # leave running
cd <project> && claude                                   # accept the trust prompt once
```

Everything is project-scoped deliberately. **Nothing belongs in `~/.claude/settings.json`** — these
choices are specific to this gateway and should not follow you into unrelated projects.

The stock 7.2.110 release works for everything **except** automatic context-limit handling and
reasoning/thinking blocks. Both need the fork; see [Required fixes](#required-fixes).

## What you get

```
glm-5.2-fp8-393k · 36.1k/393k █░░░░░░░░░░░░░░░░░░░ 9% · $0.18
```

Usage against the model's real window, with `⚠ COMPACT SOON` past 80%. Switching model with
`/model` picks up that model's limit automatically, because it is encoded in the alias.

## Context windows

**`CLAUDE_CODE_MAX_CONTEXT_TOKENS` sets the believed window to any value.** It is undocumented but
functional in 2.1.220. Measured, same model id, only the variable changed:

| Setting | Status line | Believed window |
|---|---|---|
| unset | 13.0% | ~206k |
| `262144` | 10.0% | ~269k |
| `393216` | 7.0% | ~396k |

With a truthful window everything downstream is simply correct: `/context` is accurate,
auto-compaction fires at the right point with no `CLAUDE_CODE_AUTO_COMPACT_WINDOW` override (the
documented clamp is "at most the model's context window"), and model ids stay honest.

**The variable is process-wide, so set it to the smallest window in the session** — a subagent on a
smaller model is the binding constraint:

| Session | Set to |
|---|---|
| GLM-5.2 only | `393216` |
| GLM-5.2 + Qwen or gemma subagent | `262144` |
| any session including GLM-4.7-Flash | `202752` |

A larger model added later does not raise the floor. Set it too high for any participating model and
that model overflows — which is what the context-limit fix catches.

**Compaction runs on the haiku tier and must fit the whole conversation in one request.** Point
haiku at a model with a smaller real window than the primary and large conversations become
unsummarisable. The settings file points all four tiers at one model to avoid this. If you do split
them, cap `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the smaller model's window.

## Models

| Alias | Real window | Notes |
|---|---|---|
| `glm-5.2-fp8-393k` | 393,216 | **Best default.** Fastest and correct (11s). Not multimodal. |
| `qwen3.6-35b-a3b-262k` | 262,144 | Correct, 14s |
| `gemma-4-31b-262k` | 262,144 | Correct, 16s. Handles images. |
| `qwen3-coder-30b-249k` | 249,600 | Correct, 28s |
| `qwen3.6-27b-262k` | 262,144 | Correct but 50s. Best coding benchmarks — good reviewer subagent. |
| `glm-4.7-flash-202k` | 202,752 | **Avoid.** Returned a confidently wrong answer. |

Both `glm-5.2-fp8-393k` (primary, Qwen/gemma subagents) and `qwen3.6-27b-262k` (primary, GLM/gemma
subagents) are verified working as the main model — use `claude-settings.json` or
`claude-settings-qwen-primary.json` respectively. `qwen3-vl-8b-262k` is also in the proxy config for
image work, since GLM-5.2 is not multimodal.

Note the Qwen-primary variant sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS: "262144"`, not 393216, even
though its GLM subagent has a larger window: the variable is process-wide and the **smallest**
participating window governs. Verified — the status line correctly read `262k`.

Grant 94 cannot reach `Qwen3.5-397B`, `Qwen3.5-122B` or `DeepSeek-V4-Flash` despite `GET /models`
listing them — enumeration is not entitlement. No Moonshot/Kimi models present as of 2026-07-30.

**A model needs roughly ≥64k real context to work in Claude Code at all.** The client's irreducible
baseline is ~19k (1.6k system prompt + 15.8k tool definitions + 1.5k skills) even with one tool and
no MCP, and compaction shrinks only conversation history. Bielik-11B at 32k is not viable. Every
model above clears this comfortably.

## Settings that are not optional

Each was found by failing first.

| Setting | Where | Why |
|---|---|---|
| `payload.filter` on `reasoning_effort` | proxy | PLGrid validates with `extra_forbidden`; every request otherwise dies with a bare `422`. Applies to **all** models, not just GLM. |
| `disable-cooling: true` | proxy | Cooldown is per (auth, model). With one credential any failure blacks out that model for ~60s with `503`, so a compaction retry hits the model it needs. |
| `CLAUDE_CODE_ATTRIBUTION_HEADER: "0"` | project | A per-request hash in the system prompt makes the KV prefix miss every turn. Unsloth measures "90% slower with local models". |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS: "32768"` | project | PLGrid caps output at 32768 and enforces `input + max_tokens <= context`. Claude Code otherwise sends 128000. |

## Subagents on different models

Works, verified on the wire in both directions. Pin by frontmatter:

```markdown
---
name: reviewer
description: Reviews code for correctness. Use after changes.
model: qwen3.6-27b-262k
tools: Read, Glob, Grep
---
```

Two prerequisites:

- **Allow-list the `Task` tool** — `"Task"`, or `"Task(<agent-name>)"` per agent — or dispatch is
  refused.
- **Launch with `--permission-mode acceptEdits`** (or `default`). Auto mode's classifier is
  unavailable for these models and dispatch fails with `denied by auto mode · Classifier
  unavailable`. This is **not** `--dangerously-skip-permissions`.

**Aliases must match exactly** between the proxy config and `ANTHROPIC_DEFAULT_*` / agent
frontmatter. A mismatch gives `502 unknown provider for model …`. Check with:

```bash
curl -s -H "Authorization: Bearer local-test-key" http://127.0.0.1:8317/v1/models | jq -r '.data[].id'
```

## Autonomous operation

Auto mode is unavailable for these models — the banner says so and falls back to manual. **You do
not need `--dangerously-skip-permissions`.** `permissions.allow` is deterministic pre-approval with
no classifier, so it is model-independent.

The gotcha: **rules match per command segment**, so a compound command needs every segment allowed.
GLM-5.2 habitually appends `; echo "exit: $?"`, which defeats `Bash(python3:*)` alone — hence
`Bash(echo:*)` in the settings file. Choosing "don't ask again" writes a *literal* rule to
`.claude/settings.local.json`, so pre-declaring patterns is better.

**The trust dialog has no flag or env var.** It is per-project state in the global `~/.claude.json`
under `projects["<abs-path>"].hasTrustDialogAccepted`. Until accepted, `permissions.allow` is
ignored entirely — `Ignoring N permissions.allow entries … this workspace has not been trusted` —
which matters for unattended first runs.

## Required fixes

Two fixes, both merged into `main` on `groundnuty/CLIProxyAPI`, both verified against PLGrid,
**neither upstream yet and no PR open**.

### 1. Reasoning/thinking blocks were being discarded

The response translator read reasoning only from `reasoning_content`. vLLM emits **`reasoning`**,
matching the OpenAI Responses API. Measured streaming chunks for one prompt:

| Model | `reasoning` | `reasoning_content` |
|---|---|---|
| GLM-5.2-FP8 | **42** | **0** |
| Qwen3.6-27B | **120** | **0** |
| Qwen3.6-35B-A3B | **120** | **0** |
| GLM-4.7-Flash | 81 | 81 (both) |

Three of four reasoning models lost their thinking entirely. The fourth emits both spellings, which
is why it is easy to miss: **the spelling depends on the vLLM version each model was deployed with**,
and operators pin that per model at launch. End-to-end A/B: stock delivered **0** thinking blocks,
patched delivered **1 block / 162 deltas**. For reasoning-first models this can also empty the
visible answer — a non-streaming GLM-5.2 probe returned reasoning text with `content: null`.

### 2. Context-limit errors were unrecognisable

Claude Code compacts only when the upstream message matches
`prompt is too long[^0-9]*(\d+)\s*tokens?\s*>\s*(\d+)`. PLGrid's wording does not. The fix restates
it, preserving the original text. Two compactable shapes are rewritten; a pure `max_tokens`
rejection is deliberately left alone, since compacting cannot fix it.

A/B on the same oversized request: stock leaks `API Error: 400 {"detail": …}`; patched emits
`prompt is too long: 66511 tokens > 32768 maximum (…)`, which the client acts on.

[PR #4321](https://github.com/router-for-me/CLIProxyAPI/pull/4321) upstream targets the same area but
does not solve this case — it gates on an `error.code` field PLGrid does not send and never produces
the required numeric shape. A PR should reference it.

## The proxy as a per-model compatibility layer

The gateway serves each model from whatever vLLM version was current at its deployment, so
"OpenAI-compatible" is a family of versions, not one API. The proxy is the right place to absorb the
differences. Measured surface:

| Model | `reasoning_effort` | `max_completion_tokens` | `tool_choice:"required"` |
|---|---|---|---|
| GLM-5.2-FP8 | 422 | 200 | 200 |
| GLM-4.7-Flash | 422 | 200 | **500** |
| Qwen3.6-27B | 422 | 200 | 200 |
| gemma-4-31B | 422 | 200 | 200 |

Request-shape differences need no code — `payload` rules take a model glob:

```yaml
payload:
  filter:                                   # strip what an upstream rejects
    - models: [{name: "*", protocol: "openai"}]
      params: ["reasoning_effort"]
  override:                                 # force a value for one model
    - models: [{name: "glm-4.7-flash-202k", protocol: "openai"}]
      params: {tool_choice: "auto"}
  default:                                  # set only if the client omitted it
    - models: [{name: "qwen3.6-*", protocol: "openai"}]
      params: {temperature: 0.6, top_p: 0.95}
```

That last rule is a real capability gain: the Qwen cards specify temperature 0.6 / top_p 0.95 for
precise coding and Claude Code exposes no sampling controls, so `payload.default` is the only place
to apply vendor-recommended sampling. Response-shape differences still need code.

**Diagnostic to run when a model is added or a deployment is upgraded** — this is what found fix 1:

```bash
for m in <model-ids>; do
  curl -s -N -X POST "$BASE/chat/completions" -H "Authorization: Bearer $KEY" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$m\",\"max_tokens\":120,\"stream\":true,
         \"messages\":[{\"role\":\"user\",\"content\":\"2+2? Answer briefly.\"}]}" \
  | grep -o '"reasoning[_a-z]*"' | sort | uniq -c
done
```

## Verified behaviour

All on the patched build with the canonical config.

| Capability | Result |
|---|---|
| Multi-turn agentic loop, real tool use | Diagnosed and fixed a real bug; 4/4 tests passing |
| Six of six reachable models complete a task | Verified |
| GLM-5.2 primary + Qwen/gemma subagents | Verified on the wire, per-agent ids, all 200 |
| Qwen3.6-27B primary + GLM/gemma subagents | Verified; status line correctly read 262k |
| Thinking blocks reaching the client | 16 of 18 requests (0 on stock) |
| Auto-compaction firing and recovering | `Compacting conversation…`, 111.4k → 34.6k, session continued |
| Manual `/compact` | 35,348 → 0 tokens, session usable after |
| `--resume` | Transcript reloaded, history retained |
| MCP tools | Server connected; GLM-5.2 returned a server-only sentinel value |
| `availableModels` with non-`claude` ids | Picker reduced to Default plus allowed models |
| Images | `Qwen3-VL-8B` and `gemma-4-31B` correct; GLM-5.2 is not multimodal |

**MCP needs nonessential traffic enabled.** The settings file sets
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"`; drop it if you use MCP, and do not pass
`--strict-mcp-config`.

## Known issues

**Prompting sensitivity on GLM-5.2.** It occasionally substitutes a cheaper tool or reports
completion early when a prompt makes the shortcut reasonable. Retested and largely exonerated: 5/5
tool calls in a direct API probe (streaming and not), and `tool_use=5, tool_result=5` through Claude
Code when the requirement was explicit. **Phrase requirements verifiably** ("read all five, then
report the marker from each") rather than by effort ("read them completely").

**Not upstream.** Both fixes need a source build and manual rebasing on upstream releases until a PR
lands.

**Unexplained.** 74 of 158 `count_tokens` calls returned `503` in one window and the cause was never
established (`disable-cooling: true` is the leading hypothesis, now set; not reproducible since). And
GLM-4.7-Flash returns `500` on `tool_choice: "required"` where other models return 200 — latent,
since Claude Code never sent `tool_choice` across 40 logged requests. A `payload.override` forcing
`auto` is the shim if it surfaces.

**Untested.** `/rewind`, hooks, plugins, and long unattended runs (hours) behind the proxy.

**Anthropic does not support this configuration.** "Anthropic doesn't endorse, maintain, or audit
third-party gateway products, and doesn't support routing Claude Code to non-Claude models through
any gateway." Expect no vendor help when a Claude Code release changes the wire format; pin the CLI
version for anything important.

## Security notes on the proxy

CLIProxyAPI is dual-purpose. The BYOK path used here is plain API-key code, but the same binary
contains uTLS Cloudflare-fingerprint evasion and a Claude Code impersonation mode. None of it is
exercised by this config — decide whether shipping that binary is acceptable in your environment.

Its shipped defaults are also unsafe: `host: ""` binds all interfaces and auth is fail-open when
`api-keys` is empty, i.e. an open relay to your grant key. The config here overrides both.
