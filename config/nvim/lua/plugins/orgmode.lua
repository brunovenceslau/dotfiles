-- SPDX-FileCopyrightText: 2026 Bruno Marques Venceslau de Souza <b@venceslau.dev>
--
-- SPDX-License-Identifier: GPL-3.0-or-later

return {
  {
    'nvim-orgmode/orgmode',
    event = 'VeryLazy',
    config = function()
      require('orgmode').setup({
        org_agenda_files = '~/orgfiles/**/*',
        org_default_notes_file = '~/orgfiles/refile.org',
      })
     -- Experimental LSP support
     vim.lsp.enable('org')
    end,
  },
}
