# Default model for agentic coding in Claude Code — PLGrid catalogue

All sources accessed 2026-07-30.

**Headline: your GLM-5.2 problem is very likely not GLM-5.2.** There is now documented evidence that the streaming tool-call path between Claude Code and an OpenAI-compatible backend silently truncates and drops tool calls for both GLM and Qwen models. Diagnose the pipe before you change the model.

## Recommendation

**Default — if and only if the probe below passes: `zai-org/GLM-5.2-FP8`. If it fails: `Qwen/Qwen3.6-27B` for unattended runs, `Qwen/Qwen3.6-35B-A3B` for interactive work.**
GLM-5.2 is the only candidate with strong published *tool-use* numbers (MCP-Atlas 76.8, Tool-Decathlon 48.2, against 62.8 / 26.9 for Qwen3.6-35B-A3B) and it won your task on speed and correctness. Both Qwen fallbacks share the `qwen3` / `qwen3_coder` parser pair, so switching is a one-line change. Do not deploy GLM-5.2 unattended before running the four-step probe in the section below — the failure you saw is reproducible for reasons that have nothing to do with the model's capability.

**Reviewer / subagent: `Qwen/Qwen3.6-27B` (dense).**
Best coding numbers of any available candidate — SWE-bench Verified 77.2 vs 73.4 for the A3B MoE, SWE-bench Pro 53.5 vs 49.5, Terminal-Bench 2.0 59.3 vs 51.5, SkillsBench Avg5 48.2 vs 28.7 — plus an independent Artificial Analysis Intelligence Index of 37 against the MoE's 32. Its 50s probe latency (54.5 tok/s measured independently, against 149.1 for the MoE) rules it out of the interactive loop but is harmless for a review pass, where thoroughness is the product.

**Avoid: `zai-org/GLM-4.7-Flash`.**
It returned a *wrong answer* on your shared task, which outranks any benchmark. It has the weakest published coding score here (SWE-bench Verified 59.2), publishes no Terminal-Bench, MCP-Atlas or Tool-Decathlon number at all, and its agentic results are explicitly conditioned on "Preserved Thinking mode" — the exact feature the gateway layer is documented to drop.

**Also not recommended: `google/gemma-4-31B`.** It publishes no instruction-following, tool-use, or agentic benchmark whatsoever and names no tool-call parser. Qwen's own comparison table scores it last of the models compared: SWE-bench Verified 52.0, SWE-bench Pro 35.7, Terminal-Bench 2.0 42.9. It passed your probe, but there is no published basis for trusting it in a multi-step tool loop.

## Benchmark evidence

Vendor self-reported unless marked. **Terminal-Bench 2.0 and 2.1 are different benchmarks — do not compare across those rows.**

| Benchmark | GLM-5.2 | GLM-4.7-Flash | Qwen3.6-27B | Qwen3.6-35B-A3B | Qwen3-Coder-30B | gemma-4-31B |
|---|---|---|---|---|---|---|
| SWE-bench Verified | no published number | 59.2 | **77.2** | 73.4 | no published number | 52.0 † |
| SWE-bench Pro | 62.1 | no published number | 53.5 | 49.5 | no published number | 35.7 † |
| SWE-bench Multilingual | no published number | no published number | 71.3 | 67.2 | no published number | 51.7 † |
| Terminal-Bench 2.1 | 81.0 (Terminus-2) / 82.7 (best harness) | no published number | no published number | no published number | no published number | no published number |
| Terminal-Bench 2.0 | no published number | no published number | 59.3 | 51.5 | no published number | 42.9 † |
| Terminal-Bench 2.1 (independent leaderboard) | **absent** | absent | absent | absent | absent | absent |
| MCP-Atlas | **76.8** | no published number | no published number | 62.8 | no published number | no published number |
| Tool-Decathlon | **48.2** | no published number | no published number | 26.9 | no published number | no published number |
| MCPMark | no published number | no published number | no published number | 37.0 | no published number | no published number |
| tau-bench family | no published number | τ²-Bench **79.5** | no published number | TAU3-Bench 67.2 | no published number | no published number |
| BFCL (any version) | no published number | no published number | no published number | no published number | no published number | no published number |
| IFEval / IFBench / Multi-IF | no published number | no published number | no published number | no published number | no published number | no published number |
| NL2Repo | 48.9 | no published number | 36.2 | 29.4 | no published number | 15.5 † |
| SkillsBench Avg5 | no published number | no published number | **48.2** | 28.7 | no published number | 23.6 † |
| Claw-Eval Pass^3 | no published number | no published number | **60.6** | 50.0 | no published number | 25.0 † |
| LiveCodeBench v6 | no published number | 64.0 | 83.9 | 80.4 | no published number | 80.0 |
| GPQA-Diamond | 91.2 | 75.2 | 87.8 | 86.0 | no published number | 84.3 |
| AA Intelligence Index (independent) | no published number | no published number | **37** | 32 | no published number | no published number |

† Published by Qwen in the Qwen3.6-27B comparison table — a competitor's measurement of Gemma, not Google's own.

Sources: [GLM-5.2 card](https://huggingface.co/zai-org/GLM-5.2), [GLM-4.7-Flash card](https://huggingface.co/zai-org/GLM-4.7-Flash), [Qwen3.6-27B card](https://huggingface.co/Qwen/Qwen3.6-27B), [Qwen3.6-35B-A3B card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B), [Qwen3-Coder-30B card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct), [gemma-4-31B card](https://huggingface.co/google/gemma-4-31B), [Terminal-Bench 2.1 leaderboard](https://www.tbench.ai/leaderboard/terminal-bench/2.1), [Artificial Analysis](https://artificialanalysis.ai/models/comparisons/qwen3-6-27b-vs-qwen3-6-35b-a3b).

### Three gaps worth naming

**No candidate publishes IFEval, IFBench, or Multi-IF.** The benchmark family that would most directly measure your problem is absent from all six model cards. This is the largest evidence gap in the task.

**BFCL v4 is not extractable.** The [Berkeley leaderboard](https://gorilla.cs.berkeley.edu/leaderboard.html) confirms v4 with "holistic agentic evaluation", but the table is client-rendered. I tried four routes — the HTML page, the [HF Space](https://huggingface.co/spaces/gorilla-llm/berkeley-function-calling-leaderboard), and the repo contents at [`berkeley-function-call-leaderboard`](https://api.github.com/repos/ShishirPatil/gorilla/contents/berkeley-function-call-leaderboard) and [`bfcl_eval`](https://api.github.com/repos/ShishirPatil/gorilla/contents/berkeley-function-call-leaderboard/bfcl_eval) — and the repo holds test cases and eval code, not committed scores. No multi-turn or irrelevance number for any candidate. Treat this row as genuinely unavailable, not merely unfound.

**Independent Terminal-Bench contradicts the vendor number, in your harness specifically.** Z.ai's card puts GLM-5.1 at 63.5 (Terminus-2) and 69 (best harness) on Terminal-Bench 2.1. The [official leaderboard](https://www.tbench.ai/leaderboard/terminal-bench/2.1) lists GLM-5.1 + **Claude Code** at 58.7% ± 1.2 (rank 17), below both; top of board is Claude Code + Fable 5 at 83.8%. GLM-5.2 is absent entirely. *Inference:* GLM's self-reported agentic numbers come from Z.ai's own harness and degrade in Claude Code, so discount 81.0 when planning.

## On GLM-5.2's instruction shortcutting

Your two observations are different bugs. Failure 2 (2 of 5 reads, then "FINISHED") now has strong documented mechanical support. Failure 1 (tool substitution) does not.

### What is documented — EVIDENCE

**The streaming tool-call path silently truncates GLM tool calls.** [vLLM #39757](https://github.com/vllm-project/vllm/issues/39757) reports GLM-5 in streaming mode emitting a truncated function name — *"The Function Name is get_weather, But GLM5 output is get"*. It surfaces **silently**, as wrong metadata rather than an error, and `stream=False` returns the correct name. Claude Code streams by default.

**That bug has already been reported hitting GLM inside Claude Code.** [vLLM #42400](https://github.com/vllm-project/vllm/issues/42400) — *"GLM-5.1 tool call parsing fails intermittently when used as backend for Claude Code"* — runs GLM-5.1-FP8 on vLLM 0.20.1 with `--tool-call-parser glm47 --reasoning-parser glm45` and **MTP at 3 speculative tokens**, i.e. nearly your configuration. Claude Code reports *"The model's tool call could not be parsed (retry also failed)."* It is attributed to two streaming parser bugs amplified at long context: #39757 (truncated tool names) and #36857 (arguments arriving only in the final chunk instead of incrementally). Short contexts parse fine; failures cluster near the context limit and in planning mode.

**The router layer does not preserve reasoning across tool-call turns.** [claude-code-router #1400](https://github.com/musistudio/claude-code-router/issues/1400) reports that when forwarding assistant messages containing tool calls to OpenAI-compatible providers, the internal `thinking` field is not reliably mapped to `reasoning_content` — *"thinking is enabled but reasoning_content is missing in assistant tool call message"*. Crucially the reporter generalises it: *"Kimi is just strict enough to reject requests when reasoning history is incomplete. Other OpenAI-compatible reasoning providers may benefit from the same preservation logic."* Open, no maintainer reply.

**Why that matters for GLM specifically.** Z.ai's [thinking-mode documentation](https://docs.z.ai/guides/capabilities/thinking-mode) states that with interleaved thinking and tools, *"thinking blocks should be explicitly preserved and returned together with the tool results"*, and for preserved thinking that you *"must return the complete, unmodified reasoning_content back to the API"* with *"All consecutive reasoning_content blocks must exactly match the original sequence"*. Thinking is **on by default** in GLM-5.2. So GLM depends on exactly the field the router is documented not to forward — and unlike Kimi, GLM does not error, it proceeds without its own plan. Also relevant: [claude-code-router #1133](https://github.com/musistudio/claude-code-router/issues/1133) is an open GLM-specific bug, *"reasoning_content not converted to thinking block in non-streaming mode - sglang glm-4.7"*.

**The same layer silently drops tool calls for Qwen.** [claude-code-router #1397](https://github.com/musistudio/claude-code-router/issues/1397) documents two compounding bugs in `reasoning.transformer.ts`: a `data.choices[0].index++` after reasoning completes makes later tool-call argument deltas look like they belong to a nonexistent choice, so *"the downstream accumulator to drop them"*; and a duplication bug makes argument deltas be *"seen twice and produces malformed JSON."* Named models include Qwen3.6-35B-A3B and Qwen 3 Coder. The reproducer took valid tool calls **from 10/10 to 0/10**. This is your fallback models' risk too, and it is a gateway bug, not a model bug.

**Instruction adherence is documented as weak, but only for prose style.** [GLM-5.2 discussion #44](https://huggingface.co/zai-org/GLM-5.2/discussions/44), open with no Z.ai reply, reports poor adherence to stylistic instruction and that *"It is difficult to prompt this out of the model with a system prompt."* This is the closest documented analogue to your failure 1, but it concerns writing style, not tool selection.

**The one documented GLM-5.2 tool-call pathology runs the opposite direction.** [vLLM #50399](https://github.com/vllm-project/vllm/issues/50399): GLM-5.2-FP8 on vLLM 0.26.0 with the glm47 parser emits ~127 identical tool calls until the token limit under `tool_choice: "required"` — too many, not too few. Under `auto` it emits one and stops cleanly. Related: [#49981](https://github.com/vllm-project/vllm/issues/49981) (xgrammar FSM crash/hang when tool constraints meet thinking-mode special tokens), [#48568](https://github.com/vllm-project/vllm/issues/48568) (GLM-5.2 MTP deadlock), [#50180](https://github.com/vllm-project/vllm/pull/50180) (open bugfix PR).

**MTP plus tool calling is vendor-flagged as fragile.** The [vLLM recipe](https://recipes.vllm.ai/zai-org/GLM-5.2) states verbatim: *"If you need tool calling and MTP at the same time, use the latest `main` branch."* Its own recommended command enables both — `--speculative-config.method mtp --speculative-config.num_speculative_tokens 5` alongside `--tool-call-parser glm47 --enable-auto-tool-choice`. Independent corroboration that MTP breaks tool calls beyond GLM: [vLLM #46249](https://github.com/vllm-project/vllm/issues/46249), *"Regression: Qwen3.6-27B tool calls fail on Responses API when MTP enabled"*, a post-0.23.0 regression that reverting fixes.

### What is not documented

- **No report of a GLM model substituting a cheaper tool** (your failure 1 — `Bash(tail -5)` for `Read`). Not documented.
- **No report of a GLM model explicitly declaring "FINISHED" while work remained.** The nearest hit, [claude-code-router #598](https://github.com/musistudio/claude-code-router/issues/598) — *"glm会出现任务流程不继续执行的问题"* ("GLM has the problem of the task flow not continuing to execute") — turns out on reading to be a ModelScope provider fault: empty API responses (`'choices': null`) arriving ~60s after each request against GLM-4.5. Superficially your symptom, mechanically unrelated. I am flagging it rather than counting it.
- **Search coverage, stated honestly.** The above comes from the vLLM and claude-code-router issue trackers, the official GLM-5.2 HF discussions (all 51 titles enumerated via the HF API), and one web search. I did **not** obtain coverage of Reddit r/LocalLLaMA, Hacker News, Zhihu, juejin, CSDN, or linux.do — a delegated sweep of those returned nothing before I finalised. Absence of evidence from those forums is not established here.

### Verdict

Premature completion is **not documented as a GLM-5.2 capability weakness**. What *is* documented, repeatedly and in your exact harness, is that the streaming tool-call and reasoning-transform layer between Claude Code and an OpenAI-compatible backend truncates tool names, drops argument deltas, and fails to carry `reasoning_content` across tool-call turns. GLM-5.2 is additionally documented to *require* that reasoning be returned intact. That is a sufficient explanation for failure 2 without invoking any model deficiency, and it predicts the same class of failure for your Qwen fallbacks.

Your failure 1 remains plausibly a genuine adherence weakness, consistent in spirit with discussion #44. Mitigate it with prompt explicitness rather than model choice.

**Is it fixable by sampling/serving config? Substantially yes** — but the fix is in the serving and gateway layer, not in temperature. I found no source attributing GLM instruction-shortcutting to sampling; lowering temperature is cheap and harmless but do not expect it to be the fix.

### The probe to run, in this order

1. **Re-run the 5-Read probe non-streaming.** #39757 shows the truncation vanishes at `stream=False`. This is the highest-information single test and it isolates the parser from the model.
2. **Check whether your gateway round-trips `reasoning_content` on assistant tool-call messages.** Per #1400 this is the known weak point; per Z.ai's docs GLM-5.2 needs it intact.
3. **Re-run with MTP disabled** (drop `--speculative-config`), keeping `tool_choice` at `auto`. If it now completes all five, MTP is implicated and you need vLLM `main` or no MTP.
4. **Re-run at temperature 0.6 / top_p 0.95.** Last and least likely.

Only if 1–3 pass should GLM-5.2 be the unattended default. Run step 1 against your Qwen fallbacks too — #1397 says they are exposed to the same gateway bug.

## Serving recommendations

Every value is from the linked source. Where a card publishes no agentic-specific setting, I say so rather than inventing one.

**`zai-org/GLM-5.2-FP8`** — [recipe](https://recipes.vllm.ai/zai-org/GLM-5.2), [card](https://huggingface.co/zai-org/GLM-5.2), [repo](https://github.com/zai-org/GLM-5)
- `--tool-call-parser glm47 --reasoning-parser glm45 --enable-auto-tool-choice`. Both parsers required; omitting `glm45` leaves thinking text unseparated.
- Thinking is **on by default**. `reasoning_effort` takes `max` or `high`, default `max`; the chat template "resolves effort to `max` unless `reasoning_effort` is explicitly `high`".
- Sampling: temperature 1.0 / top_p 0.95 (reasoning); temperature 1.0 / top_p 1.0, max_new_tokens 48k (Terminal-Bench 2.1); temperature 1.0 / top_p 1.0, max_new_tokens 32k (SWE-bench Pro). **No agentic-harness setting published.**
- Needs vLLM ≥ 0.23.0 or SGLang ≥ 0.5.13.post1; FP8 needs DeepGEMM (`install_deepgemm.sh`).
- **Never use `tool_choice: "required"`** — runaway duplicate calls (#50399) and FSM hangs (#49981). Use `auto`.
- **Either drop MTP or run vLLM `main`**, per the recipe's own warning.
- Preserve `reasoning_content` across turns (`clear_thinking: false` on Z.ai's API; the equivalent must be arranged in your gateway).
- Prefer a recent vLLM: the Claude Code parsing failures in #42400 were on 0.20.1.

**`zai-org/GLM-4.7-Flash`** — [card](https://huggingface.co/zai-org/GLM-4.7-Flash)
- `--tool-call-parser glm47 --reasoning-parser glm45` (same for vLLM and SGLang).
- Default temperature 1.0 / top_p 0.95 / max tokens 131,072. SWE-bench: temperature 0.7 / top_p 1.0 / max 16,384. τ²-Bench: temperature 0 / max 16,384.
- For agentic tasks the card directs you to enable **Preserved Thinking mode**. It also notes τ²-Bench needed "additional prompt" adjustment for retail/telecom to avoid user-interaction failure modes — a documented prompt-sensitivity caveat.

**`Qwen/Qwen3.6-27B`** — [card](https://huggingface.co/Qwen/Qwen3.6-27B)
- vLLM: `--reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder`. SGLang: `--reasoning-parser qwen3 --tool-call-parser qwen3_coder`.
- Thinking, precise coding: **temperature 0.6, top_p 0.95, top_k 20, min_p 0.0, presence_penalty 0.0, repetition_penalty 1.0** ← use for agentic coding.
- Thinking, general: temperature 1.0, top_p 0.95, top_k 20, presence_penalty 0.0.
- Non-thinking/instruct: temperature 0.7, top_p 0.80, top_k 20, presence_penalty 1.5.

**`Qwen/Qwen3.6-35B-A3B`** — [card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)
- vLLM/SGLang: `--reasoning-parser qwen3 --tool-call-parser qwen3_coder`.
- Thinking, coding: **temperature 0.6, top_p 0.95, top_k 20, min_p 0.0, presence_penalty 0.0**.
- Thinking, general: temperature 1.0, top_p 0.95, top_k 20, **presence_penalty 1.5**. The general preset carries presence_penalty 1.5 where the 27B's is 0.0. *Inference:* in an agentic loop, where tool-call scaffolding legitimately repeats, a 1.5 presence penalty pushes the model away from re-emitting similar call structures — use the coding preset (0.0).
- 262,144 native, 1,010,000 with YaRN. Supports `preserve_thinking` to retain reasoning across turns; enable it for agent work.

**`Qwen/Qwen3-Coder-30B-A3B-Instruct`** — [card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct)
- temperature 0.7, top_p 0.8, top_k 20, repetition_penalty 1.05. No presence_penalty specified.
- Instruct-only, so no reasoning parser applies. The card names a "specially designed function call format" and lists Qwen Code and CLINE as supported; it names **no tool-call parser flag** and publishes **no benchmark numbers at all**. 256K native, 1M with YaRN; drop to 32,768 on OOM.
- **Is it the better default despite being older? No.** It publishes nothing to justify the choice, while both Qwen3.6 models publish agentic numbers and are recommended for agentic coding. *Inference:* since Qwen3.6 still uses the `qwen3_coder` tool-call parser, Qwen kept the coder function-call format and moved the capability forward — the card itself does not say this.

**`google/gemma-4-31B`** — [card](https://huggingface.co/google/gemma-4-31B)
- "Use the following standardized sampling configuration across all use cases: temperature=1.0, top_p=0.95, top_k=64". 256K context.
- Claims "native support for structured tool use, enabling agentic workflows" but gives no function-calling syntax, no tool-call parser flag, and no tool-use benchmark. Not a defensible agentic default.

### Claude Code specifically

Z.ai's [Claude Code guide](https://docs.z.ai/devpack/tool/claude) covers wiring only: `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`, `ANTHROPIC_AUTH_TOKEN`, `API_TIMEOUT_MS=3000000`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, and the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` mappings. It specifies **no** temperature, top_p, reasoning effort, or thinking configuration, and documents no limitations. So the premise that Z.ai published Claude Code *benchmark settings* for GLM-5.2 does not hold — they published env-var wiring. The long timeout and large compact window are still worth copying.

**For the Qwen models there is no Claude Code guidance at all** — the cards reference Qwen-Agent, Qwen Code, and CLINE, never Claude Code.

## Sources

All fetched 2026-07-30.

Model cards and vendor docs
- https://huggingface.co/zai-org/GLM-5.2
- https://huggingface.co/zai-org/GLM-4.7-Flash
- https://huggingface.co/Qwen/Qwen3.6-27B
- https://huggingface.co/Qwen/Qwen3.6-35B-A3B
- https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct
- https://huggingface.co/google/gemma-4-31B
- https://github.com/zai-org/GLM-5
- https://docs.z.ai/guides/llm/glm-5.2
- https://docs.z.ai/guides/capabilities/thinking-mode
- https://docs.z.ai/devpack/tool/claude
- https://recipes.vllm.ai/zai-org/GLM-5.2

Leaderboards
- https://www.tbench.ai/leaderboard
- https://www.tbench.ai/leaderboard/terminal-bench/2.1
- https://gorilla.cs.berkeley.edu/leaderboard.html (table client-rendered, not extractable)
- https://huggingface.co/spaces/gorilla-llm/berkeley-function-calling-leaderboard (same)
- https://api.github.com/repos/ShishirPatil/gorilla/contents/berkeley-function-call-leaderboard (no committed scores)
- https://api.github.com/repos/ShishirPatil/gorilla/contents/berkeley-function-call-leaderboard/bfcl_eval (same)
- https://artificialanalysis.ai/models/comparisons/qwen3-6-27b-vs-qwen3-6-35b-a3b

Issue trackers and community
- https://github.com/vllm-project/vllm/issues/42400 (GLM-5.1 tool call parsing fails as Claude Code backend)
- https://github.com/vllm-project/vllm/issues/39757 (GLM-5 streaming truncates tool names, silently)
- https://github.com/vllm-project/vllm/issues/50399 (fetched directly)
- https://github.com/musistudio/claude-code-router/issues/598
- https://github.com/musistudio/claude-code-router/issues/1400
- https://github.com/musistudio/claude-code-router/issues/1397
- https://huggingface.co/api/models/zai-org/GLM-5.2/discussions?p=0
- https://huggingface.co/zai-org/GLM-5.2/discussions
- https://huggingface.co/zai-org/GLM-5.2/discussions/44
- https://huggingface.co/zai-org/GLM-5.2/discussions/21
- https://huggingface.co/zai-org/GLM-5.2/discussions/7
- https://huggingface.co/zai-org/GLM-5.2/discussions/33
- https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/discussions/12

Fetch-method notes
- vLLM issues 49981, 46249, 48568, 50180, 25993 and claude-code-router issues 1133, 1041, 1234, 1249, 1355, 1378, 1410 were read through search APIs (`api.github.com/search/issues`, `gh search issues`) rather than opened individually; titles and states come from those responses. Issues fetched and read in full are listed above.
- `https://z.ai/blog/glm-5.2` (empty body) and `https://qwenlm.github.io/blog/qwen3.6-35b-a3b/` (HTTP 404) returned nothing usable and are cited nowhere.
- `https://qwen.ai/blog?id=qwen3.6-35b-a3b` is client-rendered and returned no content; the Qwen positioning claims come from the model cards instead.
