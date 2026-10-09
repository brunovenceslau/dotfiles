<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Development

How to change this repository safely: the gates, what each one proves, and the
rules that are not negotiable.

Audience: whoever edits the framework. The install at `~/.config/dotfiles` is
also the development workspace, so an edit there is live in the next shell.

The page runs from reference to procedure: prerequisites and the gates first
(what each one proves), then CI, then the rules and the changes that need a
maintainer decision, and last the step-by-step recipes for common changes.

- [Prerequisites](#prerequisites)
- [The gates](#the-gates)
  - [What `make check-patterns` checks](#what-make-check-patterns-checks)
  - [The two secret scanners](#the-two-secret-scanners)
  - [`STRICT=1`](#strict1)
  - [What `make smoke` does](#what-make-smoke-does)
  - [What `make forkgate` does](#what-make-forkgate-does)
  - [What `make linkcheck` checks](#what-make-linkcheck-checks)
- [CI](#ci)
  - [Repository settings](#repository-settings)
  - [When a runner image is retired](#when-a-runner-image-is-retired)
- [Hard rules](#hard-rules)
- [Ask before doing any of these](#ask-before-doing-any-of-these)
- [Common changes](#common-changes)
  - [Add a config for a new program](#add-a-config-for-a-new-program)
  - [Add a `.local` layer to a surface](#add-a-local-layer-to-a-surface)
  - [Bump a plugin pin](#bump-a-plugin-pin)
  - [Add a gh extension](#add-a-gh-extension)
  - [Change something on the upgrade path](#change-something-on-the-upgrade-path)
  - [Change the identity step](#change-the-identity-step)
- [Deferred decisions](#deferred-decisions)
- [Landing a change](#landing-a-change)
- [Cutting a release](#cutting-a-release)
  - [Which number to bump](#which-number-to-bump)

## Prerequisites

- macOS, Apple Silicon or Intel. `install.sh` and `lib/` target bash 3.2, the
  version macOS ships. Linux is not a supported platform: the installer still
  creates the links there, but CI runs only on macOS (see
  [Who this is for](../README.md#who-this-is-for)).
- Xcode Command Line Tools, for git and the compiler toolchain:
  `xcode-select --install`.
- The tools the gates need: `make`, `shellcheck`, `zsh`, `tmux`, `fzf`, `jq`,
  `xz`.
  These are the exact names CI's "Ensure gate tools" step installs, so a tool
  missing from this list is a tool CI cannot provision either.
- `python3` with the `pyyaml` module, pinned to `6.0.3`. CI's image ships
  `python3` already; if `python3 -c 'import yaml'` fails on your machine,
  install the pinned, hash-checked version with
  `python3 -m pip install --break-system-packages --require-hashes -r .github/ci-requirements.txt`.
- `reuse` and `gitleaks`, the licensing and secret-scanning gates. `reuse`
  needs a module that can detect file encodings, and the homebrew-core formula
  installs it as the `reuse[charset-normalizer]` extra. Install it another way
  and you have to ask for that extra yourself
  (`pipx install 'reuse[charset-normalizer]'`), or every `reuse` invocation
  fails before it reads a file.
- git 2.31 or later. The smoke and its tests use
  `git rev-parse --path-format=absolute`, which older versions lack.
- For `tests/host_identity_test.sh`: `ssh-keygen`, `ssh-agent` and `ssh-add`
  (OpenSSH, which macOS ships), and time zone data for `python3`. The suite
  checks its matcher against `ssh-keygen` in `Asia/Tokyo`,
  `America/Los_Angeles` and `Europe/Berlin`, and fails when `python3` reads
  any of them as UTC (on a minimal Linux image, install `tzdata`). Under
  `STRICT=1` a missing OpenSSH tool fails the suite.
- The plugin submodules. Clone with `--recurse-submodules`, or run
  `git submodule update --init` once in an existing checkout. `make test`,
  `make smoke` and `make forkgate` never initialize them for you. Without them,
  `tests/startup_fork_gate_test.sh` and `make forkgate` fail, and every
  `make smoke` run fetches the plugins over the network into its disposable copy
  unless another local checkout already holds them.

One line covers the Homebrew-installable prerequisites:

```sh
brew install shellcheck zsh tmux fzf jq xz reuse gitleaks
```

Once a tool is missing, `STRICT=1` decides what happens: unset, a gate skips
it with a warning and still exits 0; set, the same gate fails instead of
skipping, so CI (which always sets it) can never report green on a check it
did not run. See "`STRICT=1`" below for the full rule.

## The gates

Every gate is a `make` target. CI only ever calls `make`, so local and CI stay
in parity by construction. Run `make local-ci` before every push.

| Target | What it runs | What it proves |
| --- | --- | --- |
| `make lint` | shellcheck over `install.sh`, `lib/*.sh`, `bin/`; `/bin/bash -n` over `install.sh`, `lib/` and `tests/`; `zsh -n` over `zsh/zshenv`, `zsh/zshrc` and `zsh/*.zsh`; plus `check-patterns` and `py-syntax` | The shell surface parses and passes static analysis. The `/bin/bash -n` pass uses the absolute path, which on the macOS runners is the real bash 3.2. The `zsh -n` glob is one level deep, so the pinned submodules under `zsh/plugins/` are not parsed. |
| `make check-patterns` | `bin/check-patterns` | No `curl` or `wget` download is piped, substituted or process-substituted into a shell on the same line (see the rule for its limits), and the shell, config and prose surfaces keep the portability, safety and house-style rules listed in [What `make check-patterns` checks](#what-make-check-patterns-checks). |
| `make py-syntax` | `compile()` over every tracked and untracked-but-not-ignored `.py` file in the whole checkout, from whichever subdirectory it runs, with git's local environment variables unset | Every `.py` file parses, without writing a `__pycache__`. A listed path must be a regular file (never a symlink to a device node or a FIFO), must resolve under the checkout's toplevel and not into a git directory (the checkout's `.git`, a nested repository's, a separate git dir, or any directory shaped like one), and must be at most 1 MiB (`PY_SYNTAX_MAX_BYTES`); anything else is refused before it is read. The file is then opened without following a final symlink and without blocking, and must still be the same regular file. A `GIT_DIR` or `GIT_WORK_TREE` inherited from a git hook cannot point the scan at another tree or shrink it to a subdirectory. Fails closed (not a skip) if `git rev-parse` or `git ls-files` errors OR warns on stderr (e.g. an unreadable directory), or if `git rev-parse --local-env-vars` fails or does not list `GIT_DIR` and `GIT_INDEX_FILE`. Needs git 2.31 or later; an older git fails closed with a message saying so. |
| `make test` | every `tests/*.sh`, with git's local environment variables unset | Unit coverage of the repository's own tooling. Runs all files and reports all failures, rather than stopping at the first. A `GIT_DIR`, `GIT_WORK_TREE` or `GIT_INDEX_FILE` inherited from a git hook cannot steer a suite's own `git` calls at another repository. Fails closed, before any suite runs, if `git rev-parse --local-env-vars` fails or does not list `GIT_DIR` and `GIT_INDEX_FILE`. |
| `make test-env-scrub` | a static read of the Makefile's `GIT_ENV_SCRUB` and the `test` and `py-syntax` recipes | `GIT_ENV_SCRUB` still asks git for its local environment variables, checks the list and unsets it, and both recipes expand it before their first `git` call or suite loop. `tests/make_test_env_scrub_test.sh` and `tests/py_syntax_test.sh` prove the behaviour itself. |
| `make smoke` | `bin/smoke` | A fresh install into a scratch home works, an interactive shell starts cleanly, a re-run is a no-op, the dev gates are not linked onto `PATH`, and `--purge` leaves no trace except the documented machine-local `~/.config/git/config`. |
| `make secret-scan` | `bin/secret-scan --git .` | No secret-shaped content in the tracked tree. |
| `make gitleaks` | `gitleaks dir .` | The same question asked again, with [gitleaks](https://gitleaks.io/)' maintained rule set, over the working directory as it is on disk. |
| `make forkgate` | `bin/startup-fork-gate` | `zsh -i -c exit` invokes no external binary. |
| `make reuse` | `reuse lint` | Every tracked file states its copyright holder and SPDX licence, and every licence named has its full text in `LICENSES/`. The tree is [REUSE 3.3](https://reuse.software/spec-3.3/) compliant. |
| `make linkcheck` | `python3 -I tests/linkcheck.py`, with git's local environment variables unset | Every relative link, image, reference link and definition, HTML `href` and `src`, and `#anchor` in a tracked Markdown file, and every absolute link back into this repository (the issue-form YAML included), resolves against the tracked tree. No network. See [What `make linkcheck` checks](#what-make-linkcheck-checks). |
| `make commit-identity` | `python3 -I .githooks/commit_identity.py check`, with git's local environment variables unset | No commit identity (`email` or `name` under `user`, `author` or `committer`) is set inside this repository's own git config. See [What `make commit-identity` checks](#what-make-commit-identity-checks). |
| `make local-ci` | lint, test-env-scrub, test, reuse, gitleaks, secret-scan, smoke, forkgate, linkcheck, commit-identity | Everything CI runs. |
| `make repo-settings-check` | `bin/repo-settings-check` | The live GitHub settings match `.github/repo-settings.json`. Not part of `make local-ci` and never run by CI: it reads the live settings with the maintainer's `gh` login. See [Repository settings](#repository-settings). |

`reuse lint` walks what git tracks and does not descend into the pinned plugin
submodules, so their licences are not checked here. They are recorded in
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) instead, with the commit
each one is pinned to.

Three files cannot carry a header: `config/nvim/lazy-lock.json`,
`.claude/settings.json` and `.github/repo-settings.json`, because JSON has no
comment syntax. `REUSE.toml` declares them, and `tests/reuse_gate_test.sh` fails
if a new tracked `.json` file is not declared there. Everything else states its
licence in its own comment syntax. A block copied from an upstream project is
bracketed by `SPDX-SnippetBegin` and `SPDX-SnippetEnd` and repeats that
upstream's licence in place. A whole file that is someone else's work carries
that work's licence in its own header instead: `CODE_OF_CONDUCT.md` is the
Contributor Covenant under `CC-BY-SA-4.0`, which is why `LICENSES/` holds a
fifth licence text.

### What `make check-patterns` checks

Each rule below names what it rejects, and, where it applies to only some
paths, which ones. The rules:

- No `curl` or `wget` download executed on the same line: piped into `sh`,
  `bash`, `zsh`, `ksh` or `dash` (also through `|&`, `sudo` with options, `env`,
  `exec`, a quoted name or a path such as `/bin/bash`), passed as a command
  substitution to `eval` (also `eval --`) or to a shell with a `c` option (`bash
  -lc "$(curl ...)"`, `bash --norc -c "$(curl ...)"`), or fed as a process
  substitution to `source`, `.` or a shell (`bash < <(wget ...)`), also when the
  tool is written `command curl`, `env curl`, `sudo curl`, `\curl` or
  `/usr/bin/curl`. Not caught, among others (the list is illustrative, not
  exhaustive): a download saved and executed on a later line, one passed through
  another command first (`curl ... | tee f | bash`), one fed through a
  here-string or `/dev/stdin`, a fetch behind an assignment, `time` or a brace
  group inside the substitution, a substitution that does not start the `-c`
  string (`sh -c "set -e; $(curl ...)"`), a fetch through an alias or function,
  a shell reached through `xargs` or `nohup`, and fetch tools other than curl
  and wget. This rule reads `install.sh`, `lib/`, `bin/`, `zsh/`, `config/`,
  `packages/`, `security/`, `home/`, the `Makefile`, `.githooks/` and
  `.github/` (a recipe line, a git hook, a workflow `run:` step and a composite
  action's step execute like any other code), never `tests/` (which plants
  real fetch shapes as fixtures), `docs/` or `.claude/`.
- No ad-hoc `uname -m` outside `lib/os.sh`.
- No unescaped `#` inside a Makefile `$(shell ...)`.
- No hardcoded Homebrew prefix and no `brew shellenv` or `brew --prefix` fork.
- No bash 4 syntax in `install.sh` or `lib/`.
- No GNU-only regex escape (`\s`, `\w`, `\b`, BRE `\|`) in the shell surface,
  `.githooks/`, `tests/` and the workflows (this arm's only OTHER exclusions,
  the pinned plugins dir and the script's own name, are content-independent path
  exclusions, not language exemptions; inside `tests/` ONLY, `*.py` files are
  skipped by a fixed extension - the arm's only content-independent LANGUAGE
  exemption, never a marker comment or a parse of what a file contains, because
  Python's own `re` module is a different regex dialect where those escapes are
  portable; `bin/`, `lib/`, `zsh/`, `install.sh`, `.githooks/`, the Makefile and
  the workflows carry no such exemption, since `lib/link.sh`'s `_link_bin_tree`
  links every `bin/*` file onto the live PATH by basename; non-shell code that
  needs the exemption MUST live in its own `.py` file under `tests/`, never a
  `python3 - <<'PY'` heredoc embedded in a `.sh` script - a heredoc is still
  shell-surface text to this arm, which has no notion of an embedded language;
  see `tests/release_workflow_check.py` and its caller
  `tests/release_workflow_test.sh`).
- No early-exit reader (`grep -q`, `-m`, `-l`, `head`) on the right of a pipe in
  the pipefail surface (`install.sh`, `lib/`, `bin/`, `tests/`, the workflows).
- No `--` after the first operand of `chmod`, `chown`, `chgrp`, `cp`, `mv`,
  `ln`, `rm`, `rmdir`, `mkdir`, `touch`, `cat`, `grep`, `egrep`, `fgrep` or
  `sed` in the same surface as the regex rule (not caught: a command written
  `\rm`, behind `env` or `sudo` with options, `coproc`, a `$CMD` variable, `find
  -exec`, `xargs`, an alias or `sh -c '...'` string, or split across `\` lines;
  wrongly flagged: a long option with a separate argument such as `--regexp
  PAT`, a redirection before the `--`, and prose or an unquoted `$(...)`
  argument holding a separator or keyword before a tool name and a later ` -- `,
  such as `"x; rm it by hand -- see docs"`).
- The pinned plugins still have the shapes the startup shims assume.
- No raw `readlink` (or `greadlink`) in `install.sh` or `lib/`: `$(readlink)`
  strips a target's trailing newline and BSD readlink's terminator differs from
  GNU's, so they read a link target only through `lib/link.sh`'s
  `_link_readlink`. The one exempt line is the helper's own `readlink -n` call,
  found at scan time inside the body of the one `_link_readlink() {` in that
  exact file (up to the next exact `}` at column 0; any other column-0 line
  first voids the body), never a line number, so a raw call in another function,
  another shape inside the helper, a same-named function in another file or a
  decoy `lib/sub/link.sh` still fails, and a second definition-shaped line or a
  definition not in that exact form fails the gate closed. The word in a string
  or as a name (`echo "readlink"`) is flagged too.
- No `local`, `typeset`, `declare`, `integer`, `float`, `readonly` or `private`
  without `-g` in an option word (`local` in any form), and no `for`, `foreach`
  or `select` loop variable, of zsh's `path`, `cdpath`, `fpath`, `manpath` or
  `module_path`, or of their scalars `PATH`, `CDPATH`, `FPATH`, `MANPATH` and
  `MODULE_PATH`, under `zsh/`: inside a function the local copy keeps its
  special tie, so assigning it rewrites the command search path for the whole
  call, and a loop variable overwrites the global. A line scanner cannot tell a
  function body from the top level, so a top-level declaration needs the `-g` as
  well; a plain assignment such as `path=(... $path)` and `export` are not
  declarations and pass. Not caught: a name word holding `(`, `)`, `;`, `&` or
  `|` before the name (`local foo=$(pwd) path`), a quoted or escaped name,
  `mailpath`.
- No Unicode em dash (U+2014), the house style set by `CONTRIBUTING.md` and
  `.claude/rules/docs.md` (a plain hyphen instead), checked over `install.sh`,
  `lib/`, `bin/`, `zsh/`, `config/`, `packages/`, `security/`, `home/`, plus
  `docs/`, `tests/`, `.github/`, `.claude/`, the Makefile and the top-level docs
  and metadata files, comments included (unlike the bash-4 and Homebrew-prefix
  rules, a comment does not exempt an em dash, since a comment is prose too);
  `LICENSES/`, `COPYING` and `CODE_OF_CONDUCT.md` are left out of that surface
  entirely as verbatim upstream legal text, and `config/nvim/lazy-lock.json` is
  exempted by its exact scanned path (never a bare suffix, which a decoy file
  elsewhere ending in the same segments could also match), since lazy.nvim
  rewrites it wholesale on every plugin sync. A second, narrow pass separately
  checks `bin/check-patterns`'s own source for the same character, since the
  recursive pass above excludes it by name like every other recursive arm; the
  fetch rule and the `uname -m` rule run the same narrow self-scan, with no
  exemption list: the gate's own source is written so that neither matches it
  (its patterns are assembled from pieces, its prose says "a curl piped into
  sh"), so a line added to it that either rule would flag in another file,
  comment or code, fails there too.
- No Markdown prose line over 80 columns, counted in characters, in any
  `*.md` file on the em-dash rule's surface (so `CODE_OF_CONDUCT.md`, verbatim
  upstream text, is out). Exempt: YAML front matter, fenced code blocks at any
  indent, table rows, headings, link reference definitions, HTML comments,
  lines that open with an HTML tag, and a line holding a single unbreakable
  token once its indent, quote and list markers are set aside. A token runs
  from one space to the next, except that a code span and a whole link or
  image never break, so a long URL, command or link alone on its line passes,
  and the same token sharing its line with other words fails. Every hit is
  therefore fixable by rewrapping the paragraph without changing a word. No
  Markdown file is generated today; a generated one would leave the rule by
  its exact path. A Setext heading's text line, a line inside a multi-line
  HTML block, an indented code block and front matter that never closes are
  read as prose and held to the limit. A TAB is one column, a CR before the LF
  is none, and an awk that miscounts UTF-8 characters fails the gate closed.
- No symlink where a recursive scan reads (`find`, always, over the em-dash
  rule's surface; a recursive scan never follows one it meets while walking a
  directory), plus, when the root has its own `.git`, no tracked symlink and no
  gitlink other than a pinned plugin (`git ls-files -s -z`, repo-wide, no
  pathspec) anywhere in the repository.

#### The pinned plugins directory

Every recursive rule leaves the pinned plugins out by their one exact path,
`zsh/plugins` (unless it is itself a symlink, which is then reported), never by
a directory name at any depth, so a first-party `plugins` directory elsewhere,
such as `config/nvim/lua/plugins/`, is scanned. Since no rule reads
`zsh/plugins/`, anything there but a pinned plugin fails: a direct child that is
not a directory, tracked or not, and, with a `.git`, a tracked entry that is not
a gitlink or a tracked path that lands in `zsh/plugins/` on disk under another
spelling: `zsh/plugins` in another ASCII case, or first two segments that the
filesystem itself resolves to the same directory as `zsh/plugins`, which is how
a case-insensitive filesystem's non-ASCII folding is caught. A symlink directly
under `zsh/` is reported by the symlink rule and never followed by another rule.
A gitlink counts as a pinned plugin only when it is a direct child of
`zsh/plugins/` declared as a `submodule.<name>.path` in `.gitmodules`, not a
hand-kept list.

#### How the gate fails closed

The git pass fails closed when the root has its own `.git` but git is missing,
cannot list its own local environment variables (`git rev-parse
--local-env-vars` fails, or omits `GIT_DIR` or `GIT_INDEX_FILE`), errors,
returns a malformed record, or resolves a toplevel other than the root (a
repository git refuses as dubiously owned included). Of its stderr, only the
`ls-files` listing's fails closed (a `GIT_TRACE*` variable or a `trace2.*`
config key, say); the toplevel probe's is shown only when the probe itself
fails. Git runs inside the root with `core.fsmonitor` forced off, but the root
must still be a checkout you trust.

A file holding a NUL byte anywhere these rules read (the em-dash rule's surface,
`bin/check-patterns` included) fails the gate closed, exit 2: grep reads such a
file as binary, and the rules' earlier `-I` skipped it whole, so one NUL hid
every violation in it. The rules now read every file as text (`-a`), which also
keeps GNU grep in a UTF-8 locale from skipping a file with an invalid byte. The
gate runs in the C locale (`LC_ALL=C`) whatever the caller's: in a UTF-8 locale
GNU grep's `[^|]*` does not match an invalid byte, so a fetch piped into a shell
with a `0xFF` byte in its URL passed.

Every scan error the gate detects (a `grep`, `sed`, `find` or `git` that fails,
the code/comment split and the path-exemption filters included, an unreadable
file, a pinned-plugin file that `STRICT=1` cannot verify) exits 2 as well, never
the 1 of a violation; a filter that cannot run exempts nothing. So does a
command that fails in the main shell where the gate does not check its status:
an `ERR` trap turns what `set -e` would exit with, the failing command's own
status (a `1` that reads as a violation, with no report), into 2. A known
residual: inside a `$(...)`, which does not inherit `set -e`, a failing command
that is not the last one is not seen at all (`v=$(false; echo after)` succeeds);
the gate's own substitutions end in the command whose status matters or check
the earlier ones by hand. The gate also unsets an inherited `GREP_OPTIONS`,
which BSD grep would apply to every call.

#### What the gate prints

Every line the gate prints, on stdout (the fetch rule's hits) or stderr
(everything else, the error text of `find` and `git` included), goes through one
sanitizer, since a hit echoes a file name and a file line from the scanned tree:
each C0 control byte except TAB and LF, DEL, and each UTF-8 encoded C1 control
(U+0080 to U+009F) prints as a visible `\xHH`, and on a line that is not
well-formed UTF-8 (a stray byte, an invalid lead, an overlong form) every byte
0x80 to 0xFF does, a valid character on that line included. A NUL byte in a
tool's error text is dropped. So an OSC 52 clipboard write, a CSI sequence or a
CR in a name or a line cannot reach the terminal. Two residuals: a well-formed
line still sends its UTF-8 continuation bytes, which only an 8-bit, non-UTF-8
terminal would read as C1 controls; and printable characters that reorder or
hide text, such as the bidi override U+202E, are not controls and print as they
are. The sanitizer changes only what is printed, never a rule's outcome, and a
sanitizer failure exits 2.

### The two secret scanners

`make secret-scan` and `make gitleaks` overlap on purpose, and neither replaces
the other.

`bin/secret-scan` is the floor: git and grep, no dependency, a handful of
high-signal shapes. It runs on a machine with nothing installed, which is why it
has no `STRICT` skip. `gitleaks` brings the part a hand-written grep cannot keep
up with, a maintained catalogue of provider token formats plus entropy scoring,
and it is a tool you have to install, so it skips locally and fails closed under
`STRICT=1`.

They also scan different things. `bin/secret-scan --git .` reads what git
tracks. `gitleaks dir .` reads the working directory as it is on disk: an
untracked scratch file is scanned too, which is the point, because that is the
moment before it becomes history. The pinned plugin submodules are in that scope
as well.

Both honour one waiver, the literal `secret-scan:allow` on the offending line -
`bin/secret-scan` natively, `gitleaks` through the allowlist in
`.gitleaks.toml`. Reach for it last. Neither scanner speaks for GitHub's own
push protection, which reads the same bytes on the server and honours no marker
of ours, and a literal that gets that far costs a history rewrite to remove. A
test fixture that needs a real secret shape builds it from fragments at run time
instead; see `tests/secret_scan_test.sh`. No tracked file needs the waiver
today.

### `STRICT=1`

CI runs `make local-ci STRICT=1`, and `make` exports the variable into the test
environment. With it set, a missing tool becomes a hard failure instead of a
skip. Without it, a local run can report green on a gate that never executed.

Run the gates the way CI does before concluding that a change is safe:

```sh
make local-ci STRICT=1
```

A local green can be vacuous. Platform and privilege skips (a case only a given
OS, architecture or root can stage) exit 0 even under `STRICT=1`; a missing
tool fails it. A pass proves what ran, not what was covered. When a particular
suite matters to your change, check that it did not skip.

Where `make` is unavailable, run the same commands it drives:

```sh
bin/check-patterns
shellcheck install.sh lib/*.sh bin/*
/bin/bash -n install.sh lib/*.sh
/bin/bash -n tests/*.sh          # the tests run under bash 3.2 on the macOS legs
zsh -n zsh/zshenv zsh/zshrc zsh/*.zsh
(                                  # py-syntax, abridged; stops on any git error or warning
  set -e
  lev="$(git rev-parse --local-env-vars)"
  printf '%s\n' "$lev" | grep -qx GIT_DIR
  printf '%s\n' "$lev" | grep -qx GIT_INDEX_FILE
  unset $lev
  top="$(git rev-parse --show-toplevel)"; cd "$top"
  py_list="$(mktemp)"; err_list="$(mktemp)"
  trap 'rm -f "$py_list" "$err_list"' EXIT
  git ls-files -z --cached --others --exclude-standard -- '*.py' > "$py_list" 2>"$err_list"
  if [ -s "$err_list" ]; then cat "$err_list" >&2; exit 1; fi
  [ ! -s "$py_list" ] || python3 -I -c 'import os, stat, sys
root = os.path.realpath(".")
for f in sys.stdin.buffer.read().split(b"\0")[:-1]:
    f = f.decode(sys.getfilesystemencoding(), "surrogateescape")
    st = os.stat(f)
    assert stat.S_ISREG(st.st_mode), f"{f}: not a regular file"
    real = os.path.realpath(f)
    assert real.startswith(root + os.sep), f"{f}: outside repo root"
    rel = os.path.relpath(real, root).split(os.sep)
    assert ".git" not in [c.casefold() for c in rel], f"{f}: into a git directory"
    assert st.st_size <= 1048576, f"{f}: larger than 1 MiB"
    compile(open(f, "rb").read(), f, "exec")' < "$py_list"
)
(                                  # make test: git's local env vars unset first
  lev="$(git rev-parse --local-env-vars)" || exit 1
  printf '%s\n' "$lev" | grep -qx GIT_DIR || exit 1
  printf '%s\n' "$lev" | grep -qx GIT_INDEX_FILE || exit 1
  unset $lev
  for t in tests/*.sh; do STRICT=1 bash "$t" || echo "FAILED: $t"; done
)
reuse lint
gitleaks dir . --no-banner --redact
bin/secret-scan --git .
bin/smoke
bin/startup-fork-gate
python3 -I tests/linkcheck.py .
```

### What `make smoke` does

The whole run happens under `.smoke/` inside the repository, which is
gitignored. Nothing is written outside `~/.config/dotfiles`.

When the repository root is the top level of a git checkout, which is the
default, the installer runs against a disposable copy of the working tree under
`.smoke/run/tree`, never against the checkout itself. A smoke run therefore
leaves the checkout's submodules exactly as it found them. The copy borrows the
checkout's objects, and an uninitialized submodule is filled from a local
modules directory when one holds its pinned commit. Only when none does is it
fetched, into the copy, by `install.sh`. A root that is not a checkout's top
level, such as the synthetic fixtures in `tests/smoke_test.sh`, is installed in
place, and the smoke says so.

`--keep` retains the whole scratch tree, the staged copy included. That copy
carries every gitignored file of the working tree, secret-bearing `.local`
files among them, so delete `.smoke/run` once you are done debugging.

1. Create an empty scratch `HOME` under `.smoke/run/home`, before anything is
   staged.
2. Stage the disposable copy of the checkout described above.
3. Plant a pre-existing `~/.zshenv` in the scratch `HOME`, then snapshot its
   pristine state.
4. Run `/bin/bash install.sh`, which on the macOS runners is the real bash 3.2.
5. Assert the core links, one convention link, and a non-empty manifest.
6. Pre-seed the completion stamp, then run `zsh -i -c exit` and require exit 0,
   empty stderr, and a `ZDOTDIR` sentinel that proves this config loaded.
7. Re-run the installer and assert idempotency: a byte-stable manifest, an
   identical set of links, and no new `.bak`. After the first install the only
   `.bak` is the planted `~/.zshenv.bak`.
8. Run `dotfiles-uninstall --purge` through the real user-facing path, and
   require the documented machine-local survivor, `~/.config/git/config`, to be
   a real file rather than a link into the repository.
9. Remove that survivor, then diff the home directory against the pristine
   snapshot. Any difference fails the gate and is printed.

### What `make forkgate` does

Every binary reachable on `PATH` is replaced by a logging shim placed first on
`PATH`. A hermetic `zsh -i -c exit` runs against this repository's zshenv and
zshrc, and the log must be empty. The gate proves its own instrumentation first:
a canary invocation must reach the log, and the measured shell must have
actually loaded the repository zshrc.

Out of scope, explicitly: the `precmd` window. `precmd` never fires under
`zsh -i -c exit`, so first-prompt activity is not measured.

### What `make linkcheck` checks

`tests/linkcheck.py` reads what git tracks, never a directory walk: every
`*.md` file, plus the issue-form YAML under `.github/ISSUE_TEMPLATE/`. A
tracked symlink is skipped, never followed. The script lives under `tests/`
rather than `bin/` because the installer links every `bin/` tool onto the
user's `PATH` except a fixed list of gates, and growing that list is a
link-convention change.

- The target of an inline link, an image, a reference definition, and the
  `href` or `src` of an HTML `<a>` or `<img>` tag must name a tracked file, or
  a directory holding one, inside the repository. A file that exists only on
  your machine (a gitignored `.local` file) fails, because GitHub renders the
  tracked tree, and so does a path that differs from the tracked one only in
  case. A root-absolute path (`/docs/x.md`) fails too. A `?query` is dropped
  before resolving.
- A full or collapsed reference link (`[text][ref]`, `[text][]`) must have a
  definition in the same file. A backslash-escaped bracket (`\]`) does not
  end link text or a label, and neither crosses a blank line. A definition
  may put its destination on the next line, and is no definition when
  anything but a title follows its destination. A shortcut `[ref]` is not
  checked, since it cannot be told apart from bracketed prose.
- An `#anchor` into a Markdown file must match a heading under GitHub's slug
  rule: the rendered text, lowercased, with punctuation dropped and each space
  turned into `-`. Text inside a code span is kept as written, so
  `` `_link_bin_tree` `` keeps its underscores. A repeated heading is numbered
  `-1`, `-2` in order, the way github-slugger numbers it. An explicit
  anchor counts too: the `id` or `name` of an `<a>` tag. An anchor into any
  other file, such as a `#L10` line anchor, is not checked.
- A `https://github.com/brunovenceslau/dotfiles/blob/main/...` link is resolved
  against the local tree the same way.
- Front matter, fenced code blocks and HTML comments (both running to the end
  of the file when never closed, as GitHub renders them), indented code blocks
  and inline code spans are not prose, so a link inside one is ignored. Front
  matter that never closes is prose, since GitHub renders its `---` as a rule.
  An HTML `href` or `src` may be double-quoted, single-quoted or bare. A
  tag is read much the way GitHub's HTML5 parser reads an HTML block, since
  a link it renders is live: an attribute may follow a quoted value with no
  space, a name may open with a digit, a `>` inside a quoted attribute value
  does not end the tag, and one that crosses a blank line is text. Three
  shapes HTML5 reads as live links are known misses: `<a/href="t.md">`,
  `<a =x href="t.md">` and `<a x<y href="t.md">`. A link whose text wraps
  across lines is still found, and a CRLF file reads exactly like its LF
  twin. A link destination ends at ASCII whitespace only, may hold
  balanced parentheses (up to 3 levels deep), backslash escapes and
  character references such as `&amp;`, or be written `<...>` with spaces,
  and its title may be double- or single-quoted or in parentheses, holding
  its own delimiter escaped. Neither has a length limit. Every other URL
  scheme is out of scope, since the gate never touches the network.

It exits 1 on a broken link, printing `FILE:LINE: reason: target` with control
bytes escaped as `\xHH` and the characters that reorder or hide text (bidi
controls, zero-width characters, the soft hyphen) as `\uHHHH`, and the tag
characters (U+E0000 to U+E007F) as `\UHHHHHHHH`. It
exits 2 when it cannot run: the root is not a checkout's toplevel, git fails
or warns, or a file is unreadable, not UTF-8, or reached through a symlink
swapped into the working tree.
`tests/linkcheck_test.sh` proves each rule against a fixture.

### What `make commit-identity` checks

A commit identity belongs in the global config. The check refuses an `email`
or `name` under `user`, `author` or `committer` set at git config scope
`local` (the repository's `.git/config`, or a file it includes) or `worktree`
(a `config.worktree`, when `extensions.worktreeConfig` is on). A
`git config user.email` run inside a linked worktree writes the shared
`.git/config`, so every worktree of the repository then commits under it:
signed by the right key, authored by the wrong person. `author.*` and
`committer.*` count because they set the identity too: a repository-scoped
`author.email` wins even over `git -c user.email=...`.

These stay allowed: `git -c user.email=... -c user.name=...` per command
(scope `command`, which `GIT_CONFIG_COUNT` also sets), the `GIT_AUTHOR_*` and
`GIT_COMMITTER_*` variables, and the global and system scopes. The check
reads config only. It does not look at signatures or keys.

A refusal prints one line per offending key, naming the key, its value, the
scope and the file, and the command that removes it, then one line pointing
at `git -c`:

```text
commit-identity: check: refusing: user.email 'a@b' is set at scope local in '/path/.git/config'; fix: git config --file '/path/.git/config' --unset-all user.email
```

Control characters, bidi and zero-width characters, and the code points a
terminal shows as blank (a Hangul filler, the braille blank), in a value or
a path print as `\xHH`, `\uHHHH` or `\UHHHHHHHH`, and a backslash as `\\`,
so a value cannot forge a line. A value and a file print the same way: in
single quotes, with a quote inside spelled `\x27`, so a path holding its own
`; fix:` stays inside its quotes and cannot pass for a second fix. When that
spelling changes a path, the fix names the key to remove from that file
instead of a command, which would name another file. It exits 2 when it
cannot answer: outside a repository, on a config git refuses to parse, or on
a wrong argument.

The same rule runs as two git hooks, `.githooks/pre-commit` and
`.githooks/pre-push`, which run `.githooks/commit_identity.py`. `pre-push`
matters because a rebase or a cherry-pick commits without running
`pre-commit`.

`pre-push` also compares each commit the push sends with the effective
identity, the one `git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT`
print at push time (so a `git -c user.email=...` on the push counts). A
commit whose author or committer email differs is refused, one line per
email, naming the commit:

```text
commit-identity: pre-push: refusing: commit <oid> has committer email 'a@b', not the effective 'g@x'
```

This catches an identity removed from the config before the push: the
commits made under it still carry it. Emails are compared exactly, case
included, so a case-only difference refuses: that fails closed. The first 20
offending commits in `git rev-list` order (by commit date, newest first) are
named, then one line counts the rest.

The commits compared are those a pushed tip reaches and no remote-tracking
ref and no remote oid on git's stdin reaches. Any ref under `refs/remotes/`
counts, whether or not a remote is configured for it and whichever remote is
pushed to, so a commit fetched from a fork, from a local scratch clone, or
written there by hand is not compared. A commit already fetched from a remote
passes whoever made it, so merging a fetched default branch does not trip on
GitHub's own merge commits; one the remote holds under a ref never fetched
here is still compared. A replace ref (`refs/replace/`) is not followed,
since the push sends the original commit. A deletion sends no commit and
passes without an identity; a push with commits to compare and no effective
identity exits 2. A push with nothing left to send passes: git still runs
the hook, with an empty pipe on stdin. A stdin that is not a pipe (closed,
or `/dev/null`), which `git push` never gives, a pushed object this
repository lacks (a full object name as the source, which git hands the hook
before it looks it up), and a pushed commit whose raw headers hold a NUL or
not exactly one `author` and one `committer` header (built by hand: git's
own readers disagree on which one counts) exit 2. While a config refusal
stands, the commits are not compared, since the effective identity is then
the one being refused.

A foreign author is refused on purpose: a cherry-pick that keeps someone
else's authorship, or their merge, does not match the effective identity.
Re-make a commit of yours with `git commit --amend --no-edit --reset-author`;
push a commit made by someone else, once reviewed, with
`git push --no-verify` (see [Deferred decisions](#deferred-decisions)).

The hooks run only where something points git at
`.githooks/`: the development sandbox's system dispatcher, which runs
`<toplevel>/.githooks/<hook>` when it is executable. Nothing in this
repository sets `core.hooksPath`, and the installer does not, so on the Mac
the guard runs only as this gate (see
[Deferred decisions](#deferred-decisions)). A CI checkout sets no identity in
its repository, so the gate passes there.
`tests/commit_identity_test.sh` proves each rule in scratch repositories.

The guard catches accidents. It is not an enforcement boundary: a merge, a
rebase or a cherry-pick skips `pre-commit`, a commit already on any remote
this repository tracks is not compared again, and `--no-verify` or a
repository `core.hooksPath` skips both hooks. A crafted push passes too,
harder than `--no-verify`: a refspec source holding an LF splits its line on
the hook's stdin, so its first half can name any commit as one the remote
holds. The backstop on GitHub is the signed-commits rule of the
`main-protection` branch ruleset (see
[Repository settings](#repository-settings)).

## CI

`.github/workflows/ci.yml` is a thin matrix of `make` calls.

| Leg | Runner image | Gate |
| --- | --- | --- |
| `macos-arm64` | `macos-latest` | `make local-ci STRICT=1` |
| `macos-intel` | `macos-15-intel` | `make local-ci STRICT=1` |

Both legs are real hardware of their own architecture. There is no emulation,
because what these legs exercise is exactly the part that emulation would hide:
Homebrew prefix detection, `on_arm` and `on_intel` Brewfile blocks, bash 3.2 and
the BSD toolchain. Intel has no rolling image alias, so that leg names
`macos-15-intel` explicitly. If the image is retired, the leg fails loudly
rather than dropping the coverage.

The workflow checks out submodules recursively, so smoke exercises the real
plugin path. It does not persist credentials on the runner.

Every action is pinned to a full-length commit SHA, with the release tag in a
trailing comment. GitHub enforces this: the repository's Actions settings
require SHA pinning, so a workflow that references an action by tag or branch
fails to run. Dependabot (`.github/dependabot.yml`) proposes the bumps. The gate
tools CI installs log their versions in the "Gate tool versions" step, and
`pyyaml` is installed hash-checked from `.github/ci-requirements.txt`.

Add a new gate as a `make` target first, wire it into `make local-ci`, and only
then expect CI to run it. Do not put gate logic in YAML.

### Repository settings

The GitHub settings the docs rely on are recorded in
`.github/repo-settings.json`: the default branch, merge commits as the only
merge method, `delete_branch_on_merge`, the wiki/projects/discussions off,
private vulnerability reporting and Dependabot alerts on, the Actions
permissions (SHA pinning required, only GitHub-owned actions, read-only
default workflow token), and approval required for workflow runs from every
outside contributor. `.rulesets` is an array, one entry per ruleset this repo
runs: the `main-protection` branch ruleset (signed commits, the required
status checks and their policy, the pull request policy - review count,
thread resolution, allowed merge methods - no force push, no deletion, no
bypass actors) and the `release-tags` tag ruleset (no force push, no
deletion on `refs/tags/v*`). The file is JSON so that both halves of the check
below read it with `jq`, which the gates already require, and compare it
directly with the JSON `gh api` returns.

Two checks hold the file to the rest of the world:

| Check | Runs where | Fails when |
| --- | --- | --- |
| `tests/repo_settings_test.sh` | `make test`, so every pull request, forks included. No network, no token. | A doc sentence that claims a setting is reworded or disagrees with the file, a doc mentions these settings without an anchor in the test, a doc quotes a check name the file does not require, or the required checks differ from the job names `.github/workflows/ci.yml` generates. |
| `make repo-settings-check` | A maintainer's machine, on demand. | Any live setting differs from the file (exit 1), or a setting could not be read (exit 2). |

`make repo-settings-check` prints one row per setting with its status, the
expected value and the live one. Beyond the branch ruleset, it reads the rules
that actually apply to `main` from every source and requires each one to come
from that ruleset, and it requires classic branch protection to be absent, so a
second ruleset or a classic rule cannot add enforcement the file does not state.
A setting is `ok` only when its live value was read and matches. A failed call
or a field the API left out, such as `bypass_actors` for a caller without admin
rights, is `UNREADABLE` and fails the run, so a partial read never passes. It
needs `gh` authenticated as a repository admin and `jq`, and it only issues
`GET` requests.

It is not a pull request gate on purpose. Reading these settings needs an
authenticated token, and a workflow that runs on a pull request from a fork
cannot hold one without exposing it to the fork's code. Several endpoints also
need admin rights that the workflow token does not have.

To change a setting, update `.github/repo-settings.json` and the docs in one
pull request, change the live setting after it merges, and run
`make repo-settings-check` until it passes.

### When a runner image is retired

Naming `macos-15-intel` explicitly is what keeps the Intel leg honest, and it
has one known cost. GitHub retires a numbered image eventually. Both legs are
required status checks on `main`, so from the day the image goes away the Intel
leg fails on every pull request, including the one that would fix it: the fix
changes the image name, and the check that has to pass before it can merge is
the check the dead image makes impossible. Nothing in the repository can break
that cycle, because the requirement lives in the branch ruleset rather than in
the workflow.

Breaking it is the one manual step in this project, and it is deliberately off
the success path:

1. In the repository's branch ruleset for `main`, remove `local-ci
   (macos-intel)` from the required status checks. That is the check name the
   matrix produces: `local-ci (${{ matrix.name }})`.
2. Open and merge the pull request that renames the image to the current Intel
   runner. The arm64 leg still gates it.
   The same pull request renames the check in `.github/repo-settings.json`,
   because `tests/repo_settings_test.sh` holds the file's required checks to the
   job names `ci.yml` generates.
3. Add the required check back under whatever name the renamed leg now reports,
   and run `make repo-settings-check`. Between step 1 and this step it reports
   the missing check as drift, which is expected.

Do not solve it by deleting the Intel leg, and do not solve it by making the
check non-required. The point of the explicit image name is that losing Intel
coverage is a decision someone takes, never something that happens quietly.

## Hard rules

These are not style preferences. Breaking one of them breaks a host.

**Bash 3.2 compatibility** for `install.sh` and `lib/`. No associative arrays,
no `mapfile`, no `${var,,}`. macOS ships bash 3.2 as `/bin/bash`, and the smoke
test invokes the installer through it. Files under `bin/` may use a modern bash,
because they run only on provisioned hosts and CI. `zsh/` targets zsh only.
`make check-patterns` flags all three constructs, on any host, and is their only
gate. The `/bin/bash -n` pass in `make lint` is not a backstop for them:
`declare -A` and `mapfile` are ordinary command invocations, and `${var,,}`
fails when it is expanded, so no bash reports a parse error for any of the
three. That pass covers the syntax bash 3.2 genuinely cannot parse, and only on
the macOS legs where `/bin/bash` is the real 3.2.

**POSIX regex in every `sed`, `grep` and `awk` call.** macOS runs BSD `sed` and
`grep`. GNU's `\s`, `\w`, `\b`, `\<`, `\>` and the BRE operators `\|`, `\+`,
`\?` are extensions that BSD silently reads as something else, so the command
neither matches nor fails. Write `[[:space:]]`, `[[:alnum:]_]`, and `-E` with
`|`, `+`, `?`. A Linux run cannot catch the difference, because Linux has the
GNU tools. `make check-patterns` flags these escapes in code on every host, and
it is their only gate before a Mac runs the suite.

**No early-exit reader on the right of a pipe.** Everything that runs under
`pipefail` (the installer, `bin/`, the tests, the workflow steps) must not pipe
into `grep -q`, `head` or an awk that `exit`s. The reader closes the pipe at its
first answer, the writer can still be mid-output, and its SIGPIPE fails the
pipeline at random, so a passing assertion flakes red and a negated one passes
vacuously. Feed the reader a here-string (`grep -q x <<<"$var"`) or use one
that drains (`sed -n 1p`). `make check-patterns` flags the `grep` and `head`
forms. `bin/check-patterns` itself avoids `<<<` (its re-tests use
`printf | grep -c`): under bash 3.2 a here-string whose temp file cannot be
created returns 1 without running the reader, and a fail-closed gate must not
read that as "no match".

**`--` goes before the first operand.** macOS's tools parse their arguments
with BSD getopt, which stops at the first operand. In `chmod -R go-w -- "$d"`
the mode ends option parsing, so the `--` is read as a file named `--`, and
chmod fails after doing its work. GNU getopt permutes the arguments and skips
the `--` wherever it sits, so a Linux run cannot catch it. Write
`chmod -R -- go-w "$d"` and `grep -q -- "$pat" "$f"`. `make check-patterns`
flags the misplaced form for the common file and text tools.

**The startup path takes no synchronous subprocess and no network.** Guard every
optional tool with `(( $+commands[x] ))`. If an integration ships as
`eval "$(tool init zsh)"`, or its completion as a generator command such as
`canga completion zsh` (canga is an optional external tool,
<https://github.com/brunovenceslau/canga>) or `sbx completion zsh` (`sbx`, the
Docker Sandboxes CLI, is optional too), cache it at install time in
`_cache_shell_inits` and source the cache instead. `make forkgate` catches
violations, but the cached form is the house pattern, not a workaround.

**Never hardcode the Homebrew prefix.** `/opt/homebrew` and `/usr/local` are
distinguished by testing whether the directory exists, never by running
`brew shellenv`. Architecture checks go through `is-arm64` and `is-amd64` in
`lib/os.sh`. An ad-hoc `uname -m` elsewhere fails `make check-patterns`, and so
does a `/opt/homebrew` without `/usr/local` as the adjacent word, or a
`brew shellenv` or bare `brew --prefix` fork. The one allowlisted file is
`config/gnupg/gpg-agent.conf`, which has no variable expansion and needs an
absolute pinentry path.

**Everything XDG.** `~/.zshenv` is the only file the framework puts in `$HOME`.
Back up any user file to `*.bak` before overwriting it.

**Never commit secrets.** `config/rclone` and `config/restic` are gitignored
except for their README and `*.example` files. `make secret-scan` is the
backstop.

**Python only where bash 3.2 cannot do the job, from the standard library.**
`lib/*.py` (today `lib/host_identity.py`) runs on the `python3` the Command
Line Tools ship, so it uses the standard library only and stays Python 3.9
safe: no `match` statement, no `X | Y` type unions.
`tests/host_identity_units.py`, run by `tests/host_identity_test.sh`, parses
it with `feature_version=(3, 9)`.
`install.sh` always runs it as `python3 -I`, which keeps the current
directory and the `PYTHON*` variables out of its module path, and probes that
`python3 -I -c ''` runs first: on a Mac without the Command Line Tools,
`/usr/bin/python3` is a stub.

**`make lint` must be green before every commit, and commits are signed.**

## Ask before doing any of these

The canonical list, with what to do instead, is in
[CONTRIBUTING.md](../CONTRIBUTING.md#ask-before-you-build-any-of-these). The
list below is the maintainer's working copy. An item on either list needs a
maintainer decision; CONTRIBUTING's list is the fuller statement of the
security model.

- Adding a submodule or a binary dependency.
- Any change to the security model: the plugin pinning scheme, the
  fast-syntax-highlighting neutralization, the git config scrubbing on the
  upgrade path, or the fsck settings.
- Changing the link conventions or the exceptions table.
- Running a remote interactive installer, such as the Homebrew bootstrap.
- Writing anything outside `~/.config/dotfiles`.

## Common changes

### Add a config for a new program

Create `config/<prog>/` and put the program's files in it. The convention walker
links the whole directory to `~/.config/<prog>` on the next `./install.sh`. No
code change is needed. Add the formula to `packages/Brewfile` with a comment
naming the config directory it belongs to.

If the program refuses XDG paths, use `home/<file>`, which links to `~/.<file>`.
That directory does not exist yet, and the walker skips it when absent.

If the program writes to its own config file, or keeps secrets there, it needs
an entry in the exceptions table in `lib/link.sh`. That is a link-convention
change, so ask first.

### Add a `.local` layer to a surface

Follow the existing shape: load the tracked file first, then the untracked
companion, guarded on readability and silent when absent. Use an `if` rather
than a bare `[[ ... ]] &&` when the load is the last statement in a file, so the
file's exit status stays 0. Add a `.local.example` template, and list the pair
in the [shell reference](shell-reference.md#local-files).

### Bump a plugin pin

1. Read the upstream diff between the old and new commits. Look specifically for
   source-time `curl`, `wget`, `git fetch` or `/dev/tcp` use, and for anything
   that changes the shapes the startup shims assume.
2. Update the submodule and commit the new pin.
3. Update the plugin table in
   [architecture](architecture.md#plugins-and-the-supply-chain) in the same
   commit. If the table disagrees with `git submodule status`, it is stale and
   must not be trusted.
4. Run `make local-ci STRICT=1`. `bin/check-patterns` verifies the shim
   premises, and `tests/fsyh_fetch_test.sh` covers the download branch.

### Add a gh extension

Add one `owner/repo <pin>` line to `packages/gh-extensions.txt`, where the pin
is a reviewed `vX.Y.Z` release tag. A bare commit SHA is accepted by the
validator but does not resolve for a binary extension, so a tag is the usual
form. Every line is validated before it reaches `gh extension install`: the
`owner/repo` may not start with a dash, dot or slash, and an unpinned line is
dropped.

Pinning to a release tag stops a floating `latest`. It is not the
content-addressed immutability of a submodule, because `gh` downloads a mutable
release asset.

### Change something on the upgrade path

Two constraints apply.

The parent process sourced `lib/` before the merge, so after the merge it holds
the old engine while the tree holds new config. Everything that touches the tree
after the merge must run as a fresh `install.sh` subcommand, never as an
in-process call. The boundary is marked in `install.sh` with `POST-MERGE
BOUNDARY` comments, and the behavior is covered by `tests/upgrade_test.sh`.

A subcommand name is a cross-version interface. The previous release's installer
invokes it on the new tree. Deleting an arm sends that installer to the unknown
command branch, which reports a failed upgrade. Retire a subcommand by making it
a no-op, the way `reseed-settings` is retired.

### Change the identity step

The identity step and `install.sh doctor` live in `lib/host_identity.py`;
`install.sh` only dispatches to it.

1. Change the rule in one place. The behaviour is documented once, in
   [`install.sh identity`](shell-reference.md#installsh-identity) and
   [`install.sh doctor`](shell-reference.md#installsh-doctor); other pages
   link there.
2. Keep each printed message one string literal. `docs/troubleshooting.md`
   and `docs/signing-key.md` quote them, and
   `tests/troubleshooting_messages_test.sh` fails when a quote no longer
   matches the code. Update both pages in the same commit.
3. A new `doctor` check is one `Doctor` method and one `CHECKS` entry. It
   only reads: a tool under a timeout, a file through `read_small_file()`
   (non-blocking, size-capped). It states each problem as one line with its
   fix, and passes `signing=True` only for a problem that matters to signing
   alone, which an opted-out host sees as a note.
4. A change to how the allowed-signers file is read needs a vector in
   `tests/fixtures/allowed_signers/verify-git.txt`.
   `tests/host_identity_test.sh` checks every vector against `ssh-keygen` in
   four time zones, and runs the generated differential leg of
   `tests/host_identity_conformance.py` once.
5. Run `STRICT=1 bash tests/host_identity_test.sh`, then
   `make local-ci STRICT=1`.

## Deferred decisions

Decisions about the test suite and the maintainers' tooling, each kept as it
is until its trigger fires. The ones about the framework's behaviour are in
[architecture](architecture.md#deferred-decisions).

| Decision | Kept for now | Reopen when |
| --- | --- | --- |
| Extend `install.sh doctor` to the framework's other dependencies (gh auth and its scopes, Homebrew, the pinned plugins, and the like) | `doctor` checks the identity and signing path and the tools it uses: git, python3, ssh-keygen, the ssh-agent | A pull request opens that changes `CHECKS` in `lib/host_identity.py`, or a host breaks on one of those dependencies without a `doctor` line naming it |
| Test two identity runs writing `config.local` at once | One writer per run: a temporary file and a rename, and the first `.bak` is never replaced; no concurrency test | A host reports a corrupt `config.local` or a second `.bak` |
| Test the identity step's macOS-only paths on Linux: a case-insensitive APFS spelling of `TMPDIR`, `/var` as a link to `/private/var`, and an execute-only or deleted working directory | The macOS CI legs run `tests/host_identity_test.sh`: every case there runs under the macOS `TMPDIR` in `/var/folders`, a case-insensitive spelling of `TMPDIR` is run there and skipped elsewhere, and an execute-only working directory must either work or give the one refusal for it. A deleted working directory is not tested | The first macOS run of the identity step that reports a refusal, or a macOS CI leg that fails one of these cases |
| Hold the test `.py` files to the Python 3.9 floor, in `tests/host_identity_units.py` and the Makefile `py-syntax` leg | The floor is checked for `lib/host_identity.py` only | A test `.py` file uses syntax newer than 3.9, or CI gains a 3.9 leg |
| Name the `webauthn-sk-ecdsa-sha2-nistp256@openssh.com` spelling of a security key on purpose: add it to `TYPE_ALIASES`, or pin today's behaviour with a test | A line using that name is malformed here, and `keys_named()` finds its key only because the name contains `sk-ecdsa-sha2-nistp256@openssh.com` | The next edit to `keys_named()` |
| Require a minimum `ssh-keygen` version for the conformance vectors | The suite uses the host's `ssh-keygen`. The vector `OK \x0da@x @KEY@` was reported to fail with OpenSSH 9.2 and 9.6 and to pass with 9.7 and later; that report has not been reproduced | A host with `ssh-keygen` 9.6 or older goes red on it, or the macOS CI leg shows it |
| Probe `ssh-keygen -Y sign` and `-Y verify` once, with a named message, before the conformance checks | The suite signs and verifies directly, so a broken `ssh-keygen` fails it without naming the cause | A report of a conformance failure that is empty or a traceback |
| Allow a reviewed foreign-author commit through pre-push without `--no-verify` | Refused, with `--no-verify` as the escape: a foreign author in a push is expected to be rarer here than an accident, and the refusal names the escape | The first legitimate foreign-commit push is refused |
| Count only the pushed remote's refs as already published | Any ref under `refs/remotes/` counts, configured remote or not, so forwarding an upstream's commits to a fork passes | A commit reaches a public remote unchecked through a ref under `refs/remotes/` that is not the pushed remote's: a local repository added as a remote, or a ref written by hand |
| Wire `.githooks/` as git hooks on the Mac (`core.hooksPath`, or a dispatcher like the sandbox's) | Not wired: a hook directory a sandbox can write would then run on the host, outside the sandbox. On the Mac the rule runs only as `make commit-identity` | An identity incident happens on the Mac |
| Generate NUL bytes inside the principals field in the random part of the differential corpus | A NUL in the principals field is covered by fixed lines only: the `a@x,\x00b@y` vectors and the corpus' enumerated NUL positions | The next change to the corpus generator, or a new NUL shape found by hand |

## Landing a change

One change is one branch off `main`. Write the failing test first, then the
implementation, then get the gates green. Review the final diff before opening a
pull request.

A doc that quotes what a command prints is held to that output by a test:
`tests/troubleshooting_messages_test.sh` for
[troubleshooting.md](troubleshooting.md), and `tests/restic_wrappers_test.sh`
for the `usage:` lines that `config/restic/README.md` and
[shell-reference.md](shell-reference.md) quote. A new doc that quotes program
output gets the same kind of test in the same pull request.

Check every API-facing value a doc or a command uses, such as an enum a GitHub
setting accepts, against that API's own reference before it lands.

A change that touches a security surface (the list in
[Ask before doing any of these](#ask-before-doing-any-of-these)) gets an
independent review of its diff before it merges. No gate detects a diff that
weakens a security property. Enforce a security invariant at its call site with
an explicit flag, the way the installer passes `-c fetch.fsckObjects=true` to
its own fetches, rather than inheriting it from a linked config file that a
later change can drop.

A guard that must parse the language it guards pins a literal or executes the
code under a stub. `tests/troubleshooting_messages_test.sh` checks that the
framework messages [troubleshooting.md](troubleshooting.md) and
[signing-key.md](signing-key.md) quote, in the shapes its header lists, still
appear as literal fragments in the code that prints them; the `identity:` and
`doctor:` spans are not checked yet. The "A tar that only WARNS must still fail
the staging" case of `tests/smoke_stage_test.sh` puts a stub `tar` first on
`PATH` instead of reasoning about what tar would do. Never strip comments
before a security grep unless the stripper tokenizes the language (quotes,
heredocs, `$#`/`${#v}`, a `#` inside a word).

Large changes land as a chain of small pull requests. See
[stacked pull requests](stacked-prs.md), which explains why every PR in a stack
targets `main`.

## Cutting a release

A release is a signed tag on a merge commit of `main`. Everything after the tag
push is done by
[`.github/workflows/release.yml`](../.github/workflows/release.yml).

1. Land the change as a pull request against `main` and merge it with the merge
   button.
2. Fetch, then tag that merge commit, signed:

   ```sh
   git fetch origin
   git tag -s v0.2.0 -m v0.2.0 <merge commit>
   ```

3. Push the tag:

   ```sh
   git push origin v0.2.0
   ```

Those two commands are the whole procedure. The tag push starts the release
workflow, which checks out the full history, installs a version-pinned and
sha256-verified `git-cliff`, renders the notes for the commits since the
previous tag (the whole history for the first tag) through
[`cliff.toml`](../cliff.toml), and publishes the release with
`gh release create --verify-tag`, titled `dotfiles vX.Y.Z`. Nothing on the
success path is manual.

Check the merge commit before you push. A tag that is already published is not
something to take back quietly.

The notes are built from conventional-commit subjects, so a subject that does
not follow the convention is left out of them. Merge commits are dropped too:
the branch's own commits carry the content.

There is no tracked `CHANGELOG.md`. The release page is where the notes live,
so the tree has no second copy to drift.

### Which number to bump

The first tag is `v0.1.0`.

A break means one of four things changed: an `install.sh` subcommand, a link
convention, a `.local` surface, or a documented variable.

- Before 1.0, a break is a MINOR bump, `0.y+1.0`, and it is named in the
  release notes. SemVer gives `0.y.z` no compatibility guarantee, so the
  version number by itself warns nobody: the notes are the warning.
- From 1.0 on, a break is a MAJOR bump.
- Everything else is a PATCH bump, or a MINOR one when it adds a surface
  without changing an existing one.

`v0.1.0` says the public surface is not frozen yet. It relaxes no rule that
already holds. In particular, the `install.sh` subcommand ABI applies at 0.x
exactly as it does at 1.x: the previous release's installer invokes those names
on the new tree, so an arm is retired by making it a no-op and never by
deleting it (see [Change something on the upgrade
path](#change-something-on-the-upgrade-path)).

Cut `v1.0.0` when the surface is declared stable.
