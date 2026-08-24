-- plugins for notetaking and knowledge management

-- `ob` is the Obsidian headless CLI (from npm), used here to sync whichever
-- vault the current buffer belongs to, found by walking up for `.obsidian/`.
local function ob_sync_current_vault()
  local vault_root = require('config.evergreen').vault_root(vim.fn.expand '%:p:h')
  if not vault_root then
    vim.notify('ob sync: current buffer is not inside an Obsidian vault', vim.log.levels.WARN)
    return
  end
  vim.cmd('vsplit term://' .. vault_root .. '//ob sync --path ' .. vim.fn.shellescape(vault_root))
end

return {

  {
    'nvim-neorg/neorg',
    enabled = false,
    config = function()
      require('neorg').setup {}
    end,
  },

  {
    'jakewvincent/mkdnflow.nvim',
    enabled = false,
    config = function()
      local mkdnflow = require 'mkdnflow'
      mkdnflow.setup {}
    end,
  },

  { -- obsidian-nvim/obsidian.nvim is the maintained community fork;
    -- epwalsh/obsidian.nvim (the original) is archived/unmaintained.
    'obsidian-nvim/obsidian.nvim',
    version = '*',
    ft = 'markdown',
    dependencies = {
      'nvim-lua/plenary.nvim',
    },
    keys = {
      { '<leader>nd', ':Obsidian today<cr>', desc = 'obsidian [d]aily' },
      { '<leader>nt', ':Obsidian tomorrow<cr>', desc = 'obsidian [t]omorrow' },
      { '<leader>ny', ':Obsidian yesterday<cr>', desc = 'obsidian [y]esterday' },
      { '<leader>nb', ':Obsidian backlinks<cr>', desc = 'obsidian [b]acklinks' },
      { '<leader>nf', ':Obsidian follow_link<cr>', desc = 'obsidian [f]ollow link' },
      { '<leader>nn', ':Obsidian new<cr>', desc = 'obsidian [n]ew' },
      { '<leader>ns', ':Obsidian search<cr>', desc = 'obsidian [s]earch' },
      { '<leader>no', ':Obsidian quick_switch<cr>', desc = 'obsidian [o]pen quickswitch' },
      { '<leader>nO', ':Obsidian open<cr>', desc = 'obsidian [O]pen in app' },
      { '<leader>nc', ':Obsidian toggle_checkbox<cr>', desc = 'obsidian [c]heckbox toggle' },
      { '<leader>nw', ':Obsidian workspace<cr>', desc = 'obsidian [w]orkspace switch' },
      { '<leader>na', function() require('obsidian.actions').add_property() end, desc = 'obsidian [a]dd frontmatter property (alias, etc.)' },
      { '<leader>nT', function() require('obsidian.actions').add_tag() end, desc = 'obsidian add [T]ag' },
      { '<leader>nS', ob_sync_current_vault, desc = 'ob [S]ync current vault' },
      { '<leader>nr', function() require('config.evergreen').reading_view() end, desc = 'evergreen [r]eading view (stitch child notes by page)' },
      { '<leader>nnc', function() require('config.evergreen').new_child_note() end, desc = 'evergreen new [n]ote: [c]hild (linked to source)' },
      { '<leader>nns', function() require('config.evergreen').new_source_note() end, desc = 'evergreen new [n]ote: [s]ource' },
    },
    ---@module 'obsidian'
    ---@type obsidian.config
    opts = {
      legacy_commands = false,
      workspaces = {
        { name = 'work', path = '~/vaults/work' },
        { name = 'books', path = '~/vaults/books' },
      },
    },
    config = function(_, opts)
      require('obsidian').setup(opts)
      -- obsidian's checkbox/link UI features need conceallevel 1-2; the config
      -- default is 0 elsewhere, so scope this to vault note buffers only.
      vim.api.nvim_create_autocmd('User', {
        pattern = 'ObsidianNoteEnter',
        callback = function() vim.wo.conceallevel = 1 end,
      })
      vim.api.nvim_create_autocmd('User', {
        pattern = 'ObsidianNoteLeave',
        callback = function() vim.wo.conceallevel = 0 end,
      })
    end,
  },
}
