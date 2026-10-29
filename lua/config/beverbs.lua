-- beverbs.lua: be-verb hints for English prose, shown as HINT diagnostics
-- with source "be-verb" and the kind in the message:
--   progressive  "was walking"   fix: "trudged", "shuffled", "sauntered"...
--   passive      "was signed" (by Francis)  fix: "Francis signed the treaty"
--                "needed to be redeveloped"  fix: "needed redeveloping"
--   copula       "was angry"
--   existential  "there were"
-- A progressive's fix is mechanical: the whole span becomes the simple form
-- of a more specific verb, in the same tense ("had been walking" -> "had
-- trudged", "I'm walking" -> "I trudge"). A passive gets one only when the
-- doer is named, or after need/deserve...; copulas and existentials need
-- rewording by hand.
--
-- The work runs in the Grammalecte bridge's process (scripts/beverbs.py,
-- loaded on the first check; needs scripts/setup_prose_venv.sh), on the
-- same text Grammalecte sees with the French blanked out instead. Candidates
-- come from WordNet's troponyms, ranked by Datamuse when online.
--
-- The same check runs Strunk & White's rules (scripts/strunk.py) on the
-- same parse, as HINTs with source "strunk": PARENTHETIC_COMMA (S&W 3),
-- COMMA_SPLICE (5), DANGLING_MODIFIER (11), NEGATIVE_FORM (15),
-- NOMINALIZATION and VAGUE_VERB (16), WEAK_ENDING (22). Most come with
-- fixed rewrites, each offered as its own action; VAGUE_VERB gets the
-- troponym picker.
--
-- .md and .qmd files only, not `lang: fr` documents; on open, on save, and
-- on <leader>zc. <leader>zb toggles the hints for the session.
-- <leader>zf (and <leader>la): pick a stronger verb or rewrite, or ignore
-- the rule -- by name only (BE_PASSIVE, COMMA_SPLICE...) in the usual
-- grammalecte:ignore comments or .grammalecte-ignore; a bare
-- `<!-- grammalecte:ignore -->` leaves these hinted.

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
    local function text_at(r)
      return table.concat(vim.api.nvim_buf_get_text(buf, r.lnum, r.col, r.end_lnum, r.end_col, {}), '\n')
    end
    local diags = {}
    for _, e in ipairs(resp.errors or {}) do
      local fix = e.fix ~= vim.NIL and e.fix or nil
      -- What each rewrite replaces, to refuse it once that text has changed.
      for _, c in ipairs(fix and fix.choices or {}) do
        c.original = text_at(c.lnum and c or e)
      end
      table.insert(diags, {
        lnum = e.lnum,
        col = e.col,
        end_lnum = e.end_lnum,
        end_col = e.end_col,
        severity = vim.diagnostic.severity.HINT,
        source = e.rule:match '^BE_' and 'be-verb' or 'strunk',
        code = e.rule,
        message = e.message,
        user_data = { fix = fix },
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
  vim.notify('[be-verb] be-verb and Strunk hints ' .. (M.enabled() and 'on' or 'off'), vim.log.levels.INFO)
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
    return { label = '⟨' .. d.source .. '⟩ ' .. label, fn = fn }
  end
  local function ignore(label, fn)
    return act(label, function()
      fn()
      M.check(buf)
    end)
  end
  local items = {}
  local fix = d.user_data.fix
  if fix and fix.lemma then
    table.insert(
      items,
      act('Replace ' .. d.message:match '".*"' .. ' with a stronger verb…', function()
        pick_verb(buf, d)
      end)
    )
  end
  -- Fixed rewrites, each over the hint's span or its own range.
  for _, c in ipairs(fix and fix.choices or {}) do
    table.insert(
      items,
      act(c.note .. ': "' .. vim.trim(c.text) .. '"', function()
        local r = c.lnum and c or d
        local ok, now = pcall(vim.api.nvim_buf_get_text, buf, r.lnum, r.col, r.end_lnum, r.end_col, {})
        if not ok or table.concat(now, '\n') ~= c.original then
          vim.notify('[' .. d.source .. '] the text has changed; re-check with <leader>zc', vim.log.levels.WARN)
          return
        end
        vim.api.nvim_buf_set_text(buf, r.lnum, r.col, r.end_lnum, r.end_col, vim.split(match_case(c.original, c.text), '\n'))
        M.check(buf)
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
    act('Turn be-verb and Strunk hints off (<leader>zb)', M.toggle),
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
