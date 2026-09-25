<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Shell reference

Exact facts about what this framework installs: subcommands, commands, aliases,
variables and files. For the reasoning behind any of it, see
[architecture](architecture.md).

## `install.sh` subcommands

Run from the repository root. `install` is the default when no subcommand is
given.

| Subcommand | Arguments | What it does |
| --- | --- | --- |
| `install` | none | Creates the state and cache directories, migrates a pre-XDG `~/.zsh_history` on a first install, creates every link, initializes missing plugin submodules with object checking forced on, caches the shell integrations, removes group and other write permission from `zsh/plugins`, and warns if commit signing is not configured. |
| `link` | none | Creates links and rewrites the manifest, refreshes the cached shell integrations, and removes group and other write permission from `zsh/plugins`. Nothing else. This is the arm an upgrade re-enters. |
| `packages` | none | `brew bundle` over `packages/Brewfile`, then `packages/Brewfile.local` if present, then the pinned `gh` extensions. Never runs a remote bootstrap script. |
| `upgrade` | none | Fetch, fast-forward merge, update submodules, relink, recompile. There is no bypass flag, and any argument is rejected. |
| `uninstall` | `[--purge]` | Removes manifest-listed links and restores backups. `--purge` also deletes generated cache and state, including your shell history (`$XDG_STATE_HOME/zsh/history`). |
| `reseed-settings` | none | Retired. It is kept because the previous release's installer invokes this name on the new tree. It succeeds and does nothing. |
| `help`, `-h`, `--help` | none | Prints the usage line. |

`install` is the only subcommand other than `packages` and `upgrade` that can
reach the network, and only when `git submodule status` shows an uninitialized
plugin: it then runs `git submodule update --init` to repair a non-recursive
clone. On a healthy checkout it is a strict no-op.

Exit codes: `2` for a usage error (unknown subcommand, an argument to a
subcommand that takes none, unknown uninstall option), `1` when the work could
not complete, `0` on success. A refused link makes `install` and `link` exit 1,
but only after the other links and the cached integrations are in place.
`install` then skips the plugin submodule step (its one network step) until a
re-run links cleanly.

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

`KUBE_CONTEXT_ALIASES` is declared empty on purpose. Contexts are per-machine, so
fill it in `$ZDOTDIR/functions.zsh.local`.

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

Each of these is defined only when the real tool is absent, so a Homebrew install
always wins.

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

## Generated files

Everything the framework generates, all removed by `dotfiles-uninstall --purge`.
`$XDG_STATE_HOME/zsh/history` is your shell history: `--purge` deletes it too.
`~/.config/git/config` is written once by the installer and then belongs to you
(`git config --global` writes there), so no uninstall removes it.

| Path | Contents |
| --- | --- |
| `$XDG_STATE_HOME/dotfiles/manifest` | Every link the installer created. The only input uninstall reads. |
| `$XDG_STATE_HOME/dotfiles/upgrade.lock` | A directory held for the duration of an upgrade. |
| `$XDG_STATE_HOME/dotfiles/update-check.stamp` | Mtime of the last cadence check. |
| `$XDG_STATE_HOME/dotfiles/update-last-fetch` | Mtime of the last successful background fetch. |
| `$XDG_STATE_HOME/dotfiles/update-available` | Present when the remote was ahead at the last fetch. |
| `$XDG_STATE_HOME/zsh/history` | Shell history. 1,000,000 entries, shared across live shells. A pre-XDG `~/.zsh_history` is copied here, mode 600, on the first install. |
| `$XDG_CACHE_HOME/zsh/zcompdump` and `.zwc`, `.stamp` | The completion dump, its compiled form, and the 24 hour audit clock. |
| `$XDG_CACHE_HOME/zsh/zcompcache` | The completion system's own cache. |
| `$XDG_CACHE_HOME/zsh/starship-init.zsh`, `zoxide-init.zsh`, `canga-completion.zsh` | Pre-compiled shell integrations. All three tools are optional. `starship` and `zoxide` come from the Brewfile; [canga](https://github.com/brunovenceslau/canga) is a separate project this framework never installs. Each cache is written only when its binary is on `PATH` at install, link or upgrade time, and removed once the binary is gone. |
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

`~/.config/alacritty`, `~/.config/ghostty` and `~/.config/tmux` are symlinks into
the repository, so a relative companion path resolves to the repository
directory. `.gitignore` keeps `*.local` and `*.local.*` untracked while allowing
the `*.example` templates.

Templates: `zsh/.zshrc.local.example` (also linked next to `.zshrc`),
`config/git/config.local.example`, `config/alacritty/alacritty.local.toml.example`,
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
