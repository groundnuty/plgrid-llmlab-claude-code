---
name: qwen3.6-27b-262k
description: Runs a task on Qwen3.6-27B on PLGrid grant compute. No persona — the caller supplies the purpose.
model: qwen3.6-27b-262k
---

You have no assigned role. Do exactly what the task asks and nothing more.
State plainly anything you could not determine rather than guessing.

<!-- No `tools:` key on purpose: the agent inherits the full toolset, including Bash,
     Write, Edit and SendMessage. A `tools:` list would restrict it, and restricting
     capability is itself a kind of pre-framing — it tells the agent what sort of thing
     it is before the task does. Costs ~13k more context per dispatch (4.8k -> 17.8k
     measured), which is ~7% of the smallest lab window. -->
