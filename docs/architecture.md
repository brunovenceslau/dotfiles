<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Architecture

How the framework is built and why. This page explains the design. For exact
command and file lists, see the [shell reference](shell-reference.md). For the
quality gates, see [development](development.md).

## Design goals

Four constraints shape every decision here.

1. **Keep `$HOME` clean.** Only `~/.zshenv` may live there. Everything else goes
   under the XDG base directories.
2. **Keep the interactive startup path free of subprocesses and network calls.**
   Integrations that ship as `eval "$(tool init zsh)"` are pre-compiled at
   install time instead. The one exception is a detached, non-blocking update
   fetch at most every few days (see
   [the one sanctioned background spawn](#the-one-sanctioned-background-spawn)).
3. **Keep the supply chain small.** No plugin manager, no runtime downloads,
   plugins pinned to exact commits.
4. **Make the install exactly reversible.** Every link is recorded, every
   overwritten file is backed up, and a purge leaves no trace except the
   machine-local `~/.config/git/config` (see [Exceptions](#exceptions)).

## Repository layout

```
~/.config/dotfiles
├── install.sh          bootstrap: install | link | packages | upgrade | uninstall
├── Makefile            quality gates: help, lint, check-patterns, test, reuse, gitleaks, smoke, secret-scan, forkgate, local-ci, repo-settings-check
├── lib/
│   ├── os.sh           is-arm64 / is-amd64, fork-free, sourceable from bash and zsh
│   ├── link.sh         the link() primitive, the convention walker, the manifest
│   ├── uninstall.sh    the manifest-driven reverse of link.sh
│   └── packages.sh     brew bundle plus pinned gh extensions
├── bin/                repo tools; only tmux-status is linked onto PATH
│   ├── check-patterns  static lint gate (dev only, run by make)
│   ├── secret-scan     secret-shaped content scanner (dev only)
│   ├── smoke           scratch-home install, idempotency and no-trace proof (dev only)
│   ├── startup-fork-gate   proves the startup path invokes no external binary (dev only)
│   ├── repo-settings-check diffs the live GitHub settings against .github/repo-settings.json (dev only)
│   └── tmux-status     dynamic tmux status segments, linked to ~/.local/bin
├── zsh/
│   ├── zshenv          linked to ~/.zshenv, the only framework file in $HOME
│   ├── zshrc           linked to $XDG_CONFIG_HOME/zsh/.zshrc
│   ├── aliases.zsh functions.zsh fzf.zsh restic.zsh update-check.zsh
│   └── plugins/        three SHA-pinned git submodules
├── config/             linked to ~/.config/<prog>, with three exceptions
├── packages/           Brewfile and gh-extensions.txt
├── tests/              hermetic unit tests, never touch the real $HOME
└── docs/               this documentation
```

There is no `home/` directory today. The `home/<file>` convention below is
implemented and will activate if a tool that refuses XDG paths is ever added.

## How linking works

Everything is a symlink into the repository. Edit a file in the repository and
every shell sees the change immediately. `install.sh` walks the conventions
below and records every link it creates in
`$XDG_STATE_HOME/dotfiles/manifest`, which is the only input uninstall reads.

### Conventions

| Repository path | Destination | Why |
| --- | --- | --- |
| `zsh/zshenv` | `~/.zshenv` | The single entry point in `$HOME`. It exports the XDG variables and `ZDOTDIR`, which is what keeps everything else out of `$HOME`. |
| `zsh/zshrc` | `$XDG_CONFIG_HOME/zsh/.zshrc` | Interactive config, found through `ZDOTDIR`. |
| `zsh/.zshrc.local.example` | `$ZDOTDIR/.zshrc.local.example` | The template sits next to where you create `.zshrc.local`. Linked best-effort: a clone without the template still installs. |
| `config/<prog>/` | `~/.config/<prog>` | XDG-native programs get their whole config directory. |
| `config/<name>@suffix/` | Skipped, with a warning | macOS is the only target, so there is no OS to gate on. Any `@suffix` is treated as a typo. |
| `home/<file>` | `~/.<file>` | Escape hatch for tools that refuse XDG paths. Unused today. |
| `bin/*` | `~/.local/bin/*` | Runtime tools on `PATH`. Today that is only `tmux-status`: the dev gates are an exception (below). |

### Exceptions

Three programs do not follow the whole-directory convention, and five `bin/`
tools are never linked.

| Program | Behavior | Why |
| --- | --- | --- |
| `config/gnupg/` | Only `gpg.conf` and `gpg-agent.conf` are linked into `~/.gnupg`. The directory is created with mode 0700 if the framework creates it. | `~/.gnupg` holds live secret keyrings. It must never become a symlink into the repository. |
| `config/git/` | `~/.config/git/config` is created, when absent, as a real local file that `[include]`s the tracked config by absolute path and `config.local` by relative path. `config/git/ignore` is linked normally. | `~/.config/git/config` is the path `git config --global` writes to. If it were a symlink into the repository, every global write would land in the tracked, published config. |
| `config/rclone/`, `config/restic/` | Never linked. | They hold secrets. The repository keeps only a README and `*.example` templates. See [backup and restore](backup-restore.md). |
| `bin/check-patterns`, `bin/secret-scan`, `bin/smoke`, `bin/startup-fork-gate`, `bin/repo-settings-check` | Never linked. `make` runs them from the checkout. | They are the repository's own quality gates. Linked, their generic names (`smoke`) would shadow other tools on a user's `PATH`, and they locate the repository from their own path, so they fail when run through a link. `tests/link_engine_test.sh` fails when a `bin/` tool the Makefile calls is missing from this list. A host that linked them under an older revision gets those links pruned as orphans on its next clean relink. |

`~/.config/git/config` is deliberately not recorded in the manifest, because
uninstall must not delete a machine-local file. `~/.config/git/ignore` is
recorded, because nothing writes to it.

The installer writes `~/.config/git/config` only when the path is absent or is a
symlink into the repository (`_link_git` in `lib/link.sh`). It leaves a real
file that already exists as it is and adds no `[include]` to it, and it leaves a
symlink that points elsewhere alone too. In both cases the tracked
`config/git/config` is not included, so none of its settings apply, including
`fsckObjects` on every fetch. For a real file the installer logs
`git: ~/.config/git/config exists - leaving the machine-local file intact`,
which is also what a re-run prints over the file the installer wrote itself. To
check and fix it, see
[Framework git settings do not apply](troubleshooting.md#framework-git-settings-do-not-apply).

### What `link()` does at each destination

The rules are safety-first, and a re-run is always a no-op.

| State of the destination | Action |
| --- | --- |
| Already a symlink to the intended source | Nothing changes, but the link is still recorded in the manifest. |
| A framework link (see [Who owns a link](#who-owns-a-link)), including a dangling one | Replaced, with no backup. It is not user data. |
| Any other symlink, including a dangling one | Treated like a real file, below. It is yours: `DEST.bak` holds the same link with the same target. |
| A real directory | Refused loudly. Backing up and restoring a directory is not idempotent, so this needs a human decision. |
| A real file, with no `DEST.bak` yet | Moved to `DEST.bak`, then linked. |
| A real file, with a `DEST.bak` already present | Refused loudly. The first `.bak` is the pristine pre-framework copy and is never overwritten. |
| Nothing there | Parent directory created, symlink created, recorded. |

### Who owns a link

One predicate, `_link_owned` in `lib/link.sh`, decides whether a symlink is the
framework's. Every site that removes a link without a backup asks it and
nothing else:

- `link()`, replacing a link at a destination;
- prune, in `link_manifest_finalize`, removing an orphan;
- uninstall, in `uninstall_links`;
- both conversions in `_link_git` (a whole `~/.config/git` link, and a
  `~/.config/git/config` link).

Where the framework may act at all is one more shared predicate,
`_link_under_home`. `link()` (and `_link_git`), prune, uninstall, its empty
directory pruning and `--purge` all refuse a path unless:

- `$HOME` is absolute and not `/` (it is compared without trailing slashes);
- the path is spelled strictly under `$HOME`, does not end in `/`, and has no
  `.` or `..` component;
- its parent directory, resolved physically in full, is `$HOME` or below it;
- that parent is not inside the checkout, unless `$HOME` itself is (the
  scratch `HOME` of `make smoke`);
- the path is not the checkout itself or one of its ancestors, so a purge of
  `$XDG_STATE_HOME/dotfiles` can never be the checkout.

So install never creates a link uninstall would refuse to remove. A refusal is
a warning and a non-zero exit. `install.sh link` places every other link and
exits 1. Uninstall skips the line and exits 1. Prune drops the line when
nothing exists at the path or its `.bak` (checked without following links), and
otherwise keeps it and exits 1 with a message of its own. See
[Manifest keeps an entry the framework may not act on](troubleshooting.md#manifest-keeps-an-entry-the-framework-may-not-act-on).

`install.sh` refuses to run as root, for every subcommand and with no
override (`_install_refuse_root`, the first thing the script does). A root
process must never be steered by anything a user controls, and here nearly
everything is the user's: the checkout it sources and re-executes, the manifest
and targets file it acts on, the `$HOME` and XDG directories it writes, and the
tools it runs from the user's `PATH` (`starship` on `~/.local/bin`, `git`,
`gh`). Guarding each of those was a list that kept growing, so there is one
rule instead. The check runs before any `lib/` file is sourced and before the
script reads any variable of its own. Bash itself reads `BASH_ENV`, `SHELLOPTS`
and `BASHOPTS` before the first line; sudo's default `env_delete` strips them.
It reads the uid from the absolute `/usr/bin/id`, not from `PATH` (where a
user's fake `id` could answer) and not from `$EUID` or `$UID` (which the
environment can set), and it fails closed when that uid cannot be read, as on
NixOS, which has no `/usr/bin/id`. The shebang is the absolute `/bin/bash`
(macOS's 3.2, the version the installer targets), not `env bash`, so a fake
`bash` earlier on root's `PATH` never runs either. The check also runs when the
file is sourced, so no function in `install.sh` needs to ask again. Nothing in
the framework needs root: Homebrew is user-scoped.

A root `dotfiles-upgrade` run from an older release still runs that release's
own git steps (fetch, merge, submodule update) as root; only the new tree's
`install.sh`, which the upgrade re-enters for the relink, refuses.

A symlink is the framework's when either holds:

1. **It points into the repository** (`_link_points_into`):
   - A relative target is resolved against the link's own directory.
   - The target and the repository root are compared as physical paths, with
     every existing directory component resolved. A checkout reached through a
     symlink (such as `~/.config/dotfiles` pointing at `~/src/...`) still counts
     as the repository, and a target spelled `<root>/../elsewhere` does not.
   - The target must lie strictly below the root. A link to the root itself is
     outside, and so is a prefix lookalike such as `<root>-host`.
   - The target's last component is not followed. A link to a symlink of your
     own is yours, wherever that symlink points.
   - A dangling target is resolved as far as its directories exist.
   - Anything that cannot be resolved counts as outside.
2. **`$XDG_STATE_HOME/dotfiles/targets` records it** (`_link_pair_recorded`):
   the file holds the pair of that destination and exactly its current target.
   This is how a second checkout recognizes, and uninstall removes, the links
   the first checkout made, and how switching back works. A missing file, a
   missing pair or a different target (you repointed the link) does not count.
   A path that holds a tab or a newline never gets a pair, and the lookup
   refuses one. A targets file that is itself a symlink is ignored with a
   warning.

Anything else is yours, so the doubtful case is backed up, never deleted.

Known limits of these checks:

- **Time of check to time of use.** A path is classified, then removed or
  restored a moment later. Something that swaps it in between wins the race.
  The installer runs as you, over your own `$HOME`, so whatever can race it can
  already change those files directly.
- **Intermediate symlinks.** In a link's target, every existing directory is
  resolved but the last component is not followed. In a destination, the
  parent directory is resolved in full, because the removal goes through it.
- **awk operands.** The targets file is merged with awk, which reads an operand
  of the form `name=value` as an assignment, not a file. The operands are the
  state-directory paths, which begin with `/` whenever `$XDG_STATE_HOME` and
  `$HOME` are absolute, as they must be. A relative `XDG_STATE_HOME` whose
  first component contains `=` would be misread.

The transition from a host installed before the targets file existed: that
host has no pairs yet. Its first relink from a second checkout backs up the
first checkout's links once, as `.bak` links into it. See
[Links from another checkout were backed up](troubleshooting.md#links-from-another-checkout-were-backed-up).

A refused link does not abort the walk. Every other link is still placed, and
`install.sh` then exits non-zero so the failure is visible.

### The manifest closes the loop

The manifest is written atomically and is byte-stable across identical runs,
which is what makes the idempotency check in `make smoke` meaningful.

`$XDG_STATE_HOME/dotfiles/targets` follows every manifest write: one
`destination<TAB>target` pair per manifest entry, sorted, staged in a temporary
file and renamed right after the manifest. The pairs live in their own file so
the manifest stays one bare path per line: the previous release's uninstall
reads each line as a path, and it never reads the targets file. Two renames are
not atomic together. An interruption between them leaves a pair missing, which
fails closed to a backup, or stale, which matches only a link still pointing
exactly where the framework put it. Uninstall leaves the targets file in place,
as it does the manifest, and `--purge` removes both with
`$XDG_STATE_HOME/dotfiles`.

- A **clean run** replaces the manifest with exactly the links it produced, then
  prunes orphans: a link the previous manifest recorded, that this run no longer
  produces, and that is still a framework link, is removed. This is how a
  deleted `config/<prog>` tree stops leaving a dead link behind. A pruned link's
  `DEST.bak` is restored the way uninstall restores it, since the entry leaves
  the manifest and no later uninstall would see that `.bak`. An entry whose link
  is already gone gets its `.bak` restored the same way. An orphan that is not a
  framework link, a real file you put there while a `.bak` exists, one
  `_link_under_home` refuses while something exists there (the run then exits
  1), or one that could not be removed or restored stays in the manifest and
  keeps its pair, so a later uninstall still sees it.
- A **partial run** (a refused link, or an interrupt) merges instead of
  replacing. The result is a superset, which can never orphan a link. It does not
  prune, because on a partial run "not produced" does not imply "no longer
  wanted".

`dotfiles-uninstall` reads the manifest and, for each entry:

1. Removes the path only if it is still a framework link, including one another
   checkout made. A real file you put there, or a link that is yours, is left
   alone. An entry `_link_under_home` refuses (above) is refused outright,
   removal and restore alike, and uninstall exits 1, so a tampered manifest
   naming an arbitrary path cannot touch it.
2. Restores `DEST.bak` if one exists and nothing occupies `DEST`. A backed-up
   symlink is renamed back, so it returns as the same link with the same target.
3. Prunes the now-empty parent directories, stopping at the first directory that
   still holds a file and never removing `$HOME`. A parent that was already
   empty before the install (an empty `~/.local/bin`, say) is removed too: the
   manifest records links, not directories.

`--purge` additionally removes `$XDG_CACHE_HOME/zsh`, `$XDG_STATE_HOME/zsh` and
`$XDG_STATE_HOME/dotfiles`. It refuses any path outside `$HOME` and refuses
`$XDG_CONFIG_HOME/zsh`, which is where your `.local` files live. Like every
subcommand, uninstall refuses to run as root, so a user-writable manifest can
never drive privileged deletions.

## The `.local` layer

Every config surface loads an untracked companion file. This is how two
machines differ without forking the repository. `.local` files are never
committed and never removed by uninstall. The full list is in the
[shell reference](shell-reference.md#local-files).

The ordering rule is the same everywhere: the tracked file loads first, the
`.local` companion loads last and wins.

## The interactive startup path

`~/.zshenv` runs for every zsh, including scripts and git hooks, so it holds only
exports: the XDG variables, `ZDOTDIR`, `EDITOR`, `PAGER`, `LESS`,
`STARSHIP_CONFIG`, `STARSHIP_CACHE`, a self-resolving `$DOTFILES`, and Go paths
when present. It uses zsh parameter expansion, `$commands` lookups and `-d`
tests only, so it forks nothing. `EDITOR`, `VISUAL` and `LESSOPEN` depend on
which tools are on `PATH`, and `PATH` is not final yet (the Homebrew prefix is
added by the zshrc), so the zshrc resolves those three a second time after it
builds `PATH`. The second pass only changes a value `zshenv` itself defaulted.

`$ZDOTDIR/.zshrc` runs for interactive shells, in this order. The order is
load-bearing, and the reasons are noted where they are not obvious.

1. Load the `zsh/files` module for a fork-free `mkdir`, and repair the state and
   cache directories if they are missing. The builtin `mkdir` is handed back to
   the real binary at the end of startup (step 17).
2. Fall back to `TERM=xterm-256color` when the current `$TERM` has no local
   terminfo entry. This is detected in-process through the `zsh/terminfo`
   module. Without it, an SSH session from a Ghostty client doubles typed input
   and tmux refuses to start.
3. Build `PATH`. The Homebrew prefix is found by testing whether
   `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` exists, never by running
   `brew shellenv`. `~/.local/bin` goes first, and `typeset -gU` removes
   duplicates. Then re-resolve `EDITOR`, `VISUAL` and `LESSOPEN` against the
   final `PATH`.
4. Configure history under `$XDG_STATE_HOME/zsh/history` and set the interactive
   options, including `AUTO_PUSHD`, which the directory-stack aliases depend on.
5. Set terminal window and tab titles through `precmd` and `preexec` hooks.
6. Add `zsh-completions/src` to `fpath`. This must precede `compinit`, or the
   cached dump never indexes those completions.
7. Run `compinit` against a cached, byte-compiled dump. A full rebuild with the
   insecure-directory audit runs at most once every 24 hours, gated on a
   dedicated stamp file rather than the dump's own mtime. During this block the
   `zsh/files` builtin `mv` shadows the external one, because the compdump helper
   calls `mv` and that was the last fork on the path. The audit itself forks
   `getent` when an fpath directory is group- or world-writable, so `install.sh`
   (the `install` and `link` subcommands) removes those permissions from
   `zsh/plugins`, the only framework-owned directories on `fpath`.
8. Apply completion styling: menu selection, four matchers, `_approximate`
   correction on Tab, grouped and colored listings. The `list-colors` style uses
   the evaluated form because `$LS_COLORS` is exported later, by `aliases.zsh`.
9. Source `lib/os.sh`, then `functions.zsh`, `aliases.zsh` and
   `restic.zsh`. Functions load before aliases so an alias can wrap a helper.
10. Source the cached `starship` and `zoxide` inits and the cached `canga`
    completion. The zoxide and canga caches must come after `compinit`, because
    both register a completion through `compdef`.
11. Pin `FAST_WORK_DIR` under `$XDG_CACHE_HOME/zsh`, pre-seed its
    `secondary_theme.zsh` guard file, then source `zsh-autosuggestions` and
    `fast-syntax-highlighting`, in that order. Highlighting loads last because it
    wraps every widget defined before it.
12. Restore prezto's "this path exists" cue by setting
    `FAST_HIGHLIGHT_STYLES[path]` and `[path-to-dir]` to `underline`, after the
    loader, because the plugin assigns its defaults with `: ${...:=}`.
13. Source `fzf.zsh`, which is a no-op without the `fzf` binary and skips the key
    bindings when there is no controlling terminal.
14. Source Ghostty's shell integration manually. Automatic injection works by
    driving `ZDOTDIR`, which this framework already owns.
15. Source `$ZDOTDIR/.zshrc.local`, the machine's last word.
16. Source `update-check.zsh` after `.zshrc.local`, so a host can tune or
    disable it there first.
17. Disable the `zsh/files` builtin `mkdir` again (unless it was already a
    builtin before step 1). It knows only `-p` and `-m`, so leaving it enabled
    would break `mkdir -v` in every session. `tests/startup_state_test.sh`
    asserts that `mkdir`, `mv` and `uname` are the real commands after startup.

### The prompt and `z` are cached, not evaluated

`starship` and `zoxide` both ship their zsh wiring as a command to `eval`, which
is a subprocess. `install.sh` runs `<tool> init zsh` once, on install and on
every upgrade, and writes the output to `$XDG_CACHE_HOME/zsh/<tool>-init.zsh`.
The zshrc only sources that file, guarded on the file existing rather than on the
binary. A host without the binary gets no cache, and degrades silently to zsh's
default prompt or to no `z`.

starship also writes a cache of its own: it creates its session-log directory on
every call, `init` included. Its default is `~/.cache/starship`, outside the tree
`--purge` removes. `zsh/zshenv` exports `STARSHIP_CACHE=$XDG_CACHE_HOME/zsh/starship`
for the shell, and `install.sh` sets the same value on its own `starship init`
call, because the installer runs in bash and never reads `zshenv`. The smoke
test runs with a stub `starship` that writes to that directory, so a Linux run
catches a cache that escapes the purge.

Both halves have to be wired as well as generated. The zoxide cache was produced
for a long time while nothing sourced it, so `z` silently did not exist.
`tests/navigation_state_test.sh` now measures the live shell for that class of
defect.

The cache lives under a directory that `--purge` already sweeps, so the no-trace
property still holds.

### The one sanctioned background spawn

`update-check.zsh` checks a cadence stamp with a glob, which costs no fork. Past
the cadence it spawns a fully detached `git fetch` that never blocks the prompt,
and records the result in `$XDG_STATE_HOME/dotfiles`. A `precmd` hook then
notifies on one prompt per shell and stays quiet afterwards. It has two notices,
and a host can hit both on that prompt: updates are available, and no fetch has
succeeded within the staleness window. Defaults are 3 days and 30 days, and both are
configurable. See [troubleshooting](troubleshooting.md#update-notices-do-not-go-away).

This is the only network access a shell start can cause. The fetch contacts the
`origin` remote of your clone and nothing else: like the upgrade (below), it
scrubs the global and system git config and the `GIT_CONFIG_*` environment
families, so an ambient `url.insteadOf` cannot redirect it, and it re-reads only
the credential helper from the XDG config. It forces object fsck on, runs
non-interactively (it fails instead of prompting for credentials), and writes
only into the clone's object store and `$XDG_STATE_HOME/dotfiles`.
`tests/update_check_test.sh` cases 10 and 11 cover the redirect and a malformed
object. `make forkgate` pre-seeds a fresh
stamp, so the gate measures the cadence check and never the fetch itself. To
turn the check off, set `DOTFILES_UPDATE_DISABLE` to any non-empty value, in the
environment or in `$ZDOTDIR/.zshrc.local`, which zshrc sources before
`update-check.zsh`.

## Plugins and the supply chain

The three zsh plugins are git submodules pinned to exact commits and loaded by a
static loader in the zshrc. There is no plugin manager and no runtime download.

| Plugin | Pinned commit | Role at startup |
| --- | --- | --- |
| `zsh-completions` | `28c5bdc` | `fpath` only. Its `src/` directory is indexed by the cached compdump. Nothing is executed at source time. |
| `zsh-autosuggestions` | `e52ee8c` (v0.7.1) | History-based inline suggestions. No network at source time. |
| `fast-syntax-highlighting` | `5ecd353` | Syntax colors. Sourced last so it wraps every widget. Needs the neutralization below. |

Verify the pins with `git submodule status`. If they differ from this table, this
section is stale. Any pin bump must re-audit the new source for source-time
`curl`, `wget`, `git fetch` or `/dev/tcp` use, and update this table in the same
commit. A commit pin does not protect against code a plugin downloads at runtime.

### Neutralizing the fast-syntax-highlighting theme fetch

At source time, `fast-syntax-highlighting` checks for
`$FAST_WORK_DIR/secondary_theme.zsh`. When the file is absent it downloads that
theme from the moving `master` ref and sources it. That is a runtime third-party
download on the startup path, and it would defeat the commit pin.

The zshrc closes this in three ways:

1. It pins `FAST_WORK_DIR` under `$XDG_CACHE_HOME/zsh` and pre-seeds an empty
   `secondary_theme.zsh`, so the download branch is never entered. An empty file
   sources as a no-op.
2. It shims `curl` and `wget` as failing shell functions for the duration of the
   loader. This covers the case where `$XDG_CACHE_HOME` is not writable, the seed
   write fails, and the plugin relocates its work directory to an unseeded path.
3. It shims `uname` as a function answering from `$OSTYPE`, because the plugin
   runs `$(uname -a)` at top level to probe for Darwin.

All three shims are removed with `unfunction` before anything interactive runs.
`tests/fsyh_fetch_test.sh` covers the fetch branch, and `make check-patterns`
is the static half of the same rule.

## The upgrade path

`dotfiles-upgrade` calls `install.sh upgrade`, which:

1. Takes a single-flight lock by creating
   `$XDG_STATE_HOME/dotfiles/upgrade.lock` as a directory. A trap releases it on
   exit, interrupt or termination.
2. Refuses to continue when tracked files are modified. Untracked files are
   invisible to the check.
3. Fetches through a wrapper that neutralizes ambient git configuration. The
   global and system config files and the `GIT_CONFIG_*` environment families are
   scrubbed, so a hostile `url.insteadOf` cannot redirect the fetch. Object fsck
   is re-asserted on the command line, because scrubbing also drops the tracked
   config that sets it.
4. Re-injects only the credential helper, resolved for this remote from the XDG
   config, and runs with `GIT_TERMINAL_PROMPT=0` so a missing credential fails
   loudly instead of hanging on a prompt.
5. Merges with `--ff-only`. A diverged or rewound history is refused, never reset
   to. This is the anti-rollback property.
6. Converges: updates submodules, runs `install.sh link` in a **fresh child
   process**, and byte-compiles stale plugin files.

Step 6 runs as a child process on purpose. The parent process sourced `lib/` at
startup, so after the merge it still holds the pre-merge link engine while the
working tree holds post-merge config. Relinking in-process would apply the old
rules to the new config, silently. The child re-reads the merged tree from disk.

The convergence step also runs when the fetch finds nothing to merge. An upgrade
interrupted after its merge leaves the installed state behind the tree, and
re-running `dotfiles-upgrade` is the recovery path, so "nothing to merge" must
still reconcile rather than report success and do nothing.

There is no signature verification or pin on the update path. `dotfiles-upgrade`
is a fetch plus a fast-forward merge. The protections that do apply are object
fsck on every fetch, the scrubbed ambient config, and the refusal to merge a
non-descendant history.

## Platform differences

Apple Silicon and Intel are both first-class targets. Architecture differences
never appear in link names. They are allowed in four places:

- shell guards that call `is-arm64` or `is-amd64` from `lib/os.sh` (no tracked
  file needs one today),
- `on_arm` and `on_intel` blocks in the Brewfile (none are needed today),
- untracked `.local` files,
- `config/gnupg/gpg-agent.conf`, whose `pinentry-program` line is the absolute
  Apple Silicon path `/opt/homebrew/bin/pinentry-mac`. gpg-agent.conf has no
  variable expansion, so the file cannot choose a prefix. `make check-patterns`
  allowlists this one file. On Intel the path does not exist and needs a manual
  edit (see
  [pinentry does not appear on Intel](troubleshooting.md#pinentry-does-not-appear-on-intel)).

The Homebrew prefix is detected by directory existence, so no code needs to know
which architecture it runs on to find it.
