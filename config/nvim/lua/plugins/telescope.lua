-- SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
--
-- SPDX-License-Identifier: GPL-3.0-or-later

-- telescope: fuzzy finder over files, grep, buffers and help.
--
-- The keymaps live in `keys`, NOT at the top of this file. A spec file is
-- evaluated while lazy.nvim is still resolving the plugin list, so a top-level
-- `require('telescope.builtin')` runs BEFORE telescope is installed and errors
-- on a fresh machine - which is exactly why this spec never worked in the prezto
-- setup. Declaring them in `keys` also makes the plugin lazy-load on first use.
return {
  'nvim-telescope/telescope.nvim',
  version = '*',
  dependencies = {
    'nvim-lua/plenary.nvim',
    -- optional but recommended; needs `make`, and lazy.nvim builds it on install
    { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
  },
  keys = {
    { '<leader>ff', function() require('telescope.builtin').find_files() end, desc = 'Telescope find files' },
    { '<leader>fg', function() require('telescope.builtin').live_grep() end,  desc = 'Telescope live grep' },
    { '<leader>fb', function() require('telescope.builtin').buffers() end,    desc = 'Telescope buffers' },
    { '<leader>fh', function() require('telescope.builtin').help_tags() end,  desc = 'Telescope help tags' },
  },
}
