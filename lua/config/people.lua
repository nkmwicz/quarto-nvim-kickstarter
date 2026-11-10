-- First mentions (<leader>bp): people the manuscript introduces by a short
-- name before giving the full one, short names that could be several
-- people, and people only ever named by one word. Runs in the Grammalecte
-- bridge (scripts/people.py, spaCy from the prose venv) over the cleaned
-- paragraphs of the included sections, in reading order; footnotes and
-- citations are left out, and .bib surnames don't count as single names.
--   <CR> jump to the first mention   q close

local M = {}

function M.open()
  local outline = require 'config.outline'
  local files = outline.files(true)
  if not files or #files == 0 then return end
  local paras, texts = {}, {}
  for _, it in ipairs(outline.items(files)) do
    if it.kind == 'para' then
      paras[#paras + 1] = it
      texts[#texts + 1] = it.text
    end
  end
  if #paras == 0 then
    vim.notify('[people] no paragraphs to read', vim.log.levels.WARN)
    return
  end

  vim.notify(string.format('[people] reading %d paragraphs…', #paras))
  local bib = require('config.beverbs').bibliographies(vim.api.nvim_get_current_buf())
  local ok = require('config.grammalecte').request({ op = 'people', paras = texts, bib = bib }, function(resp)
    if resp.unavailable then
      vim.notify('[people] ' .. resp.unavailable, vim.log.levels.ERROR)
      return
    end
    if not resp.people then
      vim.notify('[people] failed: ' .. tostring(resp.warning), vim.log.levels.ERROR)
      return
    end
    M.show(resp.people, paras)
  end)
  if not ok then vim.notify('[people] the prose bridge is not running', vim.log.levels.ERROR) end
end

local function where(p)
  return string.format('%s ¶%d', vim.fn.fnamemodify(p.path, ':t:r'), p.n)
end

function M.show(res, paras)
  local function target(e)
    local p = paras[e.para + 1]
    return { path = p.path, lnum = p.lnum, search = e.text }
  end

  local function render()
    local lines, hls, rowmap = {}, {}, {}
    local function head(text, empty)
      if #lines > 0 then lines[#lines + 1] = '' end
      lines[#lines + 1] = text
      hls[#hls + 1] = { #lines, 0, -1, 'Title' }
      if empty then
        lines[#lines + 1] = '  ' .. empty
        hls[#hls + 1] = { #lines, 0, -1, 'Comment' }
      end
    end
    local function row(lead, rest, e, group)
      lines[#lines + 1] = lead .. rest
      hls[#hls + 1] = { #lines, 2, #lead, group or 'Identifier' }
      rowmap[#lines] = target(e)
    end

    head(string.format('Short name before the full one — %d', #res.late),
      #res.late == 0 and 'none' or nil)
    for _, e in ipairs(res.late) do
      local fp = paras[e.full_para + 1]
      row(string.format('  %-22s', e.text),
        string.format('  first at %-16s full "%s" only at %s', where(paras[e.para + 1]), e.full, where(fp)),
        e, 'DiagnosticWarn')
    end

    head(string.format('Could be several people — %d', #res.ambiguous),
      #res.ambiguous == 0 and 'none' or nil)
    for _, e in ipairs(res.ambiguous) do
      row(string.format('  %-22s', e.text),
        string.format('  %d× from %-12s %s?', e.count, where(paras[e.para + 1]), table.concat(e.candidates, ' / ')), e)
    end

    head(string.format('Only ever one name — %d', #res.single),
      #res.single == 0 and 'none' or nil)
    for _, e in ipairs(res.single) do
      row(string.format('  %-22s', e.text), string.format('  %d× from %s', e.count, where(paras[e.para + 1])), e, 'Comment')
    end
    return lines, hls, rowmap
  end

  require('config.outline').float {
    title = 'First Mentions',
    footer = '↵ jump to first mention   q close',
    indent = 26,
    render = render,
  }
end

return M
