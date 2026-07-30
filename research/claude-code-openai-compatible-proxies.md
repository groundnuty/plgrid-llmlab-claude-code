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

### The open defect that gates this recommendation

The endpoint is real and maintained. It is also, on **current** Claude Code, substantially
broken for agentic work — and the two facts are not in contradiction, so it is worth being
precise about the mechanism.

vLLM #46025 (merged 2026-06-18) replaced unconditional system-message hoisting with
chat-template detection. That fixed a cache problem and created a generation problem.
**[#48874](https://github.com/vllm-project/vllm/issues/48874) is open** as of 2026-07-16 and
reports, verbatim from the issue body:

> Recent Claude Code CLI versions (observed with 2.1.207; 2.1.150 does not do this) send their
> agent-registry context as a **`system`-role message inside the `messages` array, after the
> user turn** […] Anthropic's first-party API accepts this shape (Claude Code works against it).

> **0.24.0 / 0.25.1**: the request is accepted and the system-role message is rendered
> **positionally** into the chat template, so the model's context *ends* with a system block
> instead of the user task. […] it emits pseudo-XML imitations of tool calls as plain text
> […] the streaming tool parser finds nothing, and the client sees a text-only turn with
> `stop_reason: end_turn`. In an agentic harness this ends the loop: **~90% of long-prompt
> tasks (SWE-bench-pro via Claude Code) died as 1-turn completions**, while short prompts
> often survived.

Three things make this directly relevant here:

1. **It reproduces on this model family.** The reporter used `Qwen/Qwen3.6-35B-A3B-FP8` — the
   MoE sibling of Qwen3.6-27B — with **both** `qwen3_coder` and `qwen3_xml` parsers and
   `--reasoning-parser qwen3`. Changing the tool parser does not help.
2. **It fails silently.** No error, no 400. Just a text-only turn that ends the agent loop.
   vLLM 0.11.0 rejected the request outright, which was less damaging because it was visible.
3. **Nobody has fixed it.** One comment, a volunteer offering to investigate (2026-07-17).
   PR #44737 "Normalize non-standard message roles from Claude Code CLI >= 2.1.154" is **still
   open**; #44576 *"Claude code does not work with vLLM"* is open with 4 comments.

The underlying tension is unresolved upstream: hoisting the message forks the prefix cache and
forces full re-prefill every turn (SGLang #28906, measured at 99.0% of reminders hoisted in
bifrost #4592), while rendering it inline can leave the context ending on a system block and
derail generation (#48874). Neither engine has a position that is right on both axes.

### Which of your models are exposed — measured, not guessed

Reading vLLM's current source rather than the issue tracker shows the behaviour is **decided by
your model's chat template**, and is therefore testable before you deploy anything.

`vllm/entrypoints/anthropic/serving.py` (main, fetched 2026-07-30) sets
`self._merge_inline_system = self._detect_merge_inline_system(chat_template)` at construction.
That function is a Jinja render probe, verbatim docstring:

> Renders a `[system, user, system, user]` conversation against the template; if it raises
> (e.g. Qwen's `loop.first` guard), the model needs inline system messages merged into the
> leading block.

- **raises → `merge_inline_system=True`** → inline system messages are merged into the leading
  system block → **#48874 cannot occur**.
- **renders cleanly → `False`** → system messages stay in position → the prompt can end on a
  system block → **#48874 occurs**.
- no chat template at all → `True` (safe default).

Running that exact probe against the real templates for the four deployed checkpoints:

| Checkpoint | Probe result | `merge_inline_system` | Verdict |
|---|---|---|---|
| `Qwen/Qwen3.6-27B` | raises `UndefinedError` | `True` | **Safe** |
| `moonshotai/Kimi-K3` | no `chat_template` field (engine-internal rendering) | `True` | **Safe** |
| `zai-org/GLM-5.2-FP8` | renders cleanly | `False` | **Exposed** |
| `google/gemma-4-31B-it` | renders cleanly | `False` | **Exposed** |

For the two exposed templates, rendering the actual `[user, system]` shape Claude Code sends
confirms the mechanism — the prompt ends on the agent-registry blob, not the user's task:

```
GLM-5.2-FP8:
  [gMASK]<sop><|system|>Reasoning Effort: Max<|user|>USER_TASK_HERE<|system|>AGENT_REGISTRY_BLOB<|assistant|><think>

gemma-4-31B-it:
  <|turn>user\nUSER_TASK_HERE<turn|>\n<|turn>system\nAGENT_REGISTRY_BLOB<turn|>\n<|turn>model\n<|channel>thought
```

**This inverts the earlier per-model risk ranking.** #48874 was filed against
`Qwen/Qwen3.6-35B-A3B-FP8`, which made Qwen3.6 look like the hazard — but the dense
`Qwen3.6-27B` template *raises*, so it is protected, while **GLM-5.2-FP8, the intended main
model, is the one exposed.** It also explains why Z.ai's benchmarks looked clean: they ran
Claude Code 2.1.156/2.1.167, which predate the system-after-user shape entirely.

Reproduce it in a minute against any checkpoint (`pip install jinja2`):

```python
import jinja2, jinja2.sandbox, jinja2.ext
t = open("chat_template.jinja").read()          # or tokenizer_config.json["chat_template"]
env = jinja2.sandbox.ImmutableSandboxedEnvironment(
    trim_blocks=True, lstrip_blocks=True, extensions=[jinja2.ext.loopcontrols])
try:
    env.from_string(t).render(messages=[
        {"role": "system", "content": "t"}, {"role": "user", "content": "t"},
        {"role": "system", "content": "t"}, {"role": "user", "content": "t"}],
        add_generation_prompt=False)
    print("EXPOSED to #48874 (vLLM leaves inline system messages in place)")
except jinja2.TemplateError as e:
    print("SAFE (vLLM merges into leading block):", type(e).__name__)
```

### Fixing an exposed model

The goal is to force `merge_inline_system = True`. Three options, cheapest first:

1. **Serve a guarded chat template** via `--chat-template my_glm52.jinja` — a copy of the
   model's template with a guard that raises on a mid-conversation `system` role. vLLM's probe
   then returns `True` and merges automatically. No fork, no patch, and the change is a config
   file you can commit.
2. **Carry a one-line local patch** — force `self._merge_inline_system = True` in
   `serving.py`. For scale reference, the adjacent role-normalization fix (PR #44737) is 15
   lines in one file, so a local carry here is small and reviewable.
3. **Put a role-normalizing proxy in front.** Heavier, but see the proxy comparison below.

**The cost of merging, stated honestly:** the system reminder Claude Code rotates each turn
lands in the *leading* block, so the cache prefix changes every turn and you get a full
re-prefill — the exact regression SGLang #28906 was written to avoid. You are choosing between
correct tool calling and prefix-cache reuse. Correctness wins; budget for the throughput hit.
Partial mitigation: vLLM's `_extract_system_text` already strips the billing header, and
`CLAUDE_CODE_ATTRIBUTION_HEADER: 0` removes the per-request hash, so what rotates is only the
reminder content.

**Also note:** PR #44737 is *not* a fix for #48874, despite being adjacent. It maps the
non-standard `ctx` and `msg` roles to `user` so they pass Pydantic validation — that addresses
the `400 invalid message role` class (cc-switch #3277), not positional rendering. `system` is
already a valid role in `AnthropicMessage`. **No open PR addresses #48874**: nothing
cross-references the issue, the only comment is a volunteer offering to investigate
(2026-07-17), and the last commit to `vllm/entrypoints/anthropic/` is 2026-07-18 on an
unrelated cache-token field.

### Has anyone published a working recipe? No — and the negative is now firm

A dedicated eight-angle search (issue trackers, proxy source, Chinese-language forums,
Reddit/HN, local-stack docs, chat templates, alternative harnesses, version matrices) plus a
completeness pass found **no published, reproducible configuration for Claude Code >= 2.1.207
against a self-hosted open-weight model on vLLM or SGLang.**

Searched and empty: GitHub issues/PRs/code search; vLLM, SGLang, Unsloth, llama.cpp, Ollama,
LM Studio and llama-swap docs; HN via the Algolia API; lobste.rs; linux.do; V2EX; CSDN;
Japanese Qiita and Zenn; Reddit r/LocalLLaMA and r/ClaudeCode (reached by driving a real Chrome
session — WebFetch and every Redlib mirror are blocked); and **discuss.vllm.ai**, which matters
most because vLLM closed GitHub Discussions specifically to route people there and it has
nothing on Claude Code since 2025. Still unsearched: Discord, Korean sources, X, video.

The closest claims, all falling short:

| Claim | CC version | Why it falls short |
|---|---|---|
| SGLang PR #28906 e2e trace | **2.1.185** | Highest claimed-working anywhere. Validates the *steer* case (system message followed by an assistant turn), not the *trailing* case #48874 is about |
| [CodeRouter §6.1](https://github.com/zephel01/CodeRouter/blob/main/docs/guides/subagent-routing.en.md) | **2.1.206–207** | Real, dated (2026-07-11), with in-repo transcripts — but backend is **Ollama**, not vLLM/SGLang, and it verified *subagent routing*, not #48874 |
| [linux.do post](https://linux.do/t/topic/2446432) | not stated | GLM-5.2-FP8 on 8×H200, vLLM, no proxy, screenshot. Dated **2026-06-22**, before the reproduction window |
| [SGLang Anthropic API doc](https://docs.sglang.io/docs/basic_usage/anthropic_api) | not stated | Maintainer-authored, but one commit (2026-06-22), never updated, no version, no transcript, and silent on the system-role problem — while attributing "tool calls returned as raw text" solely to a missing `--tool-call-parser`, which will misdiagnose exactly this bug |

Alternative harnesses (OpenHands, OpenCode, Goose, Aider) were assessed and all failed
verification for this question — they are different harnesses, their vLLM instructions are
placeholder config with no evidence anyone ran them, and switching relocates the tool-parser
dependency rather than removing it. Aider is additionally stalled: last commit 2026-05-22.

### The actual fix: turn the feature off from the client side

Static analysis of the shipped Claude Code **2.1.220** binary
(`/opt/homebrew/Caskroom/claude-code@latest/2.1.220/claude`) shows the mid-conversation system
block is behind a per-model gate, verbatim:

```js
yer=Vr((e)=>{if(lK("hipaa"))return!1;
  if(Z.CLAUDE_CODE_FORCE_MID_CONVERSATION_SYSTEM)return!0;
  let t=wde(e,"mid_conversation_system");if(t!==void 0)return t;
  let r=lo(e);
  if(r.includes("claude-3-")||r==="claude-opus-4-0"||r==="claude-opus-4-1"||r==="claude-opus-4-5"
   ||r==="claude-opus-4-6"||r==="claude-opus-4-7"||r==="claude-sonnet-4-0"||r==="claude-sonnet-4-5"
   ||r==="claude-sonnet-4-6"||r==="claude-haiku-4-5")return!1;
  if(LN(r,"mid_conv_system")||r==="claude-mythos-5")return!0;
  return p9(n_(e))});
```

Three consequences:

1. **A deny-listed model id switches the feature off.** `lo()` canonicalizes by *substring*, so
   `lo("claude-sonnet-4-5[1m]")` returns `"claude-sonnet-4-5"` and hits the deny list. The 1M
   path survives independently because `Wb(e)` tests the **raw** string. So you keep the long
   context. Prefer `claude-sonnet-4-5` over `claude-opus-4-5` — the latter's registry entry has
   `supports_1m_suffix` but no `supports_1m_beta`.
2. **There is no off switch.** The only env var in the gate,
   `CLAUDE_CODE_FORCE_MID_CONVERSATION_SYSTEM`, forces the feature *on* only.
3. **This is why every self-hosted setup trips it.** The fallback is `p9(n_(e))`, and a plain
   custom `ANTHROPIC_BASE_URL` still classifies as `firstParty`, so an unrecognized model id
   returns **true** and the block is emitted.

Note this quietly explains the linux.do post: it launches with
`--served-model-name claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 GLM-5.2`, and two of those
aliases are deny-listed.

### Step 0 — a ten-minute test that settles it for your stack

Do this before installing anything. Send the same conversation to your own `/v1/messages`
twice — once with the block as a trailing `{"role":"system"}` entry, once hoisted into the
top-level `system` field — and compare `input_tokens` in the response `usage`.

**Identical ⇒ your server hoists ⇒ that model is safe.** No debug config, no generation cost,
works on vLLM or SGLang. On SGLang, `/v1/messages/count_tokens` does it for free.

Run it per model, because there is an unresolved contradiction worth settling empirically:
#48874 reports positional rendering on `Qwen3.6-35B-A3B-FP8`, yet that model's stock template
carries `{%- if message.role == "system" %}{%- if not loop.first %}{{- raise_exception(...) }}`,
which should force hoisting — so either the reporter overrode the template or the issue's
diagnosis is incomplete. Trust your own measurement over both.

### Ranked fixes if Step 0 shows a model is exposed

1. **Serve under a deny-listed model id.** `--served-model-name claude-sonnet-4-5` plus
   `ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-5[1m]`. Fires regardless of how the
   capability lookup resolves, and keeps the 1M window. Cost: Claude Code applies that Claude
   id's registry metadata — context window, capability set, cost display — to your model.
   Derived from the shipped binary; **untested end-to-end by anyone.**
2. **CodeRouter >= v2.9.4 in front.** The only tool that fixes the array shape at *zero*
   prefix-cache cost — leading `system` hoisted, mid-conversation `system` coerced to `user`
   in place. Verified in source with regression tests. Caveat: 43 stars, born 2026-04-19, but
   genuinely active (100+ commits / 4 authors in 60d, MIT, v2.11.0 on 2026-07-28).
3. **Guarded chat template**, or **pin vLLM 0.23.0 / SGLang 0.5.14** (last releases that
   unconditionally hoist). Both buy correctness at the price of the prefix cache.
4. **Do not count on:** `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` (verified no-op — the beta is
   in the set *kept* on third-party endpoints); or waiting for upstream (vLLM 0.26.0 and CC
   2.1.220 both ship without a fix, and Anthropic is still investing in the feature).

Rule out three same-symptom confounds first, since each produces an identical text-only turn
and none is #48874: a missing `--tool-call-parser`, llama.cpp without `--jinja`, and Unsloth
Studio's server-side tool loop.

**Version boundary, from the npm registry** (`registry.npmjs.org/@anthropic-ai/claude-code`):
`2.1.150` published 2026-05-23, `2.1.153` on 2026-05-27, **`2.1.154` on 2026-05-28** — the
release where the lean system prompt became default. So the safe pin below the boundary is
**2.1.153**, which matches what cc-switch #3277 converged on, and it also sits below 2.1.161 so
auto-compact still fires. Current `stable` is 2.1.212, `latest` 2.1.220.

**Practical consequence for recommendation #1:** the no-proxy path is viable, but run Step 0
first. Qwen3.6-27B and Kimi K3 look safe as-is. GLM-5.2-FP8 and gemma-4-31B need fix 1 or 2.
And if you run Step 0 and publish the result, you will be the first — #48874 has one comment
and no maintainer response since 2026-07-16, and the forum vLLM points people to is empty on
this topic.

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

**GLM-5.2 is the standout.** Scores: SWE-bench Pro 62.1, Terminal Bench 2.1 81.0, MCP-Atlas
76.8. Weakest line is Tool-Decathlon 48.2 (vs Opus 4.8's 59.9). Caveats: tool calling **and**
MTP together need vLLM `main`, not 0.23.0 stable; hardware floor is 8×H200/H20 for FP8, 8×B200
for the real 1M window; FP8 throughput silently degrades without DeepGEMM.

#### How Z.ai actually ran Claude Code — and what they leave out

Two of Z.ai's headline numbers were produced *inside Claude Code*. The full methodology
footnotes, verbatim from the [model card](https://huggingface.co/zai-org/GLM-5.2-FP8/raw/main/README.md)
(fetched 2026-07-30):

> **ProgramBench**: We evaluate ProgramBench (200 instances) with Claude-Code 2.1.156 using
> `temperature=1.0, top_p=1.0, max_tokens=64000, max_turns=2000, sample_timeout=6h,
> reasoning_effort=max`, with a 400K context window. Each instance runs in a (4 CPUs, 8 GB RAM)
> sandbox with internet access disabled.

> **Terminal-Bench 2.1 (Claude Code)**: We evaluate in Claude Code 2.1.167 with
> `temperature=1.0, top_p=0.95, max_new_tokens=131072`. We override max_new_tokens to 128k
> **via a transparent proxy, bypassing the 64k CLI cap** to restore the configurability of
> `CLAUDE_CODE_MAX_OUTPUT_TOKENS`. We remove wall-clock time limits, while preserving per-task
> CPU and memory constraints. Scores are averaged over 5 runs.

Useful, copyable parameters: `temperature=1.0` (matches the vLLM recipe), `max_turns=2000`,
6-hour per-sample timeout, 400K context rather than the full 1M, and `reasoning_effort=max`
(the chat template's default anyway).

What this does **not** establish, and should not be cited as if it did:

- **They used a proxy, not the raw path.** The vendor itself inserted "a transparent proxy" —
  to lift the CLI's 64k output cap, not to translate protocol, but it is still an intermediary.
  That proxy is **not published**: `zai-org/GLM-5` contains only `example/`, `resources/`, and
  `skills/`; the two `claude` hits in the repo are benchmark prose. There is no harness, no
  settings file, no proxy source to inspect or reproduce.
- **The serving stack is unstated.** The footnotes never say whether Claude Code pointed at
  self-hosted vLLM/SGLang or at Z.ai's own hosted `https://api.z.ai/api/anthropic`. For a team
  reproducing this on their own GPUs, that is the single most load-bearing omission.
- **Both runs predate the current breakage.** Claude Code 2.1.156 and 2.1.167 both sit below
  the 2.1.207 where #48874 was observed. They are above 2.1.154, where strict endpoints began
  rejecting mid-conversation system roles (cc-switch #3277), so these runs were plausibly
  already receiving them — and still scored well, which hints that GLM's chat template
  tolerates inline system blocks better than Qwen3.6's. That is an inference from two verified
  facts, not a measured result. **These numbers do not validate current Claude Code.**

The honest reading: Z.ai's results show the model is strong in this harness under conditions
they controlled and did not fully disclose. They are not evidence that a stock
Claude-Code-to-vLLM setup works today.

#### Survey: every vendor benchmark that uses Claude Code as a harness

Model-card footnotes are where this methodology gets published, so 22 recent open-weight model
cards were swept for Claude Code harness mentions (`https://huggingface.co/<repo>/raw/main/README.md`,
all fetched 2026-07-30). Six of the 22 were gated (HTTP 401) and could not be read.

| Card | Uses Claude Code as harness? | Version disclosed | Config disclosed |
|---|---|---|---|
| [zai-org/GLM-5.2](https://huggingface.co/zai-org/GLM-5.2) | Yes — ProgramBench, Terminal-Bench 2.1 | **2.1.156**, **2.1.167** | Full sampling params |
| [zai-org/GLM-5](https://huggingface.co/zai-org/GLM-5) | Yes — Terminal-Bench 2.0, CyberGym | **2.1.14**, **2.1.18** | Full sampling params |
| [moonshotai/Kimi-K3](https://huggingface.co/moonshotai/Kimi-K3) | Yes — SWE-Marathon, PostTrainBench, OfficeQA Pro, SpreadsheetBench 2, Kimi Code Bench 2.0 | **none** | none |
| [MiniMaxAI/MiniMax-M2](https://huggingface.co/MiniMaxAI/MiniMax-M2) | Yes — Multi-SWE-Bench, SWE-bench Multilingual, Terminal-Bench | none (pins Terminal-Bench repo commit `94bf692`) | max steps, run count |
| [zai-org/GLM-5.1](https://huggingface.co/zai-org/GLM-5.1) | Cites others' Claude Code scores only | none | none |
| [Qwen/Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B), [-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) | Only for *other* models' NL2Repo scores | none | `temp=1.0, top_p=0.95, max_turns=900` |
| google/gemma-4-31B-it, MiniMax-M3, DeepSeek-V4-Pro, gpt-oss-120b, Mistral-Large-3, Kimi-K2-Instruct | **No mention** | — | — |

**The answer to "does anyone benchmark above the breakage": no.** The complete set of Claude
Code versions disclosed anywhere in this sweep is **2.1.14, 2.1.18, 2.1.156, 2.1.167** — all
four from Z.ai, and the highest is 2.1.167. Nothing at or above **2.1.207**, where #48874 was
observed. Every published Claude-Code-as-harness result sits below the breakage window.

Read that carefully in both directions:

- **It is not proof the bug is universal.** Absence of a disclosed version is not evidence of
  an old one. Kimi K3 published weights on 2026-07-27 and ran the Claude Code harness on five
  benchmarks without naming a version; they could well have been on 2.1.2xx. Unknowable from
  the card.
- **It is a real gap in the evidence base.** No vendor has published a reproducible
  Claude-Code-as-harness result on a current Claude Code. So there is no published setup to
  copy that is known to work today, and the one card with full parameters (GLM-5.2) is pinned
  two behaviour changes back.

Two side findings worth having:

- **Kimi built its own harness rather than using Claude Code.** Kimi K3's headline coding
  numbers (DeepSWE, Terminal-Bench 2.1, ProgramBench, FrontierSWE, MLS-Bench-Lite) all come
  from an in-house "**Kimi Code**" harness, with Claude Code reserved for a secondary set. On
  their own Kimi Code Bench 2.0 the footnote discloses "it attains **73.7** with the Claude
  Code harness" against a table figure of ~72.9 for Kimi Code — roughly parity, so the switch
  does not look performance-driven. (Column attribution read positionally from the HTML table;
  treat the 72.9 as approximate.)
- **MiniMax pins by git commit, not version** — Terminal-Bench's bundled `claude-code` at
  commit `94bf692`. That is the only reproducibility-grade pin found in the sweep, and it is a
  better convention than a version string.

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
