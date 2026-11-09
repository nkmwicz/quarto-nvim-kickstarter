-- Reverse outline (<leader>br section, <leader>bR manuscript): the first
-- sentence of every paragraph, with its word count and how much of it is
-- quotation — the topic-sentence check for whether an argument holds
-- together. Reads loaded buffers (unsaved edits included), else the files.
--   <CR> jump to the paragraph   l toggle last sentences   q close

local M = {}

local ns = vim.api.nvim_create_namespace 'binder_outline'

-- Paragraphs and headings of a markdown/Quarto text, skipping the line-1
-- metadata block, code fences, multi-line HTML comments, fenced-div
-- markers, tables and shortcodes. → { {kind, lnum, text, blockquote} }
local function blocks(lines)
  local out, n, i = {}, #lines, 1
  if lines[1] == '---' then
    i = 2
    while i <= n and not lines[i]:match '^%-%-%-%s*$' do i = i + 1 end
    i = i + 1
  elseif lines[1] and lines[1]:match '^<!%-%-' then
    while i <= n and not lines[i]:match '%-%->' do i = i + 1 end
    i = i + 1
  end

  local cur
  local function close()
    if cur then
      cur.text = table.concat(cur.lines, ' ')
      out[#out + 1] = cur
      cur = nil
    end
  end
  while i <= n do
    local l = lines[i]
    if l:match '^%s*```' or l:match '^%s*~~~' then
      close()
      i = i + 1
      while i <= n and not (lines[i]:match '^%s*```' or lines[i]:match '^%s*~~~') do i = i + 1 end
    elseif l:match '^%s*<!%-%-' then
      if not l:match '%-%->' then -- a one-line comment doesn't break the paragraph
        close()
        while i <= n and not lines[i]:match '%-%->' do i = i + 1 end
      end
    elseif l:match '^#+%s' then
      close()
      out[#out + 1] = { kind = 'heading', lnum = i, text = l }
    elseif l:match '^%s*$' or l:match '^%s*:::' or l:match '^%s*|' or l:match '^%s*{{<'
        or l:match '^%s*%-%-%-+%s*$' then
      close()
    else
      local bq = l:match '^%s*>' ~= nil
      if not cur then cur = { kind = 'para', lnum = i, lines = {}, blockquote = bq } end
      cur.lines[#cur.lines + 1] = (l:gsub('^%s*>%s?', ''))
    end
    i = i + 1
  end
  close()
  return out
end

-- Prose without footnotes, citations, comments, link targets or emphasis marks.
local function clean(text)
  text = text:gsub('%^%b[]', '')
    :gsub('%[%^[^%]]+%]', '')
    :gsub('<!%-%-.-%-%->', '')
    :gsub('%[([^%]]-)%]%b()', '%1')
    :gsub('%[([^%]]-)%]%b{}', '%1')
    :gsub('%b[]', function(s) if s:find('@', 1, true) then return '' end end)
    :gsub('%*+', '')
    :gsub('%s+', ' ')
    :gsub(' ([.,;:!?])', '%1')
  return vim.trim(text)
end

-- Words that end in a period without ending the sentence.
local ABBR = {}
for _, w in ipairs {
  'mr', 'mrs', 'ms', 'dr', 'st', 'ste', 'mme', 'mlle', 'mgr', 'fr', 'bp', 'abp', 'cf', 'vol',
  'vols', 'ed', 'eds', 'trans', 'fol', 'fols', 'ms', 'mss', 'no', 'nos', 'p', 'pp', 'c', 'ca',
  'e.g', 'i.e', 'viz', 'ibid', 'op', 'cit', 'chap', 'ch', 'n', 'nn', 'r', 'v', 'repr', 'vs',
} do ABBR[w] = true end

local function sentences(text)
  local out, s, from = {}, 1, 1
  while true do
    local a, b = text:find('[.!?][\'"\226\128\157\153%)]*%s+[%u\195\226"%(]', from)
    if not a then break end
    local word = text:sub(s, a - 1):match '([%w%.]+)$'
    if text:sub(a, a) == '.' and word and (ABBR[word:lower()] or word:match '^%u$') then
      from = a + 1
    else
      local stop = text:find('%s', a) -- end of the closing punctuation
      out[#out + 1] = vim.trim(text:sub(s, stop - 1))
      s, from = stop + 1, stop + 1
    end
  end
  local rest = vim.trim(text:sub(s))
  if rest ~= '' then out[#out + 1] = rest end
  return out
end

-- Share of the text inside quotation marks (curly, straight, guillemets).
local function quote_share(text)
  if #text == 0 then return 0 end
  local q = 0
  for m in text:gmatch '\226\128\156.-\226\128\157' do q = q + #m end
  for m in text:gmatch '"[^"]-"' do q = q + #m end
  for m in text:gmatch '\194\171.-\194\187' do q = q + #m end
  return math.min(1, q / #text)
end

-- Files to outline: the current buffer, or the manuscript's included sections.
local function sources(manuscript)
  if not manuscript then
    local path = vim.api.nvim_buf_get_name(0)
    if path == '' then return nil end
    return { { path = path, lines = vim.api.nvim_buf_get_lines(0, 0, -1, false) } }
  end
  local binder = require 'config.binder'
  local sp = binder.require_sections()
  if not sp then return nil end
  local out = {}
  for _, s in ipairs(binder.collect_sections_ordered(sp)) do
    if not s.orphan then out[#out + 1] = { path = s.path, lines = binder.file_lines(s.path) } end
  end
  return out
end

function M.open(opts)
  opts = opts or {}
  local files = sources(opts.manuscript)
  if not files or #files == 0 then
    vim.notify('[outline] nothing to outline', vim.log.levels.WARN)
    return
  end

  -- Pre-compute every paragraph once; render() only lays them out.
  local items = {}
  for _, f in ipairs(files) do
    if opts.manuscript then
      items[#items + 1] = { kind = 'file', path = f.path, lnum = 1, text = vim.fn.fnamemodify(f.path, ':t') }
    end
    local n = 0
    for _, b in ipairs(blocks(f.lines)) do
      if b.kind == 'heading' then
        items[#items + 1] = { kind = 'heading', path = f.path, lnum = b.lnum, text = b.text }
      else
        local text = clean(b.text)
        if text ~= '' then
          n = n + 1
          local sents = sentences(text)
          local words = 0
          for _ in text:gmatch '%S+' do words = words + 1 end
          items[#items + 1] = {
            kind = 'para', path = f.path, lnum = b.lnum, n = n, words = words,
            quote = b.blockquote and 1 or quote_share(text),
            first = sents[1] or text, last = #sents > 1 and sents[#sents] or nil,
          }
        end
      end
    end
  end

  local show_last = false
  local PREFIX = 18 -- '  nnn  nnnnw  qnnn%  '
  local buf = vim.api.nvim_create_buf(false, true)
  local rowmap = {}

  local function render()
    local lines, hls = {}, {}
    rowmap = {}
    for _, it in ipairs(items) do
      if it.kind == 'file' then
        if #lines > 0 then lines[#lines + 1] = '' end
        lines[#lines + 1] = '── ' .. it.text .. ' ' .. string.rep('─', math.max(3, 60 - #it.text))
        hls[#hls + 1] = { #lines, 0, -1, 'Special' }
      elseif it.kind == 'heading' then
        lines[#lines + 1] = '  ' .. it.text
        hls[#hls + 1] = { #lines, 0, -1, 'Title' }
      else
        local q = it.quote >= 0.1 and string.format('q%3d%%', math.floor(it.quote * 100 + 0.5)) or '     '
        local meta = string.format('  %3d  %4dw  %s', it.n, it.words, q)
        lines[#lines + 1] = meta .. '  ' .. it.first
        hls[#hls + 1] = { #lines, 0, #meta, it.quote >= 0.5 and 'WarningMsg' or 'Comment' }
        if show_last and it.last then
          rowmap[#lines] = it
          lines[#lines + 1] = string.rep(' ', PREFIX + 3) .. '… ' .. it.last
          hls[#hls + 1] = { #lines, 0, -1, 'Comment' }
        end
      end
      rowmap[#lines] = it
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      local len = #lines[h[1]]
      vim.api.nvim_buf_set_extmark(buf, ns, h[1] - 1, h[2], {
        end_col = h[3] < 0 and len or math.min(h[3], len), hl_group = h[4],
      })
    end
    return #lines
  end

  local nlines = render()
  local paras = 0
  for _, it in ipairs(items) do if it.kind == 'para' then paras = paras + 1 end end
  local title = opts.manuscript and 'Reverse Outline — manuscript'
    or 'Reverse Outline — ' .. vim.fn.fnamemodify(files[1].path, ':t')
  local w = math.floor(vim.o.columns * 0.85)
  local h = math.min(math.max(nlines, 3) + 2, math.floor(vim.o.lines * 0.85))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', style = 'minimal', border = require('misc.style').border,
    row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    width = w, height = h,
    title = ' ' .. title .. string.format(' (%d paragraphs) ', paras), title_pos = 'center',
    footer = ' ↵ jump   l last sentences   q close ', footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].breakindentopt = 'shift:' .. (PREFIX + 3)
  vim.wo[win].showbreak = 'NONE'
  vim.wo[win].cursorline = true

  vim.keymap.set('n', '<CR>', function()
    local it = rowmap[vim.api.nvim_win_get_cursor(win)[1]]
    if not it then return end
    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_buf_get_name(0) ~= it.path then
      vim.cmd('edit ' .. vim.fn.fnameescape(it.path))
    end
    vim.api.nvim_win_set_cursor(0, { it.lnum, 0 })
    vim.cmd 'normal! zvzz'
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'l', function()
    local it = rowmap[vim.api.nvim_win_get_cursor(win)[1]]
    show_last = not show_last
    render()
    local best
    for row, r in pairs(rowmap) do
      if r == it and (not best or row < best) then best = row end
    end
    if best then vim.api.nvim_win_set_cursor(win, { best, 0 }) end
  end, { buffer = buf, silent = true })
  require('config.binder').close_keys(buf, win)
end

-- Exposed for tests.
M._blocks, M._clean, M._sentences, M._quote_share = blocks, clean, sentences, quote_share

return M
