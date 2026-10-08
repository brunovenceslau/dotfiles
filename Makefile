# SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Makefile - repo quality gates.
#
# CI (.github/workflows/ci.yml) invokes only these targets; every gate
# lands here first and is wired into `make local-ci`. Recipes stay bash 3.2
# compatible so the macOS legs behave identically.

SHELL := /bin/bash

# This Makefile's own path, taken before any include can append to MAKEFILE_LIST.
# test-env-scrub reads it, so `make -f <copy> test-env-scrub` checks the copy.
SELF := $(lastword $(MAKEFILE_LIST))

# Wildcards so a target stays valid when its scanned directory is empty.
# Every bin/ tool is a shell script, so the whole set routes to shellcheck; a
# .py file there would need excluding first (shellcheck errors SC1071 on one).
# .githooks/ is named file by file for the same reason: its two hook wrappers
# are bash, and commit_identity.py beside them is not.
# lib/ is taken as lib/*.sh, which keeps lib/host_identity.py out. py-syntax
# below covers .py syntax separately, wherever it lives.
SH_FILES     := $(wildcard install.sh) $(wildcard lib/*.sh) $(wildcard bin/*) \
                $(wildcard .githooks/pre-commit) $(wildcard .githooks/pre-push)
# Bash-3.2 compatibility is scoped to install.sh + lib/ only; bin/
# tools run on provisioned hosts/CI under a modern bash. The /bin/bash -n 3.2
# parse pass therefore scans this subset, not all of SH_FILES.
BASH32_FILES := $(wildcard install.sh) $(wildcard lib/*.sh)
ZSH_FILES    := $(wildcard zsh/zshenv) $(wildcard zsh/zshrc) $(wildcard zsh/*.zsh)
TEST_FILES   := $(wildcard tests/*.sh)
# Sourced by the tests, so parsed with them; never run on their own.
TEST_LIB_FILES := $(wildcard tests/lib/*.sh)

# STRICT=1 (set by CI) turns a missing tool from a skip-with-warning into a hard
# failure, so a local gate never reports green on a check it did not run.
STRICT ?=

.DEFAULT_GOAL := help
.PHONY: help lint check-patterns py-syntax test test-env-scrub reuse gitleaks smoke secret-scan forkgate linkcheck commit-identity local-ci repo-settings-check

help:
	@echo "Targets:"
	@echo "  make lint                 shellcheck + zsh -n + /bin/bash -n + static patterns + python3 -I syntax check"
	@echo "  make test                 unit tests for the repo tooling (tests/*.sh), git's local env vars unset"
	@echo "  make test-env-scrub       static check: test and py-syntax unset git's local env vars first"
	@echo "  make reuse                REUSE 3.3 compliance: every file states its copyright and licence"
	@echo "  make gitleaks             gitleaks' maintained secret rule set over the working directory"
	@echo "  make smoke                fresh-install smoke in a scratch HOME (install + zsh -i + idempotency)"
	@echo "  make secret-scan          high-confidence secret scan over the tracked tree"
	@echo "  make forkgate             prove 'zsh -i -c exit' invokes no external binary"
	@echo "  make linkcheck            every relative link and #anchor in the tracked docs resolves (no network)"
	@echo "  make commit-identity      no user.email or user.name set inside this repository's own git config"
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
	  for f in $(TEST_FILES) $(TEST_LIB_FILES); do echo "/bin/bash -n $$f"; /bin/bash -n "$$f" || exit 1; done; \
	else echo "/bin/bash -n tests: no test files yet, skipping"; fi
	@if [ -n "$(strip $(ZSH_FILES))" ]; then \
	  for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || exit 1; done; \
	else echo "zsh -n: no .zsh files yet, skipping"; fi

# Static-pattern checks - forbid runtime fetches piped into a shell (curl or
# wget into sh), ad-hoc `uname -m` outside lib/os.sh (all arch
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
#   caught before its first commit too. git's local env vars are unset first
#   ($(GIT_ENV_SCRUB), see below): a leaked GIT_WORK_TREE would scan another
#   tree, and a leaked GIT_DIR would pin the toplevel to the current directory,
#   bringing back the subset scan described next. The scan is anchored to the
#   TOPLEVEL of the checkout that holds the current directory, never the
#   directory itself: `git ls-files` lists only the current subtree, so a run
#   from a subdirectory would otherwise check a subset and pass. `-z` + a
#   NUL-delimited read on the PYTHON side (never a shell word-list) is
#   load-bearing: a shell-word file list breaks open on a space or a newline in
#   a filename - either splits it into two argv entries that resolve to
#   DIFFERENT files, one of which can be an attacker-controlled decoy the real,
#   broken file's name never named. Both git calls write to a temp file first
#   (never the LEFT side of a pipe into python3), so their exit status is
#   checked directly instead of being hidden behind the pipe; their STDERR is
#   captured too and fails closed on its own - git exits 0 and only warns (e.g.
#   "could not open directory") when an unreadable subdirectory silently drops
#   files from the listing, so a clean exit status alone is not enough.
#   `rev-parse` must print exactly three lines (toplevel, git dir, common git
#   dir): a newline inside one of those paths shifts them, so anything else
#   fails closed. `--path-format=absolute` needs git 2.31 or later. An older git
#   does NOT reject it: it echoes the unknown option back as an extra first line
#   and exits 0 with an empty stderr (measured on 2.53 with an unknown option of
#   the same shape), so only that line-count check fails it closed, and the
#   ERROR text names the version. A git failure (or warning) fails closed
#   unconditionally - that is a broken invocation, never an absent-tool skip.
#   `-I` (isolated mode, see tests/release_workflow_check.py) drops the current
#   directory from sys.path; the builtin `compile()`, not the py_compile module,
#   never writes a __pycache__/*.pyc for the files it checks, nor for itself
#   (only an IMPORTED module gets bytecode-cached, and this script imports only
#   os, stat and sys). Every listed path must pass, in order, before a byte of
#   it is read:
#   - `os.stat` (follows symlinks) must succeed: a dangling symlink, or a file
#     listed but deleted since, fails with `OSError.strerror`, never a
#     traceback;
#   - it must be a REGULAR file, so a tracked symlink to a device node or a FIFO
#     is rejected without being opened: /dev/zero reads forever, and opening a
#     FIFO blocks until a writer appears, which is never;
#   - its `os.path.realpath` must stay under the toplevel, so a tracked symlink
#     to e.g. /etc/passwd is not read transparently;
#   - it must not resolve into a git directory: not through a `.git` path
#     component (compared case-folded, since APFS resolves `.GIT` to `.git`),
#     which also covers a nested repository's, and not into the git dir or the
#     common git dir `rev-parse` named, compared by device and inode so a
#     case-variant or a separate git dir under another name still matches, and
#     not into any directory shaped like a git dir (HEAD plus objects/ and
#     refs/, or HEAD plus a commondir file): a nested repository whose `.git` is
#     a gitfile keeps its git dir under any name, and a tracked symlink can
#     point into it. The shape mirrors git's is_git_directory(); its commondir
#     branch is redundant today, since a linked worktree's admin dir sits under
#     <common>/worktrees/, which the common-dir match already refuses, and is
#     kept so the shape stays git's. Those hold config, hooks and objects, which
#     the gate has no business reading or reporting on;
#   - it must be at most PY_SYNTAX_MAX_BYTES by `st_size`.
#   The checks above ran on names; the path can be swapped (to a FIFO, a device,
#   a symlink out of the tree) before it is opened. So the resolved path is
#   opened O_NONBLOCK (a FIFO open returns at once instead of blocking) and
#   O_NOFOLLOW (a final component swapped to a symlink fails), and the open
#   descriptor must still be a regular file with the device and inode the stat
#   saw; only then is it read, at most one byte past the cap, and a longer read
#   is refused. That bounds the read. It does not make the checks atomic: a
#   directory above the file swapped between the realpath and the open is caught
#   only by the device/inode match. No fixture can stage that race, so
#   O_NONBLOCK, O_NOFOLLOW and the device/inode match are backed by this
#   reasoning plus a static pin in tests/py_syntax_test.sh, not by a behavioural
#   test. A read error (EIO) fails closed like an open error, with the OS
#   message. `compile()` then reports a NUL byte in the source as SyntaxError on
#   Python 3.12 and later but as ValueError on 3.11 and earlier (the 3.12 parser
#   change), so both are caught; any other exception it raises on hostile input
#   (RecursionError, MemoryError) is reported the same way, naming its type,
#   instead of a raw traceback. Python 3.9-safe (no 3.10+ syntax). Both mktemp
#   files are cleaned up by a trap on INT/TERM/EXIT. STRICT semantics otherwise
#   match the shellcheck block.
PY_SYNTAX_MAX_BYTES := 1048576
# GIT_ENV_SCRUB - unset git's local env vars in a recipe, before its first git
#   call or suite. A git hook or a `git rebase --exec` running `make` leaks
#   GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE into every recipe. The list comes
#   from `git rev-parse --local-env-vars`, so it tracks the installed git; an
#   empty or failed answer, or one without GIT_DIR and GIT_INDEX_FILE, would
#   strip nothing, so it fails closed instead (the rule bin/check-patterns
#   applies to its own git calls). Expands to one shell list ending in `;`: use
#   it as `$(GIT_ENV_SCRUB) \` at the start of a recipe line. `test-env-scrub`
#   holds this definition and its users to that shape;
#   tests/make_test_env_scrub_test.sh and tests/py_syntax_test.sh prove the
#   behaviour.
GIT_ENV_SCRUB = lev="$$(git rev-parse --local-env-vars)" \
	  || { echo "ERROR: 'git rev-parse --local-env-vars' failed - cannot scrub git's env vars, failing closed" >&2; exit 1; }; \
	{ printf '%s\n' "$$lev" | grep -qx GIT_DIR && printf '%s\n' "$$lev" | grep -qx GIT_INDEX_FILE; } \
	  || { echo "ERROR: 'git rev-parse --local-env-vars' did not list GIT_DIR and GIT_INDEX_FILE - failing closed" >&2; exit 1; }; \
	unset $$lev \
	  || { echo "ERROR: could not unset git's local env vars - failing closed" >&2; exit 1; };
py-syntax:
	@$(GIT_ENV_SCRUB) \
	py_list="$$(mktemp "$${TMPDIR:-/tmp}/py-syntax-list.XXXXXX")" || { echo "ERROR: mktemp failed - failing closed" >&2; exit 1; }; \
	err_list="$$(mktemp "$${TMPDIR:-/tmp}/py-syntax-err.XXXXXX")" || { rm -f "$$py_list"; echo "ERROR: mktemp failed - failing closed" >&2; exit 1; }; \
	trap 'rm -f "$$py_list" "$$err_list"' INT TERM EXIT; \
	git rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir > "$$py_list" 2>"$$err_list"; \
	rc=$$?; \
	top=""; git_dir=""; common_dir=""; extra=""; \
	{ IFS= read -r top; IFS= read -r git_dir; IFS= read -r common_dir; IFS= read -r extra; } < "$$py_list"; \
	if [ "$$rc" -ne 0 ] || [ -s "$$err_list" ] || [ -z "$$top" ] || [ -z "$$git_dir" ] || [ -z "$$common_dir" ] || [ -n "$$extra" ]; then \
	  echo "ERROR: 'git rev-parse' could not name the checkout's toplevel and git dirs (exit $$rc; needs git 2.31 or later) - failing closed" >&2; \
	  cat "$$err_list" >&2; \
	  exit 1; \
	fi; \
	git -C "$$top" ls-files -z --cached --others --exclude-standard -- '*.py' > "$$py_list" 2>"$$err_list"; \
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
	      'root = os.path.realpath(sys.argv[1])' \
	      'cap = int(sys.argv[2])' \
	      'deny = set()' \
	      'for d in sys.argv[3:]:' \
	      '    try:' \
	      '        s = os.stat(d)' \
	      '    except OSError as e:' \
	      '        print(f"{d}: git dir unreadable ({e.strerror}) - failing closed", file=sys.stderr)' \
	      '        sys.exit(1)' \
	      '    deny.add((s.st_dev, s.st_ino))' \
	      'def git_dir_shaped(p):' \
	      '    j = os.path.join' \
	      '    if not os.path.isfile(j(p, "HEAD")):' \
	      '        return False' \
	      '    return (os.path.isdir(j(p, "objects")) and os.path.isdir(j(p, "refs"))) or os.path.isfile(j(p, "commondir"))' \
	      'def in_git_dir(real):' \
	      '    if any(c.casefold() == ".git" for c in os.path.relpath(real, root).split(os.sep)):' \
	      '        return True' \
	      '    p = real' \
	      '    while True:' \
	      '        try:' \
	      '            s = os.stat(p)' \
	      '        except OSError:' \
	      '            return True' \
	      '        if (s.st_dev, s.st_ino) in deny or (p != real and git_dir_shaped(p)):' \
	      '            return True' \
	      '        if p == root:' \
	      '            return False' \
	      '        p = os.path.dirname(p)' \
	      'bad = 0' \
	      'for f in sys.stdin.buffer.read().split(b"\0")[:-1]:' \
	      '    f = f.decode(sys.getfilesystemencoding(), "surrogateescape")' \
	      '    path = os.path.join(root, f)' \
	      '    try:' \
	      '        st = os.stat(path)' \
	      '    except OSError as e:' \
	      '        print(f"{f}: {e.strerror}", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    if not stat.S_ISREG(st.st_mode):' \
	      '        print(f"{f}: not a regular file - refusing to read", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    real = os.path.realpath(path)' \
	      '    if real != root and not real.startswith(root + os.sep):' \
	      '        print(f"{f}: resolves outside the repository root - refusing to read", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    if in_git_dir(real):' \
	      '        print(f"{f}: resolves into a git directory - refusing to read", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    if st.st_size > cap:' \
	      '        print(f"{f}: larger than {cap} bytes - refusing to read", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    try:' \
	      '        fd = os.open(real, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)' \
	      '    except OSError as e:' \
	      '        print(f"{f}: {e.strerror}", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    with os.fdopen(fd, "rb") as fh:' \
	      '        fst = os.fstat(fh.fileno())' \
	      '        if not stat.S_ISREG(fst.st_mode) or (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):' \
	      '            print(f"{f}: changed between the checks and the open - refusing to read", file=sys.stderr)' \
	      '            bad = 1' \
	      '            continue' \
	      '        try:' \
	      '            src = fh.read(cap + 1)' \
	      '        except OSError as e:' \
	      '            print(f"{f}: {e.strerror}", file=sys.stderr)' \
	      '            bad = 1' \
	      '            continue' \
	      '    if len(src) > cap:' \
	      '        print(f"{f}: larger than {cap} bytes - refusing to read", file=sys.stderr)' \
	      '        bad = 1' \
	      '        continue' \
	      '    try:' \
	      '        compile(src, f, "exec")' \
	      '    except (SyntaxError, ValueError) as e:' \
	      '        print(f"{f}: {e}", file=sys.stderr)' \
	      '        bad = 1' \
	      '    except Exception as e:' \
	      '        print(f"{f}: {type(e).__name__}: {e}", file=sys.stderr)' \
	      '        bad = 1' \
	      'sys.exit(bad)') "$$top" '$(PY_SYNTAX_MAX_BYTES)' "$$git_dir" "$$common_dir" < "$$py_list"; \
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
# Every suite runs with git's local env vars unset ($(GIT_ENV_SCRUB), defined above
# py-syntax): a leaked GIT_DIR, GIT_WORK_TREE or GIT_INDEX_FILE would otherwise steer
# each suite's own fixture `git` calls at THAT repository, committing or configuring
# into it.
test:
	@if [ -n "$(strip $(TEST_FILES))" ]; then \
	  $(GIT_ENV_SCRUB) \
	  failed=""; ran=0; \
	  for t in $(TEST_FILES); do echo "run $$t"; ran=$$((ran+1)); bash "$$t" || failed="$$failed $$t"; done; \
	  if [ -n "$$failed" ]; then echo "test: FAILED:$$failed" >&2; exit 1; fi; \
	  echo "test: all $$ran test files passed"; \
	else echo "test: no tests found"; fi

# Static tripwire for GIT_ENV_SCRUB: its definition must ask git for the local env
#   vars, fail closed unless GIT_DIR and GIT_INDEX_FILE are listed, and then run
#   `unset $$lev` as a command (at the start of its line, so `: unset $$lev` fails);
#   and each recipe that must be scrubbed (`test`, `py-syntax`) must expand it BEFORE
#   its first git call or suite loop. It reads this Makefile's own text ($(SELF), so
#   `make -f <copy>` checks the copy), which lets tests/make_test_env_scrub_test.sh
#   prove each check against a mutated copy. A static check proves the shape only; the
#   behaviour is proven by running the recipes under a leaked GIT_DIR (that file and
#   tests/py_syntax_test.sh).
test-env-scrub:
	@def="$$(awk '/^GIT_ENV_SCRUB =/{p=1} p{print; if ($$0 !~ /\\$$/) exit}' '$(SELF)')"; \
	if [ -z "$$def" ]; then echo "ERROR: test-env-scrub: no GIT_ENV_SCRUB definition in $(SELF) - failing closed" >&2; exit 1; fi; \
	for pat in 'lev="$$$$(git rev-parse --local-env-vars)"' 'grep -qx GIT_DIR' 'grep -qx GIT_INDEX_FILE'; do \
	  printf '%s\n' "$$def" | grep -qF -- "$$pat" \
	    || { echo "ERROR: test-env-scrub: GIT_ENV_SCRUB must contain '$$pat'" >&2; exit 1; }; \
	done; \
	lev_n="$$(printf '%s\n' "$$def" | grep -nF 'git rev-parse --local-env-vars' | head -n 1 | cut -d: -f1)"; \
	unset_n="$$(printf '%s\n' "$$def" | grep -nE '^[[:space:]]*unset \$$\$$lev( |$$)' | head -n 1 | cut -d: -f1)"; \
	if [ -z "$$unset_n" ] || [ "$$unset_n" -le "$$lev_n" ]; then \
	  echo "ERROR: test-env-scrub: GIT_ENV_SCRUB must run 'unset \$$\$$lev' as a command, after asking git for the list" >&2; exit 1; \
	fi; \
	for target in test py-syntax; do \
	  recipe="$$(awk -v t="$$target:" 'index($$0, t) == 1 {p=1; next} p && !/^\t/{p=0} p' '$(SELF)')"; \
	  if [ -z "$$recipe" ]; then echo "ERROR: test-env-scrub: no '$$target' recipe in $(SELF) - failing closed" >&2; exit 1; fi; \
	  use_n="$$(printf '%s\n' "$$recipe" | grep -nF '$$(GIT_ENV_SCRUB)' | head -n 1 | cut -d: -f1)"; \
	  first_n="$$(printf '%s\n' "$$recipe" | grep -nE 'git |for t in' | head -n 1 | cut -d: -f1)"; \
	  if [ -z "$$use_n" ] || [ -z "$$first_n" ] || [ "$$use_n" -ge "$$first_n" ]; then \
	    echo "ERROR: test-env-scrub: the '$$target' recipe must expand \$$(GIT_ENV_SCRUB) before its first git call or suite loop, or a leaked GIT_DIR steers it" >&2; \
	    exit 1; \
	  fi; \
	done; \
	echo "test-env-scrub: GIT_ENV_SCRUB is well formed and runs first in the 'test' and 'py-syntax' recipes"

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

# Link check over the tracked docs - every relative link, image, reference
#   definition and #anchor in a tracked *.md file (and every absolute link back
#   into this repository, the issue-form YAML included) resolves against the
#   TRACKED tree under GitHub's heading-slug rule. No network, so the answer
#   depends only on the tree. The logic lives in tests/linkcheck.py, not bin/:
#   lib/link.sh links every bin/* file onto the user's PATH except a hand-kept
#   list of dev gates, and growing that list is a link-convention change. It
#   runs under `python3 -I` (no current directory on sys.path) with git's local
#   env vars unset first ($(GIT_ENV_SCRUB)), so a GIT_DIR leaked from a hook
#   cannot point its `git ls-files` at another tree. The script exits 2 on any
#   error of its own, never 0. STRICT semantics match the py-syntax block.
linkcheck:
	@$(GIT_ENV_SCRUB) \
	if command -v python3 >/dev/null 2>&1; then \
	  echo "python3 -I tests/linkcheck.py"; python3 -I tests/linkcheck.py .; \
	elif [ -n "$(STRICT)" ]; then \
	  echo "ERROR: python3 not installed and STRICT=1 - failing closed" >&2; exit 1; \
	else \
	  echo "WARN: python3 not installed - skipping (set STRICT=1 to fail; CI enforces it)"; \
	fi

# Commit identity - refuse a user.email or user.name set at git config scope
#   `local` or `worktree` in this repository: the one place a stray
#   `git config user.email` inside a linked worktree lands, from where every
#   worktree commits under it. The rule lives in .githooks/commit_identity.py,
#   shared with the pre-commit and pre-push hooks there, so the gate and the
#   hooks cannot disagree. A CI checkout sets no user.* in its repository, so
#   the gate passes there; it bites on a developer's checkout, before a push.
#   git's local env vars are unset first ($(GIT_ENV_SCRUB)): a GIT_DIR leaked
#   from a hook would point the check at another repository. stdin is
#   /dev/null because the `check` mode never reads it. STRICT semantics match
#   the linkcheck block.
commit-identity:
	@$(GIT_ENV_SCRUB) \
	if command -v python3 >/dev/null 2>&1; then \
	  echo "python3 -I .githooks/commit_identity.py check"; python3 -I .githooks/commit_identity.py check </dev/null; \
	elif [ -n "$(STRICT)" ]; then \
	  echo "ERROR: python3 not installed and STRICT=1 - failing closed" >&2; exit 1; \
	else \
	  echo "WARN: python3 not installed - skipping (set STRICT=1 to fail; CI enforces it)"; \
	fi

# Run every locally-runnable CI gate and report which OS-specific
#   or not-yet-implemented legs were skipped. `smoke` runs a full scratch-HOME
#   install + interactive zsh, so it is locally runnable and gates here.
local-ci: lint test-env-scrub test reuse gitleaks secret-scan smoke forkgate linkcheck commit-identity
	@echo "----------------------------------------------------------------"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "local-ci: PASS lint (shellcheck + zsh -n + patterns + py-syntax) + test-env-scrub + test + secret-scan + smoke + forkgate + linkcheck + commit-identity"; \
	else \
	  echo "local-ci: PASS lint (zsh -n + patterns + py-syntax) + test-env-scrub + test + secret-scan + smoke + forkgate + linkcheck + commit-identity"; \
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
