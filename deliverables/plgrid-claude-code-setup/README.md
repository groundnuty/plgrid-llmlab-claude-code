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
git clone -b fix/normalize-vllm-context-limit-errors https://github.com/groundnuty/CLIProxyAPI
cd CLIProxyAPI && go build -o cli-proxy-api ./cmd/server
```

Verified A/B on the same oversized request: stock leaks `API Error: 400 {"detail": …}`; patched
emits `prompt is too long: 66511 tokens > 32768 maximum (…)`, which the client recognises.

**Not yet observed:** a long session actually recovering by compaction. The code path is confirmed
and its "cannot compact" branch was seen firing correctly, but no multi-turn recovery has been
watched end to end. Treat automatic recovery as expected-but-unproven.

## Untested

Images, MCP tools, manual `/compact`, `--resume`, and `availableModels` with these non-`claude`
ids. Subagent routing to different models **is** verified.
