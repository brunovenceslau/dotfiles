# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Makefile - repo quality gates.
#
# CI (.github/workflows/ci.yml) invokes only these targets; every gate
# lands here first and is wired into `make local-ci`. Recipes stay bash 3.2
# compatible so the macOS legs behave identically.

SHELL := /bin/bash

# Wildcards so a target stays valid when its scanned directory is empty.
# Every bin/ and lib/ tool is a shell script, so the whole set routes to
# shellcheck; a .py file here would need excluding first (shellcheck errors
# SC1071 on one). py-syntax below covers .py syntax separately, wherever it lives.
SH_FILES     := $(wildcard install.sh) $(wildcard lib/*.sh) $(wildcard bin/*)
# Bash-3.2 compatibility is scoped to install.sh + lib/ only; bin/
# tools run on provisioned hosts/CI under a modern bash. The /bin/bash -n 3.2
# parse pass therefore scans this subset, not all of SH_FILES.
BASH32_FILES := $(wildcard install.sh) $(wildcard lib/*.sh)
ZSH_FILES    := $(wildcard zsh/zshenv) $(wildcard zsh/zshrc) $(wildcard zsh/*.zsh)
TEST_FILES   := $(wildcard tests/*.sh)

# STRICT=1 (set by CI) turns a missing tool from a skip-with-warning into a hard
# failure, so a local gate never reports green on a check it did not run.
STRICT ?=

.DEFAULT_GOAL := help
.PHONY: help lint check-patterns py-syntax test reuse gitleaks smoke secret-scan forkgate local-ci repo-settings-check

help:
	@echo "Targets:"
	@echo "  make lint                 shellcheck + zsh -n + /bin/bash -n + static patterns + python3 -I syntax check"
	@echo "  make test                 unit tests for the repo tooling (tests/*.sh)"
	@echo "  make reuse                REUSE 3.3 compliance: every file states its copyright and licence"
	@echo "  make gitleaks             gitleaks' maintained secret rule set over the working directory"
	@echo "  make smoke                fresh-install smoke in a scratch HOME (install + zsh -i + idempotency)"
	@echo "  make secret-scan          high-confidence secret scan over the tracked tree"
	@echo "  make forkgate             prove 'zsh -i -c exit' invokes no external binary"
	@echo "  make local-ci             every locally-runnable CI gate; reports skipped legs"
	@echo "  make repo-settings-check  maintainer-run: diff live GitHub settings vs .github/repo-settings.json"

# Lint = shellcheck (install.sh, lib/, bin/) + `zsh -n` over all
#   .zsh + `/bin/bash -n` over the bash surface + static-pattern checks +
#   python3 -I compile() syntax check over every tracked and untracked-but-not-
#   ignored .py file. MUST be green before commit.
lint: check-patterns py-syntax
	@if command -v shellcheck >/dev/null 2>&1; then \
	  if [ -n "$(strip $(SH_FILES))" ]; then \
	    echo "shellcheck $(SH_FILES)"; shellcheck $(SH_FILES); \
	  else echo "shellcheck: no shell files yet, skipping"; fi; \
	elif [ -n "$(STRICT)" ]; then \
	  echo "ERROR: shellcheck not installed and STRICT=1 - failing closed" >&2; exit 1; \
	else \
	  echo "WARN: shellcheck not installed - skipping (set STRICT=1 to fail; CI enforces it)"; \
	fi
	@# parse the 3.2 surface (BASH32_FILES) with the absolute
	@#   /bin/bash, which on the macOS CI legs is the real 3.2 - the only place a
	@#   PARSE-level 3.2 slip (`;;&`, `|&`) is actually caught. It does NOT see
	@#   `declare -A` or `mapfile` (ordinary command invocations) or `${var,,}` (an
	@#   expansion-time failure) in ANY bash; check-patterns is the gate for those
	@#   three. Absolute path so a Homebrew bash 5 on PATH never shadows it.
	@if [ -n "$(strip $(BASH32_FILES))" ]; then \
	  for f in $(BASH32_FILES); do echo "/bin/bash -n $$f"; /bin/bash -n "$$f" || exit 1; done; \
	else echo "/bin/bash -n: no bash-3.2 files yet, skipping"; fi
	@# The test scripts RUN under `make test`'s `bash "$$t"`, which on the macOS CI legs is
	@#   the system /bin/bash 3.2. Parse-check them with the absolute /bin/bash so a bash-3.2
	@#   -only parse error (e.g. a `case` inside a `$$(...)`, whose pattern `)` the naive 3.2
	@#   scanner mis-reads - a real packages_test bug once caught this way) is caught at LINT time, fast and
	@#   un-masked, instead of at test-RUN time behind make test's per-file loop. Asserts the
	@#   tests PARSE under the system bash, not that they are 3.2 feature-limited. Like the
	@#   BASH32 pass above, the 3.2-ONLY class is caught by the system /bin/bash (real 3.2)
	@#   on both macOS legs - a lint under a newer bash is not proof of 3.2 parse-safety.
	@if [ -n "$(strip $(TEST_FILES))" ]; then \
	  for f in $(TEST_FILES); do echo "/bin/bash -n $$f"; /bin/bash -n "$$f" || exit 1; done; \
	else echo "/bin/bash -n tests: no test files yet, skipping"; fi
	@if [ -n "$(strip $(ZSH_FILES))" ]; then \
	  for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || exit 1; done; \
	else echo "zsh -n: no .zsh files yet, skipping"; fi

# Static-pattern checks - forbid `curl|sh` runtime fetches,
# ad-hoc `uname -m` outside lib/os.sh (all arch
#   branching goes through the is-arm64/is-amd64 helpers), a hardcoded Homebrew
#   prefix or brew prefix-probe fork, and bash 4 syntax in the 3.2 surface (which
#   the /bin/bash -n pass above cannot see at all). The logic lives in
#   bin/check-patterns: shellcheck-clean, unit-tested (tests/check_patterns_test.sh),
#   and fails CLOSED - the earlier inline recipe passed an absent scan path (home/)
#   to grep, whose exit 2 made `if grep` read a real match as "no match" and
#   silently disabled both checks. Kept a make target so lint/CI wire it unchanged.
check-patterns:
	@bin/check-patterns

# Syntax-only gate over the repo's .py files. Tracked AND untracked-but-not-
#   ignored files count (--others --exclude-standard): the other lint passes
#   above scan by WILDCARD, not by git tracking state, so a new .py file is
#   caught before its first commit too. `-z` + a NUL-delimited read on the
#   PYTHON side (never a shell word-list) is load-bearing: a shell-word file
#   list breaks open on a space or a newline in a filename - either splits it
#   into two argv entries that resolve to DIFFERENT files, one of which can be
#   an attacker-controlled decoy the real, broken file's name never named.
#   `git ls-files` writes to a temp file first (never the LEFT side of a pipe
#   into python3), so its own exit status is checked directly instead of
#   being hidden behind the pipe; its STDERR is captured too and fails closed
#   on its own - git exits 0 and only warns (e.g. "could not open directory")
#   when an unreadable subdirectory silently drops files from the listing, so
#   a clean exit status alone is not enough. A `git ls-files` failure (or
#   warning) fails closed unconditionally - that is a broken invocation, never
#   an absent-tool skip. `-I` (isolated mode, see tests/release_workflow_check.py)
#   drops the current directory from sys.path; the builtin `compile()`, not
#   the py_compile module, never writes a __pycache__/*.pyc for the files it
#   checks, nor for itself (only an IMPORTED module gets bytecode-cached, and
#   this script imports only os, stat and sys). A file `git ls-files` lists
#   but that is unreadable (deleted after being staged, say) fails with
#   `OSError.strerror`, never an uncaught traceback. Before opening a listed
#   path, it must be a REGULAR file (`os.stat` follows symlinks, so a tracked
#   symlink to a device node such as /dev/zero is rejected without ever being
#   read - reading one would hang the gate forever) whose `os.path.realpath`
#   stays under the repo root (a tracked symlink pointing outside the repo,
#   e.g. at /etc/hostname, must not be read transparently either). `compile()`
#   also catches ValueError - a NUL byte in the source raises that, not
#   SyntaxError, and would otherwise surface as a raw traceback. Both mktemp
#   files are cleaned up by a trap on INT/TERM/EXIT. STRICT semantics
#   otherwise match the shellcheck block.
py-syntax:
	@py_list="$$(mktemp "$${TMPDIR:-/tmp}/py-syntax-list.XXXXXX")" || { echo "ERROR: mktemp failed - failing closed" >&2; exit 1; }; \
	err_list="$$(mktemp "$${TMPDIR:-/tmp}/py-syntax-err.XXXXXX")" || { rm -f "$$py_list"; echo "ERROR: mktemp failed - failing closed" >&2; exit 1; }; \
	trap 'rm -f "$$py_list" "$$err_list"' INT TERM EXIT; \
	git ls-files -z --cached --others --exclude-standard -- '*.py' > "$$py_list" 2>"$$err_list"; \
	rc=$$?; \
	if [ "$$rc" -ne 0 ] || [ -s "$$err_list" ]; then \
	  echo "ERROR: 'git ls-files' failed (exit $$rc) or reported a warning - failing closed" >&2; \
	  cat "$$err_list" >&2; \
	  exit 1; \
	fi; \
	if [ -s "$$py_list" ]; then \
	  if command -v python3 >/dev/null 2>&1; then \
	    echo "python3 -I (compile(), NUL-delimited file list read from stdin, no bytecode written)"; \
	    python3 -I <(printf '%s\n' \
	      'import os, stat, sys' \
	      'root = os.path.realpath(os.getcwd())' \
	      'bad = 0' \
	      'for f in sys.stdin.buffer.read().split(b"\0")[:-1]:' \
	      '    f = f.decode(sys.getfilesystemencoding(), "surrogateescape")' \
	      '    try:' \
	      '        st = os.stat(f)' \
	      '    except OSError as e:' \
	      '        print(f"{f}: {e.strerror}", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    if not stat.S_ISREG(st.st_mode):' \
	      '        print(f"{f}: not a regular file - refusing to read", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    real = os.path.realpath(f)' \
	      '    if real != root and not real.startswith(root + os.sep):' \
	      '        print(f"{f}: resolves outside the repository root - refusing to read", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    try:' \
	      '        src = open(f, "rb").read()' \
	      '    except OSError as e:' \
	      '        print(f"{f}: {e.strerror}", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    try:' \
	      '        compile(src, f, "exec")' \
	      '    except (SyntaxError, ValueError) as e:' \
	      '        print(f"{f}: {e}", file=sys.stderr)' \
	      '        bad = 1' \
	      'sys.exit(bad)') < "$$py_list"; \
	    exit $$?; \
	  elif [ -n "$(STRICT)" ]; then \
	    echo "ERROR: python3 not installed and STRICT=1 - failing closed" >&2; exit 1; \
	  else \
	    echo "WARN: python3 not installed - skipping (set STRICT=1 to fail; CI enforces it)"; \
	  fi; \
	else echo "py-syntax: no .py files, skipping"; fi

# Unit tests for the repo's own tooling. KEEP-GOING: run EVERY test and report ALL failures
# at once, exiting nonzero iff any failed. The early-abort (`|| exit 1`) once MASKED a
# multi-bug macOS breakage: two independent failures surfaced one-per-CI-round because
# the run stopped at the first. An early abort makes a cascade look like a single bug.
test:
	@if [ -n "$(strip $(TEST_FILES))" ]; then \
	  failed=""; ran=0; \
	  for t in $(TEST_FILES); do echo "run $$t"; ran=$$((ran+1)); bash "$$t" || failed="$$failed $$t"; done; \
	  if [ -n "$$failed" ]; then echo "test: FAILED:$$failed" >&2; exit 1; fi; \
	  echo "test: all $$ran test files passed"; \
	else echo "test: no tests found"; fi

# REUSE 3.3 compliance - every tracked file states its copyright
#   holder and its SPDX licence, and every licence named has its full text in
#   LICENSES/. A blocking gate so a new file cannot land unlicensed, which is
#   the only moment the omission is cheap to fix. STRICT semantics are the
#   shellcheck block's: absent tool = skip with a warning locally, hard failure
#   under STRICT=1, so CI can never green a leg it did not run. `reuse lint`
#   walks what git tracks and does NOT descend into the plugin submodules;
#   their licences are recorded in THIRD-PARTY-NOTICES.md instead.
reuse:
	@if command -v reuse >/dev/null 2>&1; then \
	  echo "reuse lint"; reuse lint; \
	elif [ -n "$(STRICT)" ]; then \
	  echo "ERROR: reuse not installed and STRICT=1 - failing closed" >&2; exit 1; \
	else \
	  echo "WARN: reuse not installed - skipping (set STRICT=1 to fail; CI enforces it)"; \
	fi

# gitleaks - the maintained secret rule set, running behind the
#   zero-dependency floor of bin/secret-scan rather than in place of it: the
#   floor works on a machine with nothing installed, this one keeps up with
#   provider token formats a hand-written grep cannot. `gitleaks dir .` walks
#   the working directory as it is on disk, so an untracked file is scanned
#   BEFORE it can be committed. --redact keeps a real finding out of the CI log
#   while still naming its file and line; .gitleaks.toml holds the rule set and
#   the one `secret-scan:allow` waiver token both scanners share. STRICT
#   semantics are the shellcheck block's: absent tool = skip with a warning
#   locally, hard failure under STRICT=1, so CI can never green a leg it did
#   not run.
gitleaks:
	@if command -v gitleaks >/dev/null 2>&1; then \
	  echo "gitleaks dir ."; gitleaks dir . --no-banner --redact; \
	elif [ -n "$(STRICT)" ]; then \
	  echo "ERROR: gitleaks not installed and STRICT=1 - failing closed" >&2; exit 1; \
	else \
	  echo "WARN: gitleaks not installed - skipping (set STRICT=1 to fail; CI enforces it)"; \
	fi

# Fresh-install smoke - install into a scratch HOME (under .smoke/,
#   in-repo), assert `zsh -i -c exit` is clean (exit 0, empty stderr), and prove a
#   re-run is idempotent. A blocking gate, wired
#   into local-ci below. STRICT is forwarded so a missing zsh fails closed in CI.
smoke:
	@STRICT='$(STRICT)' bin/smoke

# High-confidence secret scan over the tracked tree - a blocking gate
#   wired into local-ci below and run in CI. A planted-secret fixture in
#   tests/secret_scan_test.sh proves it catches a real key; always runnable (git +
#   grep only), so no STRICT skip.
secret-scan:
	@bin/secret-scan --git .

# The startup-fork gate - PATH-first logging shims around a hermetic
#   `zsh -i -c exit` prove the startup path invokes no external binary. A
#   BLOCKING gate: the log-derived assertion is deterministic.
#   STRICT is forwarded so a missing zsh fails closed in CI.
forkgate:
	@STRICT='$(STRICT)' bin/startup-fork-gate

# Run every locally-runnable CI gate and report which OS-specific
#   or not-yet-implemented legs were skipped. `smoke` runs a full scratch-HOME
#   install + interactive zsh, so it is locally runnable and gates here.
local-ci: lint test reuse gitleaks secret-scan smoke forkgate
	@echo "----------------------------------------------------------------"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "local-ci: PASS lint (shellcheck + zsh -n + patterns + py-syntax) + test + secret-scan + smoke + forkgate"; \
	else \
	  echo "local-ci: PASS lint (zsh -n + patterns + py-syntax) + test + secret-scan + smoke + forkgate"; \
	  echo "local-ci: SKIP shellcheck (not installed locally; enforced in CI)"; \
	fi
	@# reuse reports on its own line, for the reason shellcheck does: without
	@# STRICT=1 the target exits 0 when the tool is absent, so the summary has to
	@# say whether the leg ran rather than fold it into a blanket PASS.
	@if command -v reuse >/dev/null 2>&1; then \
	  echo "local-ci: PASS reuse (REUSE 3.3 compliance)"; \
	else \
	  echo "local-ci: SKIP reuse (not installed locally; enforced in CI)"; \
	fi
	@if command -v gitleaks >/dev/null 2>&1; then \
	  echo "local-ci: PASS gitleaks (maintained secret rule set)"; \
	else \
	  echo "local-ci: SKIP gitleaks (not installed locally; enforced in CI)"; \
	fi

# The ONLINE half of the settings-vs-docs drift gate: diff the live GitHub
#   settings against .github/repo-settings.json with `gh api` under the
#   operator's own auth. Deliberately NOT a prerequisite of local-ci and never
#   called from CI: a pull request from a fork cannot run these calls without
#   exposing a token to untrusted code, and several endpoints need admin rights.
#   The OFFLINE half (the docs and ci.yml held to the same file) is
#   tests/repo_settings_test.sh, which `make test` runs on every pull request.
#   No STRICT skip: a missing gh or jq is exit 2, never a pass.
repo-settings-check:
	@bin/repo-settings-check
