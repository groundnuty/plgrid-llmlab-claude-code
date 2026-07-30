# Claude Code on PLGrid LLMLab

Run the [Claude Code](https://code.claude.com) CLI against the open-weight models hosted on
[PLGrid LLMLab](https://llmlab.plgrid.pl) (ACK Cyfronet) — GLM-5.2, Qwen3.6, Gemma 4 — instead of
Anthropic's API.

Verified end-to-end on 2026-07-30 with Claude Code **2.1.220**: multi-turn agentic coding, tool use,
subagents pinned to different models, auto-compaction, MCP, and `--resume`.

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

Then, from any project directory:

```bash
/path/to/plgrid-llmlab-claude-code/bin/claude-glm     # GLM-5.2-FP8 primary  (393k context)
/path/to/plgrid-llmlab-claude-code/bin/claude-qwen    # Qwen3.6-27B primary  (262k context)
```

Either script installs `.claude/settings.json` and `.claude/statusline.sh` into the current project
on first run (never overwriting an existing one), checks the proxy is reachable and serving the
model, then launches Claude Code. Put `bin/` on your `PATH` to drop the full path.

You should see:

```
glm-5.2-fp8-393k · 36.1k/393k █░░░░░░░░░░░░░░░░░░░ 9% · $0.18
```

That is usage against the model's **real** context window, with a warning past 80%.

### Make targets

| Target | Does |
|---|---|
| `make config` | create the local proxy config from the template |
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

## Opus orchestrating, lab models doing the work

**The capability this repo exists for:** Claude Opus 5 at `xhigh` effort runs your session on your
Claude subscription, and delegates implementation to GLM-5.2 and Qwen3.6 as **native Claude Code
subagents** — real subagents with their own context and tools, not tool calls. No API key. No
impersonation.

```bash
# once — OAuth against your subscription, token refreshes itself afterwards
cp config/cli-proxy-api.opus.yaml ~/.cli-proxy-api/config.yaml
$EDITOR ~/.cli-proxy-api/config.yaml          # add PLGRID_API_KEY only
./cli-proxy-api --config ~/.cli-proxy-api/config.yaml --claude-login

make proxy
cd <project> && /path/to/repo/bin/claude-opus
```

`claude-opus` installs two subagents pinned to lab models: **`lab-coder`** (GLM-5.2 — implementation)
and **`lab-reviewer`** (Qwen3.6-27B — correctness review). Ask Opus to use them by name.

Verified on the wire, one session:

| Inbound | → Upstream | Role | Status |
|---|---|---|---|
| `claude-opus-5` | Anthropic (your subscription) | main | 200 |
| `glm-5.2-fp8-393k` | `zai-org/GLM-5.2-FP8` | subagent | 200 |
| `qwen3.6-27b-262k` | `Qwen/Qwen3.6-27B` | subagent | 200 |

### Why the proxy is in the Anthropic path

Only because it has to be. Claude Code has no per-agent provider routing — verified against 2.1.220:
no `agentBaseUrl`, `providerOverride` or `modelProvider` exists, agent frontmatter accepts no
endpoint field, and `ANTHROPIC_BASE_URL` is a single global. So one endpoint must serve both
providers and route by model name, and only the proxy can do that.

**This is not impersonation.** `disable-claude-cloak-mode: true` is set, which turns off
CLIProxyAPI's Claude Code disguise and system-prompt replacement entirely. It is off because nothing
needs disguising: the client genuinely *is* Claude Code. Measured, same proxy, minutes apart —
`curl` through it gets `429`, Claude Code through it gets `200`.

### This proxy must stay local and single-user

`auth-dir` stores an `access_token` **and a `refresh_token`** in plaintext at mode `0644`, and
credentials are pooled **round-robin** across every logged-in account. On a shared host, other users
could read the token file, and requests could be served by someone else's subscription. A
lab-operated shared proxy is fine for the LLMLab leg — that is a lab-issued grant key — but must
never hold subscription tokens.

### Known limitation: Opus reports a 200k window

Behind any gateway, Claude Code cannot resolve registry context windows, so Opus shows **200k**
instead of its true 1M. There is no fix. Exhaustively checked:

| Mechanism | Per-model? |
|---|---|
| Model registry | hardcoded — two literals |
| Gateway `/v1/models` | **no window field in the schema** |
| Bootstrap `auto_compact_windows` | exists, first-party only — **tested, never requested behind a proxy** |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | process-wide only |
| Agent frontmatter | no window field |

`auto_compact_windows` is a genuine model→window map inside Claude Code — exactly the right
mechanism — but it ships only over the first-party bootstrap endpoint, which is skipped for gateway
sessions and requires a first-party credential the client does not have behind a proxy.

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is therefore deliberately **unset** in this profile: it is
process-wide, so any value is wrong for one side. The 200k default is **provably safe** — it sits
below the smallest real window in the catalogue (`glm-4.7-flash`, 202,752), so no model can overflow.

In practice this profile spends its context orchestrating and delegating rather than reading, so
200k rarely binds. If you want full context on a lab model, use `bin/claude-glm` or `bin/claude-qwen`,
which set the exact window per profile.

## Repository layout

| Path | Contents |
|---|---|
| `bin/` | `claude-opus`, `claude-glm`, `claude-qwen` — launch with a model profile |
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
