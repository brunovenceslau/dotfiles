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

## Prerequisites

- macOS, Apple Silicon or Intel. `install.sh` and `lib/` target bash 3.2, the
  version macOS ships, and there is no Linux install path.
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

One line covers the Homebrew-installable prerequisites:

```sh
brew install shellcheck zsh tmux fzf jq xz reuse gitleaks
```

Once a tool is missing, `STRICT=1` decides what happens: unset, a gate skips
it with a warning and still exits 0; set, the same gate fails instead of
skipping, so CI (which always sets it) can never report green on a check it
did not run. See "`STRICT=1`" below for the full rule.

## The gates

Every gate is a `make` target. CI only ever calls `make`, so local and CI stay in
parity by construction. Run `make local-ci` before every push.

| Target | What it runs | What it proves |
| --- | --- | --- |
| `make lint` | shellcheck over `install.sh`, `lib/`, `bin/`; `/bin/bash -n` over `install.sh`, `lib/` and `tests/`; `zsh -n` over `zsh/zshenv`, `zsh/zshrc` and `zsh/*.zsh`; plus `check-patterns` | The shell surface parses and passes static analysis. The `/bin/bash -n` pass uses the absolute path, which on the macOS runners is the real bash 3.2. The `zsh -n` glob is one level deep, so the pinned submodules under `zsh/plugins/` are not parsed. |
| `make check-patterns` | `bin/check-patterns` | No `curl` or `wget` download executed on the same line: piped into `sh`, `bash`, `zsh`, `ksh` or `dash` (also through `\|&`, `sudo` with options, `env`, `exec`, a quoted name or a path such as `/bin/bash`), passed as a command substitution to `eval` (also `eval --`) or to a shell with a `c` option (`bash -lc "$(curl ...)"`, `bash --norc -c "$(curl ...)"`), or fed as a process substitution to `source`, `.` or a shell (`bash < <(wget ...)`), also when the tool is written `command curl`, `env curl`, `sudo curl`, `\curl` or `/usr/bin/curl`. Not caught, among others (the list is illustrative, not exhaustive): a download saved and executed on a later line, one passed through another command first (`curl ... \| tee f \| bash`), one fed through a here-string or `/dev/stdin`, a fetch behind an assignment, `time` or a brace group inside the substitution, a substitution that does not start the `-c` string (`sh -c "set -e; $(curl ...)"`), a fetch through an alias or function, a shell reached through `xargs` or `nohup`, and fetch tools other than curl and wget. Also no ad-hoc `uname -m` outside `lib/os.sh`, no unescaped `#` inside a Makefile `$(shell ...)`, no hardcoded Homebrew prefix and no `brew shellenv` or `brew --prefix` fork, no bash 4 syntax in `install.sh` or `lib/`, no GNU-only regex escape (`\s`, `\w`, `\b`, BRE `\|`) in the shell surface, `tests/` and the workflows (this arm's only OTHER exclusions, the pinned plugins dir and the script's own name, are content-independent path exclusions, not language exemptions; inside `tests/` ONLY, `*.py` files are skipped by a fixed extension - the arm's only content-independent LANGUAGE exemption, never a marker comment or a parse of what a file contains, because Python's own `re` module is a different regex dialect where those escapes are portable; `bin/`, `lib/`, `zsh/`, `install.sh`, the Makefile and the workflows carry no such exemption, since `lib/link.sh`'s `_link_bin_tree` links every `bin/*` file onto the live PATH by basename; non-shell code that needs the exemption MUST live in its own `.py` file under `tests/`, never a `python3 - <<'PY'` heredoc embedded in a `.sh` script - a heredoc is still shell-surface text to this arm, which has no notion of an embedded language; see `tests/release_workflow_check.py` and its caller `tests/release_workflow_test.sh`), no early-exit reader (`grep -q`, `-m`, `-l`, `head`) on the right of a pipe in the pipefail surface (`install.sh`, `lib/`, `bin/`, `tests/`, the workflows), no `--` after the first operand of `chmod`, `chown`, `chgrp`, `cp`, `mv`, `ln`, `rm`, `rmdir`, `mkdir`, `touch`, `cat`, `grep`, `egrep`, `fgrep` or `sed` in the same surface as the regex rule (not caught: a command written `\rm`, behind `env` or `sudo` with options, `coproc`, a `$CMD` variable, `find -exec`, `xargs`, an alias or `sh -c '...'` string, or split across `\` lines; wrongly flagged: a long option with a separate argument such as `--regexp PAT`, a redirection before the `--`, and prose or an unquoted `$(...)` argument holding a separator or keyword before a tool name and a later ` -- `, such as `"x; rm it by hand -- see docs"`), and the pinned plugins still have the shapes the startup shims assume. |
| `make test` | every `tests/*.sh` | Unit coverage of the repository's own tooling. Runs all files and reports all failures, rather than stopping at the first. |
| `make smoke` | `bin/smoke` | A fresh install into a scratch home works, an interactive shell starts cleanly, a re-run is a no-op, the dev gates are not linked onto `PATH`, and `--purge` leaves no trace except the documented machine-local `~/.config/git/config`. |
| `make secret-scan` | `bin/secret-scan --git .` | No secret-shaped content in the tracked tree. |
| `make gitleaks` | `gitleaks dir .` | The same question asked again, with [gitleaks](https://gitleaks.io/)' maintained rule set, over the working directory as it is on disk. |
| `make forkgate` | `bin/startup-fork-gate` | `zsh -i -c exit` invokes no external binary. |
| `make reuse` | `reuse lint` | Every tracked file states its copyright holder and SPDX licence, and every licence named has its full text in `LICENSES/`. The tree is [REUSE 3.3](https://reuse.software/spec-3.3/) compliant. |
| `make local-ci` | lint, test, reuse, gitleaks, secret-scan, smoke, forkgate | Everything CI runs. |
| `make repo-settings-check` | `bin/repo-settings-check` | The live GitHub settings match `.github/repo-settings.json`. Not part of `make local-ci` and never run by CI: it reads the live settings with the maintainer's `gh` login. See [Repository settings](#repository-settings). |

`reuse lint` walks what git tracks and does not descend into the pinned plugin
submodules, so their licences are not checked here. They are recorded in
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) instead, with the commit
each one is pinned to.

Three files cannot carry a header: `config/nvim/lazy-lock.json`,
`.claude/settings.json` and `.github/repo-settings.json`, because JSON has no
comment syntax. `REUSE.toml` declares them, and `tests/reuse_gate_test.sh` fails if a new tracked `.json`
file is not declared there. Everything else states its licence in its own
comment syntax. A block copied from an upstream project is bracketed by
`SPDX-SnippetBegin` and `SPDX-SnippetEnd` and repeats that upstream's licence
in place. A whole file that is someone else's work carries that work's licence
in its own header instead: `CODE_OF_CONDUCT.md` is the Contributor Covenant
under `CC-BY-SA-4.0`, which is why `LICENSES/` holds a fifth licence text.

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
`bin/secret-scan` natively, `gitleaks` through the allowlist in `.gitleaks.toml`.
Reach for it last. Neither scanner speaks for GitHub's own push protection,
which reads the same bytes on the server and honours no marker of ours, and a
literal that gets that far costs a history rewrite to remove. A test fixture
that needs a real secret shape builds it from fragments at run time instead; see
`tests/secret_scan_test.sh`. No tracked file needs the waiver today.

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
tool fails it. A pass proves what ran, not what was covered. When a particular suite
matters to your change, check that it did not skip.

Where `make` is unavailable, run the same commands it drives:

```sh
bin/check-patterns
shellcheck install.sh lib/*.sh bin/*
/bin/bash -n install.sh lib/*.sh
/bin/bash -n tests/*.sh          # the tests run under bash 3.2 on the macOS legs
zsh -n zsh/zshenv zsh/zshrc zsh/*.zsh
for t in tests/*.sh; do STRICT=1 bash "$t" || echo "FAILED: $t"; done
reuse lint
gitleaks dir . --no-banner --redact
bin/secret-scan --git .
bin/smoke
bin/startup-fork-gate
```

### What `make smoke` does

The whole run happens under `.smoke/` inside the repository, which is gitignored.
Nothing is written outside `~/.config/dotfiles`.

1. Create a scratch `HOME` and snapshot the pristine tree.
2. Run `/bin/bash install.sh`, which on the macOS runners is the real bash 3.2.
3. Assert the core links, one convention link, and a non-empty manifest.
4. Pre-seed the completion stamp, then run `zsh -i -c exit` and require exit 0,
   empty stderr, and a `ZDOTDIR` sentinel that proves this config loaded.
5. Re-run the installer and assert idempotency: a byte-stable manifest, an
   identical set of links, and no new `.bak`.
6. Run `dotfiles-uninstall --purge` through the real user-facing path.
7. Diff the home directory against the pristine snapshot. Any difference fails
   the gate and is printed.

### What `make forkgate` does

Every binary reachable on `PATH` is replaced by a logging shim placed first on
`PATH`. A hermetic `zsh -i -c exit` runs against this repository's zshenv and
zshrc, and the log must be empty. The gate proves its own instrumentation first:
a canary invocation must reach the log, and the measured shell must have actually
loaded the repository zshrc.

Out of scope, explicitly: the `precmd` window. `precmd` never fires under
`zsh -i -c exit`, so first-prompt activity is not measured.

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
`macos-15-intel` explicitly. If the image is retired, the leg fails loudly rather
than dropping the coverage.

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
second ruleset or a classic rule cannot add enforcement the file does not state. A setting is `ok` only when its live value was
read and matches. A failed call or a field the API left out, such as
`bypass_actors` for a caller without admin rights, is `UNREADABLE` and fails the
run, so a partial read never passes. It needs `gh` authenticated as a repository
admin and `jq`, and it only issues `GET` requests.

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

**Bash 3.2 compatibility** for `install.sh` and `lib/`. No associative arrays, no
`mapfile`, no `${var,,}`. macOS ships bash 3.2 as `/bin/bash`, and the smoke test
invokes the installer through it. Files under `bin/` may use a modern bash,
because they run only on provisioned hosts and CI. `zsh/` targets zsh only.
`make check-patterns` flags all three constructs, on any host, and is their only
gate. The `/bin/bash -n` pass in `make lint` is not a backstop for them:
`declare -A` and `mapfile` are ordinary command invocations, and `${var,,}` fails
when it is expanded, so no bash reports a parse error for any of the three. That
pass covers the syntax bash 3.2 genuinely cannot parse, and only on the macOS
legs where `/bin/bash` is the real 3.2.

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
forms.

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
<https://github.com/brunovenceslau/canga>), cache it at install time in
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
except for their README and `*.example` files. `make secret-scan` is the backstop.

**`make lint` must be green before every commit, and commits are signed.**

## Ask before doing any of these

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

If the program writes to its own config file, or keeps secrets there, it needs an
entry in the exceptions table in `lib/link.sh`. That is a link-convention change,
so ask first.

### Add a `.local` layer to a surface

Follow the existing shape: load the tracked file first, then the untracked
companion, guarded on readability and silent when absent. Use an `if` rather than
a bare `[[ ... ]] &&` when the load is the last statement in a file, so the file's
exit status stays 0. Add a `.local.example` template, and list the pair in the
[shell reference](shell-reference.md#local-files).

### Bump a plugin pin

1. Read the upstream diff between the old and new commits. Look specifically for
   source-time `curl`, `wget`, `git fetch` or `/dev/tcp` use, and for anything
   that changes the shapes the startup shims assume.
2. Update the submodule and commit the new pin.
3. Update the plugin table in
   [architecture](architecture.md#plugins-and-the-supply-chain) in the same
   commit. If the table disagrees with `git submodule status`, it is stale and
   must not be trusted.
4. Run `make local-ci STRICT=1`. `bin/check-patterns` verifies the shim premises,
   and `tests/fsyh_fetch_test.sh` covers the download branch.

### Add a gh extension

Add one `owner/repo <pin>` line to `packages/gh-extensions.txt`, where the pin is
a reviewed `vX.Y.Z` release tag. A bare commit SHA is accepted by the validator
but does not resolve for a binary extension, so a tag is the usual form. Every
line is validated before it reaches `gh extension install`: the `owner/repo` may
not start with a dash, dot or slash, and an unpinned line is dropped.

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

## Landing a change

One change is one branch off `main`. Write the failing test first, then the
implementation, then get the gates green. Review the final diff before opening a
pull request.

A doc that quotes what a command prints is held to that output by a test:
`tests/troubleshooting_messages_test.sh` for
[troubleshooting.md](troubleshooting.md), and `tests/restic_wrappers_test.sh`
for the `usage:` lines that `config/restic/README.md` and
[shell-reference.md](shell-reference.md) quote. A new doc that quotes program output gets the same kind of
test in the same pull request.

Check every API-facing value a doc or a command uses, such as an enum a GitHub
setting accepts, against that API's own reference before it lands.

A change that touches a security surface (the list in
[Ask before doing any of these](#ask-before-doing-any-of-these)) gets an
independent review of its diff before it merges. No gate detects a diff that
weakens a security property. Enforce a security invariant at its call site with
an explicit flag, the way the installer passes `-c fetch.fsckObjects=true` to
its own fetches, rather than inheriting it from a linked config file that a
later change can drop.

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
