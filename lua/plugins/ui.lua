return {
  -- telescope
  -- a nice seletion UI also to find and open files
  {
    'nvim-telescope/telescope.nvim',
    dependencies = {
      { 'nvim-telescope/telescope-ui-select.nvim' },
      { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
      { 'nvim-telescope/telescope-dap.nvim' },
      {
        'nvim-telescope/telescope-bibtex.nvim',
        config = function()
          vim.keymap.set('n', '<leader>fr', ':Telescope bibtex<cr>', { desc = '[r]eferences' })
        end,
      },
      {
        'jmbuhr/telescope-zotero.nvim',
        enabled = true,
        dev = false,
        dependencies = {
          { 'kkharji/sqlite.lua' },
        },
        config = function()
          -- SQLite-backed Zotero picker. Disabled in favour of the .bib-file picker below.
          -- To restore: uncomment this block, remove zotero_bib_picker from the telescope
          -- config function, and re-enable telescope.load_extension 'zotero'.
          --[[
          require('zotero').setup {
            zotero_db_path      = '/home/nathan/snap/zotero-snap/common/Zotero/zotero.sqlite',
            zotero_storage_path = '/home/nathan/snap/zotero-snap/common/Zotero/storage',
          }
          local bib = require 'zotero.bib'
          local type_map = {
            journalArticle      = 'article',
            magazineArticle     = 'article',
            newspaperArticle    = 'article',
            book                = 'book',
            bookSection         = 'incollection',
            encyclopediaArticle = 'incollection',
            conferencePaper     = 'inproceedings',
            thesis              = 'phdthesis',
            report              = 'techreport',
            manuscript          = 'unpublished',
            webpage             = 'misc',
            letter              = 'misc',
            interview           = 'misc',
          }
          local field_map = {
            publicationTitle    = 'journal',
            issue               = 'number',
            place               = 'address',
            DOI                 = 'doi',
            ISSN                = 'issn',
            ISBN                = 'isbn',
            accessDate          = false,
            libraryCatalog      = false,
            extra               = false,
            citationKey         = false,
            key                 = false,
            journalAbbreviation = false,
            rights              = false,
            date                = false,
            shortTitle          = false,
            abstractNote        = false,
            numPages            = false,
          }
          bib.entry_to_bib_entry = function(entry)
            local item       = entry.value
            local citekey    = item.citekey or ''
            local ztype      = item.itemType or ''
            local btype      = type_map[ztype] or 'misc'
            local is_chapter = ztype == 'bookSection' or ztype == 'encyclopediaArticle'
            local lines      = { '@' .. btype .. '{' .. citekey .. ',' }
            if item.creators then
              local parts = {}
              for _, c in ipairs(item.creators) do
                parts[#parts + 1] = (c.lastName or '') .. ', ' .. (c.firstName or '')
              end
              lines[#lines + 1] = '  author = {' .. table.concat(parts, ' and ') .. '},'
            end
            for k, v in pairs(item) do
              if k == 'creators' or k == 'citekey' or k == 'itemType' or k == 'attachment' then
              elseif type(v) ~= 'string' or v == '' then
              else
                local mapped = field_map[k]
                if mapped == false then
                elseif mapped == 'journal' then
                  local out = is_chapter and 'booktitle' or 'journal'
                  lines[#lines + 1] = '  ' .. out .. ' = {' .. v .. '},'
                elseif mapped then
                  lines[#lines + 1] = '  ' .. mapped .. ' = {' .. v .. '},'
                else
                  lines[#lines + 1] = '  ' .. k .. ' = {' .. v .. '},'
                end
              end
            end
            lines[#lines + 1] = '}'
            lines[#lines + 1] = ''
            return table.concat(lines, '\n')
          end
          vim.keymap.set('n', '<leader>fz', ':Telescope zotero<cr>', { desc = '[z]otero' })
          ]]
        end,
      },
    },
    config = function()
      local telescope = require 'telescope'
      local actions = require 'telescope.actions'
      local previewers = require 'telescope.previewers'
      local new_maker = function(filepath, bufnr, opts)
        opts = opts or {}
        filepath = vim.fn.expand(filepath)
        vim.loop.fs_stat(filepath, function(_, stat)
          if not stat then
            return
          end
          if stat.size > 100000 then
            return
          else
            previewers.buffer_previewer_maker(filepath, bufnr, opts)
          end
        end)
      end

      local telescope_config = require 'telescope.config'
      -- Clone the default Telescope configuration
      local vimgrep_arguments = { unpack(telescope_config.values.vimgrep_arguments) }
      -- I don't want to search in the `docs` directory (rendered quarto output).
      table.insert(vimgrep_arguments, '--glob')
      table.insert(vimgrep_arguments, '!docs/*')

      telescope.setup {
        defaults = {
          buffer_previewer_maker = new_maker,
          vimgrep_arguments = vimgrep_arguments,
          file_ignore_patterns = {
            'node_modules',
            '%_cache',
            '.git/',
            'site_libs',
            '.venv',
          },
          layout_strategy = 'flex',
          sorting_strategy = 'ascending',
          layout_config = {
            prompt_position = 'top',
          },
          mappings = {
            i = {
              ['<C-u>'] = false,
              ['<C-d>'] = false,
              ['<esc>'] = actions.close,
              ['<c-j>'] = actions.move_selection_next,
              ['<c-k>'] = actions.move_selection_previous,
            },
          },
        },
        pickers = {
          find_files = {
            hidden = false,
            find_command = {
              'rg',
              '--files',
              '--hidden',
              '--glob',
              '!.git/*',
              '--glob',
              '!**/.Rpro.user/*',
              '--glob',
              '!_site/*',
              '--glob',
              '!docs/**/*.html',
              '-L',
            },
          },
        },
        extensions = {
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
          fzf = {
            fuzzy = true,                   -- false will only do exact matching
            override_generic_sorter = true, -- override the generic sorter
            override_file_sorter = true,    -- override the file sorter
            case_mode = 'smart_case',       -- or "ignore_case" or "respect_case"
          },
          -- zotero = {},  -- disabled: using .bib-file picker instead
          bibtex = {
            depth = 2,
            citation_format = '@{{cite_key}}',
            search_keys = { 'author', 'year', 'title', 'keywords' },
            citation_trim_firstname = true,
          },
        },
      }
      telescope.load_extension 'fzf'
      telescope.load_extension 'ui-select'
      telescope.load_extension 'dap'
      -- telescope.load_extension 'zotero'  -- disabled: using .bib-file picker instead
      telescope.load_extension 'bibtex'

      -- .bib-file-backed Zotero picker. Reads from a BBT auto-export instead of SQLite.
      -- Mirrors the telescope-zotero workflow: inserts @citekey at cursor and appends
      -- the full BibTeX entry to the project's references.bib (found via _quarto.yml).
      local function zotero_bib_picker(opts)
        opts = opts or {}
        local bib_path = vim.fn.expand '~/home/zotero-plugins/zotero-library.bib'

        if vim.fn.filereadable(bib_path) == 0 then
          vim.notify(
            '[zotero] Library not found. Export your Zotero library via Better BibTeX to:\n  ' .. bib_path,
            vim.log.levels.WARN
          )
          return
        end

        local content = table.concat(vim.fn.readfile(bib_path), '\n')
        local entries = {}
        for entry_str in content:gmatch '@[%w_]+%b{}' do
          local type_ = entry_str:match '^@([%w_]+)'
          local ltype = type_ and type_:lower()
          if ltype and ltype ~= 'comment' and ltype ~= 'string' and ltype ~= 'preamble' then
            local key = entry_str:match '^@[%w_]+{%s*([^,%s]+)%s*,'
            if key then
              local title_raw = entry_str:match '[Tt]itle%s*=%s*(%b{})'
                or entry_str:match '[Tt]itle%s*=%s*"([^"]*)"'
                or ''
              local title = title_raw:gsub('^{', ''):gsub('}$', ''):gsub('{(.-)}', '%1')

              local author_raw = entry_str:match '[Aa]uthor%s*=%s*(%b{})'
                or entry_str:match '[Aa]uthor%s*=%s*"([^"]*)"'
                or ''
              author_raw = author_raw:gsub('^{', ''):gsub('}$', '')
              local first_last = (author_raw:match '^([^,\n]+)' or ''):gsub('{(.-)}', '%1'):gsub('%s+$', '')

              local year = entry_str:match '[Yy]ear%s*=%s*{?(%d%d%d%d)}?'
                or entry_str:match '[Dd]ate%s*=%s*[{"]?(%d%d%d%d)'
                or ''

              table.insert(entries, {
                key = key,
                title = title,
                author = first_last,
                year = year,
                raw = entry_str .. '\n\n',
              })
            end
          end
        end

        if #entries == 0 then
          vim.notify('[zotero] No entries found in ' .. bib_path, vim.log.levels.WARN)
          return
        end

        local finders = require 'telescope.finders'
        local pickers = require 'telescope.pickers'
        local previewers = require 'telescope.previewers'
        local conf = require('telescope.config').values
        local actions = require 'telescope.actions'
        local action_state = require 'telescope.actions.state'
        local entry_display = require 'telescope.pickers.entry_display'

        local type_abbrev = {
          article       = 'art',
          book          = 'bk',
          incollection  = 'ch',
          inproceedings = 'conf',
          phdthesis     = 'phd',
          mastersthesis = 'msc',
          techreport    = 'rpt',
          unpublished   = 'ms',
          misc          = 'misc',
        }

        local displayer = entry_display.create {
          separator = ' ',
          items = {
            { width = 4 },
            { width = 24, right_justify = true },
            { remaining = true },
          },
        }

        local function make_display(e)
          local abbrev = type_abbrev[e.type and e.type:lower()] or (e.type and e.type:sub(1, 4)) or '?'
          return displayer {
            { abbrev,                      'SpecialChar' },
            { e.author .. ', ' .. e.year,  'Comment' },
            { e.title,                     'Title' },
          }
        end

        pickers
          .new(opts, {
            prompt_title = 'Zotero library',
            finder = finders.new_table {
              results = entries,
              entry_maker = function(e)
                return {
                  value = e,
                  display = function(_) return make_display(e) end,
                  ordinal = e.author .. ' ' .. e.year .. ' ' .. e.title,
                }
              end,
            },
            sorter = conf.generic_sorter(opts),
            previewer = previewers.new_buffer_previewer {
              title = 'BibTeX entry',
              define_preview = function(self, entry)
                local lines = vim.split(entry.value.raw, '\n')
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
                vim.bo[self.state.bufnr].filetype = 'bibtex'
              end,
            },
            attach_mappings = function(prompt_bufnr)
              actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local entry = action_state.get_selected_entry()
                if not entry then return end
                local item = entry.value

                vim.api.nvim_put({ '@' .. item.key }, '', false, true)

                local locate_bib = require('zotero.bib').locate_quarto_bib
                local bib_out = locate_bib()
                if not bib_out then
                  vim.notify_once('[zotero] Could not find a bibliography file', vim.log.levels.WARN)
                  return
                end
                bib_out = vim.fn.expand(bib_out)

                local ok, lines = pcall(io.lines, bib_out)
                if not ok then
                  if vim.fn.confirm("Bibliography file missing. Create '" .. bib_out .. "'?", '&Yes\n&No', 1) == 1 then
                    vim.fn.writefile({}, bib_out)
                  else
                    return
                  end
                else
                  for line in lines do
                    if line:match '^@' and line:match(item.key) then
                      return
                    end
                  end
                end

                local file = io.open(bib_out, 'a')
                if not file then
                  vim.notify('[zotero] Could not open ' .. bib_out .. ' for appending', vim.log.levels.ERROR)
                  return
                end
                file:write(item.raw)
                file:close()
                vim.print('wrote ' .. item.key .. ' to ' .. bib_out)
              end)
              return true
            end,
          })
          :find()
      end

      vim.keymap.set('n', '<leader>fz', zotero_bib_picker, { desc = '[z]otero' })
    end,
  },

  { -- Highlight todo, notes, etc in comments
    'folke/todo-comments.nvim',
    dependencies = { 'nvim-lua/plenary.nvim' },
    opts = { signs = false },
  },

  { -- edit the file system as a buffer
    'stevearc/oil.nvim',
    opts = {
      keymaps = {
        ['<C-s>'] = false,
        ['<C-h>'] = false,
        ['<C-l>'] = false,
      },
      view_options = {
        show_hidden = true,
      },
    },
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    keys = {
      { '-',          ':Oil<cr>', desc = 'oil' },
      { '<leader>ef', ':Oil<cr>', desc = 'edit [f]iles' },
    },
    cmd = 'Oil',
  },

  { -- statusline
    -- PERF: I found this to slow down the editor
    'nvim-lualine/lualine.nvim',
    enabled = false,
    config = function()
      local function macro_recording()
        local reg = vim.fn.reg_recording()
        if reg == '' then
          return ''
        end
        return '📷[' .. reg .. ']'
      end

      ---@diagnostic disable-next-line: undefined-field
      require('lualine').setup {
        options = {
          section_separators = '',
          component_separators = '',
          globalstatus = true,
        },
        sections = {
          lualine_a = { 'mode', macro_recording },
          lualine_b = { 'branch', 'diff', 'diagnostics' },
          -- lualine_b = {},
          lualine_c = { 'searchcount' },
          lualine_x = { 'filetype' },
          lualine_y = { 'progress' },
          lualine_z = { 'location' },
        },
        extensions = { 'nvim-tree' },
      }
    end,
  },

  { -- nicer-looking tabs with close icons
    'nanozuki/tabby.nvim',
    enabled = true,
    config = function()
      require('tabby.tabline').use_preset 'tab_only'
    end,
  },

  { -- scrollbar
    'dstein64/nvim-scrollview',
    enabled = true,
    opts = {
      current_only = true,
    },
  },

  { -- highlight occurences of current word
    'RRethy/vim-illuminate',
    enabled = true,
  },

  {
    "NStefan002/screenkey.nvim",
    lazy = false,
  },

  { -- filetree
    'nvim-tree/nvim-tree.lua',
    enabled = true,
    keys = {
      { '<c-b>', ':NvimTreeToggle<cr>', desc = 'toggle nvim-tree' },
    },
    config = function()
      require('nvim-tree').setup {
        disable_netrw = true,
        update_focused_file = {
          enable = true,
        },
        git = {
          enable = true,
          ignore = false,
          timeout = 500,
        },
        diagnostics = {
          enable = true,
        },
      }
    end,
  },

  -- or a different filetree
  -- {
  --   'nvim-neo-tree/neo-tree.nvim',
  --   enabled = false,
  --   branch = 'v3.x',
  --   dependencies = {
  --     'nvim-lua/plenary.nvim',
  --     'nvim-tree/nvim-web-devicons', -- not strictly required, but recommended
  --     'MunifTanjim/nui.nvim',
  --   },
  --   cmd = 'Neotree',
  --   keys = {
  --     { '<c-b>', ':Neotree toggle<cr>', desc = 'toggle nvim-tree' },
  --   },
  -- },

  -- show keybinding help window
  {
    'folke/which-key.nvim',
    enabled = true,
    config = function()
      require('which-key').setup {}
      require 'config.keymap'
    end,
  },

  { -- show tree of symbols in the current file
    'hedyhli/outline.nvim',
    cmd = 'Outline',
    keys = {
      { '<leader>lo', ':Outline<cr>', desc = 'symbols outline' },
    },
    opts = {
      providers = {
        priority = { 'markdown', 'lsp',  'norg' },
        -- Configuration for each provider (3rd party providers are supported)
        lsp = {
          -- Lsp client names to ignore
          blacklist_clients = {},
        },
        markdown = {
          -- List of supported ft's to use the markdown provider
          filetypes = { 'markdown', 'quarto' },
        },
      },
    },
  },

  { -- or show symbols in the current file as breadcrumbs
    'Bekaboo/dropbar.nvim',
    enabled = function()
      return vim.fn.has 'nvim-0.10' == 1
    end,
    dependencies = {
      'nvim-telescope/telescope-fzf-native.nvim',
    },
    config = function()
      -- turn off global option for windowline
      vim.opt.winbar = nil
      vim.keymap.set('n', '<leader>ls', require('dropbar.api').pick, { desc = '[s]ymbols' })
    end,
  },

  { -- terminal
    'akinsho/toggleterm.nvim',
    opts = {
      open_mapping = [[<c-\>]],
      direction = 'float',
    },
  },

  { -- show diagnostics list
    -- PERF: Slows down insert mode if open and there are many diagnostics
    'folke/trouble.nvim',
    enabled = false,
    config = function()
      local trouble = require 'trouble'
      trouble.setup {}
      local function next()
        trouble.next { skip_groups = true, jump = true }
      end
      local function previous()
        trouble.previous { skip_groups = true, jump = true }
      end
      vim.keymap.set('n', ']t', next, { desc = 'next [t]rouble item' })
      vim.keymap.set('n', '[t', previous, { desc = 'previous [t]rouble item' })
    end,
  },

  { -- show indent lines
    'lukas-reineke/indent-blankline.nvim',
    enabled = false,
    main = 'ibl',
    opts = {
      indent = { char = '│' },
    },
  },

  { -- highlight markdown headings and code blocks etc.
    'lukas-reineke/headlines.nvim',
    enabled = true,
    dependencies = 'nvim-treesitter/nvim-treesitter',
    config = function()
      require('headlines').setup {
        quarto = {
          query = vim.treesitter.query.parse(
            'markdown',
            [[
                (fenced_code_block) @codeblock
                ]]
          ),
          codeblock_highlight = 'CodeBlock',
          treesitter_language = 'markdown',
        },
        markdown = {
          query = vim.treesitter.query.parse(
            'markdown',
            [[
                (fenced_code_block) @codeblock
                ]]
          ),
          codeblock_highlight = 'CodeBlock',
        },
      }
    end,
  },

  { -- show images in nvim!
    '3rd/image.nvim',
    enabled = true,
    dev = false,
    ft = { 'markdown', 'quarto', 'vimwiki' },
    cond = function()
      -- Disable on Windows system
       return vim.fn.has 'win32' ~= 1 
    end,
    dependencies = {
       'leafo/magick', -- that's a lua rock
    },
    config = function()
      -- Requirements
      -- https://github.com/3rd/image.nvim?tab=readme-ov-file#requirements
      -- check for dependencies with `:checkhealth kickstart`
      -- needs:
      -- sudo apt install imagemagick
      -- sudo apt install libmagickwand-dev
      -- sudo apt install liblua5.1-0-dev
      -- sudo apt install lua5.1
      -- sudo apt install luajit

      local image = require 'image'
      image.setup {
        backend = 'kitty',
        integrations = {
          markdown = {
            enabled = true,
            only_render_image_at_cursor = true,
            -- only_render_image_at_cursor_mode = "popup",
            filetypes = { 'markdown', 'vimwiki', 'quarto' },
          },
        },
        editor_only_render_when_focused = false,
        window_overlap_clear_enabled = true,
        tmux_show_only_in_active_window = true,
        window_overlap_clear_ft_ignore = { 'cmp_menu', 'cmp_docs', 'scrollview', 'scrollview_sign' },
        max_width = nil,
        max_height = nil,
        max_width_window_percentage = nil,
        max_height_window_percentage = 30,
        kitty_method = 'normal',
      }

      local function clear_all_images()
        local bufnr = vim.api.nvim_get_current_buf()
        local images = image.get_images { buffer = bufnr }
        for _, img in ipairs(images) do
          img:clear()
        end
      end

      local function get_image_at_cursor(buf)
        local images = image.get_images { buffer = buf }
        local row = vim.api.nvim_win_get_cursor(0)[1] - 1
        for _, img in ipairs(images) do
          if img.geometry ~= nil and img.geometry.y == row then
            local og_max_height = img.global_state.options.max_height_window_percentage
            img.global_state.options.max_height_window_percentage = nil
            return img, og_max_height
          end
        end
        return nil
      end

      local create_preview_window = function(img, og_max_height)
        local buf = vim.api.nvim_create_buf(false, true)
        local win_width = vim.api.nvim_get_option_value('columns', {})
        local win_height = vim.api.nvim_get_option_value('lines', {})
        local win = vim.api.nvim_open_win(buf, true, {
          relative = 'editor',
          style = 'minimal',
          width = win_width,
          height = win_height,
          row = 0,
          col = 0,
          zindex = 1000,
        })
        vim.keymap.set('n', 'q', function()
          vim.api.nvim_win_close(win, true)
          img.global_state.options.max_height_window_percentage = og_max_height
        end, { buffer = buf })
        return { buf = buf, win = win }
      end

      local handle_zoom = function(bufnr)
        local img, og_max_height = get_image_at_cursor(bufnr)
        if img == nil then
          return
        end

        local preview = create_preview_window(img, og_max_height)
        image.hijack_buffer(img.path, preview.win, preview.buf)
      end

      vim.keymap.set('n', '<leader>io', function()
        local bufnr = vim.api.nvim_get_current_buf()
        handle_zoom(bufnr)
      end, { buffer = true, desc = 'image [o]pen' })

      vim.keymap.set('n', '<leader>ic', clear_all_images, { desc = 'image [c]lear' })
    end,
  },
}
