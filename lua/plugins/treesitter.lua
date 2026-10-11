-- nvim-treesitter `main` branch: a rewrite of the old (frozen) `master`
-- branch. It only installs parsers and ships queries; everything the old
-- `configs.setup{ highlight = …, indent = …, textobjects = … }` did is now
-- wired up by hand below, via a FileType autocmd and explicit keymaps.
--
-- Requirements (per machine — see `:checkhealth kickstart`):
--   * Neovim 0.12+
--   * tree-sitter CLI 0.26.1+ (Mason's `tree-sitter-cli`; apt's is too old)
--   * a C compiler, curl, tar
-- Parsers compile into stdpath('data')/site, not into the plugin directory.

-- Always installed. Anything else installs on demand the first time a buffer
-- of that filetype is opened (what the old `auto_install = true` did).
local ensure_installed = {
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
  'latex',
  'html',
  'css',
  'dot',
  'javascript',
  'mermaid',
  'typescript',
  'tsx',
  'bibtex',
}

local MIN_TS_CLI = '0.26.1'

-- Mason prepends its bin/ to PATH only once mason.nvim itself loads, which
-- may be after this config runs. Do it here too so `tree-sitter` resolves to
-- Mason's copy rather than an older system one (apt ships 0.25.x).
local mason_bin = vim.fs.joinpath(vim.fn.stdpath 'data', 'mason', 'bin')
if not vim.env.PATH:find(mason_bin, 1, true) then
  vim.env.PATH = mason_bin .. ':' .. vim.env.PATH
end

--- true if a new-enough tree-sitter CLI is on PATH (a pass is cached)
local cli_found = false
local function ts_cli_ok()
  if cli_found or vim.fn.executable 'tree-sitter' == 0 then
    return cli_found
  end
  local out = vim.fn.system { 'tree-sitter', '--version' }
  local v = vim.version.parse(out:match '(%d+%.%d+%.%d+)' or '')
  cli_found = v ~= nil and vim.version.ge(v, MIN_TS_CLI)
  return cli_found
end

local has_nvim_012 = vim.fn.has 'nvim-0.12' == 1
if not has_nvim_012 then
  vim.schedule(function()
    vim.notify(
      'Treesitter disabled: this config needs Neovim 0.12+ (found ' .. tostring(vim.version()) .. ').\n' .. 'Rerun ~/dotfiles/install.sh to upgrade.',
      vim.log.levels.ERROR
    )
  end)
end

local function textobj_maps(buf)
  local select = require 'nvim-treesitter-textobjects.select'
  local move = require 'nvim-treesitter-textobjects.move'
  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, desc = desc })
  end
  for lhs, query in pairs {
    af = '@function.outer',
    ['if'] = '@function.inner',
    ac = '@class.outer',
    ic = '@class.inner',
  } do
    map({ 'x', 'o' }, lhs, function()
      select.select_textobject(query, 'textobjects')
    end, query)
  end
  for lhs, spec in pairs {
    [']m'] = { 'goto_next_start', '@function.outer' },
    [']]'] = { 'goto_next_start', '@class.inner' },
    [']M'] = { 'goto_next_end', '@function.outer' },
    [']['] = { 'goto_next_end', '@class.outer' },
    ['[m'] = { 'goto_previous_start', '@function.outer' },
    ['[['] = { 'goto_previous_start', '@class.inner' },
    ['[M'] = { 'goto_previous_end', '@function.outer' },
    ['[]'] = { 'goto_previous_end', '@class.outer' },
  } do
    map({ 'n', 'x', 'o' }, lhs, function()
      move[spec[1]](spec[2], 'textobjects')
    end, spec[2])
  end
end

-- Turn on highlighting, indent and textobject keymaps for one buffer.
-- Keymaps are buffer-local, set after the filetype's own ftplugin has run,
-- so they win over e.g. the built-in python ftplugin's ]] / [[ / ]m maps
-- (the old textobjects module attached per-buffer the same way).
local function attach(buf, lang)
  if not vim.api.nvim_buf_is_valid(buf) or not pcall(vim.treesitter.start, buf, lang) then
    return
  end
  if vim.treesitter.query.get(lang, 'indents') then
    vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
  end
  if vim.treesitter.query.get(lang, 'textobjects') then
    textobj_maps(buf)
  end
end

return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    cond = has_nvim_012,
    lazy = false, -- main does not support lazy-loading
    build = ':TSUpdate',
    dependencies = {
      { 'nvim-treesitter/nvim-treesitter-textobjects', branch = 'main' },
    },
    config = function()
      local ts = require 'nvim-treesitter'

      -- quarto-nvim registers this in its own ftplugin, but only once it has
      -- loaded; registering here too means the first quarto buffer of a
      -- session never races it.
      vim.treesitter.language.register('markdown', { 'quarto', 'rmd' })

      require('nvim-treesitter-textobjects').setup {
        select = { lookahead = true },
        move = { set_jumps = true },
      }

      -- Install missing parsers. On a fresh machine Mason may still be
      -- fetching tree-sitter-cli, so wait for mason-tool-installer to finish
      -- rather than failing every build with "tree-sitter not found".
      local function install_parsers()
        ts.install(ensure_installed)
      end
      if ts_cli_ok() then
        install_parsers()
      else
        vim.api.nvim_create_autocmd('User', {
          pattern = 'MasonToolsUpdateCompleted',
          once = true,
          callback = function()
            if ts_cli_ok() then
              install_parsers()
            else
              vim.notify('tree-sitter CLI ' .. MIN_TS_CLI .. '+ not found; treesitter parsers cannot be built. See :checkhealth kickstart', vim.log.levels.WARN)
            end
          end,
        })
      end

      local available = {}
      for _, lang in ipairs(ts.get_available()) do
        available[lang] = true
      end

      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('treesitter-attach', { clear = true }),
        callback = function(args)
          local buf = args.buf
          -- bigfile.nvim flags oversized buffers; leave them alone
          if vim.b[buf].bigfile_disable_treesitter then
            return
          end
          local lang = vim.treesitter.language.get_lang(args.match)
          if not lang then
            return
          end
          if vim.treesitter.language.add(lang) then
            attach(buf, lang)
          elseif available[lang] and ts_cli_ok() then
            ts.install(lang):await(function(err)
              if not err then
                vim.schedule(function()
                  attach(buf, lang)
                end)
              end
            end)
          end
        end,
      })

      -- Incremental selection. The old module is gone; Neovim 0.12 has it
      -- built in as visual-mode `an` (grow) / `in` (shrink) / `]n` `[n`
      -- (siblings). Keep the old keys as aliases onto those.
      vim.keymap.set('n', 'gnn', 'van', { remap = true, desc = 'start node selection' })
      vim.keymap.set('x', 'grn', 'an', { remap = true, desc = 'grow node selection' })
      vim.keymap.set('x', 'grm', 'in', { remap = true, desc = 'shrink node selection' })

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
