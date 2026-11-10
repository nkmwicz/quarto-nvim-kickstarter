-- Source map (<leader>bu): how the manuscript uses its sources.
--   · every citekey, by number of citations, with the sections citing it
--   · sections leaning on one source (≥ LEAN_SHARE of ≥ LEAN_MIN citations)
--   · research/ snippets (## headings) the manuscript never uses
-- A snippet counts as used when its citekey is cited, its shelfmark (the
-- heading up to the first comma or parenthesis, "BnF ms. fr. 14223")
-- appears in a section, or a section has its <!-- research: … --> link.
--   <CR> source: its citations (Telescope) · section: open · snippet: open (vsplit)

local M = {}

local LEAN_SHARE, LEAN_MIN = 0.5, 6

local function citations_by_key(files)
  local cite = require 'config.citations'
  local keys, order, per_file = {}, {}, {}
  for _, f in ipairs(files) do
    local fname = vim.fn.fnamemodify(f.path, ':t')
    local counts = { fname = fname, path = f.path, total = 0, keys = {} }
    per_file[#per_file + 1] = counts
    for _, c in ipairs(cite.find_citations(f.lines)) do
      local k = keys[c.key]
      if not k then
        k = { key = c.key, total = 0, files = {}, file_order = {}, hits = {} }
        keys[c.key] = k
        order[#order + 1] = k
      end
      k.total = k.total + 1
      if not k.files[fname] then
        k.files[fname] = 0
        k.file_order[#k.file_order + 1] = fname
      end
      k.files[fname] = k.files[fname] + 1
      k.hits[#k.hits + 1] = { path = f.path, fname = fname, lnum = c.lnum + 1, col = c.col + 1,
        text = vim.trim(f.lines[c.lnum + 1]) }
      counts.total = counts.total + 1
      counts.keys[c.key] = (counts.keys[c.key] or 0) + 1
    end
  end
  table.sort(order, function(a, b)
    if a.total ~= b.total then return a.total > b.total end
    return a.key < b.key
  end)
  return order, per_file
end

local function unused_snippets(project, files)
  local rdir = project .. '/research'
  if vim.fn.isdirectory(rdir) == 0 then return nil end
  local text = {}
  for _, f in ipairs(files) do text[#text + 1] = table.concat(f.lines, '\n') end
  text = table.concat(text, '\n')
  local cited = {}
  for _, f in ipairs(files) do
    for _, c in ipairs(require('config.citations').find_citations(f.lines)) do cited[c.key] = true end
  end
  local out = {}
  for _, path in ipairs(vim.fn.globpath(rdir, '*.md', false, true)) do
    local fname = vim.fn.fnamemodify(path, ':t')
    for i, line in ipairs(vim.fn.readfile(path)) do
      local heading = line:match '^##%s+(.-)%s*$'
      if heading and heading ~= '' then
        local used = text:find('<!-- research: ' .. fname .. ' » ' .. heading, 1, true) ~= nil
        local key = heading:match '@([%w_][%w_:%.#%$%%&%-+%?<>~/]*)'
        if key then
          key = key:gsub('[%.:]$', '')
          used = used or cited[key]
        else
          local mark = vim.trim(heading:match '^([^,(]+)' or heading)
          used = used or (#mark >= 4 and text:find(mark, 1, true) ~= nil)
        end
        if not used then out[#out + 1] = { path = path, fname = fname, lnum = i, heading = heading } end
      end
    end
  end
  return out
end

local function show_hits(k)
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local conf = require('telescope.config').values
  pickers.new({}, {
    prompt_title = string.format(' @%s (%d) ', k.key, k.total),
    finder = finders.new_table {
      results = k.hits,
      entry_maker = function(h)
        local loc = string.format('%s:%d', h.fname, h.lnum)
        return {
          value = h, ordinal = loc .. ' ' .. h.text,
          display = loc .. string.rep(' ', math.max(1, 30 - #loc)) .. h.text,
          filename = h.path, lnum = h.lnum, col = h.col,
        }
      end,
    },
    sorter = conf.generic_sorter {},
    previewer = conf.grep_previewer {},
  }):find()
end

function M.open()
  local outline = require 'config.outline'
  local files = outline.files(true)
  if not files or #files == 0 then return end
  local project = vim.fn.fnamemodify(files[1].path, ':h:h')
  local keys, per_file = citations_by_key(files)
  local unused = unused_snippets(project, files)
  local total = 0
  for _, k in ipairs(keys) do total = total + k.total end

  local leaning = {}
  for _, f in ipairs(per_file) do
    if f.total >= LEAN_MIN then
      local top, n = nil, 0
      for key, c in pairs(f.keys) do
        if c > n or c == n and key < top then top, n = key, c end
      end
      if n / f.total >= LEAN_SHARE then
        leaning[#leaning + 1] = { kind = 'file', path = f.path, lnum = 1, fname = f.fname, key = top, n = n, total = f.total }
      end
    end
  end

  local function render()
    local lines, hls, rowmap = {}, {}, {}
    local function head(text)
      if #lines > 0 then lines[#lines + 1] = '' end
      lines[#lines + 1] = text
      hls[#hls + 1] = { #lines, 0, -1, 'Title' }
    end

    head(string.format('Sources by use — %d works, %d citations', #keys, total))
    if #keys == 0 then lines[#lines + 1] = '  (no citations)' end
    local kw = 0
    for _, k in ipairs(keys) do kw = math.max(kw, #k.key + 1) end
    kw = math.min(kw, 36)
    for _, k in ipairs(keys) do
      local where = {}
      for _, fname in ipairs(k.file_order) do
        where[#where + 1] = vim.fn.fnamemodify(fname, ':r') .. ' ' .. k.files[fname]
      end
      local lead = string.format('  %-' .. kw .. 's %4d×  ', '@' .. k.key, k.total)
      lines[#lines + 1] = lead .. table.concat(where, ' · ')
      hls[#hls + 1] = { #lines, #lead, -1, 'Comment' }
      rowmap[#lines] = { kind = 'key', k = k }
    end

    head 'Leaning on one source'
    if #leaning == 0 then
      lines[#lines + 1] = string.format('  (no section draws %d%%+ of %d+ citations from one work)',
        LEAN_SHARE * 100, LEAN_MIN)
      hls[#hls + 1] = { #lines, 0, -1, 'Comment' }
    end
    for _, l in ipairs(leaning) do
      lines[#lines + 1] = string.format('  %-28s @%s  %d of %d citations (%d%%)', l.fname, l.key, l.n, l.total,
        math.floor(l.n / l.total * 100 + 0.5))
      hls[#hls + 1] = { #lines, 2, 2 + #l.fname, 'DiagnosticWarn' }
      rowmap[#lines] = l
    end

    if unused then
      head(string.format('Research snippets never used — %d', #unused))
      if #unused == 0 then lines[#lines + 1] = '  (every snippet is cited or linked)' end
      for _, u in ipairs(unused) do
        local lead = '  ' .. u.fname .. ' › '
        lines[#lines + 1] = lead .. u.heading
        hls[#hls + 1] = { #lines, 0, #lead, 'Comment' }
        rowmap[#lines] = { kind = 'snippet', path = u.path, lnum = u.lnum }
      end
    end
    return lines, hls, rowmap
  end

  outline.float {
    title = 'Source Map',
    footer = '↵ citations / open   q close',
    indent = 6,
    render = render,
    keys = {
      ['<CR>'] = function(it, _, win)
        vim.api.nvim_win_close(win, true)
        if it.kind == 'key' then
          show_hits(it.k)
        elseif it.kind == 'snippet' then
          vim.cmd('vsplit ' .. vim.fn.fnameescape(it.path))
          vim.api.nvim_win_set_cursor(0, { it.lnum, 0 })
          vim.cmd 'normal! zt'
        else
          outline.jump(it)
        end
      end,
    },
  }
end

return M
