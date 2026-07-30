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

## R3 result: behaviour at the context limit, measured

Tested against Bielik-11B (real window 32,768) so the limit was reachable in seconds, with
`autoCompactEnabled: true` confirmed on via `/config`, through the **patched** proxy.

**With auto-compact on, Claude Code reports cleanly rather than leaking an upstream error:**

```
⎿  Context limit reached · /compact or /clear to continue
```

The proxy log shows a `400` at 15:05:50 immediately followed by a `200`, so the overflow was
detected and the client acted on it. This is Claude Code's own message, not raw JSON — which is
what the error-normalisation patch buys. Compare the stock proxy on the same condition:
`API Error: 400 {"detail": "'max_tokens' or 'max_completion_tokens' is too large…"}`.

**But automatic recovery did not happen, and manual `/compact` also failed:**

```
⎿  Compaction failed · conversation could not be reduced below the context limit
```

### Why, and what it means

This is structural, not a test artifact. **Claude Code's own baseline does not fit in a small
window.** Measured with minimal tools (`Read` only), a fresh config dir, and no MCP:

| Component | Tokens |
|---|---|
| System prompt | 1.6k |
| System tools | 15.8k |
| Skills | 1.5k |
| **Irreducible baseline** | **~19k** |

Compaction can only shrink *conversation history*; the system prompt, tool definitions and skills
are re-sent every turn and survive it. So on a 32k model, ~19k is unreclaimable and compaction has
under 14k to work with — it cannot get below the limit, exactly as the message says.

**Consequence for model choice: a model needs roughly ≥64k of real context to be usable in Claude
Code at all**, and comfortably more for real work. Bielik-11B at 32k is not a viable Claude Code
model regardless of proxy configuration. Every model in the table above (202k minimum) is far
above this floor, so this does not affect the recommended setup — it is a lower bound worth knowing
before adding a small model.

**Still unproven:** automatic compaction *succeeding* on a model with enough headroom. The failure
above is the documented and correct behaviour for an over-constrained window, so it does not
disconfirm the mechanism, but it does not confirm it either.

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
