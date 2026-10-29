-- beverbs.lua: be-verb hints for English prose, shown as HINT diagnostics
-- with source "be-verb" and the kind in the message:
--   progressive  "was walking"   fix: "trudged", "shuffled", "sauntered"...
--   passive      "was signed" (by Francis)
--   copula       "was angry"
--   existential  "there were"
-- Only progressives get a fix, since the replacement is mechanical: the
-- whole span becomes the simple form of a more specific verb, in the same
-- tense ("had been walking" -> "had trudged", "I'm walking" -> "I trudge").
--
-- The work runs in the Grammalecte bridge's process (scripts/beverbs.py,
-- loaded on the first check; needs scripts/setup_prose_venv.sh), on the
-- same text Grammalecte sees with the French blanked out instead. Candidates
-- come from WordNet's troponyms, ranked by Datamuse when online.
--
-- .md and .qmd files only, not `lang: fr` documents; on open, on save, and
-- on <leader>zc. <leader>zb toggles the hints for the session.
-- <leader>zf (and <leader>la): pick a stronger verb, or ignore the rule --
-- by name only (BE_PROGRESSIVE, BE_PASSIVE, BE_COPULA, BE_EXISTENTIAL) in
-- the usual grammalecte:ignore comments or .grammalecte-ignore; a bare
-- `<!-- grammalecte:ignore -->` leaves be-verbs hinted.

local M = {}

local grammalecte = require 'config.grammalecte'
local ns = vim.api.nvim_create_namespace 'beverbs'

local unavailable = false -- prose venv missing; set once, stops requests

function M.enabled()
  return vim.g.beverbs_enabled ~= false
end

-- Real .md/.qmd files, not markdown scratch buffers (hover docs, chat).
-- Their declared language is checked per check, since a save can change it.
local function prose_file(buf)
  local ft = vim.bo[buf].filetype
  return (ft == 'quarto' or ft == 'markdown') and vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf):match '%.q?md$' ~= nil
end

-- The bridge couldn't import spaCy & co.: say so once, and stop asking.
local function give_up(why)
  if not unavailable then
    unavailable = true
    vim.notify('[be-verb] hints unavailable: ' .. why, vim.log.levels.WARN)
  end
end

function M.check(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not M.enabled() or unavailable or not prose_file(buf) or grammalecte.is_french(buf) then
    vim.diagnostic.reset(ns, buf)
    return
  end
  local tick = vim.b[buf].changedtick
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  grammalecte.request({ op = 'beverbs', text = text, ignore = grammalecte.read_ignores(buf) }, function(resp)
    if resp.unavailable then
      give_up(resp.unavailable)
      return
    end
    -- Stale (edited since, or toggled off meanwhile): the next save re-checks.
    if not M.enabled() or not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].changedtick ~= tick then
      return
    end
    local diags = {}
    for _, e in ipairs(resp.errors or {}) do
      table.insert(diags, {
        lnum = e.lnum,
        col = e.col,
        end_lnum = e.end_lnum,
        end_col = e.end_col,
        severity = vim.diagnostic.severity.HINT,
        source = 'be-verb',
        code = e.rule,
        message = e.message,
        user_data = { fix = e.fix ~= vim.NIL and e.fix or nil },
      })
    end
    vim.diagnostic.set(ns, buf, diags)
  end)
end

function M.toggle()
  vim.g.beverbs_enabled = not M.enabled()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.check(buf) -- clears when off
    end
  end
  vim.notify('[be-verb] hints ' .. (M.enabled() and 'on' or 'off'), vim.log.levels.INFO)
end

-- The be-verb diagnostic under the cursor, else the first on the line.
function M.diagnostic_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local diags = vim.diagnostic.get(0, { namespace = ns, lnum = row - 1 })
  for _, d in ipairs(diags) do
    if d.col <= col and (col < d.end_col or d.end_lnum > d.lnum) then
      return d
    end
  end
  return diags[1]
end

-- Matches the case of the span being replaced ("Was walking" -> "Trudged").
local function match_case(original, text)
  if original:match '^%s*%u' then
    return (text:gsub('^(%s*)(%l)', function(space, c)
      return space .. c:upper()
    end, 1))
  end
  return text
end

-- Asks the bridge for replacements for d's progressive, then offers them.
local function pick_verb(buf, d)
  local original = table.concat(vim.api.nvim_buf_get_text(buf, d.lnum, d.col, d.end_lnum, d.end_col, {}), '\n')
  grammalecte.request({ op = 'suggest', fix = d.user_data.fix }, function(resp)
    if resp.unavailable then
      give_up(resp.unavailable)
      return
    end
    if not resp.suggestions or #resp.suggestions == 0 then
      vim.notify('[be-verb] no suggestions for "' .. original .. '"', vim.log.levels.INFO)
      return
    end
    vim.ui.select(resp.suggestions, {
      prompt = 'Replace "' .. vim.trim(original) .. '"',
      format_item = function(s)
        return vim.trim(original) .. ' → ' .. vim.trim(match_case(original, s.text)) .. '   (' .. s.note .. ')'
      end,
    }, function(s)
      if not s or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      -- The picker is async; don't clobber text edited in the meantime.
      local ok, now = pcall(vim.api.nvim_buf_get_text, buf, d.lnum, d.col, d.end_lnum, d.end_col, {})
      if not ok or table.concat(now, '\n') ~= original then
        vim.notify('[be-verb] the text has changed; re-check with <leader>zc', vim.log.levels.WARN)
        return
      end
      vim.api.nvim_buf_set_text(buf, d.lnum, d.col, d.end_lnum, d.end_col, { match_case(original, s.text) })
      M.check(buf)
    end)
  end)
end

-- Actions for the be-verb diagnostic under the cursor, as { label, fn }
-- items. Shared by <leader>zf and the <leader>la picker.
function M.code_actions(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local d = M.diagnostic_at_cursor()
  if not d then
    return {}
  end
  local function act(label, fn)
    return { label = '⟨be-verb⟩ ' .. label, fn = fn }
  end
  local function ignore(label, fn)
    return act(label, function()
      fn()
      M.check(buf)
    end)
  end
  local items = {}
  if d.user_data.fix then
    table.insert(
      items,
      act('Replace ' .. d.message:match '".*"' .. ' with a stronger verb…', function()
        pick_verb(buf, d)
      end)
    )
  end
  vim.list_extend(items, {
    ignore('Ignore ' .. d.code .. ' on this line', function()
      grammalecte.ignore_on_line(buf, d.lnum, d.code)
    end),
    ignore('Ignore ' .. d.code .. ' in this file', function()
      grammalecte.ignore_in_file(buf, d.code)
    end),
    ignore('Ignore ' .. d.code .. ' in this project', function()
      vim.fn.writefile({ d.code }, grammalecte.ignore_file(buf), 'a')
    end),
    act('Turn be-verb hints off (<leader>zb)', M.toggle),
  })
  return items
end

function M.setup()
  local group = vim.api.nvim_create_augroup('beverbs', { clear = true })
  local function attach(buf)
    if not prose_file(buf) then
      return
    end
    -- FileType can fire again for the same buffer (:set ft=...).
    vim.api.nvim_clear_autocmds { group = group, event = 'BufWritePost', buffer = buf }
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = group,
      buffer = buf,
      callback = function()
        M.check(buf)
      end,
    })
    -- Deferred like Grammalecte's: later loading steps bump changedtick.
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.check(buf)
      end
    end)
  end
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'quarto', 'markdown' },
    callback = function(ev)
      attach(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      attach(buf)
    end
  end
end

return M
