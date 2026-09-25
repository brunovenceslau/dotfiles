<!--
SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# Third-party notices

This framework is licensed GPL-3.0-or-later (see [COPYING](COPYING)). This page
lists the upstream projects it borrows from or depends on, what was taken from
each, where that part sits in the tree, and the licence that governs it. Every
claim below was measured against the upstream at the commit named with it, not
against its current `HEAD`.

Entries fall into three groups:

- **Redistributed code.** The bytes are in this repository. Where the borrowed
  part is a block inside one of our files, it is bracketed by
  `SPDX-SnippetBegin` and `SPDX-SnippetEnd` in the file itself, so the licence
  travels next to the code even when a single file is copied out. Where the
  whole file is the upstream work, as with `CODE_OF_CONDUCT.md`, the file's own
  SPDX header carries the upstream licence instead.
- **Referenced, not redistributed.** A git submodule pin. The commit id is
  recorded in this repository, the code is not; `git clone --recurse-submodules`
  fetches it from its own origin.
- **Optional runtime tools.** Separate programs the shell calls if the host has
  them. Nothing from them is copied here.

## Redistributed code

### prezto

- Upstream: <https://github.com/sorin-ionescu/prezto>
- Commit: `cff2d01871425b1b80710f8ec6a475c5a53145b4`
- Licence: MIT (full text below)
- Used in:
  - `zsh/aliases.zsh`, the `ll`/`la`/`l`/`lr`/`lm`/`lk`/`lt`/`lc`/`lu` listing
    family, from `modules/utility/init.zsh`. Eight of the nine alias
    definitions are verbatim once trailing comments are stripped; `la` is
    respelled `ls -lAh` where prezto chains it off `ll`.
  - `zsh/zshrc`, the compsys styling block, from `modules/completion/init.zsh`.
    Thirteen of the twenty-three code lines in that block are verbatim.

This repository is a port of a prezto-based setup, not a fork of prezto. Only
the two blocks above are prezto's expression; everything around them is this
repository's own. The `d` and `1`..`9` directory-stack aliases and the
interactive `setopt` list follow prezto's conventions, but a one-word alias or
a `setopt` name is a fact about zsh rather than authored expression, so they
carry no snippet.

```text
Copyright (c) 2009-2011 Robby Russell and contributors
Copyright (c) 2011-2017 Sorin Ionescu and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE
```

### GNU coreutils, the `dircolors` database

- Upstream: <https://github.com/coreutils/coreutils>
- Commit: `6bfc90019f070832cce9f11bdecf707ffeead759`
- Licence: FSFAP, the FSF all-permissive licence that `src/dircolors.hin`
  carries per-file (the coreutils programs themselves are GPL-3.0-or-later)
- Used in: `zsh/aliases.zsh`, the `$LS_COLORS` builder. All 148 entries are
  byte-identical to `src/dircolors.hin` at that commit. prezto obtained the
  same values by running `dircolors` at shell startup; that is a fork this
  startup path will not take, so the values are inlined and regrouped by
  colour, then joined with a zsh builtin.

```text
Copyright (C) 1996-2026 Free Software Foundation, Inc.
Copying and distribution of this file, with or without modification,
are permitted provided the copyright notice and this notice are preserved.
```

### lazy.nvim

- Upstream: <https://github.com/folke/lazy.nvim>
- Commit: `306a05526ada86a7b30af95c5cc81ffba93fef97`
- Licence: Apache-2.0 (full text in [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt))
- Used in: `config/nvim/lua/config/lazy.lua`, the bootstrap. All 33 non-blank
  lines of the snippet are the installation recipe from `doc/lazy.nvim.txt`
  lines 156 to 192, unmodified. The file adds this repository's own options
  after the snippet ends.

The `LICENSE` file at that commit is the unfilled Apache-2.0 text: its appendix
still reads `Copyright [yyyy] [name of copyright owner]`, and the repository
has no `NOTICE` file. No copyright holder can be stated without inventing one,
so the snippet names the Apache-2.0 identifier and no copyright text.

### nvim-orgmode

- Upstream: <https://github.com/nvim-orgmode/orgmode>
- Commit: `d9cd82d732cf4322100cf2c4c57b285c870bd893`
- Licence: MIT, Copyright (c) 2021 Kristijan Husak
- Used in: `config/nvim/lua/plugins/orgmode.lua`. Its 13 code lines
  (non-blank, non-comment) are the setup recipe from the upstream
  `docs/installation.org` and `README.org`: a plugin name, an `event`, a
  `config` function that calls `setup` with two default paths, the
  `vim.lsp.enable('org')` call from the README's "Experimental LSP support"
  line, and the Lua delimiters around them. These are the documented way to
  configure the plugin rather than authored expression, so the file carries no
  snippet. The notice is here because the values were taken from that
  documentation.

### telescope.nvim

- Upstream: <https://github.com/nvim-telescope/telescope.nvim>
- Commit: `40aedd8a68c78a656a10a8d62d80c54af59420fb`, the commit
  `config/nvim/lazy-lock.json` pins
- Licence: MIT, Copyright (c) 2020-2021 nvim-telescope
- Used in: `config/nvim/lua/plugins/telescope.lua`. The four keymaps
  (`<leader>ff`, `<leader>fg`, `<leader>fb`, `<leader>fh`) and their `desc`
  strings match the upstream README's usage recipe. They are the plugin's
  documented default bindings rather than authored expression, so the file
  carries no snippet; the notice records where they came from, on the same
  basis as nvim-orgmode above.

### Contributor Covenant

- Upstream: <https://github.com/EthicalSource/contributor_covenant>, the
  working repository behind <https://www.contributor-covenant.org>
- Commit: `d379fc9491eebf313942b979dfc4ab3b0d11df78`, the last commit touching
  `content/version/3/0/code_of_conduct.md` on the `release` branch
- Version: 3.0
- Licence: CC-BY-SA-4.0. The document's own Attribution section states it:
  "Contributor Covenant is stewarded by the Organization for Ethical Source
  and licensed under CC BY-SA 4.0". Note that this is the SHARE-ALIKE
  variant. Version 2.1 and earlier were CC BY 4.0; 3.0 is not.
- Used in: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). The whole file is the
  upstream work, so its own SPDX header names `CC-BY-SA-4.0` for the whole
  file rather than bracketing a snippet, and `LICENSES/CC-BY-SA-4.0.txt` holds
  the text. The adaptations are the ones the
  template asks an adopter to make and are listed in the file's own
  Attribution section: the reporting method and the identity of the Community
  Moderators are filled in, and the editorial `[NOTE: ...]` placeholders are
  removed. The Hugo front matter that the upstream file carries for the
  website build is not part of the document and was dropped.

## Referenced, not redistributed

These are git submodules under `zsh/plugins/`. This repository records a commit
id; the code is fetched from each project's own origin.

| Plugin | Pinned commit | Licence |
| --- | --- | --- |
| [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) | `e52ee8ca55bcc56a17c828767a3f98f22a68d4eb` | MIT, Copyright (c) 2013 Thiago de Arruda, Copyright (c) 2016-2021 Eric Freese |
| [zsh-completions](https://github.com/zsh-users/zsh-completions) | `28c5bdcaf81bb89e56d0df8267d822c3b8aed9e0` | The Z Shell licence, not plain MIT (see below) |
| [fast-syntax-highlighting](https://github.com/zdharma-continuum/fast-syntax-highlighting) | `5ecd353c81214f82bdeca5483fab6ccc5a2d5494` | BSD-3-Clause, Copyright (c) 2010-2016 zsh-syntax-highlighting contributors |

zsh-completions is often described as MIT. At the pinned commit its `LICENSE`
is the Z Shell licence, whose own text says that "any provisions made in
individual files take precedence", and 150 of the 180 files under `src/` carry
their own copyright notice. Anyone redistributing that submodule's contents
has to read the file they are shipping, not just the repository `LICENSE`.

## Palette credit

### gruvbox

- Upstream: <https://github.com/morhetz/gruvbox>
- Commit: `ef8864bb42bf244f0295d1c5a403b27e3d139695`
- Licence: no `LICENSE` file exists at that commit. MIT is asserted in
  `package.json` and in `README.md`, and the only holder name anywhere in the
  repository is `package.json`'s author field, `Pavel Pertsev`. Because there
  is no licence text to reproduce, none is reproduced here.
- Credited in: `config/ghostty/themes/gruvbox-ipe-light` and
  `config/ghostty/themes/ipe-amarelo`.

Both themes are this repository's own work and carry its copyright. What they
take from gruvbox is the palette convention, not the palette.
`gruvbox-ipe-light` shares none of its 17 distinct hex values with gruvbox.
`ipe-amarelo` borrows three of its 19 (`#928374`, `#d5c4a1`, `#ebdbb2`), each
named in the file where it is used, because a value that had to move for
contrast was better taken from the canonical tone than invented.

## Optional runtime tools

These are separate programs. `install.sh` does not require any of them, the
shell degrades silently when one is absent, and nothing from them is copied
into this repository. The table lists the tools whose output the startup path
caches or sources, or that the shell binds keys to. Other optional tools that
a helper calls on demand (kubectl, restic, pass-cli, op, python3, go, dig, gls,
uuidgen, osascript, lesspipe) are described, with the helpers that use them, in the
[shell reference](docs/shell-reference.md).

| Tool | Licence | What it does here |
| --- | --- | --- |
| [starship](https://github.com/starship/starship) | ISC | Renders the prompt. `install.sh` runs `starship init zsh` once and caches the result; `zsh/zshrc` sources the cache and falls back to the built-in prompt when it is absent. |
| [zoxide](https://github.com/ajeetdsouza/zoxide) | MIT | Provides the `z` jump command, cached and sourced the same way. |
| [fzf](https://github.com/junegunn/fzf) | MIT | Backs Ctrl-R, Ctrl-T and Alt-C. `zsh/fzf.zsh` returns on its first line when the binary is absent. |
| [canga](https://github.com/brunovenceslau/canga) | GPL-3.0 | Supplies its own zsh completion, which `install.sh` caches when the binary is present and skips when it is not. |

`config/starship/starship.toml` and `config/lazygit/config.yml` are this
repository's own configuration. Lines in them that match upstream
documentation are setting names and default values, which is the vocabulary
those programs define rather than authored expression.
