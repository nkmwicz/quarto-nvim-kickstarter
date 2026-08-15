-- TypeScript 7's native compiler restructured the npm package (no more
-- tsserver.js), so it needs nvim-lspconfig's `tsc` server (talks to the
-- native `tsc --lsp --stdio`) instead of typescript-tools.nvim's classic
-- tsserver.js protocol. Detect which one a project is on by reading the
-- version out of its local node_modules/typescript, so exactly one of the
-- two servers attaches per buffer.
local function get_local_ts_major(bufnr)
  local root = vim.fs.root(bufnr, { 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lockb', 'bun.lock', '.git' })
  if not root then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, root .. '/node_modules/typescript/package.json')
  if not ok or not lines or #lines == 0 then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not decoded_ok or not decoded or not decoded.version then
    return nil
  end
  return tonumber(decoded.version:match '^(%d+)')
end

local function is_ts7_project(bufnr)
  local major = get_local_ts_major(bufnr)
  return major ~= nil and major >= 7
end

return {
  {
    -- Persists ltex-ls code actions (add to dictionary, disable rule, hide false
    -- positive) to disk so they survive restarts. Stores additions in dict/ alongside
    -- the existing word files (en.dictionary, fr.dictionary — different names, no clash).
    'barreiroleo/ltex_extra.nvim',
    ft = { 'latex', 'tex', 'bib', 'markdown', 'gitcommit', 'text', 'quarto' },
    dependencies = { 'neovim/nvim-lspconfig' },
  },
  {

    -- for lsp features in code cells / embedded code
    'jmbuhr/otter.nvim',
    dev = false,
    dependencies = {
      {
        'neovim/nvim-lspconfig',
        'nvim-treesitter/nvim-treesitter',
      },
    },
    opts = {
      verbose = {
        no_code_found = false,
      },
    },
  },

  {
    -- replaces ts_ls: faster, richer refactors, and inlay hints out of the box.
    -- needs the `typescript` npm package resolvable (global install or per-project node_modules).
    'pmizio/typescript-tools.nvim',
    ft = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact' },
    dependencies = { 'neovim/nvim-lspconfig', 'nvim-lua/plenary.nvim' },
    opts = {
      -- defer to lspconfig's `tsc` server on TS7 projects (see is_ts7_project above)
      root_dir = function(bufnr, on_dir)
        if is_ts7_project(bufnr) then
          return
        end
        on_dir(require('typescript-tools.utils').get_root_dir(bufnr))
      end,
      settings = {
        tsserver_file_preferences = {
          includeInlayParameterNameHints = 'all',
          includeInlayParameterNameHintsWhenArgumentMatchesName = true,
          includeInlayFunctionParameterTypeHints = true,
          includeInlayVariableTypeHints = true,
          includeInlayPropertyDeclarationTypeHints = true,
          includeInlayFunctionLikeReturnTypeHints = true,
          includeInlayEnumMemberValueHints = true,
        },
      },
    },
  },

  {
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'williamboman/mason.nvim' },
      { 'williamboman/mason-lspconfig.nvim' },
      { 'WhoIsSethDaniel/mason-tool-installer.nvim' },
      { -- nice loading notifications
        -- PERF: but can slow down startup
        'j-hui/fidget.nvim',
        enabled = false,
        opts = {},
      },
      {
        {
          'folke/lazydev.nvim',
          ft = 'lua', -- only load on lua files
          opts = {
            library = {
              -- See the configuration section for more details
              -- Load luvit types when the `vim.uv` word is found
              { path = 'luvit-meta/library', words = { 'vim%.uv' } },
            },
          },
        },
        { 'Bilal2453/luvit-meta', lazy = true }, -- optional `vim.uv` typings
        { -- optional completion source for require statements and module annotations
          'hrsh7th/nvim-cmp',
          opts = function(_, opts)
            opts.sources = opts.sources or {}
            table.insert(opts.sources, {
              name = 'lazydev',
              group_index = 0, -- set group index to 0 to skip loading LuaLS completions
            })
          end,
        },
        -- { "folke/neodev.nvim", enabled = false }, -- make sure to uninstall or disable neodev.nvim
      },
      { 'folke/neoconf.nvim', opts = {}, enabled = false },
    },
    config = function()
      -- ltex-ls ships its own JDK; point JAVA_HOME at it before any server starts.
      vim.env.JAVA_HOME = '/usr/local/bin/ltex-ls/jdk-11.0.12+7'
      vim.env.PATH = vim.env.PATH .. ':' .. vim.env.JAVA_HOME .. '/bin'

      local lspconfig = require 'lspconfig'
      local util = require 'lspconfig.util'

      require('mason').setup()
      require('mason-lspconfig').setup {
        ensure_installed = {
          'pyright',
          'lua_ls', -- Corrected server name for Lua
          'html',
          'cssls',
          'jsonls',
          'yamlls',
          'bashls',
          'vimls',
          'dotls',
          'marksman',
          'tailwindcss',
          'emmet_ls',
          'ltex',
        },
        automatic_installation = true,
        automatic_enable = true,
      }
      require('mason-tool-installer').setup {
        ensure_installed = {
          'black',
          'stylua',
          'shfmt',
          'tailwindcss',
          'isort',
          'tree-sitter-cli',
          'jupytext',
          'eslint_d',
          'prettier',
        },
      }

      -- create footnote highliter
      local function quarto_highlighter()
        -- Clear Existing syntax for this group (important for reloads)
        vim.api.nvim_command 'silent! syntax clear QuartoFootnote'

        -- Define Syntax to Match pattern Text^[Footnote]
        vim.api.nvim_command [[
          syntax match QuartoFootnote /\^\[.\{-}\]/ contains=@Spell
        ]]
        vim.api.nvim_command 'highlight link QuartoFootnote Special'
      end

      vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
        pattern = { '*.md', '*.markdown', '*.qmd' },
        callback = quarto_highlighter,
      })

      -- Apply syntax highlighting immediately
      if vim.bo.filetype == 'markdown' or vim.bo.filetype == 'quarto' then
        quarto_highlighter()
      end

      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          local function map(keys, func, desc)
            vim.keymap.set('n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end
          local function vmap(keys, func, desc)
            vim.keymap.set('v', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          assert(client, 'LSP client not found')

          ---@diagnostic disable-next-line: inject-field
          client.server_capabilities.document_formatting = true

          map('gS', vim.lsp.buf.document_symbol, '[g]o so [S]ymbols')
          map('gD', vim.lsp.buf.type_definition, '[g]o to type [D]efinition')
          map('gd', vim.lsp.buf.definition, '[g]o to [d]efinition')
          map('<leader>k', vim.lsp.buf.hover, '<leader>[k] hover documentation')
          map('gh', vim.lsp.buf.signature_help, '[g]o to signature [h]elp')
          map('gI', vim.lsp.buf.implementation, '[g]o to [I]mplementation')
          map('gr', vim.lsp.buf.references, '[g]o to [r]eferences')
          map('[d', function()
            vim.diagnostic.jump { count = 1 }
          end, 'previous [d]iagnostic ')
          map(']d', function()
            vim.diagnostic.jump { count = -1 }
          end, 'next [d]iagnostic ')
          map('<leader>ll', vim.lsp.codelens.run, '[l]ens run')
          map('<leader>lR', vim.lsp.buf.rename, '[l]sp [R]ename')
          map('<leader>lf', vim.lsp.buf.format, '[l]sp [f]ormat')
          vmap('<leader>lf', vim.lsp.buf.format, '[l]sp [f]ormat')
          map('<leader>lq', vim.diagnostic.setqflist, '[l]sp diagnostic [q]uickfix')

          if client:supports_method 'textDocument/inlayHint' then
            vim.lsp.inlay_hint.enable(true, { bufnr = event.buf })
            map('<leader>lh', function()
              local enabled = vim.lsp.inlay_hint.is_enabled { bufnr = event.buf }
              vim.lsp.inlay_hint.enable(not enabled, { bufnr = event.buf })
            end, '[l]sp toggle inlay [h]ints')
          end
        end,
      })

      local lsp_flags = {
        allow_incremental_sync = true,
        debounce_text_changes = 150,
      }

      vim.lsp.handlers['textDocument/hover'] = vim.lsp.with(vim.lsp.handlers.hover, { border = require('misc.style').border })
      vim.lsp.handlers['textDocument/signatureHelp'] = vim.lsp.with(vim.lsp.handlers.signature_help, { border = require('misc.style').border })

      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())
      capabilities.textDocument.completion.completionItem.snippetSupport = true

      -- also needs:
      -- $home/.config/marksman/config.toml :
      -- [core]
      -- markdown.file_extensions = ["md", "markdown", "qmd"]
      vim.lsp.config('marksman', {
        capabilities = capabilities,
        filetypes = { 'markdown', 'quarto' },
        root_dir = function(bufnr, on_dir)
          local fname = vim.api.nvim_buf_get_name(bufnr)
          on_dir(util.root_pattern('.git', '.marksman.toml', '_quarto.yml')(fname))
        end,
      })
      vim.lsp.enable('marksman')

      vim.lsp.config('cssls', {
        capabilities = capabilities,
        flags = lsp_flags,
      })
      vim.lsp.enable('cssls')

      vim.lsp.config('html', {
        capabilities = capabilities,
        flags = lsp_flags,
      })
      vim.lsp.enable('html')

      vim.lsp.config('emmet_language_server', {
        capabilities = capabilities,
        flags = lsp_flags,
      })
      vim.lsp.enable('emmet_language_server')

      vim.lsp.config('yamlls', {
        capabilities = capabilities,
        flags = lsp_flags,
        settings = {
          yaml = {
            schemaStore = {
              enable = true,
              url = '',
            },
          },
        },
      })
      vim.lsp.enable('yamlls')

      vim.lsp.config('jsonls', {
        capabilities = capabilities,
        flags = lsp_flags,
      })
      vim.lsp.enable('jsonls')

      vim.lsp.config('dotls', {
        capabilities = capabilities,
        flags = lsp_flags,
      })
      vim.lsp.enable('dotls')

      -- native TS7 LSP (`tsc --lsp --stdio`); only attaches when the project's
      -- local TypeScript is >=7 (see is_ts7_project), otherwise typescript-tools.nvim handles it
      vim.lsp.config('tsc', {
        capabilities = capabilities,
        root_dir = function(bufnr, on_dir)
          if not is_ts7_project(bufnr) then
            return
          end
          local root = vim.fs.root(bufnr, { 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lockb', 'bun.lock', '.git' })
          on_dir(root or vim.fn.getcwd())
        end,
      })
      vim.lsp.enable('tsc')

      local function get_quarto_resource_path()
        local function strsplit(s, delimiter)
          local result = {}
          for match in (s .. delimiter):gmatch('(.-)' .. delimiter) do
            table.insert(result, match)
          end
          return result
        end

        local f = assert(io.popen('quarto --paths', 'r'))
        local s = assert(f:read '*a')
        f:close()
        return strsplit(s, '\n')[2]
      end

      local lua_library_files = vim.api.nvim_get_runtime_file('', true)
      local lua_plugin_paths = {}
      local resource_path = get_quarto_resource_path()
      if resource_path == nil then
        vim.notify_once 'quarto not found, lua library files not loaded'
      else
        table.insert(lua_library_files, resource_path .. '/lua-types')
        table.insert(lua_plugin_paths, resource_path .. '/lua-plugin/plugin.lua')
      end

      vim.lsp.config('lua_ls', {
        capabilities = capabilities,
        flags = lsp_flags,
        settings = {
          Lua = {
            completion = {
              callSnippet = 'Replace',
            },
            runtime = {
              version = 'LuaJIT',
              -- plugin = lua_plugin_paths, -- handled by lazydev
            },
            diagnostics = {
              disable = { 'trailing-space' },
            },
            workspace = {
              -- library = lua_library_files, -- handled by lazydev
              checkThirdParty = false,
            },
            doc = {
              privateName = { '^_' },
            },
            telemetry = {
              enable = false,
            },
          },
        },
      })
      vim.lsp.enable('lua_ls')

      vim.lsp.config('vimls', {
        capabilities = capabilities,
        flags = lsp_flags,
      })
      vim.lsp.enable('vimls')

      vim.lsp.config('julials', {
        capabilities = capabilities,
        flags = lsp_flags,
      })
      vim.lsp.enable('julials')

      vim.lsp.config('bashls', {
        capabilities = capabilities,
        flags = lsp_flags,
        filetypes = { 'sh', 'bash' },
      })
      vim.lsp.enable('bashls')

      -- Add additional languages here.
      -- See `:h lspconfig-all` for the configuration.
      -- Like e.g. Haskell:
      -- vim.lsp.config.hls.setup {
      --   capabilities = capabilities,
      --   flags = lsp_flags
      -- }

      -- vim.lsp.config.clangd.setup {
      --   capabilities = capabilities,
      --   flags = lsp_flags,
      -- }

      -- vim.lsp.config.rust_analyzer.setup {
      --  capabilities = capabilities,
      -- settings = {
      --    ['rust-analyzer'] = {
      --      diagnostics = {
      --        enable = false,
      --      },
      --    },
      --  },
      -- }

      -- vim.lsp.config.ruff_lsp.setup {
      --   capabilities = capabilities,
      --   flags = lsp_flags,
      -- }

      vim.lsp.config('ltex', {
        capabilities = capabilities,
        flags = lsp_flags,
        filetypes = { 'latex', 'tex', 'bib', 'markdown', 'gitcommit', 'text', 'quarto' },
        settings = {
          ltex = {
            enabled = { 'latex', 'tex', 'bib', 'markdown', 'quarto' },
            language = 'auto',
            diagnosticSeverity = 'information',
            sentenceCacheSize = 2000,
            additionalRules = {
              enablePickyRules = true,
              motherTongue = 'en',
            },
            disabledRules = {
              en = { 'EN_QUOTES' },
              fr = { 'APOS_TYP', 'FRENCH_WHITESPACE' },
            },
            dictionary = (function()
              local files = {}
              for _, file in ipairs(vim.api.nvim_get_runtime_file('dict/*', true)) do
                local lang = vim.fn.fnamemodify(file, ':t:r')
                local fullpath = vim.fs.normalize(file, { absolute = true })
                files[lang] = { ':' .. fullpath }
              end
              if files.default then
                for lang, _ in pairs(files) do
                  if lang ~= 'default' then
                    vim.list_extend(files[lang], files.default)
                  end
                end
                files.default = nil
              end
              return files
            end)(),
            hiddenFalsePositives = {
              en = { '{"rule": "", "sentence": "\\\\\\\\^\\\\w+"}', '{"rule": "", "sentence": "Thisproject"}' },
              fr = { '{"rule":"MORFOLOGIK_RULE_FR", "sentence":"\\\\^\\\\w"}' },
            },
          },
        },
        on_attach = function(_, bufnr)
          -- Resolve project root (walk up from the buffer for _quarto.yml or .git),
          -- then store ltex-extra files in <root>/.vscode/ltex so they are
          -- per-project and tracked in the project's own git repo, not here.
          local markers = { '_quarto.yml', '_quarto.yaml', '.git' }
          local buf_path = vim.api.nvim_buf_get_name(bufnr)
          local root = vim.fs.dirname(
            vim.fs.find(markers, { upward = true, path = buf_path })[1]
          ) or vim.fn.getcwd()
          require('ltex_extra').setup {
            load_langs = { 'en', 'fr' },
            init_check = true,
            path = root .. '/.vscode/ltex',
          }
        end,
      })
      vim.lsp.enable 'ltex'

      -- See https://github.com/neovim/neovim/issues/23291
      -- disable lsp watcher.
      -- Too lags on linux for python projects
      -- because pyright and nvim both create too many watchers otherwise
      if capabilities.workspace == nil then
        capabilities.workspace = {}
        capabilities.workspace.didChangeWatchedFiles = {}
      end
      capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false

      vim.lsp.config('pyright', {
        capabilities = capabilities,
        flags = lsp_flags,
        settings = {
          python = {
            analysis = {
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              diagnosticMode = 'workspace',
            },
          },
        },
        root_dir = function(bufnr, on_dir)
          local fname = vim.api.nvim_buf_get_name(bufnr)
          local root = util.root_pattern('.git', 'setup.py', 'setup.cfg', 'pyproject.toml', 'requirements.txt')(fname) or util.path.dirname(fname)
          on_dir(root)
        end,
      })
      vim.lsp.enable('pyright')

      -- Configure black as a formatter for Python files
      vim.api.nvim_create_autocmd('BufWritePre', {
        pattern = { '*.py', '*.qmd' },
        callback = function()
          if vim.bo.filetype == 'python' or vim.bo.filetype == 'quarto' then
            vim.lsp.buf.format { async = false }
          end
        end,
      })
    end,
  },
}
