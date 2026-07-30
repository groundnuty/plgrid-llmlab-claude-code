# Claude Code on PLGrid LLMLab — proxy lifecycle.
# The proxy is a hard dependency: Claude Code speaks Anthropic dialect, LLMLab speaks OpenAI.

REPO    := $(shell pwd)
FORK    := https://github.com/groundnuty/CLIProxyAPI
SRC     := $(REPO)/.cli-proxy-api/src
BIN     := $(REPO)/.cli-proxy-api/cli-proxy-api
CONFIG  := $(REPO)/config/cli-proxy-api.local.yaml
PORT    := $(shell sed -n 's/^port: *//p' config/cli-proxy-api.yaml | head -1)

.PHONY: help proxy build config stop status logs test clean
.DEFAULT_GOAL := help

help:
	@echo "make config   create config/cli-proxy-api.local.yaml, then add your PLGrid key"
	@echo "make build    build the patched proxy from $(FORK)"
	@echo "make proxy    start the proxy (builds and configures if needed)"
	@echo "make status   check whether the proxy is up and which models it serves"
	@echo "make stop     stop the proxy"
	@echo "make logs     tail the proxy log"
	@echo "make test     end-to-end check: proxy reachable + a real completion"
	@echo ""
	@echo "then:  ./bin/claude-glm     or    ./bin/claude-qwen"

$(CONFIG):
	@cp config/cli-proxy-api.yaml $(CONFIG)
	@chmod 600 $(CONFIG)
	@echo "created $(CONFIG) (gitignored, mode 600)"
	@echo ">>> edit it and replace PLGRID_API_KEY with your grant key"
	@echo ">>> get one at https://llmlab.plgrid.pl -> Grants -> Generate API Key"

config: $(CONFIG)

$(BIN):
	@mkdir -p $(dir $(BIN))
	@test -d $(SRC) || git clone --depth 1 $(FORK) $(SRC)
	@cd $(SRC) && git pull --ff-only 2>/dev/null || true
	@cd $(SRC) && go build -o $(BIN) ./cmd/server
	@echo "built $(BIN)"

build: $(BIN)

proxy: $(BIN) $(CONFIG)
	@grep -q PLGRID_API_KEY $(CONFIG) && { echo "error: put your key in $(CONFIG) first"; exit 1; } || true
	@$(BIN) --config $(CONFIG) & echo $$! > .cli-proxy-api/pid
	@sleep 3
	@$(MAKE) --no-print-directory status

status:
	@curl -fsS -m 5 -H "Authorization: Bearer local-test-key" \
	  http://127.0.0.1:$(PORT)/v1/models >/dev/null 2>&1 \
	  && echo "proxy up on :$(PORT), models:" \
	  && curl -fsS -m 5 -H "Authorization: Bearer local-test-key" \
	     http://127.0.0.1:$(PORT)/v1/models \
	     | python3 -c "import json,sys;[print('  ',m['id']) for m in json.load(sys.stdin)['data']]" \
	  || { echo "proxy DOWN on :$(PORT) — run: make proxy"; exit 1; }

stop:
	@test -f .cli-proxy-api/pid && kill $$(cat .cli-proxy-api/pid) 2>/dev/null && rm -f .cli-proxy-api/pid \
	  && echo "stopped" || echo "not running"

logs:
	@tail -f $$(sed -n 's/^auth-dir: *"\(.*\)"/\1/p' $(CONFIG) | head -1)/logs/*.log 2>/dev/null \
	  || echo "no request logs yet (request-log: true must be set)"

test: status
	@echo "sending a real completion through the proxy..."
	@curl -fsS -m 120 -X POST http://127.0.0.1:$(PORT)/v1/messages \
	  -H "Authorization: Bearer local-test-key" -H 'content-type: application/json' \
	  -d '{"model":"glm-5.2-fp8-393k","max_tokens":32,"messages":[{"role":"user","content":"Reply with exactly: PLGRID_OK"}]}' \
	  | python3 -c "import json,sys;d=json.load(sys.stdin);t=''.join(b.get('text','') for b in d.get('content',[]));print('  response:',t.strip() or d);sys.exit(0 if 'PLGRID_OK' in t else 1)" \
	  && echo "END-TO-END OK"

clean: stop
	@rm -rf .cli-proxy-api/src
	@echo "removed proxy source (config and binary kept)"
