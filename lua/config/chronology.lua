-- Chronology (<leader>bC): the dates each paragraph mentions, in reading
-- order across the manuscript, with backward jumps in narrative time marked
-- ↶ — sometimes a deliberate flashback, often a structural slip.
--
-- Dates come from the prose only (footnotes and citations are stripped, so
-- publication years don't count): ISO dates (1546-05-12), "12 May 1546",
-- "May 12, 1546", "May 1546", bare years and decades ("the 1540s"). Years
-- outside vim.g.binder_chronology_years (default {1000, 1899}) are ignored,
-- as are numbers after fol./p./ms./no. (folios and shelfmarks).
--   <CR> jump   a all paragraphs / dated only   q close

local M = {}

local MONTHS = {
  january = 1, february = 2, march = 3, april = 4, may = 5, june = 6, july = 7,
  august = 8, september = 9, october = 10, november = 11, december = 12,
  jan = 1, feb = 2, mar = 3, apr = 4, jun = 6, jul = 7, aug = 8, sep = 9, sept = 9,
  oct = 10, nov = 11, dec = 12,
}
local MONTH_ABBR = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }

-- A folio, page, shelfmark or item number, not a year.
local function locator_before(text, pos)
  local before = text:sub(math.max(1, pos - 14), pos - 1):lower()
  return before:match 'fols?%.%s*$' or before:match 'ff?%.%s*$' or before:match 'pp?%.%s*$'
    or before:match 'mss?%.[%a%. ]*$' or before:match 'nos?%.%s*$' or before:match 'n%.%s*$'
    or before:match 'vol%.%s*$' or before:match 'cod%.[%a%. ]*$'
end

-- Dates in text, in order of appearance: { {y, m, d, decade, pos} }.
function M.dates(text)
  local range = vim.g.binder_chronology_years or { 1000, 1899 }
  local found, taken = {}, {}
  local function add(pos, stop, y, m, d, decade)
    y = tonumber(y)
    if not y or y < range[1] or y > range[2] then return end
    for i = pos, stop do
      if taken[i] then return end
    end
    for i = pos, stop do taken[i] = true end
    found[#found + 1] = { y = y, m = m, d = d and tonumber(d), decade = decade, pos = pos }
  end
  local function month(name)
    return MONTHS[name:lower():gsub('%.$', '')]
  end

  -- most specific first, so a full date claims its year before the bare-year pass
  for pos, y, m, d, stop in text:gmatch '()%f[%d](%d%d%d%d)%-(%d%d)%-(%d%d)%f[%D]()' do
    add(pos, stop - 1, y, tonumber(m), d)
  end
  for pos, d, mon, y, stop in text:gmatch '()%f[%d](%d%d?)%s+(%a+%.?)%s+(%d%d%d%d)%f[%D]()' do
    if month(mon) then add(pos, stop - 1, y, month(mon), d) end
  end
  for pos, mon, d, y, stop in text:gmatch '()%f[%a](%a+%.?)%s+(%d%d?),?%s+(%d%d%d%d)%f[%D]()' do
    if month(mon) then add(pos, stop - 1, y, month(mon), d) end
  end
  for pos, mon, y, stop in text:gmatch '()%f[%a](%a+%.?),?%s+(%d%d%d%d)%f[%D]()' do
    if month(mon) then add(pos, stop - 1, y, month(mon)) end
  end
  for pos, y, stop in text:gmatch "()%f[%d](%d%d%d0)['’]?s%f[%A]()" do
    add(pos, stop - 1, y, nil, nil, true)
  end
  for pos, y, stop in text:gmatch '()%f[%d](%d%d%d%d)%f[%D]()' do
    if not locator_before(text, pos) then add(pos, stop - 1, y) end
  end
  table.sort(found, function(a, b) return a.pos < b.pos end)
  return found
end

-- Pad to a display width (→ and ↶ are one column, three bytes).
local function pad(s, w)
  return s .. string.rep(' ', math.max(0, w - vim.fn.strdisplaywidth(s)))
end

local function fmt(dt)
  if dt.decade then return dt.y .. 's' end
  if dt.d then return string.format('%d %s %d', dt.d, MONTH_ABBR[dt.m], dt.y) end
  if dt.m then return MONTH_ABBR[dt.m] .. ' ' .. dt.y end
  return tostring(dt.y)
end

-- Is a earlier than b, at the precision both share?
local function earlier(a, b)
  if a.y ~= b.y then return a.y < b.y end
  if not (a.m and b.m) or a.m == b.m and not (a.d and b.d) then return false end
  if a.m ~= b.m then return a.m < b.m end
  return a.d < b.d
end

local function gap(a, b)
  local years = b.y - a.y
  if years > 1 then return string.format('back %d yrs', years) end
  if years == 1 then return 'back 1 yr' end
  if a.m and b.m and b.m ~= a.m then
    local mo = b.m - a.m
    return string.format('back %d mo%s', mo, mo == 1 and '' or 's')
  end
  return 'back'
end

function M.open()
  local outline = require 'config.outline'
  local files = outline.files(true) or outline.files(false)
  if not files or #files == 0 then
    vim.notify('[chronology] nothing to read', vim.log.levels.WARN)
    return
  end
  local items = outline.items(files, { file_rows = #files > 1 })

  -- Narrative time: the last date of the previous dated paragraph. A
  -- paragraph whose first date is earlier jumps back.
  local now, dated, jumps = nil, 0, 0
  for _, it in ipairs(items) do
    if it.kind == 'para' then
      it.dates = M.dates(it.text)
      if #it.dates > 0 then
        dated = dated + 1
        if now and earlier(it.dates[1], now) then
          it.back = gap(it.dates[1], now)
          jumps = jumps + 1
        end
        now = it.dates[#it.dates]
      end
    end
  end

  local all = false
  local DATE_W = 30
  local function render()
    local lines, hls, rowmap = {}, {}, {}
    for _, it in ipairs(items) do
      if it.kind == 'file' then
        if #lines > 0 then lines[#lines + 1] = '' end
        lines[#lines + 1] = '── ' .. it.text .. ' ' .. string.rep('─', math.max(3, 60 - #it.text))
        hls[#hls + 1] = { #lines, 0, -1, 'Special' }
        rowmap[#lines] = it
      elseif it.kind == 'heading' then
        lines[#lines + 1] = '  ' .. it.text
        hls[#hls + 1] = { #lines, 0, -1, 'Title' }
        rowmap[#lines] = it
      elseif #it.dates > 0 or all then
        local span = ''
        if #it.dates > 0 then
          local first, last = it.dates[1], it.dates[1]
          for _, dt in ipairs(it.dates) do
            if earlier(dt, first) then first = dt end
            if earlier(last, dt) then last = dt end
          end
          span = fmt(first) .. (fmt(last) ~= fmt(first) and ' → ' .. fmt(last) or '')
          if fmt(it.dates[1]) ~= fmt(first) then span = fmt(it.dates[1]) .. ' (' .. span .. ')' end
        end
        local mark = it.back and '↶' or ' '
        local col = string.format(' %s ¶%-3d ', mark, it.n) .. pad(span, DATE_W)
        local note = it.back and (it.back .. '  ') or ''
        lines[#lines + 1] = col .. note .. it.first
        local lead = #string.format(' %s ¶%-3d ', mark, it.n)
        hls[#hls + 1] = { #lines, 0, lead, 'Comment' }
        if it.back then
          hls[#hls + 1] = { #lines, 0, #(' ' .. mark), 'DiagnosticWarn' }
          hls[#hls + 1] = { #lines, #col, #col + #note, 'DiagnosticWarn' }
        elseif #it.dates == 0 then
          hls[#hls + 1] = { #lines, 0, -1, 'Comment' }
        end
        rowmap[#lines] = it
      end
    end
    return lines, hls, rowmap
  end

  outline.float {
    title = string.format('Chronology (%d dated paragraphs, %d jump%s back)', dated, jumps, jumps == 1 and '' or 's'),
    footer = '↵ jump   a all paragraphs / dated only   q close',
    indent = DATE_W + 9,
    render = render,
    keys = {
      a = function(_, redraw)
        all = not all
        redraw(true)
      end,
    },
  }
end

return M
