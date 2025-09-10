return {
  { 'projekt0n/github-nvim-theme', enabled = true, lazy = false, priority = 1000 },
  { 'marko-cerovac/material.nvim', enabled = true, lazy = false, priority = 1000 },
  { 'shaunsingh/nord.nvim', enabled = false, lazy = false, priority = 1000 },
  { 'folke/tokyonight.nvim', enabled = false, lazy = false, priority = 1000 },
  { 'EdenEast/nightfox.nvim', enabled = false, lazy = false, priority = 1000 },
  { 'Mofiqul/vscode.nvim', enabled = true, lazy = false, priority = 1000 },
  {
    'catppuccin/nvim',
    name = 'catppuccin',
    enabled = false,
    lazy = false, -- make sure we load this during startup if it is your main colorscheme
    priority = 1000, -- make sure to load this before all the other start plugins
    config = function()
      -- set colorscheme and overwrite highlights
      vim.cmd.colorscheme 'catppuccin-mocha'
      local colors = require 'catppuccin.palettes.mocha'
      vim.api.nvim_set_hl(0, 'Tabline', { fg = colors.green, bg = colors.mantle })
      vim.api.nvim_set_hl(0, 'TermCursor', { fg = '#A6E3A1', bg = '#A6E3A1' })
    end,
  },

  {
    'oxfist/night-owl.nvim',
    enabled = true,
    lazy = false,
    priority = 1000,
    config = function()
      -- load the colorscheme here
      require('night-owl').setup()
      vim.cmd.colorscheme 'night-owl'
      vim.api.nvim_set_hl(0, 'TermCursor', { fg = '#A6E3A1', bg = '#A6E3A1' })
    end,
  },

  {
    'rebelot/kanagawa.nvim',
    enabled = true,
    lazy = false,
    priority = 1000,
    config = function()
      require('kanagawa').setup({
        compile = false,             -- enable compiling the colorscheme
        undercurl = true,            -- enable undercurls
        commentStyle = { italic = true },
        functionStyle = { italic = true, bold = true},
        keywordStyle = { italic = true },
        statementStyle = { bold = true },
        typeStyle = {},
        transparent = false,         -- do not set background color
        dimInactive = true,         -- dim inactive window `:h hl-NormalNC`
        terminalColors = true,       -- define vim.g.terminal_color_{0,17}
        overrides = function(colors)
          return {}
        end,
        colors = {
          theme = {
            all = {
              ui = {
                bg_gutter = 'none',
              },
            },
          },
        },
        theme = 'wave',
        background = {
          dark = 'wave',
          light = 'lotus'
        }
      })
      vim.cmd.colorscheme 'kanagawa'
      vim.api.nvim_set_hl(0, 'TermCursor', { fg = '#A6E3A1', bg = '#A6E3A1' })
    end,
  },

  {
    'olimorris/onedarkpro.nvim',
    enabled = true,
    lazy = false,
    priority = 1000,
  },

  {
    'neanias/everforest-nvim',
    enabled = true,
    lazy = false,
    priority = 1000,
  },

  -- color html colors
  {
    'NvChad/nvim-colorizer.lua',
    enabled = true,
    opts = {
      filetypes = { '*' },
      user_default_options = {
        RGB = true, -- #RGB hex codes
        RRGGBB = true, -- #RRGGBB hex codes
        names = true, -- "Name" codes like Blue or blue
        RRGGBBAA = true, -- #RRGGBBAA hex codes
        AARRGGBB = false, -- 0xAARRGGBB hex codes
        rgb_fn = false, -- CSS rgb() and rgba() functions
        hsl_fn = false, -- CSS hsl() and hsla() functions
        css = false, -- Enable all CSS features: rgb_fn, hsl_fn, names, RGB, RRGGBB
        css_fn = false, -- Enable all CSS *functions*: rgb_fn, hsl_fn
        -- Available modes for `mode`: foreground, background,  virtualtext
        mode = 'background', -- Set the display mode.
        -- Available methods are false / true / "normal" / "lsp" / "both"
        -- True is same as normal
        tailwind = false, -- Enable tailwind colors
        -- parsers can contain values used in |user_default_options|
        sass = { enable = false, parsers = { 'css' } }, -- Enable sass colors
        virtualtext = '■',
        -- update color values even if buffer is not focused
        -- example use: cmp_menu, cmp_docs
        always_update = false,
        -- all the sub-options of filetypes apply to buftypes
      },
      buftypes = {},
    },
  },
}
