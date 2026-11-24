-- libsearch.lua: <leader>rl / <leader>rL — search the indexed Zotero library
-- by meaning (the dotfiles repo's `zot -s --json`), for a question you type
-- or the visual selection, and pick a passage in Telescope:
--   <CR>   insert [@citekey, p. 66] at the cursor (after the selection), and
--          add the work's BibTeX entry to the document's bibliography
--          (config.citations, from the Better BibTeX export, as <leader>fz)
--   <C-o>  open the book in zot's reader at the passage, every hit in it
--          highlighted (n/N between them), in a floating terminal; q there
--          comes back to the picker, on the same passage, to read through several
--   <C-y>  yank the passage, quoted, with its citation
--   <Tab>  mark several passages: <CR> then cites them all as one citation,
--          [@a, pp. 3, 40; @b, p. 12] (a book's pages merged), and <C-y>
--          yanks each, quoted with its own citation
-- <leader>rL asks for a Zotero collection first (its subcollections too).
--
-- `zot` is a bash function, so it runs as `bash -c 'source zot.sh && zot ...'`
-- (Neovim's shells never read ~/.bashrc). The search runs in the background:
-- the question goes through Ollama (qwen3-embedding:8b), a few seconds, more
-- the first time while the model loads. Only books indexed on this machine are
-- searched (zot --embed; the index syncs through Zotero). The JSON's keys and
-- `zot --open`'s options are a contract with ~/dotfiles (its CLAUDE.md).

local M = {}

local zot_sh = vim.fn.expand '~/dotfiles/zot/zot.sh'

--- The visual selection on one line, or nil outside visual mode.
local function selection()
  local mode = vim.fn.mode()
  if not mode:match '[vV\22]' then
    return nil
  end
  local lines = vim.fn.getregion(vim.fn.getpos 'v', vim.fn.getpos '.', { type = mode })
  vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
  return vim.trim(table.concat(lines, ' '))
end

--- One picker entry per hit, best book first and each book's hits in its
--- order: { book = <book>, hit = <hit> }.
function M.entries(result)
  local out = {}
  for _, book in ipairs(result.books or {}) do
    for _, hit in ipairs(book.hits or {}) do
      table.insert(out, { book = book, hit = hit })
    end
  end
  return out
end

--- The Pandoc citation for a hit, or nil and why not. A page only when the
--- printed number is known: zot's "PDF p. 230" is the file's page, not one
--- to cite, so that gives a bare [@key].
function M.citation(book, hit)
  if not book.citekey or book.citekey == vim.NIL or book.citekey == '' then
    return nil, "no citekey for this item (Better BibTeX hasn't given it one)"
  end
  local page = hit.cite and hit.cite:match '^p%. (.+)$'
  if page then
    return ('[@%s, p. %s]'):format(book.citekey, page), nil
  end
  return ('[@%s]'):format(book.citekey), hit.cite and (hit.cite .. ': the printed page is unknown, so no page') or nil
end

--- One Pandoc citation for several picks ({ book, hit }, in the order
--- picked): one cite per work, in order of its first pick, its printed pages
--- merged ("p. 3", "pp. 3, 40"; numbers sorted, repeats dropped). A work
--- with no printed page among its picks is cited bare. Returns the citation
--- (nil when no pick has a citekey), the citekeys in it, and notes on what
--- was dropped.
function M.citations(picks)
  local order, pages, notes = {}, {}, {}
  for _, p in ipairs(picks) do
    local key = p.book.citekey
    if not key or key == vim.NIL or key == '' then
      table.insert(notes, ('%s: no citekey, left out'):format(p.book.title or '?'))
    else
      if not pages[key] then
        pages[key] = {}
        table.insert(order, key)
      end
      local page = p.hit.cite and p.hit.cite:match '^p%. (.+)$'
      if page then
        if not vim.tbl_contains(pages[key], page) then
          table.insert(pages[key], page)
        end
      elseif p.hit.cite then
        table.insert(notes, ('@%s %s: the printed page is unknown, so no page'):format(key, p.hit.cite))
      end
    end
  end
  if #order == 0 then
    return nil, {}, notes
  end
  local cites = {}
  for _, key in ipairs(order) do
    local ps = pages[key]
    local numeric = vim.iter(ps):all(function(x)
      return tonumber(x) ~= nil
    end)
    if numeric then
      table.sort(ps, function(a, b)
        return tonumber(a) < tonumber(b)
      end)
    end
    if #ps == 0 then
      table.insert(cites, '@' .. key)
    else
      table.insert(cites, ('@%s, %s %s'):format(key, #ps == 1 and 'p.' or 'pp.', table.concat(ps, ', ')))
    end
  end
  return '[' .. table.concat(cites, '; ') .. ']', order, notes
end

--- `zot --open`'s arguments for a hit: its book, at the hit, with all the
--- book's hits highlighted.
function M.open_args(book, hit)
  return {
    '--open',
    book.item_key,
    '--attachment',
    book.attachment_key,
    '--page',
    tostring(hit.unit + 1),
    '--para',
    tostring(hit.para),
    '--hits',
    book.hits_arg,
  }
end

local function surname(book)
  local first = book.authors and book.authors[1]
  if not first or first == vim.NIL then
    return '?'
  end
  return first:match '(%S+)$' or first
end

local function insert(buf, win, cursor, text)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, cursor)
  local line = vim.api.nvim_get_current_line()
  local under = line:sub(cursor[2] + 1, cursor[2] + 1)
  vim.api.nvim_put({ (under ~= '' and not under:match '%s') and (' ' .. text) or text }, 'c', true, true)
end

local function add_to_bibliography(buf, citekey)
  for _, entry in ipairs(require('config.zotero').parse_entries() or {}) do
    if entry.key == citekey then
      require('config.citations').add_to_bibliography(buf, entry)
      return
    end
  end
  vim.notify('[library] ' .. citekey .. " isn't in the Better BibTeX export, so no bibliography entry was added", vim.log.levels.WARN)
end

--- zot's reader at a hit, in a floating terminal; `on_close()`, if given,
--- runs once the reader has quit and its window is gone.
function M.open_reader(book, hit, on_close)
  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.85)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. (book.title or 'zot') .. ' ',
    title_pos = 'center',
  })
  local job = vim.fn.jobstart({ 'bash', '-c', 'source "$0" && zot "$@"', zot_sh, unpack(M.open_args(book, hit)) }, {
    term = true,
    on_exit = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        if on_close then
          on_close()
        end
      end)
    end,
  })
  -- The global TermOpen keymaps (config.autocommands) would take these from
  -- the reader (Esc closes its dialogs, ctrl-j/k move in them).
  for _, key in ipairs { '<Esc>', '<C-h>', '<C-j>', '<C-k>', '<C-l>' } do
    vim.keymap.set('t', key, key, { buffer = buf, nowait = true })
  end
  -- The window is the reader's alone: whenever it has focus, keys go to the
  -- reader, never to Neovim (whose q would start recording a macro). The
  -- picker closing (or a click) can leave it in normal mode, so q there goes
  -- to the reader too, and entering the window returns to terminal mode.
  vim.keymap.set('n', 'q', function()
    vim.fn.chansend(job, 'q')
  end, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, { buffer = buf, command = 'startinsert' })
  vim.cmd.startinsert()
end

local function same_hit(a, b)
  return a.book.attachment_key == b.book.attachment_key and a.hit.unit == b.hit.unit and a.hit.para == b.hit.para
end

--- The picker over a search's hits. `place` ({ entry, prompt }), after the
--- reader, opens it again where it was left: the same filter typed, the same
--- passage selected.
local function pick(result, origin, place)
  local entries = M.entries(result)
  if #entries == 0 then
    vim.notify('[library] nothing found for: ' .. result.question, vim.log.levels.INFO)
    return
  end
  local finders = require 'telescope.finders'
  local pickers = require 'telescope.pickers'
  local previewers = require 'telescope.previewers'
  local conf = require('telescope.config').values
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local entry_display = require 'telescope.pickers.entry_display'

  local displayer = entry_display.create {
    separator = ' ',
    items = { { width = 4 }, { width = 18 }, { width = 11 }, { remaining = true } },
  }

  local function chosen(prompt_bufnr)
    local entry = action_state.get_selected_entry()
    actions.close(prompt_bufnr)
    return entry and entry.value
  end

  -- The passages marked with <Tab>, in the order marked; else the one under
  -- the cursor.
  local function chosen_all(prompt_bufnr)
    local marked = action_state.get_current_picker(prompt_bufnr):get_multi_selection()
    if #marked == 0 then
      local e = chosen(prompt_bufnr)
      return e and { e } or {}
    end
    actions.close(prompt_bufnr)
    return vim.tbl_map(function(entry)
      return entry.value
    end, marked)
  end

  local placed = false
  pickers
    .new({}, {
      default_text = place and place.prompt or nil,
      -- Called after each sort; only the first one puts the selection back,
      -- so typing afterwards moves it as usual.
      on_complete = {
        function(picker)
          if placed or not place then
            return
          end
          placed = true
          local i = 0
          for entry in picker.manager:iter() do
            i = i + 1
            if same_hit(entry.value, place.entry) then
              picker:set_selection(picker:get_row(i))
              return
            end
          end
        end,
      },
      prompt_title = 'Library: ' .. result.question,
      results_title = ('%d passages in %d books  ·  <Tab> mark  <CR> cite  <C-o> read (q back here)  <C-y> yank'):format(#entries, #result.books),
      finder = finders.new_table {
        results = entries,
        entry_maker = function(e)
          local year = (e.book.year ~= vim.NIL and e.book.year) or ''
          return {
            value = e,
            ordinal = table.concat({ surname(e.book), year, e.book.title or '', e.hit.text }, ' '),
            display = function()
              return displayer {
                { ('%.2f'):format(e.hit.score), 'Number' },
                { surname(e.book) .. ' ' .. year, 'Comment' },
                { e.hit.cite, 'SpecialChar' },
                { (e.hit.text:gsub('%s+', ' ')), 'Normal' },
              }
            end,
          }
        end,
      },
      -- Keep zot's order (best book first); typing still filters.
      sorter = conf.generic_sorter {},
      previewer = previewers.new_buffer_previewer {
        title = 'Passage',
        define_preview = function(self, entry)
          local e = entry.value
          local cite = M.citation(e.book, e.hit)
          local lines = {
            '**' .. (e.book.citation ~= vim.NIL and e.book.citation or e.book.title or '?') .. '**',
            '',
            ('%s  ·  %s  ·  score %.2f'):format(cite or '(no citekey)', e.hit.cite, e.hit.score),
            '',
          }
          vim.list_extend(lines, vim.split(e.hit.text, '\n'))
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = 'markdown'
        end,
      },
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local picks = chosen_all(prompt_bufnr)
          if #picks == 0 then
            return
          end
          local cite, keys, notes = M.citations(picks)
          if not cite then
            vim.notify('[library] ' .. table.concat(notes, '\n'), vim.log.levels.WARN)
            return
          end
          insert(origin.buf, origin.win, origin.cursor, cite)
          for _, key in ipairs(keys) do
            add_to_bibliography(origin.buf, key)
          end
          if #notes > 0 then
            vim.notify('[library] ' .. table.concat(notes, '\n'), vim.log.levels.INFO)
          end
        end)
        -- Quitting the reader comes back here, to read through several.
        local function read()
          local prompt = action_state.get_current_line()
          local e = chosen(prompt_bufnr)
          if e then
            -- After Telescope has closed: closing ends insert mode, which
            -- would leave the reader's terminal in normal mode.
            vim.schedule(function()
              M.open_reader(e.book, e.hit, function()
                pick(result, origin, { entry = e, prompt = prompt })
              end)
            end)
          end
        end
        -- Each passage quoted with its own citation, a blank line between.
        local function yank()
          local picks = chosen_all(prompt_bufnr)
          if #picks == 0 then
            return
          end
          local parts = {}
          for _, e in ipairs(picks) do
            local cite = M.citation(e.book, e.hit) or (e.book.citation ~= vim.NIL and e.book.citation) or ''
            table.insert(parts, ('“%s” %s'):format((e.hit.text:gsub('%s+', ' ')), cite))
          end
          local text = table.concat(parts, '\n\n')
          vim.fn.setreg('"', text)
          vim.fn.setreg('+', text)
          vim.notify(('[library] yanked %d passage%s with citations'):format(#picks, #picks == 1 and '' or 's'), vim.log.levels.INFO)
        end
        map({ 'i', 'n' }, '<C-o>', read)
        map({ 'i', 'n' }, '<C-y>', yank)
        return true
      end,
    })
    :find()
end

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

--- A spinner and the seconds so far in the statusline (g:statusline_busy,
--- shown by config.global's statusline) while the search runs, so a slow
--- first search - Ollama loading the model - doesn't look hung. Returns the
--- function that clears it.
local function show_busy(label)
  local started, frame = vim.uv.now(), 0
  local timer = vim.uv.new_timer()
  timer:start(
    0,
    120,
    vim.schedule_wrap(function()
      frame = frame % #SPINNER + 1
      local seconds = math.floor((vim.uv.now() - started) / 1000)
      local note = seconds >= 8 and ' (the first search loads the model)' or ''
      vim.g.statusline_busy = (' %s %s %ds%s '):format(SPINNER[frame], label, seconds, note)
      vim.cmd.redrawstatus()
    end)
  )
  return function()
    timer:stop()
    timer:close()
    vim.g.statusline_busy = nil
    vim.cmd.redrawstatus()
  end
end

--- Search the library for `question` (within `collection`, if given) and
--- open the picker when the answer comes back.
function M.search(question, collection)
  if not question or vim.trim(question) == '' then
    return
  end
  if vim.fn.filereadable(zot_sh) == 0 then
    vim.notify('[library] ' .. zot_sh .. ' not found', vim.log.levels.ERROR)
    return
  end
  local origin = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(), cursor = vim.api.nvim_win_get_cursor(0) }
  local args = { '-s', '--json' }
  if collection and collection ~= '' then
    vim.list_extend(args, { '--in', collection })
  end
  table.insert(args, question)
  local done = show_busy('library: searching' .. (collection and collection ~= '' and (' ' .. collection) or '') .. '…')
  vim.system({ 'bash', '-c', 'source "$0" && zot "$@"', zot_sh, unpack(args) }, { text = true }, function(out)
    vim.schedule(function()
      done()
      if out.code ~= 0 then
        local lines = vim.split(vim.trim(out.stderr or ''), '\n')
        local last = (lines[#lines] or ''):gsub('^zot: ', '')
        vim.notify('[library] ' .. (last ~= '' and last or ('zot exited with ' .. out.code)), vim.log.levels.ERROR)
        return
      end
      local ok, result = pcall(vim.json.decode, out.stdout)
      if not ok or type(result) ~= 'table' then
        vim.notify("[library] zot's answer made no sense", vim.log.levels.ERROR)
        return
      end
      pick(result, origin)
    end)
  end)
end

--- <leader>rl: the selection, or a question typed at the prompt.
function M.ask()
  local text = selection()
  if text then
    M.search(text)
    return
  end
  vim.ui.input({ prompt = 'Search the library: ' }, M.search)
end

--- <leader>rL: a collection first, then the selection or a question.
function M.ask_in()
  local text = selection()
  vim.ui.input({ prompt = 'Collection: ' }, function(collection)
    if not collection or collection == '' then
      return
    end
    if text then
      M.search(text, collection)
    else
      vim.ui.input({ prompt = 'Search ' .. collection .. ': ' }, function(q)
        M.search(q, collection)
      end)
    end
  end)
end

return M
