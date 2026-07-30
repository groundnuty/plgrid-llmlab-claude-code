# Claude Code against PLGrid Forge — verified working configuration

**Status: verified end-to-end on 2026-07-30.** Claude Code **2.1.220** → CLIProxyAPI
**7.2.110** → PLGrid Forge (`https://llmlab.plgrid.pl/api/v1`) → `zai-org/GLM-5.2-FP8`,
completing a multi-turn agentic loop with parallel tool calls and a correct answer.

This is above the Claude Code version where the mid-conversation system-role regression
appears (vLLM #48874, observed at 2.1.207), and no equivalent configuration was published
anywhere as of 2026-07-30 — see `../research/claude-code-openai-compatible-proxies.md`.

---

## Why a proxy is required here

PLGrid Forge is a **hosted OpenAI-compatible gateway**. You do not control the serving stack,
so chat-template edits, vLLM version pins and server-side patches are all unavailable. Probed
directly (2026-07-30, authenticated):

| Endpoint | Result |
|---|---|
| `POST /api/v1/messages` (Anthropic Messages) | **404** |
| `POST /api/v1/chat/completions` | **200** |
| `POST /api/v1/responses` (OpenAI Responses) | **404** |

Claude Code speaks Anthropic dialect only, so translation is mandatory. And because
`/responses` is absent, **LiteLLM and Bifrost fail out of the box** — both route the Anthropic
`/v1/messages` path to the upstream's Responses API by default.

CLIProxyAPI targets `/chat/completions` directly
(`internal/runtime/executor/openai_compat_executor.go`), which is why it is the right tool.

## Why it survives the system-role regression

Claude Code ≥ ~2.1.154 sends its agent-registry context as a `{"role":"system"}` entry **inside**
`messages[]`, after the user turn, leaving the prompt ending on a system block. CLIProxyAPI
coerces it to `user` **in place** (`internal/translator/openai/claude/openai_claude_request.go`):

```go
if role == "system" {
    if reminderText, ok := translatorcommon.ClaudeMessageSystemReminderText(contentResult); ok {
        msgJSON := []byte(`{"role":"user","content":[{"type":"text","text":""}]}`)
        msgJSON, _ = sjson.SetBytes(msgJSON, "content.0.text", reminderText)
        messageItems = append(messageItems, msgJSON)
    }
    return true
}
```

In place, not hoisted — so the leading prefix is unchanged and prefix caching is preserved.
That is the both-ways-correct outcome that neither vLLM nor SGLang currently manages.

Observed on the wire, from the proxy's own request log:

```
IN  (Anthropic, from Claude Code): ['user(text)', 'system(text)']
OUT (OpenAI, to PLGrid)          : ['system(text)', 'user(text)', 'user(text)']
```

And the full loop, third request:

```
IN  : ['user(text)','system','assistant(tool_use)','user(tool_result)',
       'assistant(tool_use)','user(tool_result)']
OUT : ['system(text)','user(text)','user(text)','assistant(tool_calls)','tool',
       'assistant(tool_calls)','tool','tool','tool']
```

Three assistant turns, parallel tool calls translated correctly, correct final answer.

## The one gotcha: PLGrid rejects `reasoning_effort`

First attempt failed with `API Error: 422 Request validation failed`. The upstream detail:

```json
{"message":"Request validation failed.",
 "detail":[{"field":"body.reasoning_effort",
            "message":"Extra inputs are not permitted","type":"extra_forbidden"}]}
```

PLGrid's gateway validates strictly (`extra_forbidden`). CLIProxyAPI sends `reasoning_effort`
for reasoning-capable models; PLGrid does not accept it. Fixed with a `payload.filter` rule
that strips the field. **This is the single non-obvious step** — without it nothing works, and
the error surfaces to the user only as a bare `422`.

---

## Configuration

`config.yaml` — replace `<PLGRID_API_KEY>` with your grant key from
llmlab.plgrid.pl → Grants → Generate API Key. Keep the file at mode `600`; it holds a secret.

```yaml
# Bound to loopback and api-keys populated deliberately: the shipped defaults are
# host:"" (all interfaces) with fail-open auth, i.e. an open relay to your key.
host: "127.0.0.1"
port: 8317
auth-dir: "~/.cli-proxy-api"
debug: false
request-log: true          # writes <auth-dir>/logs/*.log — invaluable for diagnosis

api-keys:
  - "local-test-key"       # what Claude Code presents as ANTHROPIC_AUTH_TOKEN

openai-compatibility:
  - name: "plgrid"
    base-url: "https://llmlab.plgrid.pl/api/v1"
    api-key-entries:
      - api-key: "<PLGRID_API_KEY>"
    models:
      - name: "zai-org/GLM-5.2-FP8"
        alias: "glm-5.2"
        display-name: "GLM-5.2 FP8 (PLGrid)"
      - name: "Qwen/Qwen3.6-27B"
        alias: "qwen3.6-27b"
      - name: "google/gemma-4-31B"
        alias: "gemma-4-31b"

# PLGrid's gateway is strict (extra_forbidden) and rejects reasoning_effort,
# which CLIProxyAPI sends for reasoning-capable models. Strip it.
payload:
  filter:
    - models:
        - name: "*"
          protocol: "openai"
      params:
        - "reasoning_effort"
```

Run it:

```bash
./cli-proxy-api --config config.yaml
```

Launch Claude Code:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8317
export ANTHROPIC_AUTH_TOKEN=local-test-key
export ANTHROPIC_MODEL=glm-5.2
export ANTHROPIC_DEFAULT_HAIKU_MODEL=gemma-4-31b   # keeps compaction off the big model
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=32768         # PLGrid caps output at 32768
export CLAUDE_CODE_ATTRIBUTION_HEADER=0            # per-request hash defeats prefix caching
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
claude
```

### Why each Claude Code variable is there

- **`ANTHROPIC_DEFAULT_HAIKU_MODEL=gemma-4-31b`** — Claude Code runs *conversation
  summarization* (i.e. compaction) and background tasks on the haiku tier. Left unset it
  defaults to the primary model, putting every compaction on GLM-5.2. Gemma-4-31B is the right
  model for this job: cheap, and its weaknesses matter less for summarization.
- **`CLAUDE_CODE_MAX_OUTPUT_TOKENS=32768`** — PLGrid enforces `input + max_tokens <= context`
  and caps output at 32768. Claude Code otherwise sends `max_tokens: 128000` (observed).
- **`CLAUDE_CODE_ATTRIBUTION_HEADER=0`** — Claude Code prepends a per-request hash to the
  system prompt, so the KV prefix misses every turn. Unsloth measures the cost as "90% slower
  with local models".

## Differential test across every tool-capable model

Same task, same config, one run each, 2026-07-30. The task requires a `Glob`, three parallel
`Read` calls, then a synthesis turn — so it exercises multi-turn survival, parallel tool-call
translation, and instruction-following. Correct answer is `a.txt, b.txt, c.txt` and `3`.

| Model | Time | Answer | Verdict |
|---|---|---|---|
| `glm-5.2` | 11s | `a.txt, b.txt, c.txt — total word count: 3` | **correct** |
| `qwen3.6-35b-a3b` | 14s | `a.txt, b.txt, c.txt — 3` | **correct** |
| `gemma-4-31b` | 16s | `a.txt, b.txt, c.txt 3` | **correct** |
| `qwen3-coder-30b` | 28s | `a.txt b.txt c.txt Total word count: 3` | **correct** |
| `qwen3.6-27b` | 50s | `a.txt, b.txt, c.txt — total word count: 3` | **correct** |
| `glm-4.7-flash` | 12s | `a.txt b.txt c.txt — 21 words` | **silently wrong** |
| `qwen3.5-397b` | 1s | `400 … not available for grant '94'` | grant-blocked |
| `qwen3.5-122b` | 1s | `400 … not available for grant '94'` | grant-blocked |
| `deepseek-v4-flash` | 1s | `400 … not available for grant '94'` | grant-blocked |

**Six of six reachable models completed the agent loop.** Not one produced the #48874
signature (a text-only turn with no tool calls). That is the strongest available evidence that
CLIProxyAPI's in-place role coercion is sufficient, and it holds across three model families.

Three findings worth acting on:

1. **`gemma-4-31b` works — this corrects a pessimistic prediction.** An independent Jinja probe
   of its stock chat template (see `../research/probe-chat-template-48874.py`) shows it renders
   a mid-conversation system message *inline*, which is the #48874 exposure condition, and
   vLLM has two open `gemma4` tool-parser bugs (#39392, #44522). It works here anyway, because
   the proxy coerces the role to `user` before the template ever sees it. **A proxy-side fix
   makes template exposure irrelevant** — which is the practical argument for the proxy over a
   server-side patch, and it only becomes visible by testing.
2. **`glm-4.7-flash` is the one to avoid.** It completed the loop and read the right files —
   it returned all three filenames — but reported 21 words instead of 3. Plumbing fine, answer
   confidently wrong, which is the worst failure mode for unattended work. Note this contradicts
   the `fastfix` selection in `opencode.json`, which cites "perfect differential correctness"
   for this model at 123 tok/s. Different harness, different result; re-benchmark before
   trusting it under Claude Code.
3. **Grant 94 cannot reach three of the advertised models.** `GET /models` lists
   `Qwen/Qwen3.5-397B-A17B-FP8`, `Qwen/Qwen3.5-122B-A10B` and `deepseek-ai/DeepSeek-V4-Flash`,
   but all three return `400 … not available for grant '94'`. The model list is gateway-wide,
   not grant-scoped, so enumeration is not entitlement. This also means the OpenCode plugin's
   omission of DeepSeek-V4-Flash is defensible rather than an oversight.

**Speed vs correctness.** `glm-5.2` is both the fastest correct model (11s) and the most
capable, so the tier assignment in this document stands. `gemma-4-31b` at 16s is a sound haiku
tier — it was correct, and compaction does not need frontier reasoning. `qwen3.6-27b` is
correct but 4.5× slower; keep it for the reviewer role as `opencode.json` already does.

Caveat: one run per model on a trivial task. This establishes that the *transport and tool
loop* work per model; it is not a capability benchmark. `glm-4.7-flash`'s failure was an
arithmetic slip, not a protocol failure.

## Interactive session test (tmux, GLM-5.2)

`claude -p` exercises one code path. The interactive REPL adds streaming render, slash
commands, hooks, and the permission layer, so it was tested separately: a tmux session driving
real Claude Code 2.1.220 against `glm-5.2`, on a project with a genuine bug (a `median()` that
returns the upper-middle element for even-length input, so 2 of 4 tests fail).

**Startup.** Banner reads `glm-5.2 with xhigh effort · API Usage Billing`; status line shows
`glm-5.2 xhigh`. Session hooks fired (`Async hook SessionStart completed`). Streaming render
worked throughout, reporting 9–13k tok/s.

**The task.** *"Run python3 run_tests.py, find why the failing tests fail, fix stats.py, then
re-run to prove it passes."* GLM-5.2 then, unaided:

1. `Bash(ls -la)` — listed the directory
2. `Read(run_tests.py)`, `Read(stats.py)`
3. traced all four cases by hand and stated the root cause correctly: *"it returned the
   upper-middle element (s[n//2], which is s[2]=3) instead of averaging the two middle
   elements ((s[1]+s[2])/2 = 2.5)"*
4. `Update(stats.py)` with a correct fix:
   ```python
   mid = n // 2
   if n % 2 == 1:
       return s[mid]
   return (s[mid - 1] + s[mid]) / 2
   ```
5. rendered a markdown results table summarising each case

Verified independently afterwards: **4/4 tests pass.** The fix is correct.

**Graceful degradation, worth noting.** Midway the Bash tool became unavailable — *"The Bash
classifier is temporarily unavailable"*, then *"bash denied by auto mode · Classifier
unavailable"*. This is an artifact of running Claude Code nested inside another Claude Code
session, **not** a proxy or model failure. GLM-5.2 handled it well: it retried twice, then
switched to static analysis, reached the right diagnosis without being able to execute
anything, and still applied the correct patch. Sensible behaviour under tool loss.

**Slash commands.** `/context` rendered a full breakdown (so the `count_tokens` path works
end-to-end). `/model` listed both configured models — `glm-5.2 ✔ Custom model` and
`gemma-4-31b Custom Haiku model`.

### Two findings from the interactive test

**1. Claude Code assumes a 200k context window, but PLGrid allows 393,216 for GLM-5.2.**
`/context` and `/model` both report `31k/200k tokens (15%)`. Claude Code cannot know an
unrecognized model's window — `ANTHROPIC_DEFAULT_*_MODEL_SUPPORTED_CAPABILITIES` has no effect
behind an `ANTHROPIC_BASE_URL` gateway — so it falls back to 200k. **You lose roughly half your
usable context by default.** To recover it, alias the model onto a Claude id whose registry
entry carries a larger window (CLIProxyAPI supports aliasing upstream names onto Claude-shaped
names), e.g. serve `zai-org/GLM-5.2-FP8` as `claude-sonnet-4-5` and set
`ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-5[1m]`. That also happens to suppress the
mid-conversation system block, though CLIProxyAPI already handles that. Untested here.

**2. The `/model` picker still offers real Claude models, which will fail.** Alongside the two
custom entries it lists *Opus (1M context)*, *Fable*, *Sonnet*, *Sonnet 5 (1M context)*.
Selecting any of them sends e.g. `claude-opus-5` upstream, which PLGrid does not serve. A
footgun for anyone sharing this setup — the picker gives no hint that four of six options are
dead. Note this also **corrects a widely-reported claim**: the picker does *not* hide
non-Claude model ids when they are configured via the `ANTHROPIC_DEFAULT_*_MODEL` env vars.
That reported limitation applies to gateway model *discovery*, not to env-var configuration.

## Follow-ups, all verified 2026-07-30

### Recovering the context window: alias onto a Claude id

Aliasing the upstream model onto a Claude id makes Claude Code apply that id's registry
metadata, including its context window. Verified: with `claude-sonnet-4-5[1m]`, `/context`
reported 42,467 tokens at **4.0%** — a ~1M window, against 200k for the bare `glm-5.2` id.

```yaml
    models:
      - name: "zai-org/GLM-5.2-FP8"
        alias: "claude-sonnet-4-5"    # deny-listed id; entry has supports_1m_beta
      - name: "zai-org/GLM-5.2-FP8"
        alias: "claude-opus-4-7"
      - name: "google/gemma-4-31B"
        alias: "claude-haiku-4-5"
```

```bash
export ANTHROPIC_MODEL='claude-sonnet-4-5[1m]'
export ANTHROPIC_DEFAULT_SONNET_MODEL='claude-sonnet-4-5[1m]'
export ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-7'
export ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-haiku-4-5'
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=380000   # REQUIRED — see below
```

**`CLAUDE_CODE_AUTO_COMPACT_WINDOW` is not optional here.** The 1M declaration overshoots:
PLGrid caps GLM-5.2 at 393,216, so Claude Code would otherwise let a session run to ~1M and
the gateway would reject it. Setting the window to 380,000 makes compaction fire before the
real ceiling. The alias fixes an under-estimate by creating an over-estimate; the env var
reconciles them.

Side benefit: `claude-sonnet-4-5`, `claude-opus-4-7` and `claude-haiku-4-5` are all on the
mid-conversation-system deny list, so this also suppresses that block at the client. Redundant
given CLIProxyAPI's coercion, but harmless.

### Hiding the paid Anthropic models from `/model`

`availableModels` + `enforceAvailableModels` in **project** `.claude/settings.json` works on
2.1.220, despite the docs describing them as managed/policy settings:

```json
{
  "availableModels": ["claude-sonnet-4-5", "claude-opus-4-7", "claude-haiku-4-5"],
  "enforceAvailableModels": true
}
```

Picker before: 7 entries, 4 of them real paid models that fail against PLGrid.
Picker after: 5 entries — *Fable*, *Opus 5* and *Sonnet 5* are gone.

```
1. Default (recommended)      currently Opus 4.7 (1M context) · $5/$25 per Mtok
2. claude-opus-4-7            Custom Opus model
3. Sonnet 4.5                 (claude-sonnet-4-5-20250929)      <-- still dead
4. claude-haiku-4-5           Custom Haiku model
5. Sonnet 4.5 (1M context) ✔  (claude-sonnet-4-5[1m])
```

Two residues worth knowing. Entry 3 is Claude Code's **built-in dated row**, surfaced because
`availableModels` matched `claude-sonnet-4-5` as a version prefix — it sends
`claude-sonnet-4-5-20250929`, which the proxy does not alias, so it fails. Add an alias for the
dated id if you want all rows live. And `enforceAvailableModels` is needed for entry 1: without
it, Default is exempt from the allowlist.

The `$5/$25 per Mtok` label is cosmetic. The docs state prices are "a display label only; it
doesn't affect which model a row selects or what your provider bills."

### Autonomous operation without `--dangerously-skip-permissions`

**Auto mode is unavailable with these models.** The banner says so outright — `auto mode
unavailable for this model` — and the session falls back to `⏸ manual mode`. That also corrects
an earlier read: the "Bash classifier is temporarily unavailable" seen in the first test was not
an artifact of nesting, it was auto mode genuinely unsupported for a non-first-party model.

You do **not** need the bypass flag. `permissions.allow` is deterministic pre-approval with no
classifier involved, so it is model-independent. On first run Claude Code confirms:
*"Edit, Write, Bash(python3:*), Bash(ls:*), Bash(cat:*), Read, Glob, and Grep — These will apply
without asking."*

```json
{
  "permissions": {
    "allow": ["Read", "Glob", "Grep", "Edit", "Write",
              "Bash(python3:*)", "Bash(echo:*)", "Bash(ls:*)", "Bash(cat:*)"],
    "deny": ["Bash(rm:*)", "Bash(git push:*)", "Bash(curl:*)"]
  }
}
```

**The gotcha that will cost you the most Enters: rules match per command segment, so a compound
command needs *every* segment allowed.** GLM-5.2 habitually appends `; echo "exit: $?"`, and
`Bash(python3:*)` alone does not cover it — the prompt fires on the `echo`. Hence
`Bash(echo:*)` in the list above. Choosing "don't ask again" writes an exact-string rule to
`.claude/settings.local.json`:

```json
{"permissions": {"allow": ["Bash(echo \"exit: $?\")"]}}
```

That is literal, not a pattern, so it only covers that one string. Prefer pre-declaring
`Bash(echo:*)`. The general lesson: watch which command shapes your model emits and allow
those, rather than reaching for a blanket bypass.

Verified end-to-end in this mode: GLM-5.2 read the file, patched `median()` correctly, re-ran
the suite, and reported *"Fixed. For even-length input the median now averages the two middle
elements (stats.py:1), and python3 run_tests.py exits 0 with PASS."* at 21.6k tok/s.

### `count_tokens`: retracted, not a defect

An earlier revision of this document reported that `POST /v1/messages/count_tokens` always
returns 503 on the `openai-compatibility` path. **That was wrong.** On retest it returns 200:
10/10 sequential and 30/30 concurrent. `CountTokens` *is* implemented for that executor
(`internal/runtime/executor/openai_compat_executor.go`), tokenising locally via
`helps.TokenizerForModel`.

74 of 158 historical `count_tokens` requests did return 503 during one window on 2026-07-30.
Three hypotheses were tested and all disproved: not unimplemented (the code exists and works),
not load (30 concurrent all succeeded), and not an unconfigured model alias (that returns **502**
`unknown provider for model …`, not 503). The cause is unexplained and was not reproducible.
The nearest candidate in the source is the `home.Current()`/`HeartbeatOK()` gate in
`internal/api/server_middleware.go`, which aborts with 503 in ~1ms — matching the observed
timings — but that was not confirmed.

Recorded as an unexplained observation rather than a defect. **No patch is proposed for it**, and
it should not be cited as a reason to prefer another proxy.

**On whether to switch tools** — the alternatives are still worse on balance, for other reasons:

| Tool | `count_tokens` on an OpenAI-compatible upstream | Verdict |
|---|---|---|
| CLIProxyAPI | 503 (observed) | gap, but small and well-scoped |
| musistudio/claude-code-router | answered locally as an estimate | works, but translation engine is a closed npm bundle with `repository: None`, config is SQLite-via-UI only, and it rewrites `~/.claude/settings.json` |
| LiteLLM | routes to `api.anthropic.com` instead of `api_base` (#30043) | broken for self-hosted, plus the Responses trap |
| CodeRouter | not established | role handling is right, but 43 stars |

Switching to gain an *estimate* is a bad trade. CLIProxyAPI is the healthiest project in this
space by a wide margin — 628 commits and 45 distinct authors in 60 days, 608 issues closed
against 395 opened — so a patch there is likely to land and persist. The gap is narrow: the
endpoint and translator hook already exist; they need connecting for `openai-compatibility`
providers, with a local estimate as fallback. That is the contribution worth making.

## Recommended shape: honest model ids, config in `settings.json`

The alias-onto-Claude-ids approach solves the context window but creates two new problems: the
picker says "Sonnet 4.5" when you are talking to GLM-5.2, and it shows Anthropic price labels
that do not apply. Testing both, **honest ids are the better trade** — with one consequence to
manage, covered below.

### Real model names in the picker

`ANTHROPIC_DEFAULT_*_MODEL_NAME` and `_DESCRIPTION` work behind a gateway, per the docs: "The
`_NAME` and `_DESCRIPTION` variables also take effect when `ANTHROPIC_BASE_URL` points to an
LLM gateway."

**But `_NAME` is ignored when the model id matches a built-in Claude row.** Verified: with
`ANTHROPIC_DEFAULT_SONNET_MODEL='claude-sonnet-4-5[1m]'`, the picker showed *"Sonnet 4.5 (1M
context)"* and ignored `_NAME` entirely, while the haiku slot — pointing at a non-suffixed id —
picked up its override and displayed *"gemma-4-31B"*. So **you can have the real name or the 1M
window, not both.**

With honest ids the picker becomes self-documenting, and no override is needed for the name at
all because the id *is* the name:

```
1. Default (recommended)  Use the default model (currently glm-5.2-fp8[1m])
4. glm-5.2-fp8            PLGrid Forge · GLM-5.2 FP8 · 393k ctx
5. gemma-4-31b            PLGrid Forge · Gemma 4 31B · 262k ctx · compaction
```

Status line reads `glm-5.2-fp8 xhigh`. Price labels disappear, which is correct — they never
applied. Use `_DESCRIPTION` to carry the window and the slot's purpose, since that is the part
the id cannot express.

### Stop setting env vars by hand: use the `env` block

Everything above belongs in a committed `.claude/settings.json`, not in shell exports. Verified
working — the entire session below ran with no exported variables at all:

```json
{
  "permissions": {
    "allow": ["Read","Glob","Grep","Edit","Write",
              "Bash(python3:*)","Bash(echo:*)","Bash(ls:*)","Bash(cat:*)"],
    "deny": ["Bash(rm:*)","Bash(git push:*)","Bash(curl:*)"]
  },
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
    "ANTHROPIC_AUTH_TOKEN": "local-test-key",
    "ANTHROPIC_MODEL": "glm-5.2-fp8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.2-fp8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION": "PLGrid Forge · GLM-5.2 FP8 · 393k ctx",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.2-fp8",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION": "PLGrid Forge · GLM-5.2 FP8 · 393k ctx",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gemma-4-31b",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION": "PLGrid Forge · Gemma 4 31B · 262k ctx · compaction",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32768",
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "190000",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_AUTOUPDATER": "1"
  },
  "autoCompactEnabled": true,
  "availableModels": ["glm-5.2-fp8", "gemma-4-31b", "qwen3.6-27b"],
  "enforceAvailableModels": true
}
```

Set it once per project, commit it, done. Everything here is **project-scoped on purpose** —
nothing in this setup should go into `~/.claude/settings.json`, because these choices are
specific to the PLGrid gateway and would follow you into unrelated projects. Note this file must not contain the PLGrid key — that
stays in the proxy's config. `ANTHROPIC_AUTH_TOKEN` here is only the local proxy token.

## The context-window problem, properly

`CLAUDE_CODE_AUTO_COMPACT_WINDOW` is a single global value, but the models differ: GLM-5.2
393,216 · Qwen3.6-27B 262,144 · gemma-4-31B 262,144 · GLM-4.7-Flash 202,752. One number cannot
be right for all of them, and switching models mid-project should not require editing config.

### What actually happens at the limit

PLGrid returns a precise, machine-readable error that even states the true window:

```json
{"detail":"max_tokens=500000 cannot be greater than max_model_len=max_total_tokens=393216.
           Please request fewer output tokens. (parameter=max_tokens, value=500000)",
 "status_code":400}
```

**Claude Code will not recognise it.** Extracted from the 2.1.220 binary, the pattern it matches
to trigger reactive compaction is:

```
prompt is too long[^0-9]*(\d+)\s*tokens?\s*>\s*(\d+)
```

It needs the literal phrase *"prompt is too long"* followed by `<used> tokens > <limit>`.
PLGrid's wording matches neither. So on overflow you get a hard error, not a compaction — which
is exactly why the env var is currently load-bearing.

This also explains why the env var cannot be dropped yet, and it is the one thing standing
between this setup and a genuinely good experience.

### Interim: one conservative value

Until the above is fixed, set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` to the **smallest** window among
the models you have enabled — 190,000 above, safe even for GLM-4.7-Flash. You lose headroom on
GLM-5.2, but you never hit a hard failure. Pair it with `availableModels` so the set of reachable
models is known and the floor is predictable.

### Does the window follow the model when you switch? No.

Asked directly, and the answer is no on all three possible mechanisms — each verified:

1. **`CLAUDE_CODE_AUTO_COMPACT_WINDOW` is read at process start.** Switching with `/model`
   mid-session does not re-read it. Env vars behind a gateway are start-time only.
2. **Gateway model discovery cannot carry a window.** From the protocol reference: "Claude Code
   reads `id` and the optional `display_name` from each entry in the response's `data` array,
   and ignores entries whose `id` doesn't begin with `claude` or `anthropic`." Two fields, no
   context length. So the proxy cannot advertise per-model windows even though it knows them.
   (Discovery also never runs while `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set.)
3. **`_SUPPORTED_CAPABILITIES` has no effect behind an `ANTHROPIC_BASE_URL` gateway**, and its
   value list covers effort and thinking only — no window.

So with a single global number, switching from GLM-5.2 (393k) to GLM-4.7-Flash (202k) leaves
compaction tuned for the wrong model. Hence the conservative floor above.

### First, check that auto-compact is even on

A prerequisite that is easy to miss: on this setup `/config` reported **`Auto-compact false`**.
It is **off by default** behind a third-party endpoint, which matches the reported regression
where auto-compact stopped firing for `ANTHROPIC_BASE_URL` users
([anthropics/claude-code#65585](https://github.com/anthropics/claude-code/issues/65585)). Until
it is enabled, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` does nothing at all.

It is togglable at runtime — `/config` → *Auto-compact* → Space — but **do not configure it that
way.** `/config` writes to **user** settings (`~/.claude/settings.json`), so it silently changes
behaviour for every project on the machine. Declare it in the project file instead:

```json
{ "autoCompactEnabled": true }
```

Add that to the project `.claude/settings.json` shown above, alongside `permissions` and `env`.
Project scope keeps the setting reviewable, committed, and confined to this repo.

Verify with `/config` after launching — read it, don't toggle it — and treat "Auto-compact false"
as the first thing to check if a long session dies at the context limit.

### The fix worth contributing

Normalise the upstream error in the proxy into the shape Claude Code matches. Then compaction
fires at the right point **for every model automatically**, with no env var and no per-model
tuning — the window comes from the upstream error itself.

CLIProxyAPI has an open, unmerged PR for exactly this area — **#4321 "fix(translator): normalize
context-limit errors"** (83 additions, `sdk/api/handlers/claude/code_handlers.go`). It is not
sufficient for PLGrid, for two concrete reasons:

1. It gates on `upstreamCode` being `context_length_exceeded` or `context_too_large`, read from
   `error.code`. PLGrid returns `{"detail": …, "status_code": 400}` with no `code` field, so the
   branch never fires.
2. It only prepends `"Prompt is too long: " + message`. Claude Code's regex additionally requires
   `(\d+) tokens > (\d+)`, which PLGrid's wording does not contain — so even when the branch does
   fire, the capture groups fail and no compaction is triggered.

The contribution is to extend that normaliser to recognise vLLM/PLGrid-style phrasing, extract
the two numbers, and emit the canonical `prompt is too long: <used> tokens > <limit>`. This is the
**only** patch worth making — the `count_tokens` issue was retracted above.

The real upstream message, captured by overflowing Bielik's 32,768-token window:

```json
{"detail":"This model's maximum context length is 32768 tokens. However, your request has
           66511 input tokens. Please reduce the length of the input messages.
           (parameter=input_tokens, value=66511)","status_code":400}
```

Note this differs from the `max_tokens` overflow message quoted earlier — a normaliser must
handle both shapes. Both carry the two numbers the regex needs.

**This is also the only mechanism that gives per-model flexibility.** Because the limit arrives
in the upstream error on the request that exceeded it, the number is always the active model's
real window — no declaration, no env var, and correct immediately after a `/model` switch. Every
alternative (env var, discovery, capability declaration) is static and start-time. That makes
error normalisation not just a nicer fix but the *only* one that answers "does the window follow
the model", and it is the strongest argument for spending effort there rather than on config
ergonomics.

Worth knowing while relying on the error path: Claude Code "retries automatically after some
upstream rejections", and "the retry logic matches on the upstream's error wording, so forward
error response bodies unmodified. A gateway that wraps upstream errors in its own envelope breaks
the recovery path even when it preserves the status code." CLIProxyAPI currently *does* wrap —
observed as an Anthropic envelope whose `message` is the upstream JSON as a string. So the
normaliser has to unwrap and restate, not merely prefix.

## Model notes for this gateway

Measured limits from the OpenCode plugin (`.opencode/plugins/plgrid.js`), which took them from
the gateway's own error messages and `function_calling_supported` field:

| Model | Context | Output cap | Tool calling | Reasoning |
|---|---|---|---|---|
| `zai-org/GLM-5.2-FP8` | 393,216 | 32,768 | yes | `reasoning_content` |
| `Qwen/Qwen3.6-27B` | 262,144 | 32,768 | yes | `reasoning_content` |
| `google/gemma-4-31B` | 262,144 | 32,768 | yes | none |
| `zai-org/GLM-4.7-Flash` | 202,752 | 32,768 | yes | `reasoning_content` |
| `Qwen/Qwen3.6-35B-A3B` | 262,144 | 32,768 | yes | `reasoning_content` |

Note GLM-5.2's context here is **393,216, not the 1M the model card advertises** — PLGrid caps
it. Do not set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000` as Z.ai's own guide suggests.

Unusable for Claude Code (no function calling): `Qwen/QwQ-32B`, `Qwen/Qwen3-VL-8B-Instruct`,
`speakleash/Bielik-11B-v2.6-Instruct`, `CYFRAGOVPL/Llama-PLLuM-70B-chat-250801`,
`CYFRAGOVPL/pllum-12b-nc-chat-250715`, `meta-llama/Llama-3.3-70B-Instruct`.

`GET /models` also returns **`deepseek-ai/DeepSeek-V4-Flash`**, which the OpenCode plugin's
model map does not list — worth adding there.

## Caveats worth stating

- **CLIProxyAPI is dual-purpose.** The BYOK `openai-compatibility` path used here is clean
  plain-API-key code, but the same binary contains uTLS Cloudflare-fingerprint evasion
  (`internal/auth/claude/utls_transport.go`) and a `disable-claude-cloak-mode` flag for
  impersonating the Claude Code CLI. None of it is exercised by this config. Decide whether
  shipping that binary is acceptable in your environment.
- **Defaults are unsafe.** `host: ""` binds all interfaces and auth is fail-open when
  `api-keys` is empty — an unauthenticated relay to your grant key. Both are overridden above.
- **Release churn is extreme** — 100+ releases in 60 days, module path at `/v7`. Pin the
  version and read release notes before upgrading.
- **Anthropic does not support this.** "Anthropic doesn't endorse, maintain, or audit
  third-party gateway products, and doesn't support routing Claude Code to non-Claude models
  through any gateway." Expect no vendor help when a Claude Code release breaks translation.
- **Not yet exercised here:** subagents, `/compact` on a long session, images, and MCP tools.
  Subagent model routing is broken upstream in Claude Code regardless
  (anthropics/claude-code#43869), and subagent prompt caching is hardcoded off (#29966).

## Reproducing the verification

```bash
cd <workspace-with-a-few-txt-files>
claude -p "Use the Read tool to read every .txt file in this directory, then reply with one
line: the filenames in alphabetical order followed by the total word count." \
  --strict-mcp-config --allowedTools Read Glob
```

Expected: a correct single-line answer. Then inspect `<auth-dir>/logs/v1-messages-*.log` and
confirm the outgoing message array ends on a `user` turn rather than a `system` one, and that
`assistant(tool_calls)` / `tool` pairs appear across multiple requests. A text-only reply with
`stop_reason: end_turn` and no tool calls is the #48874 signature.
