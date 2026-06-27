-- Research manager for Quarto manuscript projects.
-- Keymaps: <leader>r...  Loaded by config/keymap.lua via M.setup().

local M = {}

-- ── utilities ────────────────────────────────────────────────────────────────

local function research_path()
  local dir = vim.fn.expand '%:p:h'
  if dir:match 'sections$' or dir:match 'research$' or dir:match 'scripts$'
    or dir:match 'data$'   or dir:match 'notes$' then
    dir = vim.fn.fnamemodify(dir, ':h')
  end
  return dir .. '/research'
end

local function require_research()
  local p = research_path()
  if vim.fn.isdirectory(p) ~= 1 then
    vim.notify('[research] no research/ directory found near this file', vim.log.levels.WARN)
    return nil
  end
  return p
end

local function ensure_research()
  local p = research_path()
  if vim.fn.isdirectory(p) ~= 1 then
    vim.fn.mkdir(p, 'p')
    local f = io.open(p .. '/scratch.md', 'w')
    if f then
      f:write '<!-- type: scratch\nkeywords:\n-->\n\n# Scratch\n\nFleeting notes and unclassified snippets.\n'
      f:close()
    end
    vim.notify('[research] created research/ with scratch.md', vim.log.levels.INFO)
  end
  return p
end

local function file_template(title)
  return '<!-- type: thematic\nkeywords:\n-->\n\n# ' .. title .. '\n\n'
end

-- ── rs: scratch ──────────────────────────────────────────────────────────────

local function cmd_scratch()
  local rp    = ensure_research()
  local fpath = rp .. '/scratch.md'
  if vim.fn.filereadable(fpath) ~= 1 then
    local f = io.open(fpath, 'w')
    if f then
      f:write '<!-- type: scratch\nkeywords:\n-->\n\n# Scratch\n\nFleeting notes and unclassified snippets.\n'
      f:close()
    end
  end
  vim.cmd('vsplit ' .. vim.fn.fnameescape(fpath))
  vim.cmd 'normal! G'
end

-- ── rf: live grep across research/ ───────────────────────────────────────────

local function cmd_find()
  local rp = require_research()
  if not rp then return end
  require('telescope.builtin').live_grep {
    search_dirs  = { rp },
    prompt_title = ' Research ',
  }
end

-- ── rh: snippet / heading picker ─────────────────────────────────────────────

local function cmd_headings()
  local rp = require_research()
  if not rp then return end

  local pickers      = require 'telescope.pickers'
  local finders      = require 'telescope.finders'
  local conf         = require('telescope.config').values
  local actions      = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'

  local results = {}
  for _, fpath in ipairs(vim.fn.globpath(rp, '*.md', false, true)) do
    local fname = vim.fn.fnamemodify(fpath, ':t:r')
    for lnum, line in ipairs(vim.fn.readfile(fpath)) do
      if line:match '^## ' then
        local heading = line:gsub('^##%s*', '')
        results[#results + 1] = {
          display  = fname .. '  ›  ' .. heading,
          ordinal  = fname .. ' ' .. heading,
          filename = fpath,
          lnum     = lnum,
        }
      end
    end
  end

  pickers.new({}, {
    prompt_title = ' Research Snippets ',
    finder = finders.new_table {
      results     = results,
      entry_maker = function(e) return e end,
    },
    sorter    = conf.generic_sorter {},
    previewer = conf.grep_previewer {},
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        if not sel then return end
        actions.close(prompt_bufnr)
        vim.cmd('edit ' .. vim.fn.fnameescape(sel.filename))
        vim.api.nvim_win_set_cursor(0, { sel.lnum, 0 })
        vim.cmd 'normal! zz'
      end)
      return true
    end,
  }):find()
end

-- ── ro: open or create (telescope picker) ────────────────────────────────────

local function cmd_open()
  local rp = ensure_research()

  local pickers      = require 'telescope.pickers'
  local finders      = require 'telescope.finders'
  local conf         = require('telescope.config').values
  local actions      = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'

  local entries = {}
  for _, fpath in ipairs(vim.fn.globpath(rp, '*.md', false, true)) do
    entries[#entries + 1] = {
      display  = vim.fn.fnamemodify(fpath, ':t:r'),
      ordinal  = vim.fn.fnamemodify(fpath, ':t:r'),
      filename = fpath,
    }
  end

  pickers.new({}, {
    prompt_title = ' Research  (type a new name to create) ',
    finder = finders.new_table {
      results     = entries,
      entry_maker = function(e) return e end,
    },
    sorter    = conf.generic_sorter {},
    previewer = conf.file_previewer {},
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local sel         = action_state.get_selected_entry()
        local prompt_text = action_state.get_current_picker(prompt_bufnr):_get_prompt()
        actions.close(prompt_bufnr)

        local fpath
        if sel then
          fpath = sel.filename
        else
          -- nothing matched: create from prompt text
          local name = prompt_text:gsub('%s+', '-'):gsub('[^%w%-]', ''):lower()
          if name == '' then return end
          fpath = rp .. '/' .. name .. '.md'
        end

        if vim.fn.filereadable(fpath) ~= 1 then
          local title = vim.fn.fnamemodify(fpath, ':t:r'):gsub('-', ' ')
          local f = io.open(fpath, 'w')
          if f then f:write(file_template(title)); f:close() end
        end
        vim.cmd('vsplit ' .. vim.fn.fnameescape(fpath))
        vim.cmd 'normal! G'
      end)
      return true
    end,
  }):find()
end

-- ── rn: new note (quick input, no picker) ────────────────────────────────────

local function cmd_new()
  local rp = ensure_research()
  vim.ui.input({ prompt = 'Research note name: ' }, function(input)
    if not input or input == '' then return end
    local name  = input:gsub('%s+', '-'):gsub('[^%w%-]', ''):lower()
    local fpath = rp .. '/' .. name .. '.md'
    if vim.fn.filereadable(fpath) ~= 1 then
      local f = io.open(fpath, 'w')
      if f then f:write(file_template(input)); f:close() end
    end
    vim.cmd('vsplit ' .. vim.fn.fnameescape(fpath))
    vim.cmd 'normal! G'
  end)
end

-- ── keymap registration ───────────────────────────────────────────────────────

function M.setup()
  local wk = require 'which-key'
  wk.add {
    { '<leader>r',  group = '[r]esearch' },
    { '<leader>rf', cmd_find,     desc = '[f]ind in research (grep)' },
    { '<leader>rh', cmd_headings, desc = '[h]eadings / snippet picker' },
    { '<leader>rn', cmd_new,      desc = '[n]ew research note' },
    { '<leader>ro', cmd_open,     desc = '[o]pen research file' },
    { '<leader>rs', cmd_scratch,  desc = '[s]cratch' },
  }
end

return M
