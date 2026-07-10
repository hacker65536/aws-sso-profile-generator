BINARY := aws-sso-profiles
PKG := ./cmd/aws-sso-profiles
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: build test race vet fmt fmt-check lint vuln check completions clean

build: ## Build the binary
	go build -ldflags "$(LDFLAGS)" -o $(BINARY) $(PKG)

test: ## Run tests
	go test ./...

race: ## Run tests with the race detector
	go test -race ./...

vet:
	go vet ./...

fmt:
	gofmt -w .

fmt-check:
	@unformatted=$$(gofmt -l .); \
	if [ -n "$$unformatted" ]; then echo "needs gofmt:"; echo "$$unformatted"; exit 1; fi

lint: ## Run golangci-lint (must be installed)
	golangci-lint run

vuln: ## Run govulncheck
	go run golang.org/x/vuln/cmd/govulncheck@latest ./...

check: fmt-check vet race ## CI-equivalent local gate

completions: build ## Generate shell completions into ./completions-go
	@mkdir -p completions-go
	./$(BINARY) completion bash > completions-go/$(BINARY).bash
	./$(BINARY) completion zsh  > completions-go/$(BINARY).zsh
	./$(BINARY) completion fish > completions-go/$(BINARY).fish

clean:
	rm -f $(BINARY)
	rm -rf dist completions-go
