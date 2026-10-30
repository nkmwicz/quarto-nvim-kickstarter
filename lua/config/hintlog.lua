-- hintlog.lua: a log of wrong be-verb, Strunk and style hints, to tune the
-- rules against. Two kinds of entry:
--   false_positive  a hint that shouldn't be there: "Wrong hint" in the
--                   <leader>zf / <leader>la actions on it
--   false_negative  a hint that should be there and isn't: <leader>zm on the
--                   line, or on a visual selection, then pick the rule
-- Each entry keeps the whole buffer as it was (an echo or a reporting tense
-- depends on the rest of the document), so scripts/replay_hints.py can
-- re-run the check in the same context and say which entries the current
-- rules still get wrong (<leader>zr). The log is stdpath('data')/
-- prose-hints.jsonl, outside this public repo, since it holds unpublished
-- prose. A logged false positive stays hidden while its line reads the same.

local M = {}

M.path = vim.fn.stdpath 'data' .. '/prose-hints.jsonl'

local replay = vim.fn.stdpath 'config' .. '/scripts/replay_hints.py'

-- What <leader>zm offers; OTHER is for a problem no rule covers yet.
M.RULES = {
  'BE_PROGRESSIVE',
  'BE_PASSIVE',
  'BE_COPULA',
  'BE_EXISTENTIAL',
  'PARENTHETIC_COMMA',
  'COMMA_SPLICE',
  'DANGLING_MODIFIER',
  'NEGATIVE_FORM',
  'NOMINALIZATION',
  'VAGUE_VERB',
  'WEAK_ENDING',
  'NOMINAL_SUBJECT',
  'GERUND_SUBJECT',
  'VAGUE_THIS',
  'SUBJECT_VERB_GAP',
  'NOUN_STACK',
  'OF_CHAIN',
  'ECHO',
  'QUOTE_ENDING',
  'REPORTING_TENSE',
  'OTHER',
}

local function key(file, rule, line, flagged)
  return table.concat({ file, rule, vim.trim(line), flagged }, '\0')
end

-- Logged false positives, re-read when the log changes.
local cache = { mtime = nil, hidden = {} }

local function hidden_set()
  local stat = vim.uv.fs_stat(M.path)
  local mtime = stat and (stat.mtime.sec .. '.' .. stat.mtime.nsec)
  if mtime == cache.mtime then
    return cache.hidden
  end
  local hidden = {}
  for _, l in ipairs(stat and vim.fn.readfile(M.path) or {}) do
    local ok, e = pcall(vim.json.decode, l)
    if ok and e.kind == 'false_positive' then
      hidden[key(e.file, e.rule, e.line, e.flagged)] = true
    end
  end
  cache = { mtime = mtime, hidden = hidden }
  return hidden
end

-- Whether a hint (rule over `flagged` on line lnum) was logged as wrong.
function M.hidden(buf, rule, lnum, flagged)
  local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ''
  return hidden_set()[key(vim.api.nvim_buf_get_name(buf), rule, line, flagged)] == true
end

-- The lines from the blank line above lnum to the one below.
local function paragraph(lines, lnum)
  local first, last = lnum + 1, lnum + 1
  while first > 1 and not lines[first - 1]:match '^%s*$' do
    first = first - 1
  end
  while last < #lines and not lines[last + 1]:match '^%s*$' do
    last = last + 1
  end
  return table.concat(lines, '\n', first, last)
end

-- Asks why (optional; <Esc> cancels), then appends the entry r, which
-- holds the kind, rule and range (0-based, end exclusive).
local function record(buf, r, done)
  vim.ui.input({ prompt = r.rule .. ' ' .. r.kind:gsub('_', ' ') .. ', why? (optional) ' }, function(note)
    if note == nil or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    r.note = note ~= '' and note or nil
    r.time = os.date '%Y-%m-%d %H:%M'
    r.file = vim.api.nvim_buf_get_name(buf)
    r.line = lines[r.lnum + 1]
    r.flagged = table.concat(vim.api.nvim_buf_get_text(buf, r.lnum, r.col, r.end_lnum, r.end_col, {}), '\n')
    r.paragraph = paragraph(lines, r.lnum)
    r.text = table.concat(lines, '\n')
    r.bib = require('config.beverbs').bibliographies(buf)
    vim.fn.writefile({ vim.json.encode(r) }, M.path, 'a')
    vim.notify('[hintlog] logged ' .. r.rule .. ' (' .. r.kind:gsub('_', ' ') .. ')', vim.log.levels.INFO)
    if done then
      done()
    end
  end)
end

-- Logs the hint d as wrong, and hides it.
function M.false_positive(buf, d)
  record(buf, {
    kind = 'false_positive',
    rule = d.code,
    source = d.source,
    message = d.message,
    lnum = d.lnum,
    col = d.col,
    end_lnum = d.end_lnum,
    end_col = d.end_col,
  }, function()
    require('config.beverbs').check(buf)
  end)
end

-- Logs a missed hint over the visual selection, or else the cursor line.
function M.missed()
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local r
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local region = vim.fn.getregionpos(vim.fn.getpos 'v', vim.fn.getpos '.', { type = mode })
    local first, last = region[1][1], region[#region][2]
    -- getregionpos ends on the last byte of the last character.
    r = { lnum = first[2] - 1, col = first[3] - 1, end_lnum = last[2] - 1, end_col = last[3] }
    vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
  else
    local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
    r = { lnum = lnum, col = 0, end_lnum = lnum, end_col = #vim.api.nvim_get_current_line() }
  end
  vim.ui.select(M.RULES, { prompt = 'Which rule missed this?' }, function(rule)
    if rule then
      r.kind, r.rule = 'false_negative', rule
      record(buf, r)
    end
  end)
end

-- Re-checks every logged entry with the current rules, in a split.
function M.replay()
  if vim.fn.filereadable(M.path) == 0 then
    vim.notify('[hintlog] nothing logged yet', vim.log.levels.INFO)
    return
  end
  vim.cmd 'botright new'
  vim.fn.jobstart({ require('config.grammalecte').python(), replay, M.path }, { term = true })
end

return M
