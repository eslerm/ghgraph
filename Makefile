# Makefile for ghgraph
# Self-documenting: run `make` or `make help` to see available targets.

.PHONY: help doctor config build release run test check-heavy fuzz mutants mutants-diff mutants-extreme mutants-equiv fmt lint check check-full audit vet tree tree-check clean install setup

BINARY_NAME := ghgraph

# Fuzzing knobs (see the `fuzz` target).
TARGET ?= config_gate
SECS ?= 60

# Mutation-testing knobs (see the `mutants` targets). Scope, timeout policy,
# and the known-equivalent exclusions live in .cargo/mutants.toml so every
# invocation shares them; FILE narrows a run, SINCE picks the diff base for
# `mutants-diff` (the per-milestone form).
# JOBS is deliberately modest: each job is a full build tree plus a test
# suite, and a mutant that breaks a loop's progress can allocate at memory-
# bandwidth speed until the timeout kills it — 4 concurrent runaways have
# OOMed a 16GB machine. Loop-bearing code should also carry a progress
# debug_assert (see gh::scrub_tokens) so that class dies by panic instead.
JOBS ?= 2
FILE ?=
SINCE ?= main

help: ## Show this help
	@echo "$(BINARY_NAME) — make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

#
# Getting started
#

doctor: ## Check prerequisites: gh CLI (authenticated) and the Rust toolchain
	@command -v cargo >/dev/null 2>&1 && echo "✓ cargo $$(cargo --version | cut -d' ' -f2)" || { echo "✗ cargo not found — https://rustup.rs"; exit 1; }
	@command -v gh >/dev/null 2>&1 && echo "✓ gh $$(gh --version | head -1 | cut -d' ' -f3)" || { echo "✗ gh not found — ghgraph's only transport (https://cli.github.com)"; exit 1; }
	@gh auth status >/dev/null 2>&1 && echo "✓ gh authenticated" || { echo "✗ gh not authenticated — run: gh auth login"; exit 1; }
	@echo "✓ ready"

config: ## Write a starter config to $XDG_CONFIG_HOME/ghgraph/ (never overwrites)
	@dest="$${XDG_CONFIG_HOME:-$$HOME/.config}/ghgraph/config.json"; \
	if [ -e "$$dest" ]; then echo "exists, not overwriting: $$dest"; \
	else mkdir -p "$$(dirname "$$dest")" && cp config.example.json "$$dest" && echo "wrote $$dest — edit it, then: ghgraph sync"; fi

#
# Build and run
#

build: ## Build (debug)
	cargo build

release: ## Build (optimized)
	cargo build --release

run: ## Run ghgraph — pass args with ARGS, e.g. make run ARGS="attention"
	@cargo run -- $(ARGS)

install: ## Install the binary into ~/.cargo/bin
	cargo install --path .

#
# Quality — `make check` is the pre-commit gate
#

fmt: ## Format the source
	cargo fmt --all

lint: ## Clippy, warnings as errors
	cargo clippy --all-targets -- -D warnings

test: ## Run the test suite
	cargo test

fuzz: ## Fuzz a target (out-of-build, nightly). TARGET=config_gate SECS=60
	@command -v cargo-fuzz >/dev/null 2>&1 || { echo "cargo-fuzz not found — run: cargo install cargo-fuzz"; exit 1; }
	@nb="$$(dirname "$$(rustup which --toolchain nightly cargo)")"; \
	echo "fuzzing $(TARGET) for $(SECS)s on nightly…"; \
	PATH="$$nb:$$HOME/.cargo/bin:$$PATH" cargo fuzz run $(TARGET) -- -max_total_time=$(SECS)

mutants: ## Mutation-test the crate (full sweep ~4h; needs cargo-mutants). FILE=src/foo.rs narrows
	@command -v cargo-mutants >/dev/null 2>&1 || { echo "cargo-mutants not found — run: cargo install cargo-mutants"; exit 1; }
	cargo mutants $(if $(FILE),--file $(FILE)) --jobs $(JOBS)

mutants-diff: ## Mutation-test only code changed since SINCE (default: main)
	@command -v cargo-mutants >/dev/null 2>&1 || { echo "cargo-mutants not found — run: cargo install cargo-mutants"; exit 1; }
	@t=$$(mktemp); git diff $$(git merge-base $(SINCE) HEAD) > $$t; \
		cargo mutants --in-diff $$t --jobs $(JOBS); s=$$?; rm -f $$t; exit $$s

# Function-replacement mutants only — the pseudo-tested-code sweep: a
# survivor here is a function whose ENTIRE body can vanish unnoticed, the
# signal operator-level noise drowns. The ' in ' discriminator relies on
# cargo-mutants' mutant-naming convention (operator mutants read "replace X
# with Y in fn"; body replacements read "replace fn -> T with v") — verified
# exact against --list at 0.27; re-verify after a cargo-mutants major bump.
mutants-extreme: ## Pseudo-tested-code sweep: function-replacement mutants only (~35 min)
	@command -v cargo-mutants >/dev/null 2>&1 || { echo "cargo-mutants not found — run: cargo install cargo-mutants"; exit 1; }
	cargo mutants --exclude-re ' in ' --jobs $(JOBS)

# The inverse gate over the argued-equivalent ledger: each entry is
# "pattern|expected-missed-count", and the run must miss EXACTLY that many.
# Fewer missed means a note rotted in the secretly-killable direction (a
# test now discriminates it — the db.rs reverse-selects hook did exactly
# this): delete the entry and its code note, and record the killing test
# there instead. MORE missed means a new survivor appeared inside the same
# function — triage it. Counts, not names, because mutant names embed
# line numbers that drift. Entries mirror .cargo/mutants.toml exclude_re
# plus the documented-at-code survivors.
MUTANTS_EQUIV := \
	'replace match guard e.kind\(\) == std::io::ErrorKind::BrokenPipe with true in emit|1' \
	'replace - with \+ in overhead_intercept_ms|2' \
	'replace < with <= in wrong_version|1' \
	'replace > with >= in wrong_version|1'

mutants-equiv: ## Verify the argued-equivalent mutants still survive, exactly (drift either way fails)
	@command -v cargo-mutants >/dev/null 2>&1 || { echo "cargo-mutants not found — run: cargo install cargo-mutants"; exit 1; }
	@for entry in $(MUTANTS_EQUIV); do \
		re=$${entry%|*}; want=$${entry##*|}; \
		cargo mutants --no-config --re "$$re" --jobs $(JOBS) >/dev/null 2>&1; \
		got=$$(wc -l < mutants.out/missed.txt | tr -d ' '); \
		[ "$$got" -eq "$$want" ] || { echo "equiv ledger drift for $$re: expected $$want missed, got $$got — a stale note (fewer) or a new survivor (more)"; exit 1; }; \
		echo "as argued ($$got missed): $$re"; \
	done

check: ## Fast pre-commit gate: format, clippy, check, test
	cargo fmt --all -- --check
	cargo clippy --all-targets -- -D warnings
	cargo check --all-targets
	cargo test
	@echo "✓ all checks passed"

check-heavy: ## The ignored heavy tests (e.g. the 120s live watchdog stall)
	cargo test -- --ignored --skip capture_

check-full: check audit vet tree-check ## check, plus the supply-chain checks CI runs

#
# Supply chain (dependency policy — see DESIGN.md; all four run in CI)
#

audit: ## Scan dependencies for known advisories (needs cargo-audit; make setup)
	@command -v cargo-audit >/dev/null 2>&1 || { echo "cargo-audit not found — run 'make setup' (or: cargo install cargo-audit)"; exit 1; }
	cargo audit

vet: ## Vet the dependency tree against supply-chain/ (needs cargo-vet; make setup)
	@command -v cargo-vet >/dev/null 2>&1 || { echo "cargo-vet not found — run 'make setup' (or: cargo install cargo-vet)"; exit 1; }
	cargo vet --locked

# The snapshot's first line embeds the local checkout path (cargo prints the
# root package's manifest dir); sed strips it so the snapshot is
# host-portable — CI checkouts and contributor clones live elsewhere. Both
# targets write to a temp file first: a plain redirect would truncate the
# committed snapshot before a failing cargo runs, and a pipe into diff would
# let diff's exit status mask cargo's.
TREE_CMD := cargo tree --locked --edges normal --target all

tree: ## Regenerate the dependency-graph snapshot (run after any Cargo.toml/lock change)
	@t=$$(mktemp); $(TREE_CMD) > $$t || { rm -f $$t; echo "cargo tree failed (lockfile drift?)"; exit 1; }; \
		sed -E -i.bak '1s| \(.*\)$$||' $$t && rm -f $$t.bak; \
		mv $$t supply-chain/cargo-tree.txt && \
		echo "wrote supply-chain/cargo-tree.txt — review the diff like code"

tree-check: ## Fail if the dependency graph moved without a snapshot update
	@t=$$(mktemp); $(TREE_CMD) > $$t || { rm -f $$t; echo "cargo tree failed (lockfile drift?)"; exit 1; }; \
		sed -E -i.bak '1s| \(.*\)$$||' $$t && rm -f $$t.bak; \
		diff -u supply-chain/cargo-tree.txt $$t || \
		{ rm -f $$t; echo "dependency graph diverged from supply-chain/cargo-tree.txt — run 'make tree' and review"; exit 1; }; \
		rm -f $$t

# Versions match .github/workflows/ci.yml — bump both together, by diff.
setup: ## Install the dev tools the quality targets need (cargo-audit, cargo-vet)
	cargo install cargo-audit --version 0.22.2 --locked
	cargo install cargo-vet --version 0.10.2 --locked

#
# Housekeeping
#

clean: ## Remove build artifacts
	cargo clean

.DEFAULT_GOAL := help
