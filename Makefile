.PHONY: all build test race vet lint fmt fmt-check tidy vuln cover gate clean db-up db-down test-db migrate-up

VERSION ?= dev
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w
BINS    := afs-migrate

GOLANGCI_LINT_VERSION ?= v2.15.0
GOVULNCHECK_VERSION   ?= v1.8.0

all: gate

build:
	@mkdir -p bin
	@for b in $(BINS); do CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o bin/$$b ./cmd/$$b || exit 1; done

test:
	go test ./...

race:
	go test -race ./...

vet:
	go vet ./...

# Build golangci-lint with this module's toolchain (go.mod), so it can analyze Go 1.27 code.
lint:
	GOTOOLCHAIN=$(shell go env GOVERSION) go run github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION) run

fmt:
	gofmt -w .

fmt-check:
	@out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "$$out"; exit 1; fi

tidy:
	go mod tidy

vuln:
	go run golang.org/x/vuln/cmd/govulncheck@$(GOVULNCHECK_VERSION) ./...

# Coverage: migrate must stay at or above 90%. Set AFS_TEST_DATABASE_URL so the integration tests run.
cover:
	go test -count=1 -cover ./migrate/...

# The full quality gate. Must pass before every commit.
gate: tidy fmt-check vet lint race build
	@echo "gate passed"

clean:
	$(RM) -r ./bin ./dist

# Local PostgreSQL for integration tests (Docker). CI uses a postgres:17 service container.
PG_URL ?= postgres://postgres:postgres@localhost:55432/postgres?sslmode=disable

db-up:
	docker run -d --name afs-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:17

db-down:
	docker stop afs-pg && docker rm afs-pg

# Integration tests: up/down/up, constraints, spend reservation, row-level security.
test-db:
	AFS_TEST_DATABASE_URL="$(PG_URL)" go test -count=1 ./...

# Apply migrations to the database at AFS_DATABASE_URL.
migrate-up:
	go run ./cmd/afs-migrate up
