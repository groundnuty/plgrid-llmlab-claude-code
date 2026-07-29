# Running Claude Code against your own OpenAI-compatible models

**Question.** Which community projects let the Claude Code CLI talk to OpenAI-compatible
models, which are actually alive rather than abandoned after a weekend, and which fit a
self-hosted deployment of GLM-5.2-FP8, Qwen3.6-27B, gemma-4-31B, and Kimi K3?

**Method.** Candidates came from five GitHub repository searches plus web search. Liveness
was measured directly against the GitHub API (`gh api`) on 2026-07-30 — not inferred from
search snippets or README claims, which is how abandoned projects keep getting recommended.
The window is 2026-05-30 → 2026-07-30. Leading candidates then went through three
adversarial verification passes each (setup, liveness quality, trust) against pinned commits;
one verifier downloaded and ran the Bifrost binary against a controlled upstream.

*All figures accessed 2026-07-30 via the GitHub REST API or the cited page.*

---

## The headline: for self-hosted vLLM you probably need no proxy at all

vLLM serves the **Anthropic Messages API natively**. Its OpenAI-compatible server exposes
`POST /v1/messages` and `/v1/messages/count_tokens` alongside `/v1/chat/completions` and
`/v1/responses` ([Online Serving](https://docs.vllm.ai/en/latest/serving/online_serving/)).
vLLM ships an official Claude Code integration page whose entire configuration is:

```bash
vllm serve <model> --served-model-name my-model \
  --enable-auto-tool-choice --tool-call-parser <parser>
```
```bash
ANTHROPIC_BASE_URL=http://localhost:8000
ANTHROPIC_API_KEY=dummy
ANTHROPIC_AUTH_TOKEN=dummy
ANTHROPIC_DEFAULT_OPUS_MODEL=my-model
ANTHROPIC_DEFAULT_SONNET_MODEL=my-model
ANTHROPIC_DEFAULT_HAIKU_MODEL=my-model
```

— [vLLM: Claude Code](https://docs.vllm.ai/en/stable/serving/integrations/claude_code/)

This is not a fringe path. `vllm/entrypoints/anthropic/` has 45 commits since
[PR #22627](https://github.com/vllm-project/vllm/pull/22627) landed the endpoint in Oct 2025,
with heavy June–July 2026 maintenance: prefix-caching-aware system-message placement
(#44602), cache-usage reporting (#40912), `num_cache_creation_tokens` (#48535), tool_use
argument-dropping fixes (#45287). vLLM tracks Claude Code releases.

**SGLang serves it too.** If you are on SGLang rather than vLLM — both are plausible for an
FP8 GLM-5.2 deployment — the same path exists and is under active development: #28522 added
Anthropic-compatible API documentation, #29169 strips the `x-anthropic-billing-header`
server-side, and open PRs are refining `tool_result` ordering (#29083), document blocks
(#31179), and thinking-block signatures (#29242). It is rougher than vLLM's implementation —
#32255 *"OpenAI and Anthropic protocols are not working in sglang"* was filed and closed on
2026-07-23. Verify against your build before committing.

**Validate before you commit GPU time — the system-role handling is not fully fixed.** vLLM
#46025 (merged 2026-06-18) replaced unconditional hoisting with chat-template detection, but
**[#48874](https://github.com/vllm-project/vllm/issues/48874) is open** as of 2026-07-16:
*"Anthropic /v1/messages renders system-role messages inside `messages` positionally into the
chat template (**breaks Claude Code >=2.1.2xx tool calling**)"*. PR #44737, "Normalize
non-standard message roles from Claude Code CLI >= 2.1.154", is **still open**, and
#44576 *"Claude code does not work with vLLM"* remains open with 4 comments. So run a
realistic multi-turn, multi-tool session on a pinned Claude Code version first; this is the
most likely thing to bite you, and it is engine-side, not proxy-side.

**Why this matters more than tool choice.** Every translating proxy converts
Anthropic → OpenAI → Anthropic, and each hop is where the documented failures live: dropped
`cache_control`, stripped thinking history, corrupted streaming tool-call deltas, mangled
`max_tokens`. Serving Anthropic format directly skips all of it.

**The one thing a proxy still buys you: multiplexing.** One vLLM process serves one model —
verified, not assumed: the feature request for multi-model serving
([#21481](https://github.com/vllm-project/vllm/issues/21481)) was closed **`not_planned`**.
Claude Code reads `ANTHROPIC_BASE_URL` once at launch and never re-reads it. So if you want
your four models reachable in one session — or Claude Code's opus/sonnet/haiku tiers pointed
at *different* models — you need something in front. Since vLLM already speaks Anthropic,
that something can be a **plain reverse proxy routing on the JSON `model` field** (nginx,
Caddy, a 100-line Go service). No translation, no vendor, nothing to abandon. Consider this
before adopting any of the products below.

---

## Anthropic's official position

Claude Code accepts **Anthropic dialect only**. The gateway protocol admits exactly three
formats, and all three are Anthropic dialects — there is no OpenAI `/chat/completions` row:

| Format | Selected by | Endpoints |
|---|---|---|
| Anthropic Messages | `ANTHROPIC_BASE_URL` | `/v1/messages`, `/v1/messages/count_tokens` (optional) |
| Amazon Bedrock InvokeModel | `ANTHROPIC_BEDROCK_BASE_URL` + `CLAUDE_CODE_USE_BEDROCK=1` | `/model/{model}/invoke`, `…/invoke-with-response-stream` |
| Google Agent Platform rawPredict | `ANTHROPIC_VERTEX_BASE_URL` + `CLAUDE_CODE_USE_VERTEX=1` | `:rawPredict`, `:streamRawPredict` |

— [Gateway protocol reference](https://code.claude.com/docs/en/llm-gateway-protocol)

And support is explicitly withheld:

> Any gateway that exposes a supported API format works. Anthropic doesn't endorse,
> maintain, or audit third-party gateway products, and **doesn't support routing Claude Code
> to non-Claude models through any gateway.**

— [Other LLM gateways](https://code.claude.com/docs/en/llm-gateway)

That is a support disclaimer, not a prohibition — the same docs document an org-wide gateway
rollout. But expect zero vendor recourse when a Claude Code release breaks translation, and
the docs say plainly that "a gateway that doesn't forward [new capabilities] breaks the
corresponding features." That is the structural reason projects in this space die.

One further trap: `ANTHROPIC_DEFAULT_*_MODEL_SUPPORTED_CAPABILITIES` has **no effect** behind
an `ANTHROPIC_BASE_URL` gateway — it works only under `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX`/
`_FOUNDRY`. So you cannot declare `thinking`, `effort`, or `interleaved_thinking` support for
your models. The only documented remedy is `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`.

---

## Direction matters, and names actively mislead

| Direction | What it does | Wanted? |
|---|---|---|
| `cc → openai` | Serves an **Anthropic-shaped** `/v1/messages`; Claude Code points at it via `ANTHROPIC_BASE_URL`, and it forwards to OpenAI-compatible backends | **Yes** |
| `subscription → openai` | Wraps a Claude Max/Pro subscription and exposes it **as** an OpenAI `/v1/chat/completions` endpoint | No |

Excluded as wrong-direction despite matching every search term: `wende/claude-max-api-proxy`,
`sethschnrt/claude-max-api-proxy`, `ziozzang/claude2openai-proxy`,
`meaning-systems/claude-code-proxy`, `dtzp555-max/ocp`, `claude-openai-proxy` (PyPI),
`dwgx/WindsurfAPI`. Excluded as different tools: `seifghazi/claude-code-proxy` and
`liaohch3/claude-tap` (traffic inspection), `Infisical/agent-vault` (credential vault).
Verified wrong-direction on inspection: **`NadirRouter/NadirClaw`** — its `/v1/messages`
surface forwards only to Anthropic and cannot reach OpenAI-compatible backends.

Two repos named `claude-code-proxy` point in opposite directions. A third
(`raine/claude-code-proxy`) is a subscription bridge.

---

## Liveness measurements

### Alive — substantive June/July 2026 development

| Repo | Stars | Commits 60d | Authors 60d | Merged PRs 60d | Latest release | Forks |
|---|---|---|---|---|---|---|
| [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | 45,499 | 628 | 45 | 123 | v7.2.106 (07-29) | 7,069 |
| [BerriAI/litellm](https://github.com/BerriAI/litellm) | 55,032 | 2,241 | 38 | 1,948 | v1.94.0 (07-28) | 10,181 |
| [lidge-jun/opencodex](https://github.com/lidge-jun/opencodex) | 5,727 | 2,837 | 52 | 266 | v2.7.43 (07-29) | 457 |
| [maximhq/bifrost](https://github.com/maximhq/bifrost) | 6,880 | 1,316 | 71 | 1,132 | ent-v1.5.6 (07-24) | 963 |
| [musistudio/claude-code-router](https://github.com/musistudio/claude-code-router) | 36,273 | 365 | 11 | 28 | v3.0.17 (07-28) | 3,034 |
| [decolua/9router](https://github.com/decolua/9router) | 24,032 | 313 | 112 | 2 | (07-16) | — |
| [ENTERPILOT/GoModel](https://github.com/ENTERPILOT/GoModel) | 1,022 | 220 | 6 | 190 | v0.1.64 (07-29) | 73 |
| [routatic/proxy](https://github.com/routatic/proxy) | 899 | 63 | 22 | 43 | v0.6.2 (07-23) | 114 |

Found late, not fully vetted, but alive and relevant: **[diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute)**
(34,067 stars, MIT, local-first, `omniroute setup-claude`) and
**[Alishahryar1/free-claude-code](https://github.com/Alishahryar1/free-claude-code)**
(42,901 stars). Also **[mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)**
(5,198 stars, MIT, 65 commits / 11 authors in 60d) — a model *multiplexer* that proxies
`/v1/messages`, which is close to the reverse-proxy shape recommended above.

### Dead or dying — fails the two-month filter

| Repo | Stars | Last push | Commits 60d | Note |
|---|---|---|---|---|
| [1rgs/claude-code-proxy](https://github.com/1rgs/claude-code-proxy) | 3,710 | 2026-06-23 | 1 | The original "Run Claude Code on OpenAI models" |
| [fuergaosi233/claude-code-proxy](https://github.com/fuergaosi233/claude-code-proxy) | 2,753 | 2026-03-12 | 0 | Still the top web-search hit |
| [Portkey-AI/gateway](https://github.com/Portkey-AI/gateway) | 12,593 | 2026-05-25 | 0 | Large project gone quiet |
| [Helicone/ai-gateway](https://github.com/Helicone/ai-gateway) | 615 | 2025-11-21 | 0 | 8 months stale |
| [9j/claude-code-mux](https://github.com/9j/claude-code-mux) | 520 | 2025-11-19 | 0 | **Archived** |
| [luohy15/y-router](https://github.com/luohy15/y-router) | 382 | 2026-01-11 | 0 | **Archived** |
| [maxnowack/anthropic-proxy](https://github.com/maxnowack/anthropic-proxy) | 414 | 2025-04-28 | 0 | **Archived** |
| [OnlyTerp/UltraCode-Shim](https://github.com/OnlyTerp/UltraCode-Shim) | 416 | 2026-06-18 | 39 | Stalled ~6 weeks |
| [starbaser/ccproxy](https://github.com/starbaser/ccproxy) | 354 | 2026-07-14 | 77 | Single author, 0 merged PRs |
| [Mirrowel/LLM-API-Key-Proxy](https://github.com/Mirrowel/LLM-API-Key-Proxy) | 531 | 2026-07-17 | 1 | Push activity without commits |
| [NadirRouter/NadirClaw](https://github.com/NadirRouter/NadirClaw) | 626 | 2026-07-20 | 14 | Also wrong direction |
| [glidea/claude-worker-proxy](https://github.com/glidea/claude-worker-proxy) | 274 | 2026-07-10 | 5 | |
| [KroMiose/claude-code-nexus](https://github.com/KroMiose/claude-code-nexus) | 253 | 2025-08-20 | 0 | |
| [m0n0x41d/anthropic-proxy-rs](https://github.com/m0n0x41d/anthropic-proxy-rs) | 83 | 2026-05-29 | 0 | |
| [empero-org/claude-code-proxy](https://github.com/empero-org/claude-code-proxy) | 12 | 2026-06-29 | 1 | |
| [gabrielmaialva33/anthropic-proxy](https://github.com/gabrielmaialva33/anthropic-proxy) | 12 | 2026-03-23 | 0 | |
| [loulin/claude-bridge](https://github.com/loulin/claude-bridge) | 10 | 2026-03-30 | 0 | |
| [elusznik/open-claude-router](https://github.com/elusznik/open-claude-router) | 3 | 2025-11-22 | 0 | |

### Issue triage — whether anyone is home

| Repo | Opened (45d) | Closed (45d) | Open backlog | Reading |
|---|---|---|---|---|
| CLIProxyAPI | 395 | **608** | 347 | Closing faster than they arrive |
| litellm | 899 | 735 | 4,504 | Huge but actively triaged |
| opencodex | 273 | 235 | 62 | Keeping pace |
| bifrost | 223 | 146 | 706 | Falling behind but staffed |
| claude-code-router | 84 | **24** | **1,043** | Backlog growing; 36k stars, one maintainer |
| routatic/proxy | 15 | 19 | 8 | Small and current |
| GoModel | 34 | 30 | 32 | Small and current |

Commit substance was sampled directly; none of the "alive" set is bot churn. Contribution is
concentrated, though: litellm's 38 authors are ~9 accounts with ~1,880 of 2,191 commits;
claude-code-router is musistudio (570 lifetime) with the next contributor at 18; bifrost's
raw count includes 1,754 `github-actions[bot]` commits.

---

## The decisive technical constraint: Responses API vs chat/completions

Two of the most-recommended gateways call the **wrong upstream endpoint** by default.

- **LiteLLM**: on the `/v1/messages` path, provider `openai` routes to the OpenAI
  **Responses** API. `_RESPONSES_API_PROVIDERS = frozenset({"openai"})` in
  `litellm/llms/anthropic/experimental_pass_through/messages/handler.py`; `get_complete_url()`
  returns `f"{api_base}/responses"`. Opt-out is
  `LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES` — present in `litellm/__init__.py`
  but **undocumented for this scenario**.
- **Bifrost**: same behaviour, confirmed empirically. A verifier ran Bifrost v1.6.6 against a
  controlled upstream: the `/anthropic` path calls `/v1/responses` for both streaming and
  non-streaming, and returns HTTP 404 when the upstream serves only `/chat/completions`. Fix
  is a custom provider with `allowed_requests{responses:false, chat_completion:true}`.
- **CLIProxyAPI**: no trap. `internal/runtime/executor/openai_compat_executor.go` builds
  `strings.TrimSuffix(baseURL,"/") + "/chat/completions"` directly.

**For this deployment it is less dangerous than it sounds:** vLLM serves `/v1/responses` too,
so the default may simply work. Verify on your build before relying on it. SGLang and
llama.cpp are the ones that will 404.

Two more Bifrost findings from the live test: `network_config.base_url` must **omit** `/v1`
(otherwise the upstream receives `/v1/v1/responses`), and Claude Code's `max_tokens` arrives
as `max_output_tokens`/`max_completion_tokens` — on upstreams accepting only `max_tokens` the
cap is silently dropped, with 171–289× output overruns (open issue #5606).

---

## Trust findings — stated plainly

These are disqualifications, not nitpicks, and none are visible from stars or commit counts.

**`decolua/9router` — do not use.** Its own docs (`gitbook/content/en/faq.md`) state
"**No telemetry:** - No usage tracking - No analytics - No phone-home" while
`src/app/layout.js` renders `<GoogleAnalytics gaId={"G-LC959F603F"} />` unconditionally in the
root layout. It ships a TLS MITM subsystem installing a "9Router MITM Root CA" into the OS
system trust store. **19 published GitHub security advisories between 2026-05-13 and
2026-07-16, six critical** (unauthenticated RCE, OS command injection, hardcoded fallback JWT
secret, unauthenticated CRUD on `/api/providers` with API-key leak). It contains purpose-built
ban-evasion code (`open-sse/utils/claudeCloaking.js` forging billing headers), automated quota
gaming, cookie-lifting providers, and a reimplementation of Cursor's proprietary
`x-cursor-checksum`. And `open-sse/utils/bypassHandler.js` **fabricates responses on the
Claude Code path with no off switch**.

**`lidge-jun/opencodex` — not defensible at an employer.** `src/oauth/anthropic.ts:6` hides
Claude Code's own OAuth client ID behind `atob("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")`
— the only base64-obfuscated constant in `src/` apart from image decoding.
`src/adapters/client-fingerprint.ts` exists so requests are not "rejected — or quietly flagged"
as non-first-party. `src/oauth/local-token-detect.ts` extracts the Claude Code token via
`security find-generic-password -s "Claude Code-credentials" -w`. Separately, the project has
publicly declared it is **replacing its entire runtime** with a Go port (`MAINTAINERS.md`:
"Transition to `dev2-go` (current phase)"), so the TypeScript Claude Code bridge you would
adopt is scheduled for reimplementation. No branch protection on `main` or `dev`.

**`router-for-me/CLIProxyAPI` — best technical fit, real caveat.** The BYOK
`openai-compatibility` path is clean plain-API-key code with no evasion involved. But the same
binary contains `internal/auth/claude/utls_transport.go`, whose stated purpose is "to bypass
Cloudflare's TLS fingerprinting on Anthropic domains", a documented `disable-claude-cloak-mode`
flag controlling "the Claude Code CLI disguise and system prompt replacement", and
`codex.identity-confuse`. Operational defaults are also unsafe: `server_middleware.go` notes
"When no providers are available, it allows all requests (legacy behaviour)" and
`config.example.yaml` ships `host: ""`, binding all interfaces — an unauthenticated process
holding all your keys until you populate `api-keys`. The management panel auto-downloads from
GitHub unless disabled. Roughly 60 of 294 README lines are affiliate copy for account resellers.

**`musistudio/claude-code-router` — architectural problems for a team.** All
Anthropic↔OpenAI translation lives in `@the-next-ai/ai-gateway`, an npm package by the same
author with **`repository: None`** shipping only a bundled 699 KB `dist/index.js` — the
load-bearing code is not in the repo you are auditing. v3 has **no hand-editable config**:
state is `config.sqlite` mutated through a browser UI, so server provisioning and
config-in-git are out. With a "System default" profile it **rewrites your real
`~/.claude/settings.json`** (open issue #1575). It optionally installs a MITM CA. Confirmed
bug #1587: token usage dropped from `message_delta` on exactly the
`openai_chat_completions` → Anthropic SSE path.

**`maximhq/bifrost` — company-backed, two operational cautions.** `npx -y @maximhq/bifrost`
downloads an unsigned binary from `downloads.getmaxim.ai` with no checksum or signature
verification and executes it, defaulting to `latest` resolved at every run, so pinning the npm
package does not pin the gateway. v1.6.6 exits FATAL on first boot without egress to
`getbifrost.ai` for pricing data. CVE-2026-55245 (High, SSRF) was maintainer-reported and
patched in 1.5.16. Dashboard and inference endpoints accept anonymous requests by default.

**`BerriAI/litellm`** — 12 published advisories Apr–Jun 2026 (3 Critical, 5 High),
concentrated in proxy auth and admin endpoints; `telemetry = True` is still the default in
`litellm/__init__.py`; `uv tool install 'litellm[proxy]'` installs enterprise-licensed code
unconditionally. No evasion machinery.

---

## Per-model fitness

All four models exist and all four have **native, trained-in** function calling. Gemma 4
closed the gap that made Gemma 1–3 unusable for agentic work: the model card states
"**Function Calling** – Native support for structured tool use, enabling agentic workflows."

| Model | CC fit | Context | Required vLLM flags |
|---|---|---|---|
| **GLM-5.2-FP8** (744B-A40B MoE, MIT) | **good** | 1M native | `--tool-call-parser glm47 --reasoning-parser glm45 --enable-auto-tool-choice` |
| **Kimi K3** (2.8T/104B MoE) | **good** | 1M | see thinking-history note below |
| **Qwen3.6-27B** (dense + vision, Apache-2.0) | **good** | 262K native | `--tool-call-parser qwen3_xml --reasoning-parser qwen3` |
| **gemma-4-31B-it** (30.7B dense, Apache-2.0) | **workable** | 256K nominal | `--tool-call-parser gemma4 --reasoning-parser gemma4 --chat-template …gemma4.jinja` |

**GLM-5.2 is the standout, and Z.ai proves the harness works.** The model card benchmarks it
*inside Claude Code*: "We evaluate ProgramBench (200 instances) with Claude-Code 2.1.156" and
"Terminal-Bench 2.1 (Claude Code): We evaluate in Claude Code 2.1.167". Scores: SWE-bench Pro
62.1, Terminal Bench 2.1 81.0, MCP-Atlas 76.8. Weakest line is Tool-Decathlon 48.2 (vs Opus
4.8's 59.9). Caveats: tool calling **and** MTP together need vLLM `main`, not 0.23.0 stable;
hardware floor is 8×H200/H20 for FP8, 8×B200 for the real 1M window; FP8 throughput silently
degrades without DeepGEMM. Note Z.ai overrode `max_new_tokens` to 128k "via a transparent
proxy, bypassing the 64k CLI cap".

**Qwen3.6-27B has a parser-name trap.** The model card prescribes `--tool-call-parser
qwen3_coder`; current vLLM docs and the vLLM recipe for this model both use **`qwen3_xml`**.
Users report `qwen3_coder` degenerating into an infinite `!!!!!!!` stream on long inputs
containing a tool call. Use `qwen3_xml`. Arguments travel as unescaped XML
(`<parameter=name>VALUE</parameter>`), so types are reconstructed from the JSON schema —
booleans and integers in Claude Code tool args are the coercion risk. Keep `--max-model-len`
at ≥128K; the vendor warns below that "preserve thinking capabilities" fails.

**gemma-4-31B is the weak link — use it as the haiku tier, not the main model.** Its tool-call
wire format is custom and not JSON: `<|tool_call>call:name{key:<|"|>value<|"|>}` with unquoted
keys and no escape mechanism for the string delimiter. Two open engine bugs bite: vLLM #39392
(`gemma4` parser emits `<pad>` tokens under **concurrent** requests) and vLLM #44522
(streaming parser leaks raw delimiters into tool arguments). Effective long-context recall is
well under nameplate — MRCR v2 8-needle at 128k is 66.4%. Recommended temperature is 1.0,
which sits awkwardly with exact-string file edits. No BFCL or SWE-bench numbers published.

**Kimi K3's single highest-risk requirement.** The model card: "Kimi K3 was trained in the
**preserved thinking history mode**. For multi-turn conversations and tool calls, Kimi K3
requires the complete [reasoning content passed back as-is]." A translator that keeps only
`content` + `tool_calls` will not error — it silently puts every multi-turn tool loop
off-distribution. Also: `reasoning_effort="medium"` is **rejected** (`{low, high, max}` only);
`ENABLE_TOOL_SEARCH=false` is required because "The Kimi endpoint does not support this
feature yet; it must be set to false, otherwise tool calls misbehave." Self-hosting needs
8×B300/GB300 or 8×MI355X, and the vLLM recipe is still badged "Pre-release". **Moonshot serves
a first-party Anthropic endpoint** at `https://api.moonshot.ai/anthropic` — for Kimi K3 the
hosted path may beat self-hosting outright.

---

## What actually breaks in practice, and the settings that prevent it

Set these before anything else. Sources are engine docs, vendor docs, and traced issues.

**1. `CLAUDE_CODE_ATTRIBUTION_HEADER: 0` — the single highest-value setting.**
Claude Code prepends a per-request hash to the system prompt, so the KV prefix misses on
every request. Unsloth measures the cost as "**90% slower with local models**". vLLM handles
it server-side in **> 0.17.1**; on older builds set it in `~/.claude/settings.json` (shell
exports are ignored by some builds).
[vLLM](https://docs.vllm.ai/en/stable/serving/integrations/claude_code/) ·
[Unsloth](https://unsloth.ai/docs/basics/claude-code)

**2. Mid-conversation `role: "system"` — the self-hosted performance killer.** Claude Code
emits transient system-role messages inside the message array. Gateways that hoist them to
the top-level `system` block fork the prefix cache and force a **full re-prefill every turn**.
A Bifrost operator serving GLM-5 on SGLang and Kimi-K2 on vLLM measured **99.0% of reminders
hoisted (n=17,913)** versus 0.5% on the inline path (n=22,350) — bifrost issue #4592. Both
engines moved to probing the chat template instead: SGLang PR #28906 (merged 2026-06-22),
vLLM #46025 (merged 2026-06-18). **Only partially resolved** — vLLM #48874 is open as of
2026-07-16 and reports the same class of defect breaking tool calling on Claude Code >=2.1.2xx.
Strict endpoints reject these messages outright with `400 invalid message role: system`,
reported across four providers at Claude Code 2.1.154 (cc-switch issue #3277, 65 comments).

**3. Auto-compact silently stopped firing on third-party endpoints from v2.1.161.** A reporter
traced the gate: `_Y8()` requires `XA() === "firstParty"`, so the flag never resolves for
`ANTHROPIC_BASE_URL` users. One MiniMax user reached **~2.4M input tokens on a single request**
with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` set and ignored. Manual `/compact` still works.
Still live at end of June on the available evidence.
[anthropics/claude-code#65585](https://github.com/anthropics/claude-code/issues/65585)

**4. Your "small fast model" is not small — and it runs compaction.** Anthropic's docs state
Claude Code reads `ANTHROPIC_DEFAULT_HAIKU_MODEL` "everywhere it uses the small fast model"
and runs "background functionality, such as **conversation summarization**" on it. Every
official self-hosted guide — vLLM's included — points all three tiers at the same served
model. So compaction and per-turn `/goal` evaluation land on your 744B MoE, competing for the
same GPUs and KV cache. **This is the strongest argument for your multi-model setup:** point
`ANTHROPIC_DEFAULT_HAIKU_MODEL` at Qwen3.6-27B (or gemma-4-31B, whose weaknesses matter less
for summarization) and keep GLM-5.2 for the main tiers.

**5. Thinking history must round-trip.** Claude Code strips `thinking` blocks and
`reasoning_content`, so the proxy must re-inject them. Kimi returns `thinking is enabled but
reasoning_content is missing in assistant tool call message at index 2`. CLIProxyAPI merged a
fix (PR #3719). On Qwen3.6 set `chat-template-kwargs = {"preserve_thinking": true}`; the
Gemma-4 default template drops prior-turn reasoning and forces re-prefill.

**6. Streaming translation corrupts tool-call arguments.** A 10-trial probe against
claude-code-router went from **10/10 to 0/10** valid tool calls by adding the `reasoning`
transformer (Qwen3.6-35B-A3B via llama.cpp); Claude Code saw `required parameter "command" is
missing`. A second reporter reproduced it on LM Studio with **no** reasoning transformer, so
the fault surface is wider than the issue title. claude-code-router#1397.

**7. `count_tokens` is a hidden dependency.** LiteLLM routed
`/v1/messages/count_tokens` to `api.anthropic.com` rather than the configured `api_base` —
invalid for air-gapped deployments (#30043). CLIProxyAPI had the mirror bug, inflating every
`/context` entry by ~2k tokens and triggering premature auto-compaction (#4103, fixed).

**8. `--kv-cache-dtype fp8` may break tool-call JSON.** "Quantizing k leads to broken json on
tool calls, which is fairly unrecoverable" — single anecdote, but the GLM-5.2 recipe enables
FP8 KV cache by default. Worth an A/B test.

**9. Also relevant.** `ENABLE_TOOL_SEARCH` defaults off behind a non-first-party base URL, so
MCP tools load upfront. Fine-grained tool streaming is off by default behind a custom base URL
(`CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING=1`). The `/model` picker only lists IDs
starting with `claude` or `anthropic`. `ANTHROPIC_BASE_URL` is read **once at process start**.
The `[1m]` suffix is client-side syntax and breaks if it reaches the upstream `model` field.
Forward upstream error bodies **unmodified** — Claude Code's retry logic matches on error
wording. `ANTHROPIC_SMALL_FAST_MODEL` is deprecated in favour of `ANTHROPIC_DEFAULT_HAIKU_MODEL`.

**10. Two Claude Code limitations no proxy can fix.** Subagent model routing is broken
upstream — `Agent(model:)`, agent frontmatter `model:`, and `CLAUDE_CODE_SUBAGENT_MODEL` all
resolve to the parent model (anthropics/claude-code#43869). And subagents have prompt caching
hardcoded off (#29966). Plans to route different agent roles to different models among your
four models are partly blocked regardless of tool choice.

---

## Recommendation

*Stated assumption: you are serving with vLLM or SGLang. FP8 GLM-5.2 implies one of the two,
but you did not say which, and the flags below are vLLM's. SGLang has the same native
Anthropic path with a rougher implementation — see the headline section.*

**1. Start with no proxy, but validate first.** Point Claude Code straight at vLLM's native
`/v1/messages` for GLM-5.2. Set `CLAUDE_CODE_ATTRIBUTION_HEADER: 0`, run vLLM > 0.17.1 (and
`main` if you want MTP with tool calling), verify the `glm47` parser is registered, and copy
Z.ai's own tuning: `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`, `API_TIMEOUT_MS=3000000`. This
eliminates the entire class of translation bugs above and has no third-party dependency to be
abandoned. **Before committing GPU time, run a realistic multi-turn multi-tool session on a
pinned Claude Code version** — vLLM #48874 (open) reports system-role rendering breaking tool
calling on Claude Code >=2.1.2xx. If you hit it, that is the one case where a proxy that
normalizes roles earns its keep.

**2. Add multiplexing only when you need it.** To reach all four models in one session, prefer
a **thin reverse proxy routing on the `model` field** to Anthropic-native vLLM instances —
nginx/Caddy or llama-swap. Still zero translation.

**3. If you want a product instead, `CLIProxyAPI` is the strongest technical fit** — arbitrary
`base-url`, direct `/chat/completions` (no Responses trap), `count_tokens` actually
implemented, a merged Kimi thinking-history fix, and the healthiest triage numbers here. Two
conditions: set `api-keys` and bind `host: 127.0.0.1` before it ever runs, and accept that the
binary also contains Cloudflare TLS-fingerprint evasion and Claude Code impersonation. If
that is unacceptable at your organisation — a defensible position — use **LiteLLM** with
`LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES` if your endpoints lack `/responses`,
accepting a heavier install and an active advisory history.

**4. Avoid `9router` and `opencodex` outright**, on the trust findings above. Avoid
`claude-code-router` for anything needing reproducible config or auditable translation code.

**5. Model-tier assignment.** `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` → GLM-5.2-FP8;
`ANTHROPIC_DEFAULT_HAIKU_MODEL` → Qwen3.6-27B. Keep gemma-4-31B off the main path until vLLM
#39392 (concurrent-request `<pad>` corruption) is fixed. For Kimi K3, price Moonshot's hosted
`https://api.moonshot.ai/anthropic` against an 8×B300 node before committing to self-hosting.

**6. Pin Claude Code and read release notes.** Two of the worst findings here — the
`role: "system"` 400 and the auto-compact regression — arrived in specific point releases and
were worked around by pinning plus `DISABLE_AUTOUPDATER=1`. Anthropic does not support this
configuration, so you own the regression risk.
