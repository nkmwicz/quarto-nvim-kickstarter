return {
  -- { 'shaunsingh/nord.nvim', enabled = true, lazy = false, priority = 1000 },
  -- { 'folke/tokyonight.nvim', enabled = true, lazy = false, priority = 1000 },
  -- { 'EdenEast/nightfox.nvim', enabled = true, lazy = false, priority = 1000 },
  -- { 'Mofiqul/vscode.nvim', enabled = true, lazy = false, priority = 1000 },
  {
    'catppuccin/nvim',
    name = 'catppuccin',
    enabled = false,
    lazy = false, -- make sure we load this during startup if it is your main colorscheme
    priority = 1000, -- make sure to load this before all the other start plugins
    config = function()
      require('catppuccin').setup({
        flavour = 'mocha',
        integrations = {
          treesitter = true,
          native_lsp = { enabled = true },
          markdown = true,
          telescope = { enabled = true },
        },
      })
      -- set colorscheme and overwrite highlights
      vim.cmd.colorscheme 'catppuccin-mocha'
      local colors = require 'catppuccin.palettes.mocha'
      vim.api.nvim_set_hl(0, 'Tabline', { fg = colors.green, bg = colors.mantle })
      vim.api.nvim_set_hl(0, 'TermCursor', { fg = '#A6E3A1', bg = '#A6E3A1' })
    end,
  },

  -- {
  --   'oxfist/night-owl.nvim',
  --   enabled = false,
  --   lazy = false,
  --   priority = 1000,
  --   config = function()
  --     -- load the colorscheme here
  --     require('night-owl').setup()
  --     vim.cmd.colorscheme 'night-owl'
  --     vim.api.nvim_set_hl(0, 'TermCursor', { fg = '#A6E3A1', bg = '#A6E3A1' })
  --   end,
  -- },

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
        functionStyle = { italic = true, bold = true, underline = true },
        keywordStyle = { italic = true },
        statementStyle = { bold = true },
        typeStyle = {},
        transparent = false,         -- do not set background color
        dimInactive = true,         -- dim inactive window `:h hl-NormalNC`
        terminalColors = true,       -- define vim.g.terminal_color_{0,17}
        overrides = function(colors)
          local theme = colors.theme
          -- theme.syn.constant is the real orange (surimiOrange/lotusOrange);
          -- theme.syn.fun is the default function blue, repurposed here for vars.
          -- Left as direct group overrides (not shared theme.syn.* slots) so
          -- unrelated things that read those slots (e.g. Directory) are untouched.
          local orange = theme.syn.constant
          local blue = theme.syn.fun
          local func_style = { italic = true, bold = true, underline = true }
          return {
            -- functions: declarations, calls, methods, builtins, constructors -> orange, underlined
            ['Function'] = vim.tbl_extend('force', { fg = orange }, func_style),
            ['@constructor'] = vim.tbl_extend('force', { fg = orange }, func_style),
            ['@lsp.typemod.function.readonly'] = vim.tbl_extend('force', { fg = orange }, func_style),
            -- builtins like range()/list()/dict() default-link to Special (light
            -- blue) via Neovim, bypassing Function entirely -- pull them back in.
            -- @function.builtin alone wins priority over @type.builtin in an
            -- actual call, so range(10) etc. still come out orange below.
            ['@function.builtin'] = vim.tbl_extend('force', { fg = orange }, func_style),

            -- typings: builtin/primitive types used as annotations (not called)
            -- -> light gray. Only fires without @function.builtin in the mix,
            -- so it never competes with the orange builtin-call styling above,
            -- and it's a separate capture from plain @type, so it doesn't touch
            -- class declarations/instantiation (still bold+boxed / orange).
            ['@type.builtin'] = { fg = theme.syn.comment },

            -- variables: plain names, member/property access, `const`-style readonly
            -- bindings (which kanagawa otherwise links to Constant), LSP-typed
            -- "variable" tokens (var/let/const in JS-TS, plain assignment in Python),
            -- and parameters -> blue
            ['@variable'] = { fg = blue },
            ['@variable.member'] = { fg = blue },
            ['@lsp.mod.readonly'] = { fg = blue },
            ['@lsp.type.variable'] = { fg = blue },
            ['@variable.parameter'] = { fg = blue },
            -- class fields/properties: LSP's "property" semantic type falls back
            -- to Identifier (the Constant yellow) by default, overriding the
            -- treesitter @variable.member blue above since semantic tokens render
            -- at higher priority
            ['@lsp.type.property'] = { fg = blue },

            -- genuine literal constants (ALL_CAPS, enums, etc. -- not `const`
            -- bindings, which are just vars above) -> the yellow displaced from
            -- @variable.member, so they no longer collide with function-orange
            ['Constant'] = { fg = theme.syn.identifier },

            -- classes: bold with a background "block" behind the name.
            -- Verified directly against the python/typescript grammars: neither
            -- emits a class-specific capture (nor LSP semantic "class" tokens in
            -- this setup) -- class names, declared or used, are tagged @type,
            -- which is also what interfaces/generics/type-aliases use. There's
            -- no finer-grained hook available, so this styles all of @type.
            ['Type'] = { fg = theme.syn.type, bg = theme.ui.bg_p2, bold = true },
            ['@lsp.type.class'] = { fg = theme.syn.type, bg = theme.ui.bg_p2, bold = true },

            -- markdown/qmd headers: kanagawa links @markup.heading -> Function
            -- (orange) by default, which drags headers along with our
            -- Python/JS function-orange override above. Break that link and
            -- give headers their own color instead. All heading levels
            -- (@markup.heading.1..6) fall back to this since kanagawa never
            -- sets the per-level groups.
            ['@markup.heading'] = { fg = blue, bold = true },
          }
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
