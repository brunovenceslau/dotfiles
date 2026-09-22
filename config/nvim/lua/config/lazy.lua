-- SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
--
-- SPDX-License-Identifier: GPL-3.0-or-later

-- SPDX-SnippetBegin
-- SPDX-License-Identifier: Apache-2.0
-- Snippet source: folke/lazy.nvim, the installation recipe in
-- doc/lazy.nvim.txt lines 156-192, at commit
-- 306a05526ada86a7b30af95c5cc81ffba93fef97. All 33 non-blank lines below are
-- that recipe verbatim, unmodified. Change statement (Apache-2.0 section 4b):
-- the file it sits in adds this repo's own options after SPDX-SnippetEnd, and
-- nothing inside the snippet. lazy.nvim's LICENSE at that commit names no copyright
-- holder (its appendix still reads "Copyright [yyyy] [name of copyright
-- owner]") and the repository carries no NOTICE file, so no
-- SPDX-SnippetCopyrightText can be stated without inventing one.
-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Setup lazy.nvim
require("lazy").setup({
  spec = {
    -- import your plugins
    { import = "plugins" },
  },

  -- Configure any other settings here. See the documentation for more details.
  -- colorscheme that will be used when installing plugins.
  install = { colorscheme = { "habamax" } },
  -- automatically check for plugin updates
  checker = { enabled = true },
})
-- SPDX-SnippetEnd

-- Below the upstream snippet: this repository's own Neovim options.

vim.api.nvim_set_option("clipboard","unnamed")
