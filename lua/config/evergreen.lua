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
--- actually resolvable (by Obsidian and by our own reverse lookup below).
--- Always the raw id, never an alias: obsidian.nvim's built-in
--- `:Obsidian backlinks` (`Note.get_reference_paths`) only searches for a
--- note's filename/id, not its aliases, so an alias-based link is invisible
--- to it even though it still resolves fine on follow and still matches our
--- own `collect_child_notes` search below (which searches for whatever this
--- function returns). Deliberately does NOT use a bare `title:` field —
--- `Note.reference_ids()` doesn't recognize that as a valid reference, only
--- id/aliases/filename do.
local function link_key(note)
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

local new_chapter_choice = '+ New chapter...'

--- Distinct `chapter:` values already used among `source_note`'s child
--- notes, in the same page-sorted order `collect_child_notes` produces (so
--- the picker roughly follows the book's own structure).
local function existing_chapters(source_note, root)
  local seen, list = {}, {}
  for _, note in ipairs(collect_child_notes(source_note, root)) do
    local chapter = note:get_field 'chapter'
    if chapter and chapter ~= '' and not seen[chapter] then
      seen[chapter] = true
      table.insert(list, chapter)
    end
  end
  return list
end

--- Resolve a chapter label via `callback(chapter)`: offers a picker of
--- chapters already used for `source_note` (plus a "new chapter" entry that
--- falls back to free text), or goes straight to free text if none exist yet.
local function prompt_chapter(source_note, root, callback)
  local chapters = root and existing_chapters(source_note, root) or {}
  if #chapters == 0 then
    vim.ui.input({ prompt = 'Chapter: ' }, function(chapter) callback(chapter and vim.trim(chapter) or '') end)
    return
  end
  vim.ui.select(vim.list_extend({ new_chapter_choice }, chapters), { prompt = 'Chapter: ' }, function(choice)
    if not choice or choice == '' then
      callback ''
    elseif choice == new_chapter_choice then
      vim.ui.input({ prompt = 'Chapter: ' }, function(chapter) callback(chapter and vim.trim(chapter) or '') end)
    else
      callback(choice)
    end
  end)
end

--- Prompt for a title, chapter label, and page locator, create a new child
--- note via `:Obsidian new`, and pre-link it to the current source note.
function M.new_child_note()
  local source_note = resolve_source_note()
  if not source_note then
    return
  end
  local root = M.vault_root(vim.fs.dirname(tostring(source_note.path)))
  vim.ui.input({ prompt = 'Note title: ' }, function(title)
    if not title or vim.trim(title) == '' then
      return
    end
    title = vim.trim(title)
    prompt_chapter(source_note, root, function(chapter)
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

--- Populate `bufnr`'s frontmatter as a new source note: either pick a Zotero
--- entry (title/author/year/citekey filled in, file renamed to match) or
--- enter a source type by hand. `default_title` seeds the manual path so a
--- title already typed at note-creation time isn't asked for twice.
function M.fill_source_note(bufnr, default_title)
  vim.ui.select({ 'Pick from Zotero library', 'Enter manually' }, { prompt = 'Source note: ' }, function(choice)
    if not choice then
      return
    end
    if choice == 'Pick from Zotero library' then
      require('config.zotero').pick {
        prompt_title = 'Zotero library — new source note',
        on_select = function(entry)
          insert_frontmatter_fields(bufnr, {
            { key = 'type', value = 'source' },
            { key = 'title', value = entry.title },
            { key = 'author', value = entry.author },
            { key = 'year', value = entry.year },
            { key = 'citekey', value = entry.key },
            { key = 'status', value = 'reading' },
          })
          -- Rename the file to match the Zotero title, now that we have one.
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.api.nvim_buf_call(bufnr, function() M.rename_to_title_slug() end)
            end
          end)
        end,
      }
      return
    end

    local function finish(title)
      title = title and vim.trim(title) or ''
      if title == '' then
        return
      end
      vim.ui.select(source_types, { prompt = 'Source type: ' }, function(source_type)
        local fields = { { key = 'type', value = 'source' }, { key = 'title', value = title } }
        if source_type then
          table.insert(fields, { key = 'source_type', value = source_type })
        end
        table.insert(fields, { key = 'status', value = 'reading' })
        insert_frontmatter_fields(bufnr, fields)
      end)
    end

    if default_title and default_title ~= '' then
      finish(default_title)
    else
      vim.ui.input({ prompt = 'Source title: ' }, finish)
    end
  end)
end

--- Prompt for a title, create a new source note via `:Obsidian new`, and
--- fill it in via `fill_source_note`.
function M.new_source_note()
  vim.ui.input({ prompt = 'Source title: ' }, function(title)
    if not title or vim.trim(title) == '' then
      return
    end
    title = vim.trim(title)
    M.suppress_next_auto_prompt()
    vim.cmd('Obsidian new ' .. vim.fn.fnameescape(title))
    M.fill_source_note(vim.api.nvim_get_current_buf(), title)
  end)
end

--- Resolve `origin_bufnr`'s source note and prompt for chapter/page, then
--- write `type`/`source`/`chapter`/`page` frontmatter into `bufnr`.
function M.fill_child_note(bufnr, origin_bufnr)
  if not origin_bufnr or not vim.api.nvim_buf_is_valid(origin_bufnr) then
    vim.notify('evergreen: no origin note to resolve a source from', vim.log.levels.WARN)
    return
  end
  local source_note = resolve_source_note(origin_bufnr)
  if not source_note then
    return
  end
  local root = M.vault_root(vim.fs.dirname(tostring(source_note.path)))
  prompt_chapter(source_note, root, function(chapter)
    vim.ui.input({ prompt = 'Page: ' }, function(page)
      page = page and vim.trim(page) or ''
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
end

--- Prompt for a title, create a new child note via `:Obsidian new` linked
--- to the current buffer's source, and fill it in via `fill_child_note`.
function M.new_child_note()
  local source_note = resolve_source_note()
  if not source_note then
    return
  end
  local origin_bufnr = vim.api.nvim_get_current_buf()
  vim.ui.input({ prompt = 'Note title: ' }, function(title)
    if not title or vim.trim(title) == '' then
      return
    end
    M.suppress_next_auto_prompt()
    vim.cmd('Obsidian new ' .. vim.fn.fnameescape(vim.trim(title)))
    M.fill_child_note(vim.api.nvim_get_current_buf(), origin_bufnr)
  end)
end

-- --- Auto-detect capture on [[link]]-triggered note creation --------------
--
-- Every note creation (`[[link]]` "create new note?", `:Obsidian new`,
-- templates, unique notes) funnels through obsidian.nvim's `Note.create`,
-- which fires a `User ObsidianNoteCreate` autocmd synchronously, before the
-- note is written to disk. That's too early to run an async `vim.ui.select`
-- (the write happens right after, in the same call), so instead: stash the
-- origin buffer + typed title there, then act on the *next* `ObsidianNoteEnter`
-- for that same path (fired once the new note's buffer becomes current) --
-- offering a type picker and filling in frontmatter the same way the manual
-- `<leader>nnc`/`<leader>nns` commands do.

--- path -> { origin_bufnr, title }, consumed once by the matching
--- ObsidianNoteEnter.
local pending_creates = {}

--- Set right before `new_child_note`/`new_source_note` call `:Obsidian new`
--- themselves, so the auto-detect prompt doesn't also fire for a note
--- they're already filling in by hand.
local suppress_next = false
function M.suppress_next_auto_prompt()
  suppress_next = true
end

local new_note_type_choices = { 'Child note (linked to source)', 'Source note', 'Normal note' }

function M.prompt_new_note_type(bufnr, origin_bufnr, default_title)
  vim.ui.select(new_note_type_choices, { prompt = 'New note type: ' }, function(choice)
    if not choice or choice == 'Normal note' then
      return
    elseif choice == new_note_type_choices[1] then
      M.fill_child_note(bufnr, origin_bufnr)
    else
      M.fill_source_note(bufnr, default_title)
    end
  end)
end

--- Register the ObsidianNoteCreate/BufEnter autocmd pair that drives the
--- auto-detect prompt. Call once from the obsidian.nvim plugin spec's
--- `config` function.
---
--- Deliberately uses native `BufEnter`, not obsidian.nvim's own
--- `ObsidianNoteEnter` proxy event: that proxy is wired up by a `FileType`
--- autocmd that registers a buffer-scoped `BufEnter` handler, and for a
--- brand-new buffer `FileType` can fire as part of the very same `BufEnter`
--- that's supposed to trigger it, i.e. too late to still catch it — the
--- proxy silently misses the first entry into a freshly created note.
--- Native `BufEnter` has no such race.
function M.setup()
  vim.api.nvim_create_autocmd('User', {
    pattern = 'ObsidianNoteCreate',
    callback = function(ev)
      if suppress_next then
        suppress_next = false
        return
      end
      local data = ev.data
      if not data or not data.note or not data.note.id then
        return
      end
      -- Only plain, user-typed creations (skip daily/unique/etc. scopes).
      local scope = data.opts and data.opts.scope or 'plain'
      if scope ~= 'plain' then
        return
      end
      -- Keyed by `id` (the filename stem), not path: `data.note.path` here
      -- is a plain table reconstructed by nvim_exec_autocmds's Object
      -- marshaling, which drops the `Path` metatable/__tostring — plain
      -- string fields like `id` survive that marshaling intact.
      pending_creates[data.note.id] = {
        origin_bufnr = vim.api.nvim_get_current_buf(),
        title = data.note.title or data.note.id,
      }
    end,
  })

  vim.api.nvim_create_autocmd('BufEnter', {
    pattern = '*.md',
    callback = function(ev)
      local id = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ':t:r')
      local pending = pending_creates[id]
      if not pending then
        return
      end
      pending_creates[id] = nil
      if frontmatter_field(ev.buf, 'type') then
        return -- a template already stamped a type; don't second-guess it
      end
      M.prompt_new_note_type(ev.buf, pending.origin_bufnr, pending.title)
    end,
  })

  -- Typing `[[Title` and accepting the completion menu's "(create)" entry
  -- is a *different* creation path than the follow_link "Create new note?"
  -- confirm dialog: it never opens the new note's buffer at all (it just
  -- writes the file via the `obsidian.write_note` LSP command and inserts
  -- the link text where you were typing), so the BufEnter hook above never
  -- sees it. Wrap `actions.write_note` to open the note right after writing
  -- it — matching the "create it, then go write in it" workflow — which
  -- also lets BufEnter fire as normal from there.
  --
  -- Must happen before obsidian.nvim's LSP client first initializes:
  -- `lsp/handlers/initialize.lua` snapshots every `actions.*` function into
  -- a `vim.lsp.commands` closure once, on first attach, so patching
  -- `actions.write_note` any later would be invisible to that path (the
  -- `workspace/executeCommand` fallback path re-`require`s the module on
  -- every call, so it isn't affected either way).
  local actions = require 'obsidian.actions'
  local orig_write_note = actions.write_note
  actions.write_note = function(note)
    orig_write_note(note)
    local id = note and note.id
    if id and pending_creates[id] then
      local path = tostring(note.path)
      vim.schedule(function() vim.cmd('edit ' .. vim.fn.fnameescape(path)) end)
    end
  end
end

return M
