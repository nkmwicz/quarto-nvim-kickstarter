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
          'tsx',
          'bibtex',
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
      -- Fold options and the open-folds-on-read safety net live in
      -- config.global / config.autocommands (loaded before any buffer),
      -- not here — see those files.
      vim.api.nvim_set_keymap('n', '<Tab>', 'za', { noremap = true, silent = true })
    end,
  },

  { -- auto-close and auto-rename matching JSX/HTML tags
    'windwp/nvim-ts-autotag',
    ft = { 'html', 'javascript', 'javascriptreact', 'typescript', 'typescriptreact', 'xml', 'markdown' },
    opts = {},
  },
}
