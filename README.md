# Claude Code on PLGrid LLMLab

Run the [Claude Code](https://code.claude.com) CLI against the open-weight models hosted on
[PLGrid LLMLab](https://llmlab.plgrid.pl) (ACK Cyfronet) — GLM-5.2, Qwen3.6, Gemma 4 — either
instead of Anthropic's models or **alongside them in the same session**.

## What you get

Four launch profiles. Pick one per project; switch any time.

| | `bin/claude-all` | `bin/claude-opus` | `bin/claude-glm` | `bin/claude-qwen` |
|---|---|---|---|---|
| **Drives the session** | Claude Opus 5, `xhigh` | Claude Opus 5, `xhigh` | GLM-5.2-FP8 | Qwen3.6-27B |
| **Session context** | 1M | 1M | 393k | 262k |
| **Subagents it can reach** | Anthropic + OpenAI + lab | Anthropic + lab | lab | lab |
| **Subagents preinstalled** | `lab-coder`, `lab-reviewer`, `gpt-analyst` | `lab-coder`, `lab-reviewer` | none — add your own | none — add your own |
| **Requires** | Claude sub + ChatGPT sub + grant | Claude sub + grant | grant | grant |
| **Driver responsiveness** | slowest — frontier reasoning at `xhigh` | slowest — frontier reasoning at `xhigh` | fastest of the four | ~4.5× slower than GLM |
| **Reach for it when** | you want an independent read from a second frontier lab alongside cheap bulk work | the reasoning is the hard part and the typing is not | you want speed and owe nothing to a subscription | you'd rather the driver be careful than quick |

**`claude-all` is the one to look at.** Claude Opus 5 orchestrates at its full 1M context and
delegates to **native Claude Code subagents** — real subagents with their own context and tools, not
tool calls or MCP shims — spanning **three providers at once**. Verified on the wire in a single
session:

```
claude-opus-5      -> Anthropic             18 × 200     main, your Claude subscription
gpt-5.6-sol        -> OpenAI                 3 × 200     subagent, your ChatGPT subscription
glm-5.2-fp8-393k   -> zai-org/GLM-5.2-FP8    9 × 200     subagent, grant compute
claude-haiku-4-5   -> Anthropic              1 × 200     subagent
```

**No API keys.** Both legs run on subscriptions you already pay for, used by their own clients. The
OpenAI leg needs no identity handling at all (`codex.disable-codex-cloaking: true`). The Anthropic
leg has one known rough edge: its endpoint validates the first system block, and Claude Code's own
auto-mode Bash classifier sends a different one — see
[auto mode's Bash classifier](#auto-modes-bash-classifier-is-unreliable-through-the-proxy).

The pattern that makes it worth it: the expensive model plans and reviews, a second frontier model
from a different lab gives an independent read, and grant compute does the bulk. `claude-opus` is
the same thing without the OpenAI leg, if you only have the one subscription.

Every profile gives you the full Claude Code experience against lab models: multi-turn agentic loops, tool
use, auto-compaction, MCP servers, `--resume`, and a status line showing usage against each model's
**real** context window. Autonomous operation works without `--dangerously-skip-permissions`.

Verified end-to-end on 2026-07-30 with Claude Code **2.1.220** — every claim above was measured, and
what did **not** work is documented too.

---

## Getting started

**Prerequisites:** a PLGrid grant with LLMLab access, Python 3, and Claude Code installed.
No Go toolchain needed — `make build` downloads a prebuilt, checksum-verified binary.

```bash
git clone https://github.com/groundnuty/plgrid-llmlab-claude-code
cd plgrid-llmlab-claude-code

make config        # creates config/cli-proxy-api.local.yaml (gitignored, mode 600)
$EDITOR config/cli-proxy-api.local.yaml    # replace PLGRID_API_KEY with your grant key
                   # get one at llmlab.plgrid.pl -> Grants -> Generate API Key

make proxy         # downloads the patched proxy and starts it
make test          # end-to-end check: expect PLGRID_OK
```

Then, from any project directory, pick a profile:

```bash
/path/to/plgrid-llmlab-claude-code/bin/claude-glm     # GLM-5.2-FP8 drives   (393k context)
/path/to/plgrid-llmlab-claude-code/bin/claude-qwen    # Qwen3.6-27B drives   (262k context)
```

For `bin/claude-all` or `bin/claude-opus` — Opus orchestrating subagents across providers — use the
corresponding proxy config and log in once per subscription first; see
[that section](#opus-orchestrating-across-providers).

Each script installs `.claude/settings.json`, `.claude/statusline.sh` (and for `claude-opus`, the lab
subagents) into the current project on first run, never overwriting anything that already exists. It
also checks the proxy is up and actually serving the model before launching, so an alias typo fails
immediately with a useful message instead of mid-session. Put `bin/` on your `PATH` to drop the full
path.

You should see:

```
glm-5.2-fp8-393k · 36.1k/393k █░░░░░░░░░░░░░░░░░░░ 9% · $0.18
```

That is usage against the model's **real** context window, with a warning past 80%.

### Make targets

| Target | Does |
|---|---|
| `make config [PROFILE=lab\|opus\|all]` | create the local proxy config from a profile template |
| `make login-claude` / `make login-codex` | OAuth against each subscription (opus, all) |
| `make build` | download the prebuilt proxy for your platform, checksum-verified |
| `make build-from-source` | build it instead (needs Go 1.26) |
| `make proxy` | start it (builds and configures if needed) |
| `make status` | is it up, and which models does it serve |
| `make test` | send a real completion end-to-end |
| `make stop` / `make logs` / `make clean` | lifecycle |

## Why a proxy is required

Claude Code speaks the **Anthropic Messages** dialect only. LLMLab serves an **OpenAI-compatible**
API (`/v1/chat/completions`; `/v1/messages` and `/v1/responses` both 404). Something must translate.

This repo uses [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), which targets
`/chat/completions` directly — LiteLLM and Bifrost both default the Anthropic path to the upstream's
*Responses* API and so fail against LLMLab out of the box.

Two fixes are needed on top of the upstream release, both on our fork and both verified:

1. **Reasoning was being discarded.** The translator read only `reasoning_content`; vLLM emits
   `reasoning`. Three of four reasoning models lost their entire chain of thought silently.
2. **Context-limit errors were unrecognisable**, so sessions died instead of compacting.

See [`deliverables/plgrid-setup-reference.md`](deliverables/plgrid-setup-reference.md#required-fixes)
for measurements and A/B evidence, and [Fork and releases](#fork-and-releases) below.

## Opus orchestrating across providers

**The capability this repo exists for:** Claude Opus 5 at `xhigh` effort with its **full 1M context**
runs your session, and delegates to **native Claude Code subagents** pinned to models from three
different providers — real subagents with their own context and tools, not tool calls.

```bash
make build                      # downloads the proxy binary; no Go needed
make config PROFILE=all         # writes config/cli-proxy-api.local.yaml (gitignored, 600)
$EDITOR config/cli-proxy-api.local.yaml     # replace PLGRID_API_KEY

make login-claude               # OAuth, your Claude subscription  — opens a browser
make login-codex                # OAuth, your ChatGPT subscription — opens a browser

make proxy                      # start it
make status                     # expect claude-*, gpt-*, and the lab aliases

cd <your project>
/path/to/plgrid-llmlab-claude-code/bin/claude-all
```

If Codex CLI is already logged in, its token in `~/.codex/auth.json` carries the same fields the
proxy expects and can be reused instead of a second grant.

Three subagents install on first run — **`lab-coder`** (GLM-5.2, implementation), **`lab-reviewer`**
(Qwen3.6-27B, correctness), **`gpt-analyst`** (`gpt-5.6-sol`, independent second opinion). Ask Opus
to use them by name. Add your own with any alias `make status` lists:

```markdown
---
name: tricky-bit
description: Narrow tasks worth a different model.
model: gpt-5.6-terra
tools: Read, Glob, Grep
---
```

Verified on the wire, one session, all three providers concurrently:

| Inbound | → Upstream | Role | Status |
|---|---|---|---|
| `claude-opus-5[1m]` | Anthropic — Claude subscription | main, 1M window | 18 × 200 |
| `gpt-5.6-sol` | OpenAI — ChatGPT subscription | subagent | 3 × 200 |
| `glm-5.2-fp8-393k` | `zai-org/GLM-5.2-FP8` — grant | subagent | 9 × 200 |
| `claude-haiku-4-5-20251001` | Anthropic | subagent | 1 × 200 |

`bin/claude-opus` is the same profile without the OpenAI leg.

### Why the proxy is in the Anthropic path

Only because it has to be. Claude Code has no per-agent provider routing — verified against 2.1.220:
no `agentBaseUrl`, `providerOverride` or `modelProvider` exists, agent frontmatter accepts no
endpoint field, and `ANTHROPIC_BASE_URL` is a single global. So one endpoint must serve both
providers and route by model name, and only the proxy can do that.

### Which models get 1M

The `[1m]` suffix is stripped client-side and converted to the `context-1m-2025-08-07` beta header.
It is per-model, and not every model on the subscription accepts it — measured:

| Model | `[1m]` | Result |
|---|---|---|
| `claude-opus-5` | yes | 200 |
| `claude-sonnet-5` | yes | 200 |
| `claude-haiku-4-5-20251001` | no | `400 The long context beta is not yet available for this subscription.` |

So the profiles set `[1m]` on the Opus and Sonnet defaults and leave Haiku alone. A subagent
dispatched with `model: sonnet` inherits `ANTHROPIC_DEFAULT_SONNET_MODEL`, so without the suffix it
silently runs at 200k — visible in its status line as `200k`, not `1000k`.

### Auto mode's Bash classifier is unreliable through the proxy

**Symptom.** In auto mode, Bash commands outside `permissions.allow` intermittently fail with
*"auto mode cannot determine the safety of Bash"* or *"Classifier unavailable"*.

**What is established.** The Anthropic subscription endpoint validates the **first system block**.
Measured through the proxy with everything else held identical:

| First system block | Result |
|---|---|
| `"You are Claude Code, Anthropic's official CLI for Claude."` | 200 |
| `"You are a security monitor for autonomous AI coding agents."` | 429 |
| `"You are a helpful assistant."` | 429 |

Auto mode's Bash classifier sends that security-monitor prompt, so its calls are rejected. The `429`
carries `{"type":"rate_limit_error","message":"Error"}` — an empty message, which is what makes this
easy to misread as a quota problem. It is not: ordinary conversation turns on the same account at the
same moment return 200.

**Partial mitigation, not a fix.** Setting `"cloak_mode": "always"` in the Claude token JSON under
`auth-dir` forces the identity block onto every request. Measured over 17 classifier calls each way:

| Setting | classifier calls returning 200 |
|---|---|
| `disable-claude-cloak-mode: true` | 1 / 17 |
| `+ "cloak_mode": "always"` | 4 / 17 |

Sessions become usable because Claude Code retries until one lands, but the majority still fail.
Something beyond the system prompt is also at play and is not yet identified — possibly genuine rate
limiting layered on top. Do not treat this as solved.

Note `disable-claude-cloak-mode: false` alone does **nothing** here, because upstream's "auto" mode
only cloaks non-`claude-cli` clients:

```go
default: return !strings.HasPrefix(userAgent, "claude-cli")
```

A `curl` probe therefore gets cloaked while the real classifier does not — which makes curl a
misleading way to test any of this.

**If you want reliable Bash today**, run with `--permission-mode acceptEdits`, which never calls the
classifier (`auto` → classify; `acceptEdits` → ask). Everything in `permissions.allow` still runs
without prompting, and every profile pre-approves a read-only working set.

### This proxy must stay local and single-user

`auth-dir` stores an `access_token` **and a `refresh_token`** in plaintext at mode `0644`, and
credentials are pooled **round-robin** across every logged-in account. On a shared host, other users
could read the token file, and requests could be served by someone else's subscription. A
lab-operated shared proxy is fine for the LLMLab leg — that is a lab-issued grant key — but must
never hold subscription tokens.

### Context windows: how each profile gets its real one

Every profile runs at its model's true window, but by two different mechanisms.

**Opus uses its native 1M**, via the `[1m]` suffix on `ANTHROPIC_MODEL`. Claude Code strips the
suffix before the wire and converts it into a `context-1m-2025-08-07` beta header, which the proxy
forwards untouched. Measured:

```
Opus 5 (1M context) · 69.8k/1000k █░░░░░░░░░░░░░░░░░░░ 7%
Free space: 933.2k (93.3%)
```

Without the suffix it falls back to 200k, because behind a gateway Claude Code cannot resolve
registry context windows. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` does **not** help there — it is documented
as clamped to "at most the model's context window", so with the client believing 200k it clamps to
itself (measured: `1000000` still reported 200k). The suffix works because it does not raise a
believed limit, it enables a real upstream capability.

**Lab profiles use `CLAUDE_CODE_MAX_CONTEXT_TOKENS`** set to each model's exact real window —
`393216` for GLM-5.2, `262144` for Qwen3.6-27B. That path is not clamped because the values sit at
or below what the client already assumes.

**Subagents are deliberately left unset.** The variable is process-wide, so any value would be wrong
for one participant. Unset means lab subagents fall back to 200k — below the smallest real window in
the catalogue (`glm-4.7-flash`, 202,752), so nothing can overflow. Under-using a subagent's context
is safe; over-declaring is not.

For completeness, these do **not** offer per-model windows and were each checked: the model registry
(hardcoded, two literals), gateway `/v1/models` discovery (no window field in the schema), agent
frontmatter (no window field), and the bootstrap `auto_compact_windows` map (real, but first-party
only — never requested behind a proxy).

## Repository layout

| Path | Contents |
|---|---|
| `bin/` | `claude-all`, `claude-opus`, `claude-glm`, `claude-qwen` — launch with a profile |
| `config/` | proxy configs, per-profile Claude Code settings, status line, lab subagents |
| `Makefile` | proxy lifecycle |
| `deliverables/` | the reference manual, gateway performance report, investigation record |
| `research/` | model selection research, proxy landscape survey, diagnostic scripts |

## Documentation

Each fact has exactly one home. Start here, then follow the link that matches your question.

| Document | Answers |
|---|---|
| [**Setup reference**](deliverables/plgrid-setup-reference.md) | Every configuration decision and why. Context windows, subagents, autonomous operation, the required fixes, per-model compatibility shimming, known issues. **The manual — read this second.** |
| [Gateway performance](deliverables/plgrid-forge-observed-performance.md) | Measured latency and per-model timings. Written for the LLMLab operators. |
| [Model selection research](research/plgrid-model-selection-for-agentic-coding.md) | Which model to use as primary and as reviewer, with benchmark citations. |
| [Proxy landscape survey](research/claude-code-openai-compatible-proxies.md) | Why CLIProxyAPI, and why the alternatives fail. Liveness data on the whole ecosystem. |
| [Investigation record](deliverables/claude-code-plgrid-working-config.md) | How the conclusions were reached, including six that were later overturned. Read when something breaks. |

## Models

| Alias | Real window | Role |
|---|---|---|
| `glm-5.2-fp8-393k` | 393,216 | **Default primary.** Fastest and correct. Not multimodal. |
| `qwen3.6-27b-262k` | 262,144 | Alternative primary, or reviewer subagent. Best coding benchmarks, slower. |
| `qwen3.6-35b-a3b-262k` | 262,144 | General work |
| `gemma-4-31b-262k` | 262,144 | Handles images |
| `qwen3-coder-30b-249k` | 249,600 | Coding |
| `qwen3-vl-8b-262k` | 262,144 | Vision |
| `glm-4.7-flash-202k` | 202,752 | **Avoid** — returned a confidently wrong answer under test |

Aliases carry the real context window so the status line can display true usage. **They must match
between `config/cli-proxy-api.yaml` and the settings files** — a mismatch gives
`502 unknown provider`. `make status` lists what the proxy actually serves.

## Fork and releases

The proxy is built from [`groundnuty/CLIProxyAPI`](https://github.com/groundnuty/CLIProxyAPI), whose
`main` carries both fixes. Neither is upstream yet.

The fork is released as
**[`v7.2.110-plgrid.1`](https://github.com/groundnuty/CLIProxyAPI/releases/tag/v7.2.110-plgrid.1)**
with prebuilt binaries for `linux/amd64`, `linux/arm64`, `darwin/arm64` and `darwin/amd64`, plus
`checksums.txt`. `make build` picks the right one for your platform, verifies its SHA-256, and falls
back to a source build if no asset matches. Built `CGO_ENABLED=0 -trimpath`; the Linux binaries are
statically linked.

The version scheme is upstream base plus our patch level, so rebasing on a new upstream release is a
version bump.

**Note on the fork's CI.** It inherits upstream's workflows, but GitHub disables Actions on forked
repositories until a maintainer enables them once in the *Actions* tab — so this release was built
and uploaded manually. If you enable Actions and re-push the tag, `release.yaml` will build it
automatically (it needs only `GITHUB_TOKEN`). `docker-image.yml` will still fail without
`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`, which forks do not inherit; repointing it at `ghcr.io`
would work with `GITHUB_TOKEN`. **There is currently no Docker image** — the binary is the
supported path.

The real exit is upstream. The reasoning-field fix in particular affects **any** vLLM-backed gateway,
not just LLMLab, so it is worth a PR. Note
[PR #4321](https://github.com/router-for-me/CLIProxyAPI/pull/4321) already targets the context-limit
area and should be referenced rather than conflicted with.

## Caveats

**Anthropic does not support this.** Their docs state they "don't support routing Claude Code to
non-Claude models through any gateway." Expect no vendor help when a Claude Code release changes the
wire format — pin the CLI version for anything important.

**CLIProxyAPI is dual-purpose.** The BYOK path used here is plain API-key code, but the same binary
contains TLS-fingerprint evasion and a Claude Code impersonation mode. None is exercised by this
config; decide whether that is acceptable in your environment. Its shipped defaults also bind all
interfaces with fail-open auth — the config here overrides both.

**Your key stays local.** `config/cli-proxy-api.local.yaml` is gitignored and created at mode 600.
Never commit it.
