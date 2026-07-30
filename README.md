# Claude Code on PLGrid LLMLab

Run the [Claude Code](https://code.claude.com) CLI against the open-weight models hosted on
[PLGrid LLMLab](https://llmlab.plgrid.pl) (ACK Cyfronet) — GLM-5.2, Qwen3.6, Gemma 4 — instead of
Anthropic's API.

Verified end-to-end on 2026-07-30 with Claude Code **2.1.220**: multi-turn agentic coding, tool use,
subagents pinned to different models, auto-compaction, MCP, and `--resume`.

---

## Getting started

**Prerequisites:** a PLGrid grant with LLMLab access, Go 1.26, Python 3, and Claude Code installed.

```bash
git clone https://github.com/groundnuty/plgrid-llmlab-claude-code
cd plgrid-llmlab-claude-code

make config        # creates config/cli-proxy-api.local.yaml (gitignored, mode 600)
$EDITOR config/cli-proxy-api.local.yaml    # replace PLGRID_API_KEY with your grant key
                   # get one at llmlab.plgrid.pl -> Grants -> Generate API Key

make proxy         # builds the patched proxy and starts it
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
| `make build` | build the patched proxy from the fork |
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

## Repository layout

| Path | Contents |
|---|---|
| `bin/` | `claude-glm`, `claude-qwen` — launch Claude Code with a model profile |
| `config/` | proxy config template, per-profile Claude Code settings, status line |
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

**To make this easier for users, tag the fork.** It inherits upstream's CI, which fires on any tag:

- `.github/workflows/release.yaml` uses only `secrets.GITHUB_TOKEN`, which **is** available on
  forks — so tagging produces a GitHub Release with prebuilt binaries automatically, and `make build`
  could be replaced by a download.
- `.github/workflows/docker-image.yml` needs `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`, which a fork
  does **not** inherit — that job will fail unless those secrets are added or it is repointed at
  `ghcr.io` (which works with `GITHUB_TOKEN`).

Suggested tag: `v7.2.110-plgrid.1` — upstream base plus our patch level, so provenance is obvious and
rebasing on a new upstream release is an obvious version bump.

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
