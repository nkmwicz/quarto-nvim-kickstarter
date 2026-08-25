-- Evergreen/source-note workflow for Obsidian vaults: source notes (books,
-- articles, websites) carry `type: source` frontmatter and a summary body.
-- Atomic "child" notes link back via `source: [[Source Title]]` plus an
-- optional `chapter:` label and a `page:` locator. This module resolves that
-- link graph by grepping
-- frontmatter directly (same no-external-database approach as
-- binder.lua/research.lua) rather than a database, and provides:
--   - a read-only "reading view" that stitches a source's child notes into
--     one buffer in page order
--   - capture commands that create a new source note, or a new child note
--     pre-linked to the current source

local M = {}

--- Walk up from `start_dir` for a `.obsidian` directory and return the vault root.
function M.vault_root(start_dir)
  local found = vim.fs.find('.obsidian', { path = start_dir, upward = true, type = 'directory' })[1]
  if not found then
    return nil
  end
  return vim.fs.dirname(found)
end

local roman_values = { i = 1, v = 5, x = 10, l = 50, c = 100, d = 500, m = 1000 }

local function roman_to_int(s)
  local total, prev = 0, 0
  for i = #s, 1, -1 do
    local v = roman_values[s:sub(i, i)]
    if not v then
      return nil
    end
    if v < prev then
      total = total - v
    else
      total = total + v
      prev = v
    end
  end
  return total
end

--- Parse a `page:` locator into a sortable key {kind, value}: kind 0 = roman
--- (front matter, sorts first), 1 = arabic page/range (sorts by start page),
--- 2 = anything else (sorts last).
local function locator_key(raw)
  if not raw or raw == '' then
    return { 2, 0 }
  end
  local s = tostring(raw):gsub('%s+', '')
  local start = s:match '^([^%-]+)' or s
  local num = tonumber(start)
  if num then
    return { 1, num }
  end
  local lower = start:lower()
  if lower:match '^[ivxlcdm]+$' then
    local v = roman_to_int(lower)
    if v then
      return { 0, v }
    end
  end
  return { 2, 0 }
end

--- Extract the link target from a wikilink string like "[[Title]]" or
--- "[[Title|alias]]". Returns nil if `raw` isn't a wikilink.
local function link_target(raw)
  if type(raw) ~= 'string' then
    return nil
  end
  local inner = raw:match '^%[%[(.-)%]%]$'
  if not inner then
    return nil
  end
  return (inner:match '^([^|]+)') or inner
end

local function escape_regex(s)
  return (s:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$|\\])', '\\%1'))
end

local function strip_quotes(s)
  return (s:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1'))
end

--- Read a top-level frontmatter field straight out of a buffer as a list of
--- values, so this works even on unsaved changes (unlike Note.from_file,
--- which reads disk). Handles both the inline scalar form (`key: value`)
--- and the YAML block-list form (`key:` / `  - value`) — obsidian.nvim's
--- own property/tag UI writes properties as block lists, even
--- single-value ones.
local function frontmatter_values(bufnr, key)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 200, false)
  if lines[1] ~= '---' then
    return {}
  end
  for i = 2, #lines do
    if lines[i] == '---' then
      break
    end
    local k, v = lines[i]:match '^(%S+):%s*(.-)%s*$'
    if k == key then
      if v ~= '' then
        return { strip_quotes(v) }
      end
      local values = {}
      local j = i + 1
      while lines[j] and lines[j] ~= '---' and lines[j]:match '^%s*%-%s+' do
        table.insert(values, strip_quotes(lines[j]:match '^%s*%-%s+(.-)%s*$'))
        j = j + 1
      end
      return values
    end
  end
  return {}
end

local function frontmatter_field(bufnr, key)
  return frontmatter_values(bufnr, key)[1]
end

--- Best human-readable label for a note. `note.title` (obsidian.nvim's own
--- field) is nil when a note is loaded via `Note.from_file` — it is not a
--- reliable source of a display name — so resolve it ourselves: prefer an
--- explicit `title:` frontmatter field (what you fill in for citation
--- purposes), then the first alias, then fall back to the raw id/filename.
local function display_title(note)
  local title_field = note:get_field 'title'
  if title_field and title_field ~= '' then
    return title_field
  end
  if note.aliases and note.aliases[1] and note.aliases[1] ~= '' then
    return note.aliases[1]
  end
  return note.id
end

--- The string to embed inside a `[[...]]` link to `note` so the link is
--- actually resolvable (by Obsidian and by our own reverse lookup below):
--- the first alias if there is one (readable, and set automatically from
--- whatever title you typed at note creation), else the raw id. Deliberately
--- does NOT use a bare `title:` field — `Note.reference_ids()` doesn't
--- recognize that as a valid reference, only id/aliases/filename do.
local function link_key(note)
  if note.aliases and note.aliases[1] and note.aliases[1] ~= '' then
    return note.aliases[1]
  end
  return note.id
end

--- Search the vault for a note whose id, alias, or `title:` field matches
--- `target` verbatim. Used when a child note's `source:` link doesn't match
--- any filename directly (e.g. it's an alias, not the raw id).
local function find_note_by_reference(root, target)
  local Note = require 'obsidian.note'
  local escaped = escape_regex(target)
  local cmd = {
    'rg', '--line-number', '--no-heading', '--ignore-case', '--glob', '*.md',
    '-e', '^title:\\s*' .. escaped .. '\\s*$',
    '-e', '^\\s*-\\s*"?' .. escaped .. '"?\\s*$',
    root,
  }
  local ok, lines = pcall(vim.fn.systemlist, cmd)
  if not ok or vim.v.shell_error > 1 then
    return nil
  end
  local seen = {}
  for _, line in ipairs(lines) do
    local file = line:match '^(.-):%d+:'
    if file and not seen[file] then
      seen[file] = true
      local ok_note, note = pcall(Note.from_file, file)
      if ok_note and (vim.tbl_contains(note:reference_ids(), target) or note:get_field 'title' == target) then
        return note
      end
    end
  end
  return nil
end

--- Resolve the source note for `bufnr`: the note itself if it has
--- `type: source`, or the note its `source` field points to otherwise.
local function resolve_source_note(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    vim.notify('evergreen: buffer is not a file', vim.log.levels.WARN)
    return nil
  end
  local Note = require 'obsidian.note'
  if vim.tbl_contains(frontmatter_values(bufnr, 'type'), 'source') then
    return Note.from_file(path)
  end
  local target = link_target(frontmatter_field(bufnr, 'source'))
  if not target then
    vim.notify('evergreen: current note has no `source` link and is not `type: source`', vim.log.levels.WARN)
    return nil
  end
  local root = M.vault_root(vim.fs.dirname(path))
  if not root then
    vim.notify('evergreen: not inside an Obsidian vault', vim.log.levels.WARN)
    return nil
  end
  local found = vim.fs.find(target .. '.md', { path = root, upward = false, type = 'file', limit = 1 })[1]
  if found then
    return Note.from_file(found)
  end
  local note = find_note_by_reference(root, target)
  if not note then
    vim.notify(('evergreen: source note %q not found'):format(target), vim.log.levels.ERROR)
    return nil
  end
  return note
end

--- Find every note in the vault whose `source` field links to `source_note`.
local function collect_child_notes(source_note, root)
  local Note = require 'obsidian.note'
  local id = link_key(source_note)
  local pattern = '^source:.*\\[\\[' .. escape_regex(id)
  local cmd = { 'rg', '--line-number', '--no-heading', '--ignore-case', '--glob', '*.md', pattern, root }
  local ok, lines = pcall(vim.fn.systemlist, cmd)
  if not ok or vim.v.shell_error > 1 then
    vim.notify('evergreen: ripgrep search failed', vim.log.levels.ERROR)
    return {}
  end
  local seen, notes = {}, {}
  for _, line in ipairs(lines) do
    local file = line:match '^(.-):%d+:'
    if file and not seen[file] and file ~= tostring(source_note.path) then
      seen[file] = true
      local ok_note, note = pcall(Note.from_file, file)
      if ok_note then
        table.insert(notes, note)
      end
    end
  end
  table.sort(notes, function(a, b)
    local ka, kb = locator_key(a:get_field 'page'), locator_key(b:get_field 'page')
    if ka[1] ~= kb[1] then
      return ka[1] < kb[1]
    end
    if ka[2] ~= kb[2] then
      return ka[2] < kb[2]
    end
    return display_title(a) < display_title(b)
  end)
  return notes
end

local function note_body_lines(note)
  local all = vim.fn.readfile(tostring(note.path))
  local start = 1
  if note.has_frontmatter and note.frontmatter_end_line then
    start = note.frontmatter_end_line + 1
  end
  while all[start] and vim.trim(all[start]) == '' do
    start = start + 1
  end
  return vim.list_slice(all, start, #all)
end

--- Open a read-only buffer stitching every child note for the current
--- source together in page order.
function M.reading_view()
  local source_note = resolve_source_note()
  if not source_note then
    return
  end
  local root = M.vault_root(vim.fs.dirname(tostring(source_note.path)))
  if not root then
    return
  end
  local notes = collect_child_notes(source_note, root)
  if #notes == 0 then
    vim.notify('evergreen: no child notes found for ' .. display_title(source_note), vim.log.levels.WARN)
    return
  end

  local lines, jump_targets = { '# Reading: ' .. display_title(source_note), '' }, {}
  local last_chapter = false
  for _, note in ipairs(notes) do
    local chapter = note:get_field 'chapter'
    if chapter and chapter ~= '' then
      if chapter ~= last_chapter then
        table.insert(lines, '### ' .. chapter)
        table.insert(lines, '')
        last_chapter = chapter
      end
    else
      last_chapter = false
    end
    local page = note:get_field 'page'
    local label = page and ('p. ' .. page) or '(no page)'
    table.insert(lines, ('## %s — %s'):format(label, display_title(note)))
    jump_targets[#lines] = tostring(note.path)
    table.insert(lines, '')
    for _, l in ipairs(note_body_lines(note)) do
      table.insert(lines, l)
    end
    table.insert(lines, '')
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false

  vim.cmd 'vsplit'
  vim.api.nvim_win_set_buf(0, bufnr)

  vim.keymap.set('n', '<CR>', function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for i = row, 1, -1 do
      if jump_targets[i] then
        vim.cmd.wincmd 'p'
        vim.cmd.edit(vim.fn.fnameescape(jump_targets[i]))
        return
      end
    end
  end, { buffer = bufnr, desc = 'evergreen: open source note under cursor' })
end

local function insert_frontmatter_fields(bufnr, fields)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local insert_at
  if lines[1] == '---' then
    for i = 2, #lines do
      if lines[i] == '---' then
        insert_at = i
        break
      end
    end
  end
  local new_lines = {}
  for _, f in ipairs(fields) do
    table.insert(new_lines, f.key .. ': ' .. f.value)
  end
  if insert_at then
    vim.api.nvim_buf_set_lines(bufnr, insert_at - 1, insert_at - 1, false, new_lines)
  else
    table.insert(new_lines, 1, '---')
    table.insert(new_lines, '---')
    table.insert(new_lines, '')
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, new_lines)
  end
end

--- Prompt for a title, chapter label, and page locator, create a new child
--- note via `:Obsidian new`, and pre-link it to the current source note.
function M.new_child_note()
  local source_note = resolve_source_note()
  if not source_note then
    return
  end
  vim.ui.input({ prompt = 'Note title: ' }, function(title)
    if not title or vim.trim(title) == '' then
      return
    end
    title = vim.trim(title)
    vim.ui.input({ prompt = 'Chapter: ' }, function(chapter)
      chapter = chapter and vim.trim(chapter) or ''
      vim.ui.input({ prompt = 'Page: ' }, function(page)
        page = page and vim.trim(page) or ''
        vim.cmd('Obsidian new ' .. vim.fn.fnameescape(title))
        local bufnr = vim.api.nvim_get_current_buf()
        local fields = {
          { key = 'type', value = 'child' },
          { key = 'source', value = ('[[%s]]'):format(link_key(source_note)) },
        }
        if chapter ~= '' then
          table.insert(fields, { key = 'chapter', value = chapter })
        end
        if page ~= '' then
          table.insert(fields, { key = 'page', value = page })
        end
        insert_frontmatter_fields(bufnr, fields)
      end)
    end)
  end)
end

--- Best string to slug the current note's filename from: `author:` +
--- `title:` (joined; `author:` may be a scalar or a YAML list) if both are
--- present, else `title:` alone, else the first alias.
local function slug_source(bufnr)
  local title = frontmatter_field(bufnr, 'title')
  if title and title ~= '' then
    local authors = frontmatter_values(bufnr, 'author')
    if #authors > 0 then
      return table.concat(authors, ', ') .. ' ' .. title
    end
    return title
  end
  return frontmatter_values(bufnr, 'aliases')[1]
end

--- Rename the current note's file to match the slug of its `author:` +
--- `title:` fields (or `title:` alone, or first alias, as fallbacks) — the
--- same slugging algorithm `note_id_func` uses for new notes
--- (`obsidian.builtin.title_id`). Delegates to `:Obsidian rename` so
--- backlinks across the vault get updated too. Appends `-2`, `-3`, ... if
--- the slug collides with a different existing file.
function M.rename_to_title_slug()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    vim.notify('evergreen: buffer is not a file', vim.log.levels.WARN)
    return
  end
  local title = slug_source(bufnr)
  if not title or title == '' then
    vim.notify('evergreen: note has no `title:` field or alias to slugify from', vim.log.levels.WARN)
    return
  end

  local builtin = require 'obsidian.builtin'
  local dir = vim.fs.dirname(path)
  local current_stem = vim.fn.fnamemodify(path, ':t:r')
  local base = builtin.title_to_slug(title)
  local candidate, idx = base, 2
  while candidate ~= current_stem and vim.fn.filereadable(vim.fs.joinpath(dir, candidate .. '.md')) == 1 do
    candidate = ('%s-%d'):format(base, idx)
    idx = idx + 1
  end

  if candidate == current_stem then
    vim.notify('evergreen: filename already matches title slug', vim.log.levels.INFO)
    return
  end

  vim.cmd('Obsidian rename ' .. candidate)
end

local source_types = { 'book', 'article', 'website', 'video', 'podcast' }

--- Prompt for a title and source type, create a new source note via
--- `:Obsidian new`, and stamp it `type: source`.
function M.new_source_note()
  vim.ui.input({ prompt = 'Source title: ' }, function(title)
    if not title or vim.trim(title) == '' then
      return
    end
    title = vim.trim(title)
    vim.ui.select(source_types, { prompt = 'Source type: ' }, function(source_type)
      vim.cmd('Obsidian new ' .. vim.fn.fnameescape(title))
      local bufnr = vim.api.nvim_get_current_buf()
      local fields = { { key = 'type', value = 'source' }, { key = 'title', value = title } }
      if source_type then
        table.insert(fields, { key = 'source_type', value = source_type })
      end
      table.insert(fields, { key = 'status', value = 'reading' })
      insert_frontmatter_fields(bufnr, fields)
    end)
  end)
end

return M
