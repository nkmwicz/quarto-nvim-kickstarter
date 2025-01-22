return {
  {
    'nvim-treesitter/nvim-treesitter',
    dev = false,
    dependencies = {
      {
        'nvim-treesitter/nvim-treesitter-textobjects',
      },
    },
    run = ':TSUpdate',
    config = function()
      ---@diagnostic disable-next-line: missing-fields
      require('nvim-treesitter.configs').setup {
        auto_install = true,
        ensure_installed = {
          'r',
          'python',
          'markdown',
          'markdown_inline',
          'julia',
          'bash',
          'yaml',
          'lua',
          'vim',
          'query',
          'vimdoc',
          'latex', -- requires tree-sitter-cli (installed automatically via Mason)
          'html',
          'css',
          'dot',
          'javascript',
          'mermaid',
          'norg',
          'typescript',
        },
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        indent = {
          enable = true,
        },
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = 'gnn',
            node_incremental = 'grn',
            scope_incremental = 'grc',
            node_decremental = 'grm',
          },
        },
        textobjects = {
          select = {
            enable = true,
            lookahead = true,
            keymaps = {
              -- You can use the capture groups defined in textobjects.scm
              ['af'] = '@function.outer',
              ['if'] = '@function.inner',
              ['ac'] = '@class.outer',
              ['ic'] = '@class.inner',
            },
          },
          move = {
            enable = true,
            set_jumps = true, -- whether to set jumps in the jumplist
            goto_next_start = {
              [']m'] = '@function.outer',
              [']]'] = '@class.inner',
            },
            goto_next_end = {
              [']M'] = '@function.outer',
              [']['] = '@class.outer',
            },
            goto_previous_start = {
              ['[m'] = '@function.outer',
              ['[['] = '@class.inner',
            },
            goto_previous_end = {
              ['[M'] = '@function.outer',
              ['[]'] = '@class.outer',
            },
          },
        },
        -- fold = {
        --   enable = true,
        --   indent_levels = true,
        -- },
      }
      vim.o.foldmethod = 'expr'
      vim.o.foldexpr = 'nvim_treesitter#foldexpr()' -- treesitter folding
      -- vim.opt.foldtext = "v:folddashes.repeat(v:foldlevel)..' ' .. v:foldstart .. ' lines: ' .. (v:foldend - v:foldstart + 1)"
      vim.api.nvim_set_keymap('n', '<Tab>', 'za', { noremap = true, silent = true })
      local vim = vim
      local api = vim.api
      local M = {}
      function M.nvim_create_augroups(definitions)
        for group_name, definition in pairs(definitions) do
          api.nvim_command('augroup ' .. group_name)
          api.nvim_command 'autocmd!'
          for _, def in ipairs(definition) do
            local command = table.concat(vim.tbl_flatten { 'autocmd', def }, ' ')
            api.nvim_command(command)
          end
          api.nvim_command 'augroup END'
        end
      end

      local autoCommands = {
        -- other autocommands
        open_folds = {
          { 'BufReadPost,FileReadPost', '*', 'normal zR' },
        },
      }

      M.nvim_create_augroups(autoCommands)
    end,
  },
}
