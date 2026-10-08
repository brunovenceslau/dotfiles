<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Shell reference

Exact facts about what this framework installs: subcommands, commands, aliases,
variables and files. For the reasoning behind any of it, see
[architecture](architecture.md).

- [`install.sh` subcommands](#installsh-subcommands)
  - [`install.sh identity`](#installsh-identity)
- [Lifecycle commands](#lifecycle-commands)
- [restic wrappers](#restic-wrappers)
- [Helper functions](#helper-functions)
  - [kubectl helpers](#kubectl-helpers)
- [Aliases](#aliases)
  - [Listing](#listing)
  - [Navigation](#navigation)
  - [Shell and meta](#shell-and-meta)
  - [git](#git)
  - [Tool fallbacks](#tool-fallbacks)
  - [Network and macOS](#network-and-macos)
- [Commands on `PATH`](#commands-on-path)
- [Key bindings](#key-bindings)
- [Shell options](#shell-options)
- [Environment variables](#environment-variables)
- [Generated files](#generated-files)
- [`.local` files](#local-files)
- [Config surfaces](#config-surfaces)

## `install.sh` subcommands

Run from the repository root. `install` is the default when no subcommand is
given.

| Subcommand | Arguments | What it does |
| --- | --- | --- |
| `install` | none | Creates the state and cache directories, migrates a pre-XDG `~/.zsh_history` on a first install, creates every link, initializes missing plugin submodules with object checking forced on, caches the shell integrations, removes group and other write permission from `zsh/plugins`, runs the automatic [identity step](#installsh-identity), and warns if commit signing is not configured or the signing key is stale. |
| `link` | none | Creates links and rewrites the manifest, refreshes the cached shell integrations, removes group and other write permission from `zsh/plugins`, and runs the automatic [identity step](#installsh-identity). Nothing else. This is the arm an upgrade re-enters. |
| `packages` | none | `brew bundle` over `packages/Brewfile`, then `packages/Brewfile.local` if present, then the pinned `gh` extensions. Never runs a remote bootstrap script. |
| `upgrade` | none | Fetch, fast-forward merge, update submodules, relink (which runs the automatic [identity step](#installsh-identity)), recompile. There is no bypass flag, and any argument is rejected. |
| `uninstall` | `[--purge]` | Removes manifest-listed links and restores backups. `--purge` also deletes generated cache and state, including your shell history (`$XDG_STATE_HOME/zsh/history`). |
| `identity` | `[--name "Full Name"]`, `[--rotate]` | Sets `user.email`, `user.signingkey`, `commit.gpgsign`, `tag.gpgsign` and `gpg.ssh.allowedSignersFile` (and `user.name` with `--name`) in `~/.config/git/config.local` from this host's allowed-signers file and ssh-agent. `--rotate` replaces a signing key that no longer verifies. See [`install.sh identity`](#installsh-identity). |
| `reseed-settings` | none | Retired. It is kept because the previous release's installer invokes this name on the new tree. It succeeds and does nothing. |
| `help`, `-h`, `--help` | none | Prints the usage. |

`install` is the only subcommand other than `packages` and `upgrade` that can
reach the network, and only when `git submodule status` shows an uninitialized
plugin: it then runs `git submodule update --init` to repair a non-recursive
clone. On a healthy checkout it is a strict no-op.

Exit codes: `2` for a usage error (unknown subcommand, an argument to a
subcommand that takes none, unknown uninstall or identity option), `1` when
the work could not complete, `0` on success. A refused link makes `install`
and `link` exit 1, but only after the other links and the cached integrations
are in place.
`install` then skips the plugin submodule step (its one network step) until a
re-run links cleanly.

### `install.sh identity`

Configures this host's git identity and SSH commit signing from the host
itself: its allowed-signers file and its ssh-agent. The logic is
`lib/host_identity.py`, run with `python3 -I`. When `python3 -I -c ''` fails,
the step warns and is skipped.

`install` and `link` run the same step automatically, and so does `upgrade`,
which re-enters `link` on the new tree. The automatic step:

- writes only when the effective config lacks `user.email`,
  `user.signingkey` or `commit.gpgsign` (`true`, or the explicit `false`
  below), so a host that signs hears nothing from it while its key verifies;
- on such a host, in `link` and so in every `upgrade`, prints one line when
  a later file turns off the signing `config.local` turns on, or when the
  configured key no longer verifies for `user.email` (its entry is gone or
  expired, the key is revoked, or the revocation file cannot be checked),
  naming `<checkout>/install.sh identity --rotate` or, for an override or
  when the revocation file is the cause, `<checkout>/install.sh identity`.
  `install` leaves that to its advisory, which prints the full report below;
- never rotates a key, and never writes `user.name`, which nothing on the host
  can derive;
- writes nothing in an SSH session (`SSH_CONNECTION` is set), where the agent
  is usually forwarded from another machine and holds that machine's keys.
  `install.sh identity`, run on purpose, still works there;
- prints one line when it cannot act, naming the cause and
  `<checkout>/install.sh identity`, which prints the details;
- never changes the exit status of `install`, `link` or `upgrade`.

Every git config read here asks for the effective value outside any
repository: all system and global levels, includes on, with git's
repository-local environment variables (`GIT_DIR`, `GIT_CONFIG_PARAMETERS`,
`GIT_CONFIG_COUNT` and the rest of `git rev-parse --local-env-vars`) removed.
Git runs from a fresh, empty directory under `$TMPDIR`, with
`GIT_CEILING_DIRECTORIES` set to its parent, so it finds no repository: not the
one you run the installer from, not a `$HOME` that is one, not one holding
`$TMPDIR`. Before the first read, `git rev-parse --git-dir` must report that
there is no repository there. A repository's own config, or a `git -c` in the
calling environment, never steers it. An `[includeIf "gitdir:..."]` or
`[includeIf "onbranch:..."]` in your global config is read without error and
never applies here, since no repository is open. An
`[includeIf "hasconfig:remote.*.url:..."]` does apply when a remote URL in the
global or system config matches, as it does for plain git outside a repository.

The step reads no git config at all, and says so in one line naming the cause
(`identity: not reading the git config: ...`), when it cannot run git outside
every repository and with your own config files. Among the causes: a relative
`GIT_CONFIG_GLOBAL` or `GIT_CONFIG_SYSTEM`, a `$TMPDIR` whose path holds a `:`
or that every user can write to without the sticky bit, a repository that git
still finds, a git that cannot start there at all (such as on a config file it
cannot parse), and a working directory the step cannot name or re-enter after
stepping into the empty one. The writing modes then write nothing, and `install`
still completes. A directory you may enter but not read is not such a case:
where the system cannot open it to return to it, as on macOS, the step returns
by its path.

A `GIT_CONFIG_GLOBAL` that names any file other than
`$XDG_CONFIG_HOME/git/config` hides `config.local`, which that file includes,
so the step writes nothing under it. Relative paths in `user.signingkey`,
`gpg.ssh.allowedSignersFile` and `gpg.ssh.revocationFile` resolve against
`$HOME` here.

1. **Find the allowed-signers file.** The first of these that is set wins:
   `$CANGA_HOST_ALLOWED_SIGNERS`, then the effective
   `gpg.ssh.allowedSignersFile` (a leading `~` is expanded), then
   `$XDG_CONFIG_HOME/git/allowed_signers` (`~/.config/git/allowed_signers` by
   default) if it exists. A source that is set but names a missing file is
   reported, not skipped. The file must be a regular file of at most 1 MiB.
2. **Read it** in the ssh-keygen(1) ALLOWED SIGNERS format,
   `principals [options] keytype base64 [comment]`, deciding each line the way
   `ssh-keygen -Y verify -n git` does, which is what `git verify-commit` runs:
   lines end at a newline only, principal and namespace patterns know `*` and
   `?` and nothing else, a `!pattern` denies, and a repeated or unknown option
   rejects the line. An entry counts only when its `namespaces` option is
   absent or matches `git`, its `valid-after` and `valid-before` bounds hold
   now, and it is not a `cert-authority` line. A key that the effective
   `gpg.ssh.revocationFile` lists (a key list or a KRL) never counts, and a
   revocation file that is set but cannot be read writes nothing, and so does
   a key list that holds a line, other than a comment, that is not a key or
   holds a NUL byte. A principal
   counts only when it is a literal address, never a pattern such as
   `*@example.com`, and holds no space, `<>`, `[]`, quote, control or
   invisible character. Malformed lines are skipped and named, and a line
   other than a comment that holds a NUL byte is one, since `ssh-keygen`
   stops reading a line there.
   A malformed line that spells an ssh-agent key anywhere in it, read the way
   `ssh-keygen` reads it or word by word, makes the step and `--rotate` write
   nothing: this step reads some lines more strictly than `ssh-keygen` does
   (glibc's takes a seconds field of 61, for one), so that key may be valid
   there.
3. **Match the ssh-agent keys** from `ssh-add -L` by the exact
   `<keytype> <base64>`. An RSA key listed as `rsa-sha2-256` or
   `rsa-sha2-512` is the `ssh-rsa` key, as `ssh-keygen` reads it, and is
   written as `ssh-rsa`. Comments are ignored on both sides, and agent order
   decides nothing. Every match is a candidate: one email, one key.
4. **Narrow to one identity.** The expected email is the effective
   `user.email` when it is set, and otherwise the one email every candidate
   shares. Candidates for any other email drop out. Several emails with no
   `user.email`, no candidate left for the `user.email` you set, or more than
   one key left for the email write nothing. The message names each email and
   key fingerprint (`SHA256:...`).
5. **Write**, only where no level sets the key yet: `user.email`,
   `user.signingkey` as `key::<keytype> <base64>`, `commit.gpgsign = true`,
   `tag.gpgsign = true`, `gpg.ssh.allowedSignersFile` (the file from step 1, so
   a git that does not inherit your shell's environment verifies against it
   too), and `user.name` when `--name` is given. The file is
   `$XDG_CONFIG_HOME/git/config.local`.

A key that already has a value, in `config.local` or anywhere in the effective
config, is never overwritten. An equal value is left alone (a
`user.signingkey` path to the same public key counts as equal). A different
one is kept and reported, and then the step writes nothing at all, so
`commit.gpgsign` is never turned on beside a key it did not choose. A value
that is right in `config.local` but overridden by a later file, such as
`~/.gitconfig`, is reported with that file's name.

One exception: an effective `commit.gpgsign = false` or `tag.gpgsign =
false`, set in `config.local` or at any other level, is this host's exception
to signing, unless `config.local` itself says `true`. The step keeps it,
prints `identity: <key> is false (<origin>) - kept as this host's exception,
so it stays off`, and still writes the email, the key and whatever else is
absent. A conflicting `user.email`, `user.signingkey` or
`gpg.ssh.allowedSignersFile` still makes it write nothing.

A `true` in `config.local` that a later file turns `false` is not the
exception: `install.sh identity` reports it as overridden and writes nothing,
the `install` advisory names it, and `link` (so every `upgrade`) prints one
line naming the file that turns signing off. A `false` in `config.local` that
a later `true` overrides is named too, and leaves nothing to write.

Before writing, the step checks that some file git reads has an `[include]`
of `config.local`. Before it first changes an existing `config.local`, it
copies it to `config.local.bak`. An existing `.bak` is kept, because the first
backup is the pristine one. The write goes through a temporary file next to
`config.local` and a rename. A `config.local` that is a symlink is not written.
A run with nothing to add rewrites nothing. After a write, the step reads
every written key back through the effective config and reports one that
reads differently.

The step writes nothing unless the effective `gpg.format` is `ssh`, which the
tracked config sets. Under any other format the `key::` value would go to gpg,
and every signed commit would fail.

`--name` takes one line without `<` or `>`. A `config.local` that exists but
is not a regular file (a FIFO, a directory) is refused before any git read,
since git opens it through the include.

#### Rotating the signing key

`install.sh identity --rotate` replaces `user.signingkey`, and nothing else,
when two things hold: the configured key no longer verifies for the effective
`user.email` (its entry is gone, expired, outside the `git` namespace, not yet
valid, or the key is revoked), and exactly one ssh-agent key does. It refuses
when the key is still valid, when no key or several keys qualify, and when
`user.signingkey` comes from a file other than `config.local`. It keeps the
`.bak` rule above and prints the old and the new fingerprint. The automatic
step never rotates. What retiring an old key does and does not protect against
is in [architecture](architecture.md#rotating-the-signing-key).

#### The stale-key report

`install.sh identity` and the installer's signing advisory report:

- an effective `user.signingkey` that no longer verifies for `user.email` in
  the allowed-signers file, or that the revocation file lists;
- a `key::` (or public-key path) `user.signingkey` that the ssh-agent does not
  hold, since signing then fails. A certificate, or a private key with no
  `.pub` beside it, is reported as not checked: git can sign with one, and
  this step does not read either;
- a `user.signingkey` set in any file other than `config.local`;
- a dangling or present `~/.gitconfig` (the advisory only, signing on or off),
  since git reads it after `~/.config/git/config` and `git config --global`
  then reads and writes only it.

`install.sh identity` exits `0` when the identity is in place, `1` when it wrote
nothing, kept a different value, or reported a stale key, and `2` on a usage
error.

## Lifecycle commands

These are zsh functions from `zsh/functions.zsh`. They exist only in an
interactive shell that loaded this framework. Both have Tab completion.

| Command | Equivalent |
| --- | --- |
| `dotfiles-upgrade` | `$DOTFILES/install.sh upgrade` |
| `dotfiles-uninstall [--purge]` | `$DOTFILES/install.sh uninstall [--purge]` |

## restic wrappers

Defined in `zsh/restic.zsh`, and only when the `restic` binary is present. Each
takes a repository name that maps to `$XDG_CONFIG_HOME/restic/<name>.env` and
runs `<runner> run --env-file <that file> -- restic <args...>`. Tab completion
offers the `.env` files you have.

| Command | Secret runner | References it resolves |
| --- | --- | --- |
| `restic-pass-cli <repo> [restic args...]` | `pass-cli run --env-file` (Proton Pass CLI) | `pass://vault/item/field` |
| `restic-op <repo> [restic args...]` | `op run --env-file` (1Password CLI) | `op://vault/item/field` |

Every value in an env file is a secret reference, never a literal secret, and
the runner resolves the references into restic's own environment only. Each
runner understands only its own scheme, so an env file serves one runner: a
repository reachable through both needs two files, such as `photos_b2.env`
(`pass://`) and `photos_b2_op.env` (`op://`).

| Exit code | Meaning |
| --- | --- |
| `2` | No repository name given. stderr shows `usage: pass-cli-backed wrapper <repo> [restic args...]` (`op-backed` for `restic-op`). An explicitly empty name (`restic-op ""`) prints `usage: <wrapper> <repo> [restic args...]` and the env directory to look in. |
| `1` | `<name>.env` does not exist, or the runner is not on `PATH`. |
| other | The runner's own exit status, which is restic's when the runner passes it through. |

See [backup and restore](backup-restore.md).

## Helper functions

| Function | Behavior |
| --- | --- |
| `mkcd <dir>` | Create the directory with parents, then `cd` into it. |
| `up [n]` | `cd` up `n` levels. Default 1. |
| `extract <archive>` | Unpack into the current directory, dispatching on the extension: `.tar.bz2`/`.tbz2`, `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`, `.tar`, `.gz`, `.bz2`, `.xz`, `.zip`, `.7z`. Exits 2 when the argument is missing or not a file, 1 for an unknown extension. Trusts the archive's member paths, so do not point it at untrusted archives. |
| `serve [port]` | Serve the current directory over HTTP on `127.0.0.1`, port 8000 by default. Never binds `0.0.0.0`. Requires `python3`, or `python` when that is Python 3. |
| `gcd [subpath]` | `cd` to the git repository root, or to a path beneath it. |
| `finder` | `cd` to the directory of the frontmost Finder window. |
| `go_test [args]` | `go test` with PASS, SKIP and FAIL colorized. Preserves go's exit status. |
| `go_test_cover [args]` | Run with a coverage profile and open the HTML report. |
| `disappointed`, `flip`, `shrug` | Copy an emoticon to the clipboard, or print it when no clipboard tool is available. |
| `matrix` | An awk screensaver. Ctrl-C to stop. |

### kubectl helpers

Defined only when `kubectl` is present. The pickers also need `fzf`.

| Command | Behavior |
| --- | --- |
| `k` | Alias for `kubectl`. |
| `kn` | Pick a namespace with fzf and set it on the current context. |
| `kc [alias\|context]` | Switch context. With no argument, pick with fzf. An argument is resolved through `KUBE_CONTEXT_ALIASES` first. |
| `kcn [context] [namespace]` | Both at once. |

`KUBE_CONTEXT_ALIASES` is declared empty on purpose. Contexts are per-machine,
so fill it in `$ZDOTDIR/functions.zsh.local`.

## Aliases

### Listing

`ls` maps to `gls --color=auto --group-directories-first` when GNU coreutils is
installed, and to `ls -G` otherwise. The rest chain off `ls`, so changing `ll`
changes everything built on it.

| Alias | Expansion | Notes |
| --- | --- | --- |
| `ll` | `ls -lh` | |
| `la` | `ls -lAh` | With hidden files. |
| `l` | `ls -1A` | One column. |
| `lr` | `ll -R` | Recursive. |
| `lm` | `la \| "$PAGER"` | Paged. |
| `lk` | `ll -Sr` | By size, largest last. |
| `lt` | `ll -tr` | By mtime, newest last. |
| `lc` | `lt -c` | By ctime. |
| `lu` | `lt -u` | By atime. |
| `lx` | `ll -XB` | By extension. Defined only with GNU `ls`. |

### Navigation

| Alias | Expansion |
| --- | --- |
| `d` | `dirs -v` |
| `1` through `9` | `cd +1` through `cd +9` |
| `..`, `...`, `....`, `.....` | `cd ..` and deeper |
| `~` | `cd ~` |
| `-` | `cd -` |

`d` and the numbered aliases depend on `AUTO_PUSHD`, which the zshrc sets. With
that option off the stack stays empty, so `d` prints only the current directory
at index 0 and `1` through `9` fail with `no such entry in dir stack`.

### Shell and meta

| Alias | Expansion |
| --- | --- |
| `history` | `history 1` (the whole history, numbered) |
| `zhistory` | `cat "$HISTFILE"` |
| `path` | `print -l $path` |
| `reload` | `source "$ZDOTDIR/.zshrc"` |

### git

| Alias | Expansion |
| --- | --- |
| `g` | `git` |
| `gst` | `git status` |
| `gs` | `git status --short --branch` |
| `gd`, `gds` | `git diff`, `git diff --staged` |
| `ga`, `gc` | `git add`, `git commit` |
| `gco`, `gsw`, `gb` | `git checkout`, `git switch`, `git branch` |
| `gl` | `git log --oneline --graph --decorate --all` |
| `gp`, `gpl` | `git push`, `git pull` |
| `gpf` | `git push --force-with-lease` |
| `gru`, `gfa` | `git remote update`, `git fetch --all` |
| `greb`, `grebi` | `git rebase`, `git rebase -i` |
| `grs` | `git reset --soft` |
| `gsh`, `gshw` | `git show`, `git show -w` |
| `gcm`, `gcmaster` | `git checkout main`, `git checkout master` |
| `gf` | `git log` with a full-body format, `--name-status` and `--grep` |
| `gss`, `gssu` | `git stash save`, `git stash save -u` |
| `grh` | `gssu && git reset --hard` |
| `grhom`, `grhum` | `gssu && git reset --hard origin/main` or `upstream/main` |
| `grhomaster`, `grhumaster` | The same against `master` |

The `grh` family stashes with `-u` **before** resetting, so a hard reset is
always recoverable from `git stash list`. Do not simplify these to a bare reset.

The repository's own git config also defines `git pushf` as
`push --force-with-lease`.

### Tool fallbacks

Each of these is defined only when the real tool is absent, so a Homebrew
install always wins.

| Alias | Falls back to |
| --- | --- |
| `fd` | `fdfind` |
| `hd` | `hexdump -C` |
| `md5sum` | `md5` |
| `sha1sum` | `shasum` |

### Network and macOS

| Alias | Behavior |
| --- | --- |
| `ip` | Public IP through a DNS TXT query. Defined only when `dig` is present and no real `ip` command (such as iproute2mac) is on `PATH`. |
| `ips` | Every local interface address. |
| `flushdns` | Flush the DNS cache. Uses sudo. |
| `hidedesktop`, `showdesktop` | Toggle Finder desktop icons. |
| `afk` | `pmset displaysleepnow` |
| `tailscale` | The CLI inside Tailscale.app. Defined only when the app is installed and no `tailscale` command is on `PATH`. |
| `stopwatch` | Time an interval. Stop with Ctrl-D. |
| `uuid` | A lowercase UUID. Defined only when `uuidgen` is present. |
| `ducks`, `suducks` | Ten largest entries in the current directory, with and without sudo. |
| `niceness` | Processes with their nice values. |
| `ascii-rainbow` | Print the eight ANSI colors. |

## Commands on `PATH`

| Command | Where it comes from |
| --- | --- |
| `tmux-status` | `bin/tmux-status`, linked to `~/.local/bin`. The tmux status line runs it; you rarely call it yourself. It is the only `bin/` tool the installer links: `check-patterns`, `secret-scan`, `smoke`, `startup-fork-gate` and `repo-settings-check` are repository gates that `make` runs from the checkout. |
| `z <dir>` | zoxide's jump command, from the cached `zoxide init zsh`. Present only when `zoxide` was on `PATH` at install, link or upgrade time. |
| `is-arm64`, `is-amd64` | Shell functions from `lib/os.sh`: exit 0 on the matching CPU architecture. For a host's own `.local` files. |

`PATH` is built by the zshrc in this order, with duplicates removed:
`~/.local/bin`, then the Homebrew prefix (`bin` and `sbin` under `/opt/homebrew`
or `/usr/local`, whichever holds `bin/brew`), then `$GOPATH/bin` and
`/usr/local/go/bin` when they exist (added by `zshenv`), then the inherited
`PATH`. On a macOS login shell, `/etc/zprofile` runs `path_helper` between
`zshenv` and the zshrc, which can move the two Go directories after the system
directories.

## Key bindings

| Keys | Action | Condition |
| --- | --- | --- |
| Ctrl-R | fzf history search | fzf's `key-bindings.zsh` found, and a terminal is attached |
| Ctrl-T | fzf file picker, inserted at the cursor | The same |
| Alt-C | fzf directory picker, then `cd` | The same |
| tmux prefix | `C-a`, with `C-b` kept as a secondary prefix | tmux |
| prefix `\|`, prefix `-` | Split the window side by side, or top and bottom, in the current directory | tmux |
| prefix `c` | New window in the current directory | tmux |
| prefix `r` | Reload `tmux.conf` | tmux |

## Shell options

The user-visible options the zshrc sets:

| Option | Effect |
| --- | --- |
| `AUTO_CD` | Typing a directory name changes into it. |
| `AUTO_PUSHD`, `PUSHD_IGNORE_DUPS`, `PUSHD_SILENT`, `PUSHD_TO_HOME` | Every `cd` pushes onto the directory stack that `d` and `1` to `9` use. |
| `CDABLE_VARS` | `cd DOTFILES` works when a variable holds the path. |
| `EXTENDED_GLOB`, `INTERACTIVE_COMMENTS` | The `#`, `~` and `^` glob operators, and `#` comments at the prompt. |
| `RM_STAR_WAIT` | `rm *` waits 10 seconds before it runs. |
| `NO_FLOW_CONTROL`, `NO_BEEP`, `NOTIFY` | Ctrl-S and Ctrl-Q reach the line editor, no bell, and a finished background job is reported at once. |
| `EXTENDED_HISTORY`, `INC_APPEND_HISTORY`, `SHARE_HISTORY` | Timestamped history, written as commands run and shared across live shells. |
| `HIST_IGNORE_ALL_DUPS`, `HIST_IGNORE_SPACE`, `HIST_REDUCE_BLANKS`, `HIST_VERIFY` | Keep only the newest duplicate, skip a command that starts with a space, normalize blanks, and show a history expansion before running it. |
| `COMPLETE_IN_WORD`, `ALWAYS_TO_END`, `PATH_DIRS` | Completion from both ends of a word, cursor to the end afterwards, and path search for a command that contains a slash. |

## Environment variables

Set by `zsh/zshenv`, which runs for every zsh. Most honor a value that is
already set. Six do not: `ZDOTDIR`, `DOTFILES`, `STARSHIP_CONFIG`,
`STARSHIP_CACHE`, `HOMEBREW_NO_ANALYTICS` and, when `~/go` exists, `GOPATH` are
exported unconditionally and overwrite whatever the calling environment had.
Override those from `$ZDOTDIR/.zshrc.local`, which runs later.
`tests/zshenv_contract_test.sh` pins both lists.

| Variable | Value |
| --- | --- |
| `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` | The spec defaults under `$HOME`. |
| `ZDOTDIR` | `$XDG_CONFIG_HOME/zsh` |
| `DOTFILES` | The repository root, resolved from the `~/.zshenv` symlink with no fork. |
| `EDITOR` | `nvim` when it is on `PATH`, otherwise `vim`. In an interactive shell this is re-checked after the zshrc adds the Homebrew prefix and `~/.local/bin`, so a Homebrew `nvim` is found on a GUI-launched terminal too. |
| `VISUAL`, `PAGER` | `$EDITOR`, `less`. |
| `LANG` | `en_US.UTF-8` |
| `LESS` | `-g -i -M -R -w` |
| `LESSOPEN` | Set when `lesspipe.sh` or `lesspipe` is on `PATH`, re-checked like `EDITOR`. |
| `BROWSER` | `open`, on macOS only. |
| `HOMEBREW_NO_ANALYTICS` | `1` |
| `STARSHIP_CONFIG` | `$XDG_CONFIG_HOME/starship/starship.toml` |
| `STARSHIP_CACHE` | `$XDG_CACHE_HOME/zsh/starship`. starship keeps its session logs here, and `--purge` removes the directory. `install.sh` sets the same value when it runs `starship init`. |
| `GOPATH` | `$HOME/go` when that directory exists. |
| `skip_global_compinit` | `1`, to suppress a duplicate global compinit. |
| `GIT_CEILING_DIRECTORIES` | `$CANGA_HOST_BASE_DIR/github.com/brunovenceslau/docker-sbx/envs` (`CANGA_HOST_BASE_DIR` defaults to `$HOME/src`), prepended to any existing value, only when that directory exists, the resulting path is absolute, and it contains no `:`. It stops git searching above a docker-sbx environment. An entry already in the list is not added again. Apps launched from the Dock or Finder do not get it. |

Set elsewhere:

| Variable | Set by | Value |
| --- | --- | --- |
| `LSCOLORS`, `LS_COLORS` | `zsh/aliases.zsh` | The BSD scheme and the GNU `dircolors` default database, inlined. `LS_COLORS` also drives the completion list colors. |
| `FAST_WORK_DIR` | `zsh/zshrc` | `$XDG_CACHE_HOME/zsh/fast-syntax-highlighting` |
| `FZF_DEFAULT_COMMAND`, `FZF_CTRL_T_COMMAND`, `FZF_ALT_C_COMMAND`, `FZF_DEFAULT_OPTS` | `zsh/fzf.zsh` | Derived from `fd` or `fdfind` when present. |
| `GHOSTTY_SHELL_FEATURES` | `zsh/zshrc` | `ssh-env,ssh-terminfo` appended, under Ghostty only. |

Read as configuration:

| Variable | Default | Effect |
| --- | --- | --- |
| `DOTFILES_UPDATE_CADENCE_DAYS` | 3 | How often the background update fetch runs. |
| `DOTFILES_UPDATE_STALENESS_DAYS` | 30 | Age at which a stalled update channel is reported. |
| `DOTFILES_UPDATE_DISABLE` | unset | Any non-empty value disables the update sentinel. `DOTFILES_UPDATE_DISABLE=0` disables it too, because the test is `-n`, not a comparison against `1`. |
| `FZF_SHELL_DIR` | unset | Where to find fzf's `key-bindings.zsh` and `completion.zsh`. |
| `STRICT` | unset | Set by CI. Turns a skipped gate into a hard failure. |
| `CANGA_HOST_ALLOWED_SIGNERS` | unset | Read by [`install.sh identity`](#installsh-identity) as the first place to look for the allowed-signers file. |

## Generated files

Everything the framework generates, all removed by `dotfiles-uninstall --purge`.
`$XDG_STATE_HOME/zsh/history` is your shell history: `--purge` deletes it too.
`~/.config/git/config` is written once by the installer and then belongs to you
(`git config --global` writes there), so no uninstall removes it.

| Path | Contents |
| --- | --- |
| `$XDG_STATE_HOME/dotfiles/manifest` | Every link the installer created. The only input uninstall reads. |
| `$XDG_STATE_HOME/dotfiles/targets` | One `destination<TAB>target` pair per manifest entry. Lets a relink from another checkout recognize the framework's links. |
| `$XDG_STATE_HOME/dotfiles/upgrade.lock` | A directory held for the duration of an upgrade. |
| `$XDG_STATE_HOME/dotfiles/update-check.stamp` | Mtime of the last cadence check. |
| `$XDG_STATE_HOME/dotfiles/update-last-fetch` | Mtime of the last successful background fetch. |
| `$XDG_STATE_HOME/dotfiles/update-available` | Present when the remote was ahead at the last fetch. |
| `$XDG_STATE_HOME/zsh/history` | Shell history. 1,000,000 entries, shared across live shells. A pre-XDG `~/.zsh_history` is copied here, mode 600, on the first install. |
| `$XDG_CACHE_HOME/zsh/zcompdump` and `.zwc`, `.stamp` | The completion dump, its compiled form, and the 24 hour audit clock. |
| `$XDG_CACHE_HOME/zsh/zcompcache` | The completion system's own cache. |
| `$XDG_CACHE_HOME/zsh/starship-init.zsh`, `zoxide-init.zsh`, `canga-completion.zsh`, `sbx-completion.zsh` | Pre-compiled shell integrations. All four tools are optional. `starship` and `zoxide` come from the Brewfile; [canga](https://github.com/brunovenceslau/canga) and `sbx` (the Docker Sandboxes CLI) are separate projects this framework never installs. Each cache is written only when its binary is on `PATH` at install, link or upgrade time, and removed once the binary is gone. |
| `$XDG_CACHE_HOME/zsh/fast-syntax-highlighting/` | The pinned `FAST_WORK_DIR`, including the empty theme guard file. |
| `$XDG_CACHE_HOME/zsh/starship/` | starship's own session logs, through `STARSHIP_CACHE`. starship creates the directory on every call. Without the variable it would write `~/.cache/starship`, which `--purge` does not remove. |

## `.local` files

Untracked, never committed, never removed by uninstall. Each loads after its
tracked counterpart and overrides it.

| Tracked surface | Local companion | Mechanism |
| --- | --- | --- |
| `zsh/zshrc` | `$ZDOTDIR/.zshrc.local` | Sourced last, before the update sentinel. |
| `zsh/aliases.zsh` | `$ZDOTDIR/aliases.zsh.local` | Sourced at the end of the file. |
| `zsh/functions.zsh` | `$ZDOTDIR/functions.zsh.local` | Sourced at the end of the file. |
| `zsh/fzf.zsh` | `$ZDOTDIR/fzf.zsh.local` | Sourced at the end of the file. |
| `zsh/restic.zsh` | `$ZDOTDIR/restic.zsh.local` | Sourced at the end of the file. |
| `config/git/config` | `~/.config/git/config.local` | Relative `[include]` from the machine-local `~/.config/git/config`. This is where host identity, the signing key and the credential helper belong. |
| `config/git/config` | `config/git/config.local` (in the repository) | Relative `[include]` from the tracked config. Also honored. |
| `config/alacritty/alacritty.toml` | `config/alacritty/alacritty.local.toml` | Last entry of the `import` list. |
| `config/ghostty/config` | `config/ghostty/config.local` | `config-file = ?config.local`, processed last. |
| `config/tmux/tmux.conf` | `~/.config/tmux/tmux.local.conf` | `source-file -q` at the bottom. |
| `packages/Brewfile` | `packages/Brewfile.local` | Bundled after the tracked Brewfile. |
| `packages/gh-extensions.txt` | `packages/gh-extensions.local.txt` | Read alongside the tracked manifest, under the same validation. |

`~/.config/alacritty`, `~/.config/ghostty` and `~/.config/tmux` are symlinks
into the repository, so a relative companion path resolves to the repository
directory. `.gitignore` keeps `*.local` and `*.local.*` untracked while allowing
the `*.example` templates.

Templates: `zsh/.zshrc.local.example` (also linked next to `.zshrc`),
`config/git/config.local.example`,
`config/alacritty/alacritty.local.toml.example`,
`config/ghostty/config.local.example`, `config/tmux/tmux.local.conf.example`,
`packages/Brewfile.local.example`.

## Config surfaces

| Repository path | Installed at | Program |
| --- | --- | --- |
| `config/git/` | `~/.config/git/config` (real file), `~/.config/git/ignore` (link) | git |
| `config/gnupg/` | `~/.gnupg/gpg.conf`, `~/.gnupg/gpg-agent.conf` | gpg, with `pinentry-mac`. The pinentry path is absolute and written for Apple Silicon, see [troubleshooting](troubleshooting.md#pinentry-does-not-appear-on-intel) |
| `config/nvim/` | `~/.config/nvim` | Neovim, bootstrapped through lazy.nvim with `orgmode` and `telescope` |
| `config/starship/` | `~/.config/starship` | The prompt. Two lines, laid out for an 80 column window. No module prints a `$version`, to keep toolchain calls off the prompt. |
| `config/tmux/` | `~/.config/tmux` | tmux. Prefix `C-a`, with `C-b` kept as secondary. |
| `config/ghostty/` | `~/.config/ghostty` | Ghostty. Shell integration is sourced by the zshrc, not auto-injected. |
| `config/alacritty/` | `~/.config/alacritty` | Alacritty. The config only orchestrates imports. |
| `config/lazygit/` | `~/.config/lazygit` | lazygit |
| `config/rclone/`, `config/restic/` | Not installed | Templates and README only. |
