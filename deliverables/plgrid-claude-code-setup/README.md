# Claude Code on PLGrid Forge — runnable setup

Everything needed to point the Claude Code CLI at PLGrid Forge (ACK Cyfronet) models.
Findings and evidence behind each choice: `../claude-code-plgrid-working-config.md`.

Verified 2026-07-30 with Claude Code **2.1.220** and CLIProxyAPI **7.2.110**.

## Install

```bash
# 1. Proxy binary (stock release; no build needed for the base setup)
brew install cliproxyapi          # or: download the release for your platform

# 2. Config, with your grant key
cp cli-proxy-api.config.yaml ~/.cli-proxy-api/config.yaml
$EDITOR ~/.cli-proxy-api/config.yaml     # replace PLGRID_API_KEY
chmod 600 ~/.cli-proxy-api/config.yaml   # it holds a secret

# 3. Per-project Claude Code config
mkdir -p <your-project>/.claude
cp claude-settings.json <your-project>/.claude/settings.json
cp statusline.sh        <your-project>/.claude/statusline.sh
chmod +x               <your-project>/.claude/statusline.sh

# 4. Run
cli-proxy-api --config ~/.cli-proxy-api/config.yaml     # leave running
cd <your-project> && claude                              # accept the trust prompt once
```

Nothing goes in `~/.claude/settings.json`. Every setting here is project-scoped on purpose —
these choices are specific to this gateway and should not follow you into other projects.

## What you get

```
glm-5.2-fp8-393k[1m] · 36.1k/393k █░░░░░░░░░░░░░░░░░░░ 9% · $0.18
```

Usage against the model's **real** limit. Claude Code's own indicator would read 4% here, because
every model deliberately declares a 1M window (see below); the status line reads the true limit out
of the `-393k` segment in the model id. At 80% it appends `⚠ COMPACT SOON`.

Switching model with `/model` picks up that model's encoded limit automatically, and subagents
pinned to other models are shown correctly too, because the limit travels in the name.

## The three settings that are not optional

Each of these was found the hard way; without them the setup fails in ways that are hard to
diagnose.

| Setting | Where | Why |
|---|---|---|
| `payload.filter` on `reasoning_effort` | proxy config | PLGrid validates with `extra_forbidden`. Without it every request dies with a bare `422`. |
| `disable-cooling: true` | proxy config | Cooldown is per (auth, model). With one credential, any failure blacks out that model for ~60s with `503`, so a compaction retry hits the model it needs. |
| `CLAUDE_CODE_ATTRIBUTION_HEADER: "0"` | project settings | Claude Code prepends a per-request hash to the system prompt, so the KV prefix misses every turn. Unsloth measures the cost as "90% slower with local models". |

## Why every model declares `[1m]`

Claude Code's context windows are **hardcoded** — the 2.1.220 binary contains exactly two values,
200,000 and 1,000,000. A gateway cannot advertise a window (tested: `max_input_tokens` in the
discovery cache is parsed but ignored), and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is a single
process-wide value that cannot be right for several models at once.

So the approach is: declare 1M everywhere, let the **upstream** enforce the real limit — it knows
it exactly — and show the truth in the status line. The trade is that Claude Code's own percentage
and its proactive compaction become meaningless. All enforcement moves to the gateway.

## Model notes

| Alias | Real window | Notes |
|---|---|---|
| `glm-5.2-fp8-393k` | 393,216 | Best default: fastest **and** correct in testing (11s) |
| `qwen3.6-35b-a3b-262k` | 262,144 | Correct, 14s |
| `gemma-4-31b-262k` | 262,144 | Correct, 16s |
| `qwen3-coder-30b-249k` | 249,600 | Correct, 28s |
| `qwen3.6-27b-262k` | 262,144 | Correct but slow, 50s — good for a reviewer subagent |
| `glm-4.7-flash-202k` | 202,752 | **Avoid.** Completed the loop but returned a confidently wrong answer |

Grant 94 cannot reach `Qwen3.5-397B`, `Qwen3.5-122B` or `DeepSeek-V4-Flash` despite `GET /models`
listing them. No Moonshot/Kimi models present as of 2026-07-30.

**Keep the compaction model equal to the primary.** Compaction runs on the haiku tier, so if it
points at a model whose real window is smaller than the primary's, large conversations cannot be
summarised — the compaction request itself overflows. The settings file therefore points all four
tiers at the same model. If summarisation cost matters more than context length, instead set haiku
to `gemma-4-31b-262k` **and** add `"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "250000"` so the effective
window is the smaller of the two. Do not mix the two approaches.

## Optional: automatic limit handling

With the stock proxy, exceeding a model's real window produces a raw upstream error and the session
stops. Claude Code only recovers when the message matches
`prompt is too long[^0-9]*(\d+)\s*tokens?\s*>\s*(\d+)`, which PLGrid's wording does not.

A patch that restates the upstream error in that form is on a **fork branch, unmerged, with no PR
opened**: `groundnuty/CLIProxyAPI@fix/normalize-vllm-context-limit-errors`. Using it needs a source
build (Go 1.26):

```bash
git clone https://github.com/groundnuty/CLIProxyAPI && cd CLIProxyAPI
git checkout fix/accept-openai-reasoning-field          # thinking blocks — see below
git merge --no-edit fix/normalize-vllm-context-limit-errors   # automatic context limits
go build -o cli-proxy-api ./cmd/server
```

**Two independent fixes live on that fork, both verified against PLGrid.** The reasoning-field fix
matters for every reasoning model and is the more important of the two.

Verified A/B on the same oversized request: stock leaks `API Error: 400 {"detail": …}`; patched
emits `prompt is too long: 66511 tokens > 32768 maximum (…)`, which the client recognises.

**Not yet observed:** a long session actually recovering by compaction. The code path is confirmed
and its "cannot compact" branch was seen firing correctly, but no multi-turn recovery has been
watched end to end. Treat automatic recovery as expected-but-unproven.

## R3 — behaviour at the context limit: PASSES

### Auto-compaction fires and recovers (GLM-5.2, real headroom)

Tested on `glm-5.2-fp8-393k[1m]` (real window 393,216) with the trigger set low
(`CLAUDE_CODE_AUTO_COMPACT_WINDOW: "110000"`) so there was both ample history to summarise and
ample headroom for the summarising request itself. Context was filled by reading ~89KB data files
one at a time.

Observed, in order:

```
3% until auto-compact                 <- client counts down against the trigger
✽ Compacting conversation… (9s)       <- fires automatically
0.0k/393k ░░░░░░░░░░░ 0%             <- context reclaimed
65.0k/393k ███░░░░░░░░ 17%           <- session continues normally afterwards
```

A follow-up prompt after compaction was answered normally. **Auto-compaction works end to end on a
model with adequate context.** This is the requirement, and it is met.

### The failure mode on small-window models, and the floor it implies

The same test on Bielik-11B (real window 32,768) produced Claude Code's own clean message —
`Context limit reached · /compact or /clear to continue` rather than raw upstream JSON, which is
what the error-normalisation patch buys — but recovery failed, and manual `/compact` also failed
with `conversation could not be reduced below the context limit`.

That is correct behaviour, not a defect. **Claude Code's baseline does not fit in a small window.**
Measured with only the `Read` tool, a fresh config dir, and no MCP:

| Component | Tokens |
|---|---|
| System prompt | 1.6k |
| System tools | 15.8k |
| Skills | 1.5k |
| **Irreducible baseline** | **~19k** |

Compaction shrinks conversation history only; system prompt, tool definitions and skills are
re-sent every turn and survive it. On a 32k model ~19k is unreclaimable, leaving under 14k to work
with.

**Implication: a model needs roughly ≥64k real context to work in Claude Code at all**, and more
for real tasks. Every model in the table above (202k minimum) clears this comfortably. Bielik-11B
is not viable as a Claude Code model at any proxy setting.

## R4 — one model driving, two subagents on different models: PASSES

Primary `glm-5.2-fp8-393k[1m]`, with two subagents pinned by frontmatter, each auditing a
different file containing a different real bug:

```markdown
---
name: parser-auditor
model: qwen3.6-27b-262k
tools: Read
---
```

Both bugs were found and correctly diagnosed — the exclusive upper bound in `range(int(lo), int(hi))`
and the integer division in `sum(xs) // len(xs)`. Wire-level routing from the proxy log:

| Inbound alias | → Upstream model | Agent id | Status |
|---|---|---|---|
| `glm-5.2-fp8-393k` | `zai-org/GLM-5.2-FP8` | MAIN | 200 |
| `qwen3.6-27b-262k` | `Qwen/Qwen3.6-27B` | `3609017b` | 200 |
| `gemma-4-31b-262k` | `google/gemma-4-31B` | `12bee177` | 200 |

Three models, three distinct upstreams, one session, with per-agent ids for attribution.

**Two prerequisites, both learned by failing first.** The `Task` tool must be allow-listed
(`"Task"`, or `"Task(<agent-name>)"` per agent) or dispatch is refused. And auto mode's classifier
is unavailable for these models, so launch with `--permission-mode acceptEdits` (or `default`);
otherwise subagent dispatch fails with `parser-auditor denied by auto mode · Classifier
unavailable`. Neither needs `--dangerously-skip-permissions`.

**The first R4 attempt failed for an instructive reason:** every subagent request returned `502
unknown provider for model qwen3.6-27b-262k`, because the running proxy had been configured with
the bare alias `qwen3.6-27b` while the settings referenced `qwen3.6-27b-262k`. The aliases in the
proxy config and in `ANTHROPIC_DEFAULT_*` / agent frontmatter must match exactly. Check with:

```bash
curl -s -H "Authorization: Bearer local-test-key" http://127.0.0.1:8317/v1/models | jq -r '.data[].id'
```

## Compaction model sizing — important

**The model that performs compaction must have a context window at least as large as the model
being compacted.** Compaction runs on the haiku tier and must fit the entire conversation in one
request in order to summarise it. Point haiku at a smaller-window model and large conversations
become unsummarisable: the compaction request itself overflows, and you get
`Compaction failed · conversation could not be reduced below the context limit`.

Anthropic's docs state the principle — Claude Code "won't fall back to a model with a smaller
context window than the primary's, since summarizing there would cut off part of the conversation
first" — but **that guard cannot help here**, because under the declare-`[1m]`-everywhere scheme
the client believes every model has 1M and cannot see the real difference. The guard silently
never engages.

So the rule must be enforced by hand:

- **Safe:** haiku = the primary model (what `claude-settings.json` does).
- **Safe:** haiku = a smaller model **and** `CLAUDE_CODE_AUTO_COMPACT_WINDOW` capped to that
  smaller model's real window.
- **Broken:** haiku = a smaller model with no cap. Works until the conversation exceeds the haiku
  model's window, then compaction fails permanently and the session cannot be recovered.

## No flag disables the trust dialog

There is no CLI flag or environment variable. It is per-project state in **`~/.claude.json`** under
`projects["<absolute-path>"].hasTrustDialogAccepted`. Setting it to `true` for a path pre-accepts
that project. Relevant strings in the 2.1.220 binary are `hasTrustDialogAccepted` and
`hasCompletedOnboarding`; there is no `CLAUDE_CODE_TRUST_ALL`, `bypassTrustDialog`, or
`--dangerously-skip-trust`.

Note this is a **global** file, so pre-accepting projects is a machine-level edit, not something
that can ship in a project's `.claude/settings.json`. Also note that `permissions.allow` entries in
project settings are **ignored until the dialog is accepted** — observed verbatim:
`Ignoring 4 permissions.allow entries from .claude/settings.json: this workspace has not been
trusted.` So for unattended first runs, the trust state has to be seeded in advance.

## Untested

Images, MCP tools, manual `/compact`, `--resume`, and `availableModels` with these non-`claude`
ids. Subagent routing to different models **is** verified.

## Model choice — and a caution about blaming the model

Research summary: `../../research/plgrid-model-selection-for-agentic-coding.md`.

**Recommended:** `glm-5.2-fp8-393k` as primary — the only candidate with published tool-use numbers
(MCP-Atlas 76.8, Tool-Decathlon 48.2, against 62.8 / 26.9 for Qwen3.6-35B-A3B) and fastest-and-correct
in local testing. `qwen3.6-27b-262k` as reviewer subagent — best coding numbers available
(SWE-bench Verified 77.2 vs 73.4 for the A3B MoE, Terminal-Bench 2.0 59.3 vs 51.5), and its 50s
latency is irrelevant for a review pass. **Avoid** `glm-4.7-flash-202k`: it returned a wrong answer
here, and publishes no tool-use benchmark at all.

**Root cause found: the proxy was discarding every model's chain of thought.** An earlier revision
blamed [claude-code-router #1400](https://github.com/musistudio/claude-code-router/issues/1400) — a
misapplied citation, since that is a different proxy and is not installed here. The real defect was in
CLIProxyAPI, and it is now fixed and measured.

The OpenAI-to-Claude response translator read reasoning only from `reasoning_content`. vLLM's
OpenAI-compatible server emits **`reasoning`** instead, matching the OpenAI Responses API. Measured
streaming delta chunks from PLGrid for one short prompt:

| Model | `reasoning` | `reasoning_content` |
|---|---|---|
| `zai-org/GLM-5.2-FP8` | **42** | **0** |
| `Qwen/Qwen3.6-27B` | **120** | **0** |
| `Qwen/Qwen3.6-35B-A3B` | **120** | **0** |
| `zai-org/GLM-4.7-Flash` | 81 | 81 (both) |
| `Qwen/Qwen3-Coder-30B` | 0 | 0 (non-reasoning) |
| `google/gemma-4-31B` | 0 | 0 (non-reasoning) |

Three of the four reasoning models lost their thinking entirely. The fourth emits both spellings,
which is why the bug is easy to miss — **whether it bites depends on the vLLM version each model was
deployed with**, and operators commonly pin that per model at launch. PLGrid runs vLLM 0.24 for
GLM-5.2 with `--reasoning-parser glm45` correctly set, so this was never a serving misconfiguration.

End-to-end A/B, same request, thinking enabled:

| | Thinking blocks reaching Claude Code | `thinking_delta` events |
|---|---|---|
| stock 7.2.110 | **0** | **0** |
| patched | **1** | **162** |

For reasoning-first models the damage exceeds losing thinking blocks. A non-streaming probe of
GLM-5.2 returned substantial `reasoning` text with **`content: null`** — so dropping the field can
leave the visible answer empty, and streaming showed 42 reasoning chunks against 2 content chunks.

**This is a strong candidate explanation for the instruction shortcutting.** GLM-5.2 was planning in
`reasoning`, the proxy discarded it, and the model was effectively driven with its plan removed from
the transcript — consistent with "claims completion without doing the work". Stated as a candidate,
not proven: we have not re-run the original 5-read probe against the patched build.

Fix: `groundnuty/CLIProxyAPI@fix/accept-openai-reasoning-field` — adds `openAIReasoningNode()`, which
prefers `reasoning_content` and falls back to `reasoning`, across all three read sites (streaming
delta, single-choice non-streaming, non-streaming message loop). Preferring the existing spelling
keeps DeepSeek-style backends byte-identical, so the change is additive. 4 new tests, package green.

Still worth checking, and unaffected by this fix:
[vLLM #39757](https://github.com/vllm-project/vllm/issues/39757) truncates GLM tool names in
streaming but not with `stream=False`, and
[#42400](https://github.com/vllm-project/vllm/issues/42400) reports that behind Claude Code with our
parser pair. Those are vLLM-level. Keep `tool_choice` at `auto` —
[#50399](https://github.com/vllm-project/vllm/issues/50399) shows GLM-5.2-FP8 emitting ~127 duplicate
calls under `"required"`.

For the operators: the vLLM recipe warns *"If you need tool calling and MTP at the same time, use the
latest `main` branch"* while its own recommended command enables both. And discount the vendor's
Terminal-Bench 2.1 claim of 81.0 — the [official leaderboard](https://www.tbench.ai/leaderboard/terminal-bench/2.1)
puts GLM-5.1 **in Claude Code** at 58.7%.

**Serving settings for the reviewer subagent** (from the Qwen3.6-27B card): temperature 0.6,
top_p 0.95, top_k 20, min_p 0.0, presence_penalty 0.0 — the "precise coding" preset. Note the
Qwen3.6-35B-A3B card's *general* preset uses presence_penalty 1.5, which would penalise the
legitimately repetitive structure of tool calls; use the coding preset for agent work.

**No candidate publishes IFEval, IFBench, or Multi-IF**, and BFCL v4 scores are not extractable.
The benchmark family that would most directly measure instruction adherence is absent for all six
models — worth knowing before treating any of these numbers as decisive on this axis.
