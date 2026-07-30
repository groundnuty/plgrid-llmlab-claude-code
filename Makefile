# Claude Code on PLGrid LLMLab — proxy lifecycle.
# The proxy is a hard dependency: Claude Code speaks Anthropic dialect, LLMLab speaks OpenAI.

REPO     := $(shell pwd)
FORK     := https://github.com/groundnuty/CLIProxyAPI
VERSION  := v7.2.110-plgrid.1
SRC      := $(REPO)/.cli-proxy-api/src
BIN      := $(REPO)/.cli-proxy-api/cli-proxy-api
CONFIG   := $(REPO)/config/cli-proxy-api.local.yaml
PORT     := $(shell sed -n 's/^port: *//p' config/cli-proxy-api.yaml | head -1)

# Prebuilt binaries are published on the fork's releases; no Go toolchain needed.
OS       := $(shell uname -s | tr A-Z a-z)
ARCH     := $(shell uname -m | sed 's/^x86_64$$/amd64/; s/^aarch64$$/arm64/')
TARBALL  := cli-proxy-api_$(VERSION)_$(OS)_$(ARCH).tar.gz
URL      := $(FORK)/releases/download/$(VERSION)/$(TARBALL)

.PHONY: help proxy build build-from-source config stop status logs test clean
.DEFAULT_GOAL := help

help:
	@echo "make config   create config/cli-proxy-api.local.yaml, then add your PLGrid key"
	@echo "make build    download the patched proxy $(VERSION) ($(OS)/$(ARCH))"
	@echo "make build-from-source   build it instead (needs Go 1.26)"
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
	@echo "downloading $(TARBALL)"
	@curl -fsSL -o $(dir $(BIN))/$(TARBALL) $(URL) || { \
	  echo "download failed for $(OS)/$(ARCH) — falling back to a source build"; \
	  $(MAKE) --no-print-directory build-from-source; exit $$?; }
	@curl -fsSL -o $(dir $(BIN))/checksums.txt $(FORK)/releases/download/$(VERSION)/checksums.txt
	@cd $(dir $(BIN)) && (shasum -a 256 -c --ignore-missing checksums.txt 2>/dev/null \
	  || sha256sum -c --ignore-missing checksums.txt) | grep -q OK \
	  && echo "checksum verified" || { echo "CHECKSUM MISMATCH — refusing to install"; exit 1; }
	@tar xzf $(dir $(BIN))/$(TARBALL) -C $(dir $(BIN))
	@chmod +x $(BIN) && rm -f $(dir $(BIN))/$(TARBALL)
	@$(BIN) -version 2>&1 | head -1 || true

build-from-source:
	@mkdir -p $(dir $(BIN))
	@test -d $(SRC) || git clone --depth 1 --branch $(VERSION) $(FORK) $(SRC)
	@cd $(SRC) && CGO_ENABLED=0 go build -o $(BIN) ./cmd/server
	@echo "built $(BIN) from source"

build: $(BIN)

proxy: $(BIN) $(CONFIG)
	@grep -q PLGRID_API_KEY $(CONFIG) && { echo "error: put your key in $(CONFIG) first"; exit 1; } || true
	@mkdir -p .cli-proxy-api
	@nohup $(BIN) --config $(CONFIG) > .cli-proxy-api/proxy.log 2>&1 & echo $$! > .cli-proxy-api/pid
	@sleep 4
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
	@tail -n 40 -f .cli-proxy-api/proxy.log 2>/dev/null \
	  || echo "no proxy log yet — start it with: make proxy"

test: status
	@echo "sending a real completion through the proxy..."
	@# max_tokens must leave room for a thinking block: reasoning models emit
	@# thinking first, and a small budget is consumed before any answer text.
	@curl -fsS -m 180 -X POST http://127.0.0.1:$(PORT)/v1/messages \
	  -H "Authorization: Bearer local-test-key" -H 'content-type: application/json' \
	  -d '{"model":"glm-5.2-fp8-393k","max_tokens":1024,"messages":[{"role":"user","content":"Reply with exactly: PLGRID_OK"}]}' \
	  | python3 -c "import json,sys; d=json.load(sys.stdin); c=d.get('content',[]); \
	    text=''.join(b.get('text','') for b in c if b.get('type')=='text'); \
	    think=sum(len(b.get('thinking','')) for b in c if b.get('type')=='thinking'); \
	    print('  reply   :', text.strip() or '(none)'); \
	    print('  thinking:', f'{think} chars' if think else 'none (model or fix inactive)'); \
	    sys.exit(0 if 'PLGRID_OK' in text else 1)" \
	  && echo "END-TO-END OK"

clean: stop
	@rm -rf .cli-proxy-api/src
	@echo "removed proxy source (config and binary kept)"
