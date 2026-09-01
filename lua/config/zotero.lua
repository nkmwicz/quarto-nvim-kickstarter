-- Shared Zotero .bib picker: parses the Better BibTeX export once and hands
-- matched entries to a caller-supplied `on_select`. Extracted out of
-- ui.lua's `<leader>fz` (citation insertion) so evergreen.lua's source-note
-- capture can reuse the same picker to populate frontmatter instead.

local M = {}

local bib_path = vim.fn.expand '~/home/zotero-plugins/zotero-library.bib'

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

--- Parse the exported .bib file into `{key, type, title, author, year, raw}`
--- entries. `author` is just the first author's "Last, First" (enough for
--- display and for slugging); `raw` is the full BibTeX entry text.
function M.parse_entries()
  if vim.fn.filereadable(bib_path) == 0 then
    vim.notify(
      '[zotero] Library not found. Export your Zotero library via Better BibTeX to:\n  ' .. bib_path,
      vim.log.levels.WARN
    )
    return nil
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
          type = ltype,
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
    return nil
  end
  return entries
end

--- Open a Telescope picker over the parsed library. `opts.on_select(entry)`
--- is called with the chosen entry; `opts.prompt_title` overrides the
--- picker's title.
function M.pick(opts)
  opts = opts or {}
  local entries = M.parse_entries()
  if not entries then
    return
  end

  local finders = require 'telescope.finders'
  local pickers = require 'telescope.pickers'
  local previewers = require 'telescope.previewers'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local entry_display = require 'telescope.pickers.entry_display'

  local displayer = entry_display.create {
    separator = ' ',
    items = {
      { width = 4 },
      { width = 24, right_justify = true },
      { remaining = true },
    },
  }

  local function make_display(e)
    local abbrev = type_abbrev[e.type] or (e.type and e.type:sub(1, 4)) or '?'
    return displayer {
      { abbrev,                     'SpecialChar' },
      { e.author .. ', ' .. e.year, 'Comment' },
      { e.title,                    'Title' },
    }
  end

  pickers
    .new({}, {
      prompt_title = opts.prompt_title or 'Zotero library',
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
      sorter = conf.generic_sorter {},
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
          if not entry then
            return
          end
          if opts.on_select then
            opts.on_select(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
