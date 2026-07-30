import json, glob, os
import jinja2, jinja2.sandbox, jinja2.ext

def detect_merge_inline_system(chat_template):
    """Verbatim reimplementation of vLLM main:
    vllm/entrypoints/anthropic/serving.py::_detect_merge_inline_system"""
    if not chat_template:
        return True, "no template -> merge (safe)"
    try:
        env = jinja2.sandbox.ImmutableSandboxedEnvironment(
            trim_blocks=True, lstrip_blocks=True,
            extensions=[jinja2.ext.loopcontrols])
        env.from_string(chat_template).render(
            messages=[{"role": "system", "content": "t"},
                      {"role": "user", "content": "t"},
                      {"role": "system", "content": "t"},
                      {"role": "user", "content": "t"}],
            add_generation_prompt=False)
        return False, "rendered OK -> leaves system inline"
    except jinja2.TemplateError as e:
        return True, f"raised {type(e).__name__} -> merge into leading block"

def render_48874_shape(chat_template):
    """The actual shape Claude Code >=2.1.2xx sends per vLLM #48874:
    user task first, then an agent-registry system message AFTER it."""
    env = jinja2.sandbox.ImmutableSandboxedEnvironment(
        trim_blocks=True, lstrip_blocks=True,
        extensions=[jinja2.ext.loopcontrols])
    return env.from_string(chat_template).render(
        messages=[{"role": "user", "content": "USER_TASK_HERE"},
                  {"role": "system", "content": "AGENT_REGISTRY_BLOB"}],
        add_generation_prompt=True)

def load(path):
    if path.endswith(".jinja"):
        return open(path).read()
    d = json.load(open(path))
    return d.get("chat_template")

files = sorted(glob.glob("tmpl/*.jinja")) + sorted(glob.glob("tmpl/*.tok.json"))
for f in files:
    name = os.path.basename(f).replace(".jinja","").replace(".tok.json"," (tokenizer_config)")
    try:
        t = load(f)
    except Exception as e:
        print(f"{name:34s} LOAD FAILED {e}"); continue
    if not t:
        print(f"{name:34s} NO chat_template FIELD -> vLLM returns merge=True (safe by default)"); continue
    merge, why = detect_merge_inline_system(t)
    verdict = "SAFE from #48874" if merge else ">>> EXPOSED to #48874 <<<"
    print(f"\n{'='*78}\n{name}\n  template bytes: {len(t)}")
    print(f"  vLLM merge_inline_system = {merge}   ({why})")
    print(f"  => {verdict}")
    if not merge:
        try:
            out = render_48874_shape(t)
            tail = out[-260:].replace("\n","\\n")
            print(f"  rendered [user, system] tail (what the model sees LAST):\n    ...{tail}")
            print(f"  ends with the system blob? {'AGENT_REGISTRY_BLOB' in out[-160:]}")
        except jinja2.TemplateError as e:
            print(f"  (render of [user,system] raised: {e})")
