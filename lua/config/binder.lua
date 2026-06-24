-- Scrivener-style binder for Quarto manuscript projects.
-- Keymaps: <leader>b...  Loaded by config/keymap.lua via M.setup().

local M = {}

-- ── utilities ────────────────────────────────────────────────────────────────

-- Resolve the sections/ directory relative to the current file.
local function sections_path()
  local dir = vim.fn.expand '%:p:h'
  if dir:match 'sections$' or dir:match 'scripts$'
    or dir:match 'data$' or dir:match 'notes$' then
    dir = vim.fn.fnamemodify(dir, ':h')
  end
  return dir .. '/sections'
end

-- Guard: return sections path or nil + notify.
local function require_sections()
  local p = sections_path()
  if vim.fn.isdirectory(p) ~= 1 then
    vim.notify('[binder] no sections/ directory found near this file', vim.log.levels.WARN)
    return nil
  end
  return p
end

-- Guard: return true if the current file lives inside sections/.
local function require_section_file()
  local p = vim.fn.expand '%:p'
  if p == '' then
    vim.notify('[binder] no file open', vim.log.levels.WARN)
    return false
  end
  if not p:match '/sections/' then
    vim.notify('[binder] current file is not inside a sections/ directory', vim.log.levels.WARN)
    return false
  end
  return true
end

-- Parse the first metadata block (<!-- --> or --- ---) of a file.
-- Returns a table of key/value strings; empty table if none found.
local function parse_meta(fpath)
  local meta = {}
  local in_meta, meta_end = false, ''
  for i, line in ipairs(vim.fn.readfile(fpath, '', 40)) do
    if i == 1 and line == '---' then
      in_meta, meta_end = true, '^%-%-%-'
    elseif i == 1 and line:match '^<!%-%-' then
      in_meta, meta_end = true, '%-%->'
    elseif in_meta and line:match(meta_end) then
      break
    elseif in_meta then
      local k, v = line:match '^(%w[%w_-]*):%s*(.-)%s*$'
      if k and v ~= '' then meta[k] = v end
    end
  end
  return meta
end

-- Update or insert key=value inside the first <!-- --> block.
-- If no HTML comment block exists, prepends one.
local function set_meta_field(fpath, key, value)
  local lines = vim.fn.readfile(fpath)
  if #lines == 0 then
    vim.notify('[binder] cannot read ' .. vim.fn.fnamemodify(fpath, ':t'), vim.log.levels.WARN)
    return false
  end
  local in_meta, meta_end_pat, meta_end_line, field_line = false, '', -1, -1
  for i, line in ipairs(lines) do
    if i == 1 and line:match '^<!%-%-' then
      in_meta, meta_end_pat = true, '%-%->'
    elseif in_meta and line:match(meta_end_pat) then
      meta_end_line = i
      break
    elseif in_meta and line:match('^' .. key .. ':') then
      field_line = i
    end
  end
  if field_line ~= -1 then
    lines[field_line] = key .. ': ' .. value
  elseif meta_end_line ~= -1 then
    table.insert(lines, meta_end_line, key .. ': ' .. value)
  else
    -- No HTML comment block — prepend one
    for i, l in ipairs({ '<!--', key .. ': ' .. value, '-->', '' }) do
      table.insert(lines, i, l)
    end
  end
  vim.fn.writefile(lines, fpath)
  if vim.fn.expand '%:p' == fpath then vim.cmd 'silent! e' end
  return true
end

-- Count prose words in a file, skipping the metadata block and code fences.
local function word_count(fpath)
  local n, in_meta, in_code, meta_end = 0, false, false, ''
  for i, line in ipairs(vim.fn.readfile(fpath)) do
    if i == 1 and line == '---' then
      in_meta, meta_end = true, '^%-%-%-'
    elseif i == 1 and line:match '^<!%-%-' then
      in_meta, meta_end = true, '%-%->'
    elseif in_meta and line:match(meta_end) then
      in_meta = false
    elseif not in_meta then
      if line:match '^%s*```' then
        in_code = not in_code
      elseif not in_code then
        local text = line:gsub('%b[]%b()', ''):gsub('`[^`]*`', ''):gsub('^#+%s*', '')
        for _ in text:gmatch '%S+' do n = n + 1 end
      end
    end
  end
  return n
end

-- Collect all section files from sp with parsed metadata and word counts.
local function collect_sections(sp)
  local paths = vim.fn.globpath(sp, '*.qmd', false, true)
  vim.list_extend(paths, vim.fn.globpath(sp, '*.md', false, true))
  table.sort(paths)
  local out = {}
  for _, fpath in ipairs(paths) do
    local meta = parse_meta(fpath)
    out[#out + 1] = {
      path     = fpath,
      fname    = vim.fn.fnamemodify(fpath, ':t'),
      status   = meta.status   or '',
      summary  = meta.summary  or '',
      keywords = meta.keywords or '',
      words    = word_count(fpath),
    }
  end
  return out
end

-- Like collect_sections but ordered by the first parent document's include lines.
-- Sections not referenced in the parent are appended at the end.
-- Falls back to alphabetical when no parent is found.
local function collect_sections_ordered(sp)
  local project_dir = vim.fn.fnamemodify(sp, ':h')
  local parents = {}
  local hits = vim.fn.systemlist { 'grep', '-rl', '--include=*.qmd', '{{< include', project_dir }
  for _, h in ipairs(hits) do
    if not h:match '/sections/' then parents[#parents + 1] = h end
  end

  if #parents == 0 then return collect_sections(sp) end

  local plines = vim.fn.readfile(parents[1])
  local ordered, seen = {}, {}
  for _, line in ipairs(plines) do
    local included = line:match '{{<%s*include%s+(.-)%s*>}}'
    if included then
      local fname = vim.fn.fnamemodify(included, ':t')
      local full  = sp .. '/' .. fname
      if vim.fn.filereadable(full) == 1 and not seen[fname] then
        seen[fname] = true
        local meta = parse_meta(full)
        ordered[#ordered + 1] = {
          path     = full,
          fname    = fname,
          status   = meta.status   or '',
          summary  = meta.summary  or '',
          keywords = meta.keywords or '',
          words    = word_count(full),
        }
      end
    end
  end

  -- Append orphaned section files not referenced in the parent.
  for _, s in ipairs(collect_sections(sp)) do
    if not seen[s.fname] then ordered[#ordered + 1] = s end
  end

  return ordered
end

-- Find parent .qmd files (outside sections/) that contain {{< include >}} lines.
local function find_parents(project_dir)
  local hits = vim.fn.systemlist {
    'grep', '-rl', '--include=*.qmd', '{{< include', project_dir,
  }
  local parents = {}
  for _, h in ipairs(hits) do
    if not h:match '/sections/' then parents[#parents + 1] = h end
  end
  return parents
end

-- Open a scratch float.  opts: width, height, modifiable (default false).
local function open_float(lines, title, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if not opts.modifiable then vim.bo[buf].modifiable = false end
  local w = opts.width  or math.floor(vim.o.columns * 0.72)
  local h = opts.height or math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = 'editor',
    row       = math.floor((vim.o.lines - h) / 2),
    col       = math.floor((vim.o.columns - w) / 2),
    width = w, height = h,
    style     = 'minimal',
    border    = require('misc.style').border,
    title     = ' ' .. title .. ' ',
    title_pos = 'center',
  })
  return buf, win
end

local function close_keys(buf, win)
  for _, k in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', k, function() vim.api.nvim_win_close(win, true) end,
      { buffer = buf, silent = true })
  end
end

-- ── bl: set status ───────────────────────────────────────────────────────────

local function cmd_label()
  if not require_section_file() then return end
  local fpath = vim.fn.expand '%:p'
  local meta  = parse_meta(fpath)
  vim.ui.select(
    { 'todo', 'draft', 'review', 'done' },
    { prompt = 'Set status (current: ' .. (meta.status ~= '' and meta.status or 'none') .. '): ' },
    function(choice)
      if not choice then return end
      set_meta_field(fpath, 'status', choice)
      vim.notify('[binder] status set to ' .. choice)
    end
  )
end

-- ── bn: new section ──────────────────────────────────────────────────────────

local function cmd_new()
  local sp = require_sections()
  if not sp then return end
  local existing = vim.fn.globpath(sp, '_*.qmd', false, true)
  local max_n = 0
  for _, f in ipairs(existing) do
    local n = tonumber(vim.fn.fnamemodify(f, ':t'):match '^_(%d+)')
    if n and n > max_n then max_n = n end
  end
  local num = string.format('%02d', max_n + 1)
  vim.ui.input(
    { prompt = 'Section name (→ _' .. num .. '-<name>.qmd): ' },
    function(name)
      if not name or name == '' then return end
      name = name:lower():gsub('%s+', '-'):gsub('[^%w%-]', '')
      if name == '' then
        vim.notify('[binder] invalid name', vim.log.levels.WARN)
        return
      end
      local fname = '_' .. num .. '-' .. name .. '.qmd'
      local fpath = sp .. '/' .. fname
      if vim.fn.filereadable(fpath) == 1 then
        vim.notify('[binder] file already exists: ' .. fname, vim.log.levels.WARN)
        return
      end
      vim.fn.writefile({
        '<!--',
        'status: todo',
        'summary: ',
        'keywords: ',
        '-->',
        '',
        '',
      }, fpath)
      vim.cmd('edit ' .. vim.fn.fnameescape(fpath))
      vim.api.nvim_win_set_cursor(0, { 3, #'summary: ' })
      vim.notify('[binder] created ' .. fname)
    end
  )
end

-- ── bb: back to parent ───────────────────────────────────────────────────────

local function cmd_back()
  local fname = vim.fn.expand '%:t'
  if fname == '' then
    vim.notify('[binder] no file open', vim.log.levels.WARN)
    return
  end
  local sp = sections_path()
  local project_dir = vim.fn.fnamemodify(sp, ':h')
  local hits = vim.fn.systemlist {
    'grep', '-rl', '--include=*.qmd', fname, project_dir,
  }
  local parents = {}
  for _, h in ipairs(hits) do
    if not h:match '/sections/' then parents[#parents + 1] = h end
  end
  if #parents == 0 then
    vim.notify('[binder] no parent document includes ' .. fname, vim.log.levels.WARN)
    return
  end
  local function jump(path)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    vim.fn.search(vim.fn.escape(fname, '.'), 'w')
  end
  if #parents == 1 then
    jump(parents[1])
  else
    vim.ui.select(
      vim.tbl_map(function(p) return vim.fn.fnamemodify(p, ':t') end, parents),
      { prompt = 'Jump to parent:' },
      function(_, idx)
        if idx then jump(parents[idx]) end
      end
    )
  end
end

-- ── bm: reorder sections in parent ──────────────────────────────────────────

local function cmd_move()
  local sp = require_sections()
  if not sp then return end
  local project_dir = vim.fn.fnamemodify(sp, ':h')
  local parents = find_parents(project_dir)
  if #parents == 0 then
    vim.notify('[binder] no parent document with {{< include >}} found', vim.log.levels.WARN)
    return
  end

  -- Use first parent (most projects have one).
  local pfile = parents[1]
  local plines = vim.fn.readfile(pfile)

  -- Collect include lines and their positions from the parent.
  local include_pos = {}   -- {line_idx, fname, original_line}
  for i, line in ipairs(plines) do
    local included = line:match '{{<%s*include%s+(.-)%s*>}}'
    if included then
      local fname = vim.fn.fnamemodify(included, ':t')
      local full  = sp .. '/' .. fname
      if vim.fn.filereadable(full) == 1 then
        include_pos[#include_pos + 1] = { idx = i, fname = fname, line = line }
      end
    end
  end

  if #include_pos == 0 then
    vim.notify('[binder] no section include lines found in ' .. vim.fn.fnamemodify(pfile, ':t'),
      vim.log.levels.WARN)
    return
  end

  -- Enrich with metadata.
  local order = {}
  local current_fname = vim.fn.expand '%:t'
  local cur = 1
  for i, entry in ipairs(include_pos) do
    local meta = parse_meta(sp .. '/' .. entry.fname)
    order[#order + 1] = vim.tbl_extend('force', entry, {
      status  = meta.status or '',
    })
    if entry.fname == current_fname then cur = i end
  end

  local function render()
    local ls = {}
    for i, s in ipairs(order) do
      local marker = i == cur and '>' or ' '
      ls[#ls + 1] = string.format(' %s %d.  [%-6s]  %s', marker, i,
        s.status ~= '' and s.status or '—', s.fname)
    end
    ls[#ls + 1] = ''
    ls[#ls + 1] = '  j/k: select    K/J: move up/down    <Enter>: save to ' .. vim.fn.fnamemodify(pfile, ':t') .. '    q: cancel'
    return ls
  end

  local buf, win = open_float(render(), 'Reorder Sections', { modifiable = true })
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_cursor(win, { cur, 0 })

  local function redraw()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render())
    vim.bo[buf].modifiable = false
    vim.api.nvim_win_set_cursor(win, { cur, 0 })
  end

  vim.keymap.set('n', 'j', function()
    if cur < #order then cur = cur + 1; redraw() end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'k', function()
    if cur > 1 then cur = cur - 1; redraw() end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'K', function()
    if cur > 1 then order[cur], order[cur-1] = order[cur-1], order[cur]; cur = cur - 1; redraw() end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'J', function()
    if cur < #order then order[cur], order[cur+1] = order[cur+1], order[cur]; cur = cur + 1; redraw() end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', function()
    for i, entry in ipairs(order) do
      plines[include_pos[i].idx] = entry.line
    end
    vim.fn.writefile(plines, pfile)
    vim.api.nvim_win_close(win, true)
    vim.notify('[binder] order saved to ' .. vim.fn.fnamemodify(pfile, ':t'))
    local pbuf = vim.fn.bufnr(pfile)
    if pbuf ~= -1 then vim.cmd('checktime ' .. pbuf) end
  end, { buffer = buf, silent = true })
  close_keys(buf, win)
end

-- ── bo: outliner ─────────────────────────────────────────────────────────────

local STATUS_ICON = { todo = '○', draft = '◑', review = '◕', done = '●' }

local function cmd_outliner()
  local sp = require_sections()
  if not sp then return end
  local sections = collect_sections_ordered(sp)
  if #sections == 0 then
    vim.notify('[binder] no section files found', vim.log.levels.WARN)
    return
  end

  local C1, C2, C3 = 10, 6, 30   -- status, words, filename column widths
  -- Lua's string.format doesn't support * for dynamic widths; bake them in.
  local row_fmt  = string.format('  %%-%ds  %%%ds  %%-%ds  %%s', C1, C2, C3)
  local lines    = {}
  local fmap     = {}               -- line number → fpath

  lines[1] = string.format(row_fmt, 'status', 'words', 'file', 'summary')
  lines[2] = '  ' .. string.rep('─', C1 + C2 + C3 + 40)

  for _, s in ipairs(sections) do
    local icon       = STATUS_ICON[s.status] or '·'
    local status_str = icon .. ' ' .. (s.status ~= '' and s.status or '—')
    local words_str  = tostring(s.words) .. 'w'
    local avail      = math.max(10, vim.o.columns - C1 - C2 - C3 - 12)
    local summary    = #s.summary > avail and s.summary:sub(1, avail - 1) .. '…' or s.summary
    if summary == '' then summary = '—' end
    lines[#lines + 1] = string.format(row_fmt, status_str, words_str, s.fname, summary)
    fmap[#lines] = s.path
  end

  local buf, win = open_float(lines, 'Outliner', { width = math.floor(vim.o.columns * 0.9) })
  vim.api.nvim_win_set_cursor(win, { 3, 0 })

  vim.keymap.set('n', '<CR>', function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if fmap[row] then
      vim.api.nvim_win_close(win, true)
      vim.cmd('edit ' .. vim.fn.fnameescape(fmap[row]))
    end
  end, { buffer = buf, silent = true })
  close_keys(buf, win)
end

-- ── bc: corkboard ────────────────────────────────────────────────────────────

local function cmd_corkboard()
  local sp = require_sections()
  if not sp then return end
  local sections = collect_sections_ordered(sp)
  if #sections == 0 then
    vim.notify('[binder] no section files found', vim.log.levels.WARN)
    return
  end

  -- Load parent file so movement mode can save the new order.
  local pfile, plines, include_pos = nil, nil, {}
  local parents = find_parents(vim.fn.fnamemodify(sp, ':h'))
  if #parents > 0 then
    pfile  = parents[1]
    plines = vim.fn.readfile(pfile)
    for i, line in ipairs(plines) do
      local included = line:match '{{<%s*include%s+(.-)%s*>}}'
      if included then
        local fname = vim.fn.fnamemodify(included, ':t')
        if vim.fn.filereadable(sp .. '/' .. fname) == 1 then
          include_pos[#include_pos + 1] = { idx = i, fname = fname, line = line }
        end
      end
    end
  end
  local fname_to_line = {}
  for _, e in ipairs(include_pos) do fname_to_line[e.fname] = e.line end

  local order     = {}
  for i, s in ipairs(sections) do order[i] = s end
  local cur       = 1
  local move_mode = false
  local inner     = 54
  local idx_to_line = {}   -- card index → first buffer line, updated by render()

  local function render()
    local ls = {}
    idx_to_line = {}
    for i, s in ipairs(order) do
      idx_to_line[i] = #ls + 1
      local sel = (i == cur) and move_mode
      local tl, tr, bl, br, si, bar
      if sel then
        tl, tr, bl, br, si = '╔', '╗', '╚', '╝', '║'
        bar = string.rep('═', inner)
      else
        tl, tr, bl, br, si = '┌', '┐', '└', '┘', '│'
        bar = string.rep('─', inner)
      end

      local icon       = STATUS_ICON[s.status] or '·'
      local status_tag = icon .. ' ' .. (s.status ~= '' and s.status or '—')
      local words_tag  = s.words .. 'w'
      local gap = math.max(1, inner - #s.fname - #status_tag - #words_tag - 2)
      local hdr = s.fname .. string.rep(' ', gap) .. status_tag .. '  ' .. words_tag
      ls[#ls + 1] = tl .. bar .. tr
      ls[#ls + 1] = si .. ' ' .. hdr:sub(1, inner - 1)
                      .. string.rep(' ', math.max(0, inner - 1 - #hdr)) .. ' ' .. si
      ls[#ls + 1] = si .. string.rep(' ', inner + 1) .. si

      local body = s.summary ~= '' and s.summary or '(no summary)'
      if s.keywords ~= '' then body = body .. '  ·  ' .. s.keywords end
      local bw = inner - 2
      repeat
        local seg = body:sub(1, bw)
        if #body > bw then
          local cut = seg:match '(.*)%s'
          if cut and #cut > 2 then seg = cut end
        end
        ls[#ls + 1] = si .. ' ' .. seg .. string.rep(' ', bw - #seg) .. ' ' .. si
        body = body:sub(#seg + 1):gsub('^%s+', '')
      until body == ''

      ls[#ls + 1] = bl .. bar .. br
      ls[#ls + 1] = ''
    end
    return ls
  end

  local function get_footer()
    if move_mode then
      return ' j/k · select   K/J · move card   m · move[on]   ↵ · save order   q · close '
    else
      return ' j/k · select   m · move[off]   ↵ · open   q · close '
    end
  end

  local buf, win = open_float(render(), 'Corkboard', {
    width  = inner + 4,
    height = math.floor(vim.o.lines * 0.85),
  })
  vim.api.nvim_win_set_config(win, { footer = get_footer(), footer_pos = 'center' })

  local function scroll_to_cur()
    local lnum = idx_to_line[cur] or 1
    vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  end

  local function redraw()
    local lines = render()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_win_set_config(win, { footer = get_footer(), footer_pos = 'center' })
    scroll_to_cur()
  end

  scroll_to_cur()

  vim.keymap.set('n', 'j', function()
    if cur < #order then cur = cur + 1; redraw() end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'k', function()
    if cur > 1 then cur = cur - 1; redraw() end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'm', function()
    move_mode = not move_mode; redraw()
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'K', function()
    if move_mode and cur > 1 then
      order[cur], order[cur - 1] = order[cur - 1], order[cur]; cur = cur - 1; redraw()
    end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'J', function()
    if move_mode and cur < #order then
      order[cur], order[cur + 1] = order[cur + 1], order[cur]; cur = cur + 1; redraw()
    end
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', function()
    if move_mode and pfile then
      local n = 0
      for _, s in ipairs(order) do
        if fname_to_line[s.fname] then
          n = n + 1
          if include_pos[n] then
            plines[include_pos[n].idx] = fname_to_line[s.fname]
          end
        end
      end
      vim.fn.writefile(plines, pfile)
      vim.api.nvim_win_close(win, true)
      vim.notify('[binder] order saved to ' .. vim.fn.fnamemodify(pfile, ':t'))
      local pbuf = vim.fn.bufnr(pfile)
      if pbuf ~= -1 then vim.cmd('checktime ' .. pbuf) end
    else
      vim.api.nvim_win_close(win, true)
      vim.cmd('edit ' .. vim.fn.fnameescape(order[cur].path))
    end
  end, { buffer = buf, silent = true })
  close_keys(buf, win)
end

-- ── bf: focus mode ───────────────────────────────────────────────────────────

local function cmd_focus()
  if not require_section_file() then return end
  local fpath = vim.fn.expand '%:p'
  local fname = vim.fn.fnamemodify(fpath, ':t')
  local buf   = vim.fn.bufnr(fpath)
  if buf == -1 then
    buf = vim.fn.bufadd(fpath)
    vim.fn.bufload(buf)
  end
  local w = math.min(90, math.floor(vim.o.columns * 0.78))
  local h = math.floor(vim.o.lines * 0.88)
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = 'editor',
    row       = math.floor((vim.o.lines - h) / 2),
    col       = math.floor((vim.o.columns - w) / 2),
    width = w, height = h,
    style     = 'minimal',
    border    = require('misc.style').border,
    title     = '  ' .. fname .. ' — focus ',
    title_pos = 'center',
  })
  vim.wo[win].wrap       = true
  vim.wo[win].linebreak  = true
  vim.wo[win].number     = false
  vim.wo[win].signcolumn = 'no'
  -- <leader>bf again closes the focus window from inside it
  vim.keymap.set('n', '<leader>bf', function()
    vim.api.nvim_win_close(win, false)
  end, { buffer = buf, silent = true, desc = 'close [f]ocus' })
end

-- ── bh: section history ──────────────────────────────────────────────────────

local function cmd_history()
  if not require_section_file() then return end
  local fpath = vim.fn.expand '%:p'
  local fname = vim.fn.fnamemodify(fpath, ':t')
  local log   = vim.fn.systemlist { 'git', 'log', '--oneline', '--', fpath }
  if #log == 0 then
    vim.notify('[binder] no git history for ' .. fname, vim.log.levels.WARN)
    return
  end

  local lines = { '  ' .. fname, '' }
  for _, l in ipairs(log) do lines[#lines + 1] = '  ' .. l end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  <Enter>: show diff in split    q: close'

  local buf, win = open_float(lines, 'Section History')
  vim.api.nvim_win_set_cursor(win, { 3, 0 })

  vim.keymap.set('n', '<CR>', function()
    local row  = vim.api.nvim_win_get_cursor(win)[1]
    local hash = lines[row] and lines[row]:match '^%s+(%x+)'
    if not hash then return end
    vim.api.nvim_win_close(win, true)
    vim.cmd('botright split | terminal git show ' .. hash .. ' -- ' .. vim.fn.shellescape(fpath))
  end, { buffer = buf, silent = true })
  close_keys(buf, win)
end

-- ── bir: status report (moved from keymap.lua) ───────────────────────────────

local function cmd_report()
  local sp = require_sections()
  if not sp then return end
  local files = vim.fn.globpath(sp, '*.qmd', false, true)
  vim.list_extend(files, vim.fn.globpath(sp, '*.md', false, true))
  if #files == 0 then
    vim.notify('[binder] no section files found', vim.log.levels.WARN)
    return
  end

  local by_status, no_status = {}, {}
  for _, fpath in ipairs(files) do
    local fname    = vim.fn.fnamemodify(fpath, ':t')
    local status   = nil
    local in_meta, meta_end = false, ''
    for i, line in ipairs(vim.fn.readfile(fpath, '', 30)) do
      if i == 1 and line == '---' then
        in_meta, meta_end = true, '^%-%-%-'
      elseif i == 1 and line:match '^<!%-%-' then
        in_meta, meta_end = true, '%-%->'
      elseif in_meta and line:match(meta_end) then
        break
      elseif in_meta then
        local s = line:match '^status:%s*(.-)%s*$'
        if s and s ~= '' then status = s end
      end
    end
    if status then
      by_status[status] = by_status[status] or {}
      table.insert(by_status[status], fname)
    else
      table.insert(no_status, fname)
    end
  end

  local total, report, shown = #files, {}, {}
  for _, st in ipairs { 'todo', 'draft', 'review', 'done' } do
    local list = by_status[st]
    if list then
      shown[st] = true
      table.sort(list)
      local pct = math.floor(#list / total * 100 + 0.5)
      report[#report + 1] = string.format('%s  (%d%%  %d/%d)', st, pct, #list, total)
      for _, f in ipairs(list) do report[#report + 1] = '  ' .. f end
      report[#report + 1] = ''
    end
  end
  for st, list in pairs(by_status) do
    if not shown[st] then
      table.sort(list)
      local pct = math.floor(#list / total * 100 + 0.5)
      report[#report + 1] = string.format('%s  (%d%%  %d/%d)', st, pct, #list, total)
      for _, f in ipairs(list) do report[#report + 1] = '  ' .. f end
      report[#report + 1] = ''
    end
  end
  if #no_status > 0 then
    table.sort(no_status)
    local pct = math.floor(#no_status / total * 100 + 0.5)
    report[#report + 1] = string.format('(no status)  (%d%%  %d/%d)', pct, #no_status, total)
    for _, f in ipairs(no_status) do report[#report + 1] = '  ' .. f end
  end

  local buf, win = open_float(report, 'Manuscript Status Report',
    { width = math.floor(vim.o.columns * 0.5) })
  close_keys(buf, win)
end

-- ── keymap registration ───────────────────────────────────────────────────────

function M.setup()
  local wk = require 'which-key'
  local tb = require 'telescope.builtin'

  wk.add({
    { '<leader>b',   group = '[b]inder' },

    { '<leader>bs', function()
        local sp = require_sections()
        if sp then tb.find_files { prompt_title = ' Binder Sections ', search_dirs = { sp }, hidden = true } end
      end, desc = '[s]ections' },

    { '<leader>bl', cmd_label,     desc = '[l]abel / set status' },
    { '<leader>bn', cmd_new,       desc = '[n]ew section' },
    { '<leader>bb', cmd_back,      desc = '[b]ack to parent' },
    { '<leader>bm', cmd_move,      desc = '[m]ove / reorder' },
    { '<leader>bo', cmd_outliner,  desc = '[o]utliner' },
    { '<leader>bc', cmd_corkboard, desc = '[c]orkboard' },
    { '<leader>bf', cmd_focus,     desc = '[f]ocus mode' },
    { '<leader>bh', cmd_history,   desc = '[h]istory' },

    { '<leader>bi',  group = '[i]nspector' },
    { '<leader>bir', cmd_report,   desc = '[r]eport' },
    { '<leader>bis', function()
        local sp = require_sections()
        if sp then tb.live_grep {
          search_dirs  = { sp },
          prompt_title = ' Inspector: Status ',
          default_text = 'status: ',
        } end
      end, desc = '[s]tatus grep' },
    { '<leader>bik', function()
        local sp = require_sections()
        if sp then tb.live_grep {
          search_dirs  = { sp },
          prompt_title = ' Inspector: Keywords ',
          default_text = 'keywords: ',
        } end
      end, desc = '[k]eywords grep' },
  }, { mode = 'n' })
end

return M
