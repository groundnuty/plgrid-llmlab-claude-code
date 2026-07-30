#!/usr/bin/env bash
# Project-scoped status line for models behind an Anthropic-translating proxy.
#
# Every model declares a 1M window so Claude Code never compacts prematurely, which
# makes its own used_percentage meaningless. This recovers the truth by reading the
# real limit out of the model id, where it is encoded as a "-<N>k" segment
# (e.g. glm-5.2-fp8-393k). Falls back to the declared window when absent.
IN=$(cat)
python3 - "$IN" <<'PY'
import json, sys, re
d = json.loads(sys.argv[1])
cw    = d.get("context_window") or {}
model = (d.get("model") or {}).get("display_name") or (d.get("model") or {}).get("id") or "?"
used  = cw.get("total_input_tokens") or 0
declared = cw.get("context_window_size") or 0

m = re.search(r'-(\d+)k(?:\[|$|-)', model)
real = int(m.group(1)) * 1000 if m else declared
pct  = (used / real * 100) if real else 0

bar_n = 20
filled = min(bar_n, int(pct / 100 * bar_n))
bar = "█" * filled + "░" * (bar_n - filled)
warn = "  ⚠ COMPACT SOON" if pct >= 80 else ""
cost = (d.get("cost") or {}).get("total_cost_usd")
cost_s = f" · ${cost:.2f}" if isinstance(cost, (int, float)) else ""

print(f"{model} · {used/1000:.1f}k/{real/1000:.0f}k {bar} {pct:.0f}%"
      f"{'' if m else ' (declared)'}{cost_s}{warn}")
PY
