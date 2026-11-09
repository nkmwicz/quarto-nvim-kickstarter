-- Daily writing log for a binder manuscript: `.binder-log` at the project
-- root (sibling of sections/), one line per day, committed with the
-- manuscript. Only projects with a log are logged; <leader>bLi creates one.
--
--   2026-11-09<TAB>+412<TAB>48210<TAB>intro.qmd +300, ch2.qmd +112, ch3.qmd +0
--   date, net words, manuscript total at the last update, sections saved
--   that day with their net words (+0: revised, same length).
--
-- Words are counted per section on save (the count on disk just before the
-- first save of the session is the baseline), so only writing done in
-- Neovim counts, and the log is merged into today's line on exit
-- (VimLeavePre) or <leader>bLw.

local M = {}

local LOG = '.binder-log'
local HEADER = '# binder writing log: date, net words, manuscript total, sections saved (net words each)'

local baseline = {} -- path → words on disk at the last save
local pending  = {} -- path → { delta = n } since the last flush (saved, possibly +0)

local function binder() return require 'config.binder' end

local function project_of(path)
  return path:match '^(.*)/sections/[^/]+%.q?md$'
end

local function log_path(project) return project .. '/' .. LOG end

local function has_log(project)
  return vim.fn.filereadable(log_path(project)) == 1
end

-- Parse one log line → { date, net, total, files = { {name, n} } } or nil.
local function parse(line)
  local date, net, total, rest = line:match '^(%d%d%d%d%-%d%d%-%d%d)\t([+-]%d+)\t(%d+)\t?(.*)$'
  if not date then return nil end
  local files = {}
  for name, n in rest:gmatch '%s*([^,]+) ([+-]%d+)' do
    files[#files + 1] = { name = name, n = tonumber(n) }
  end
  return { date = date, net = tonumber(net), total = tonumber(total), files = files }
end

local function format(e)
  local parts = {}
  for _, f in ipairs(e.files) do parts[#parts + 1] = string.format('%s %+d', f.name, f.n) end
  return string.format('%s\t%+d\t%d\t%s', e.date, e.net, e.total, table.concat(parts, ', '))
end

local function manuscript_total(project)
  local total = 0
  for _, s in ipairs(binder().collect_sections_ordered(project .. '/sections')) do
    total = total + s.words
  end
  return total
end

-- This project's unflushed sections: { {name, n, path} }, in name order.
local function pending_for(project)
  local out = {}
  for path, p in pairs(pending) do
    if project_of(path) == project then
      out[#out + 1] = { name = vim.fn.fnamemodify(path, ':t'), n = p.delta, path = path }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- The log's lines with this session merged into today's entry; also returns
-- that entry and whether anything was pending.
local function merged(project)
  local lines = has_log(project) and vim.fn.readfile(log_path(project)) or { HEADER }
  local today = os.date '%Y-%m-%d'
  local idx, entry
  for i = #lines, 1, -1 do
    local e = parse(lines[i])
    if e and e.date == today then idx, entry = i, e; break end
  end
  local new = pending_for(project)
  if #new == 0 then return lines, entry, false end

  entry = entry or { date = today, net = 0, total = 0, files = {} }
  local by_name = {}
  for _, f in ipairs(entry.files) do by_name[f.name] = f end
  for _, p in ipairs(new) do
    if by_name[p.name] then
      by_name[p.name].n = by_name[p.name].n + p.n
    else
      by_name[p.name] = { name = p.name, n = p.n }
      entry.files[#entry.files + 1] = by_name[p.name]
    end
  end
  entry.net = 0
  for _, f in ipairs(entry.files) do entry.net = entry.net + f.n end
  entry.total = manuscript_total(project)
  if idx then lines[idx] = format(entry) else lines[#lines + 1] = format(entry) end
  return lines, entry, true
end

-- Write this session's pending counts into the project's log.
function M.flush(project, verbose)
  if not has_log(project) then return end
  local lines, entry, changed = merged(project)
  if not changed then
    if verbose then vim.notify '[log] nothing new to log' end
    return
  end
  vim.fn.writefile(lines, log_path(project))
  for _, p in ipairs(pending_for(project)) do pending[p.path] = nil end
  if verbose then vim.notify(string.format('[log] today %+d words', entry.net)) end
end

function M.flush_all(verbose)
  local projects = {}
  for path in pairs(pending) do
    local pr = project_of(path)
    if pr then projects[pr] = true end
  end
  if verbose and vim.tbl_isempty(projects) then vim.notify '[log] nothing new to log' end
  for pr in pairs(projects) do M.flush(pr, verbose) end
end

-- Today's net words for a project (log + unflushed session), or nil without a log.
function M.today(project)
  if not has_log(project) then return nil end
  local _, entry = merged(project)
  return entry and entry.net or 0
end

local function current_project()
  local sp = binder().require_sections()
  return sp and vim.fn.fnamemodify(sp, ':h')
end

function M.init()
  local project = current_project()
  if not project then return end
  if has_log(project) then
    vim.notify('[log] ' .. LOG .. ' already exists — logging is on')
    return
  end
  vim.fn.writefile({ HEADER }, log_path(project))
  vim.notify('[log] created ' .. LOG .. ' — saves to sections/ are logged on exit')
end

-- Float: recent days, newest first, with totals, streak and bars.
function M.show()
  local project = current_project()
  if not project then return end
  if not has_log(project) then
    vim.notify('[log] no ' .. LOG .. ' here — <leader>bLi to start one', vim.log.levels.WARN)
    return
  end
  local lines = merged(project)
  local days = {}
  for _, l in ipairs(lines) do
    local e = parse(l)
    if e then days[#days + 1] = e end
  end
  table.sort(days, function(a, b) return a.date > b.date end)

  local function day_offset(date)
    local y, m, d = date:match '(%d+)-(%d+)-(%d+)'
    local t = os.time { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
    local now = os.date '*t'
    local noon = os.time { year = now.year, month = now.month, day = now.day, hour = 12 }
    return math.floor((noon - t) / 86400 + 0.5)
  end
  local week, month = 0, 0
  for _, e in ipairs(days) do
    local off = day_offset(e.date)
    if off < 7 then week = week + e.net end
    if off < 30 then month = month + e.net end
  end
  -- streak: consecutive logged days ending today (or yesterday, if today is empty)
  local streak, expect = 0, nil
  for _, e in ipairs(days) do
    local off = day_offset(e.date)
    if expect == nil then
      if off > 1 then break end
      expect = off
    end
    if off ~= expect then break end
    streak, expect = streak + 1, expect + 1
  end

  local out = {
    string.format('  Today %+d   ·   7 days %+d   ·   30 days %+d   ·   streak %d day%s',
      days[1] and day_offset(days[1].date) == 0 and days[1].net or 0, week, month,
      streak, streak == 1 and '' or 's'),
    '',
  }
  local shown = math.min(#days, 60)
  local maxabs = 1
  for i = 1, shown do maxabs = math.max(maxabs, math.abs(days[i].net)) end
  local BAR = 20
  for i = 1, shown do
    local e = days[i]
    local len = math.floor(BAR * math.abs(e.net) / maxabs + 0.5)
    local bar = string.rep(e.net >= 0 and '█' or '▒', len) .. string.rep(' ', BAR - len)
    local parts = {}
    for _, f in ipairs(e.files) do parts[#parts + 1] = string.format('%s %+d', f.name, f.n) end
    out[#out + 1] = string.format('  %s  %6s  %s  %s', e.date, string.format('%+d', e.net), bar,
      table.concat(parts, ', '))
  end
  if shown == 0 then out[#out + 1] = '  (nothing logged yet)' end

  local b = binder()
  local buf, win = b.open_float(out, 'Writing Log — ' .. vim.fn.fnamemodify(project, ':t'),
    { width = math.floor(vim.o.columns * 0.85) })
  vim.wo[win].wrap = true
  vim.wo[win].breakindent = true
  vim.wo[win].breakindentopt = 'shift:42'
  vim.wo[win].showbreak = 'NONE'
  b.close_keys(buf, win)
end

function M.setup()
  local group = vim.api.nvim_create_augroup('BinderWritingLog', { clear = true })
  local pat = { '*/sections/*.qmd', '*/sections/*.md' }
  local modified = {}

  vim.api.nvim_create_autocmd('BufWritePre', {
    group = group, pattern = pat,
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if not project_of(path) then return end
      if baseline[path] == nil then
        baseline[path] = vim.fn.filereadable(path) == 1 and binder().word_count(path) or 0
      end
      modified[path] = vim.bo[ev.buf].modified
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group, pattern = pat,
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if baseline[path] == nil then return end
      local n = binder().word_count(path)
      if modified[path] or n ~= baseline[path] then
        pending[path] = pending[path] or { delta = 0 }
        pending[path].delta = pending[path].delta + n - baseline[path]
      end
      baseline[path] = n
      modified[path] = nil
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      pcall(M.flush_all, false)
    end,
  })
end

return M
