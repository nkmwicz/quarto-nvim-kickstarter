-- Visual-mode bold/italic toggles for markdown and Quarto buffers.
--
-- <C-b> toggles **bold**, <C-i> toggles *italics* on the selection. Stars
-- either inside the selection (`**word**` selected) or just outside it (`word`
-- selected inside `**word**`) count as existing emphasis, so a second press
-- removes it. Bold and italics stack (`***word***`) and each key only adds or
-- removes its own stars. Whitespace at the edges of the selection is left
-- outside the markers (`**word **` isn't emphasis in Pandoc). The new text stays
-- selected, so <C-b><C-i> gives bold italics. Blockwise selections toggle each
-- line on its own.
--
-- Mapping <C-b> here also replaces Vim's visual-mode page-up (which extends the
-- selection a screenful), in these buffers only.

local M = {}

local api = vim.api

local function line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
end

-- Stars at the start of `s` (or, with `from_end`, at its end).
local function stars(s, from_end)
  local pat = from_end and '%*+$' or '^%*+'
  local m = s:match(pat)
  return m and #m or 0
end

-- Toggle a `w`-star marker on the span [sr,sc)–[er,ec) (0-based rows, byte
-- columns, end exclusive). Returns the new span, or nil if nothing was done.
local function toggle(buf, w, sr, sc, er, ec)
  -- Keep edge whitespace outside the markers.
  local first, last = line(buf, sr), line(buf, er)
  while sc < #first and first:sub(sc + 1, sc + 1):match '%s' and not (sr == er and sc >= ec) do
    sc = sc + 1
  end
  while ec > 0 and last:sub(ec, ec):match '%s' and not (sr == er and ec <= sc) do
    ec = ec - 1
  end
  if sr == er and ec <= sc then
    return nil
  end

  local head = first:sub(sc + 1, sr == er and ec or #first)
  local tail = last:sub(sr == er and sc + 1 or 1, ec)
  local inner = math.min(stars(head), stars(tail, true))
  if sr == er and inner * 2 >= ec - sc then
    inner = 0 -- a selection of nothing but stars
  end

  local outside = false
  local k = inner
  if inner == 0 then
    k = math.min(stars(first:sub(1, sc), true), stars(last:sub(ec + 1)))
    outside = k > 0
  end

  local present = (w == 2 and k >= 2) or (w == 1 and k % 2 == 1)
  local same = sr == er
  local marker = string.rep('*', w)

  if not present then
    api.nvim_buf_set_text(buf, er, ec, er, ec, { marker })
    api.nvim_buf_set_text(buf, sr, sc, sr, sc, { marker })
    return sr, sc, er, ec + (same and 2 * w or w)
  elseif outside then
    api.nvim_buf_set_text(buf, er, ec, er, ec + w, {})
    api.nvim_buf_set_text(buf, sr, sc - w, sr, sc, {})
    return sr, sc - w, er, same and ec - w or ec
  else
    api.nvim_buf_set_text(buf, er, ec - w, er, ec, {})
    api.nvim_buf_set_text(buf, sr, sc, sr, sc + w, {})
    return sr, sc, er, ec - (same and 2 * w or w)
  end
end

local function run(w)
  local buf = api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local segs = vim.fn.getregionpos(vim.fn.getpos 'v', vim.fn.getpos '.', { type = mode })
  vim.cmd 'normal! \27'
  if #segs == 0 then
    return
  end

  -- getregionpos gives 1-based inclusive columns, the end being the start of
  -- the last character (or v:maxcol for line ends); convert to 0-based,
  -- end-exclusive byte columns.
  local function span(s, e)
    local text = line(buf, e[2] - 1)
    local ec = math.min(e[3], #text)
    if ec > 0 then
      ec = ec + vim.str_utf_end(text, ec)
    end
    return s[2] - 1, math.max(s[3] - 1, 0), e[2] - 1, ec
  end

  if mode == '\22' then
    for _, seg in ipairs(segs) do
      toggle(buf, w, span(seg[1], seg[2]))
    end
    return
  end

  local sr, sc, er, ec = toggle(buf, w, span(segs[1][1], segs[#segs][2]))
  if not sr then
    return
  end
  -- Reselect the result, charwise.
  local text = line(buf, er)
  local last = ec - 1
  last = last + vim.str_utf_start(text, last + 1)
  api.nvim_buf_set_mark(buf, '<', sr + 1, sc, {})
  api.nvim_buf_set_mark(buf, '>', er + 1, last, {})
  vim.cmd 'normal! `<v`>'
end

function M.attach(buf)
  local opts = { buffer = buf, silent = true }
  vim.keymap.set('x', '<C-b>', function() run(2) end, vim.tbl_extend('force', opts, { desc = 'toggle **bold**' }))
  vim.keymap.set('x', '<C-i>', function() run(1) end, vim.tbl_extend('force', opts, { desc = 'toggle *italics*' }))
end

return M
