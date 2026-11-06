-- Citations in Quarto manuscripts: which .bib files a buffer uses, adding an
-- entry to them (<leader>fz), @ completion, and a warning on any citation
-- Pandoc wouldn't find.
--
-- Paths resolve the way Quarto does, from the file that declares them, so
-- none of this depends on Neovim's working directory: the document's metadata
-- block, then _metadata.yml from its directory up to the project root, then
-- _quarto.yml. What counts as a citation follows Pandoc's parser, tested
-- against `quarto pandoc --citeproc`: keys are case-sensitive, and `x@key` and
-- `a.@key` are plain text. Where it's unsure it stays quiet, since Pandoc's
-- own warnings still catch whatever this misses at render time.

local M = {}

local zotero = require 'config.zotero'
local ns = vim.api.nvim_create_namespace 'citations'

-- Quarto's cross-reference prefixes: @fig-map is no citation.
local crossref_prefixes = {}
for _, p in ipairs { 'fig', 'tbl', 'sec', 'eq', 'lst', 'thm', 'lem', 'cor', 'prp', 'cnj', 'def', 'exm', 'exr', 'sol', 'rem' } do
  crossref_prefixes[p] = true
end

-- A key's characters. Bytes above 127 are UTF-8 letters, except sequences led
-- by C2 or E2 (punctuation: « », the curly quotes in @key’s, dashes).
local key_char = '[%w_\128-\191\195-\225\227-\244]'
local key_start = '^' .. key_char .. '+'
local key_continued = '^[:%.#%$%%&%-%+%?<>~/]' .. key_char .. '+'

-- Where a document's YAML metadata block is: at the top, after any blank lines
-- and the binder/research <!-- --> block.
local function metadata_range(lines)
  local i = 1
  while lines[i] do
    if vim.trim(lines[i]) == '' then
      i = i + 1
    elseif lines[i]:match '^%s*<!%-%-' then
      while lines[i] and not lines[i]:find('-->', 1, true) do
        i = i + 1
      end
      i = i + 1
    elseif lines[i]:match '^%-%-%-%s*$' then
      for j = i + 1, #lines do
        if lines[j]:match '^%-%-%-%s*$' or lines[j]:match '^%.%.%.%s*$' then
          return i, j
        end
      end
      return nil
    else
      return nil
    end
  end
end

local function unquote(s)
  return (vim.trim(s):gsub('^["\'](.*)["\']$', '%1'))
end

-- The paths of a top-level `bibliography:` field (scalar, [a, b] or a block
-- list), or nil. Top-level only, so `# bibliography: x` is not one.
local function declared_paths(lines, first, last)
  for i = first, last do
    local value = lines[i]:match '^bibliography:%s*(.-)%s*$'
    if value then
      value = value:gsub('%s+#.*$', '')
      local paths = {}
      if value == '' then
        local j = i + 1
        while j <= last and lines[j]:match '^%s*%-%s+' do
          table.insert(paths, unquote(lines[j]:match '^%s*%-%s+(.-)%s*$'))
          j = j + 1
        end
      elseif value:match '^%[' then
        for item in value:sub(2, -2):gmatch '[^,]+' do
          table.insert(paths, unquote(item))
        end
      else
        paths[1] = unquote(value)
      end
      return paths
    end
  end
end

local function declared_in_file(file)
  if vim.fn.filereadable(file) == 0 then
    return nil
  end
  local lines = vim.fn.readfile(file)
  return declared_paths(lines, 1, #lines)
end

local function absolute(dir, paths)
  return vim.tbl_map(function(p)
    return vim.fs.normalize(p:match '^[/~]' and p or vim.fs.joinpath(dir, p))
  end, paths)
end

-- The buffer's directory, or the working directory if it has no file yet.
local function buffer_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= '' and vim.fs.dirname(name) or vim.uv.cwd()
end

--- Absolute paths of the bibliographies `buf` declares or inherits; may be empty.
function M.bibliographies(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local dir = buffer_dir(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, last = metadata_range(lines)
  local paths = first and declared_paths(lines, first, last)
  if paths then
    return absolute(dir, paths)
  end
  local root = vim.fs.root(dir, '_quarto.yml')
  if not root then
    return {}
  end
  local current = dir
  while true do
    paths = declared_in_file(vim.fs.joinpath(current, '_metadata.yml'))
    if paths then
      return absolute(current, paths)
    end
    if current == root or vim.fs.dirname(current) == current then
      break
    end
    current = vim.fs.dirname(current)
  end
  return absolute(root, declared_in_file(vim.fs.joinpath(root, '_quarto.yml')) or {})
end

-- Results that only change with the file, so large .bib files parse only once.
local function cached(cache, path, parse)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local stamp = ('%d.%d.%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
  if not cache[path] or cache[path].stamp ~= stamp then
    cache[path] = { stamp = stamp, value = parse() }
  end
  return cache[path].value
end

local not_entries = { comment = true, string = true, preamble = true }
local key_cache = {}

-- The set of keys in a BibTeX file; nil if it is missing, or not BibTeX (CSL
-- JSON/YAML), so unknowable. Read by line, not zotero.parse_entries' balanced
-- braces: one unbalanced entry there would hide every key after it.
local function keys_in(path)
  if not path:match '%.bib$' then
    return nil
  end
  return cached(key_cache, path, function()
    local keys = {}
    for _, line in ipairs(vim.fn.readfile(path)) do
      local kind, key = line:match '^%s*@(%w+)%s*[{(]%s*([^,%s]+)'
      if kind and not not_entries[kind:lower()] then
        keys[key] = true
      end
    end
    return keys
  end)
end

local function blank(s)
  return (' '):rep(#s)
end

-- Blanks inline code spans: a run of backticks up to the next run of the same length.
local function mask_code_spans(line)
  local pos = 1
  while true do
    local s, e = line:find('`+', pos)
    if not s then
      return line
    end
    local run, closed = e - s + 1, nil
    local search = e + 1
    while true do
      local cs, ce = line:find('`+', search)
      if not cs then
        break
      end
      if ce - cs + 1 == run then
        closed = ce
        break
      end
      search = ce + 1
    end
    if closed then
      line = line:sub(1, s - 1) .. blank(line:sub(s, closed)) .. line:sub(closed + 1)
      pos = closed + 1
    else
      pos = e + 1
    end
  end
end

-- `lines` with everything Pandoc wouldn't read as a citation blanked, byte
-- for byte so columns still line up: metadata, code, comments, shortcodes,
-- URLs, link targets, example-list labels.
local function masked(lines)
  local out = {}
  local first, last = metadata_range(lines)
  local fence, in_comment
  for i, line in ipairs(lines) do
    if first and i >= first and i <= last then
      line = ''
    elseif fence then
      local closing = line:match '^%s*(`+)%s*$' or line:match '^%s*(~+)%s*$'
      if closing and closing:sub(1, 1) == fence:sub(1, 1) and #closing >= #fence then
        fence = nil
      end
      line = ''
    else
      local rest_start = 1
      -- Tested before comments are blanked, which would look like indentation.
      local indented = line:match '^    ' or line:match '^\t'
      if in_comment then
        local _, e = line:find('-->', 1, true)
        if e then
          line = blank(line:sub(1, e)) .. line:sub(e + 1)
          in_comment = false
          rest_start = e + 1
        else
          line = ''
        end
      end
      if not in_comment then
        local opening = line:match '^%s*(```+)' or line:match '^%s*(~~~+)'
        if opening then
          fence = opening
          line = ''
        else
          while true do
            local s = line:find('<!--', rest_start, true)
            if not s then
              break
            end
            local _, e = line:find('-->', s + 4, true)
            if not e then
              line = line:sub(1, s - 1)
              in_comment = true
              break
            end
            line = line:sub(1, s - 1) .. blank(line:sub(s, e)) .. line:sub(e + 1)
          end
          if indented then
            line = '' -- an indented code block, or near enough
          end
          line = mask_code_spans(line)
          line = line:gsub('{{<.->}}', blank)
          line = line:gsub('%a[%w+.-]*://%S+', blank)
          line = line:gsub('%]%b()', blank)
          line = line:gsub('^(%s*)(%(@[%w_-]*%))', function(space, label)
            return space .. blank(label)
          end)
        end
      end
    end
    out[i] = line
  end
  return out
end

-- What may directly precede a citation's @: Pandoc reads `x@key` and `a.@key`
-- as plain text, and `\@` is an escape. Bytes above 127 end a curly quote or dash.
local function may_precede(c)
  return c:match '[%s%[%(%*_"\'%-;~%^/]' ~= nil or c:byte() > 127
end

local function read_key(line, start)
  local _, stop = line:find(key_start, start)
  if not stop then
    return nil
  end
  while true do
    local _, more = line:find(key_continued, stop + 1)
    if not more then
      return line:sub(start, stop), stop
    end
    stop = more
  end
end

--- Every citation in `lines`, as { key, lnum, col, end_col } (0-based, end
--- exclusive; the span includes the @). Cross-references are left out.
function M.find_citations(lines)
  local found = {}
  for i, line in ipairs(masked(lines)) do
    local pos = 1
    while true do
      local at = line:find('@', pos, true)
      if not at then
        break
      end
      pos = at + 1
      if at == 1 or may_precede(line:sub(at - 1, at - 1)) then
        local key, stop = line:match('^{([^}]+)}', at + 1), nil
        if key then
          stop = at + #key + 2
        else
          key, stop = read_key(line, at + 1)
        end
        if key then
          pos = stop + 1
          if not crossref_prefixes[key:match '^(%l+)%-' or ''] then
            table.insert(found, { key = key, lnum = i - 1, col = at - 1, end_col = stop })
          end
        end
      end
    end
  end
  return found
end

-- The first bibliography that can take a new BibTeX entry, or if `buf` declares
-- none, references.bib at the project root (else beside the file).
local function bib_to_append_to(buf)
  local paths = M.bibliographies(buf)
  if #paths == 0 then
    local dir = buffer_dir(buf)
    return vim.fs.joinpath(vim.fs.root(dir, '_quarto.yml') or dir, 'references.bib')
  end
  for _, path in ipairs(paths) do
    if path:match '%.bib$' then
      return path
    end
  end
end

--- Add `item` (a config.zotero entry: `key` and `raw`) to `buf`'s bibliography
--- unless one of its bibliographies already has the key.
function M.add_to_bibliography(buf, item)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  for _, path in ipairs(M.bibliographies(buf)) do
    local keys = keys_in(path)
    if keys and keys[item.key] then
      return
    end
  end
  local target = bib_to_append_to(buf)
  if not target then
    vim.notify('[citations] no .bib among this document\'s bibliographies', vim.log.levels.WARN)
    return
  end
  if vim.fn.filereadable(target) == 0 then
    if vim.fn.confirm("Bibliography file missing. Create '" .. target .. "'?", '&Yes\n&No', 1) ~= 1 then
      return
    end
    vim.fn.writefile({}, target)
  end
  local existing = vim.fn.readblob(target)
  local file = io.open(target, 'a')
  if not file then
    vim.notify('[citations] could not open ' .. target .. ' for appending', vim.log.levels.ERROR)
    return
  end
  -- A last line with no newline would run into the new entry's @.
  file:write((existing ~= '' and existing:sub(-1) ~= '\n') and '\n' or '', item.raw)
  file:close()
  vim.notify('[citations] wrote ' .. item.key .. ' to ' .. target, vim.log.levels.INFO)
  M.check(buf)
end

--- Warn on citations missing from the buffer's bibliographies. Says nothing
--- when it can't tell: no bibliography, one it can't read, or inline `references:`.
function M.check(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].filetype ~= 'quarto' or vim.bo[buf].buftype ~= '' then
    return
  end
  vim.diagnostic.reset(ns, buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, last = metadata_range(lines)
  for i = first or 1, first and last or 0 do
    if lines[i]:match '^references:' then
      return
    end
  end
  local paths = M.bibliographies(buf)
  if #paths == 0 then
    return
  end
  local known, names = {}, {}
  for _, path in ipairs(paths) do
    local keys = keys_in(path)
    if not keys then
      return
    end
    table.insert(known, keys)
    table.insert(names, vim.fs.basename(path))
  end
  local library = keys_in(zotero.bib_path) or {}
  local diags = {}
  for _, c in ipairs(M.find_citations(lines)) do
    local defined = vim.iter(known):any(function(keys)
      return keys[c.key]
    end)
    if not defined then
      table.insert(diags, {
        lnum = c.lnum,
        col = c.col,
        end_col = c.end_col,
        severity = vim.diagnostic.severity.WARN,
        source = 'citation',
        code = 'UNDEFINED',
        message = ('@%s is not in %s%s'):format(c.key, table.concat(names, ', '), library[c.key] and ' (it is in your Zotero library)' or ' or your Zotero library'),
        user_data = { key = c.key, in_library = library[c.key] },
      })
    end
  end
  vim.diagnostic.set(ns, buf, diags)
end

--- Actions for the undefined citation under the cursor, as { label, fn } items
--- for the <leader>la picker: copy its entry over from the Zotero library.
function M.code_actions(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  for _, d in ipairs(vim.diagnostic.get(buf, { namespace = ns, lnum = row - 1 })) do
    if d.user_data.in_library and d.col <= col and col < d.end_col then
      local key = d.user_data.key
      return {
        {
          label = '⟨citation⟩ Add @' .. key .. ' to the bibliography from Zotero',
          fn = function()
            for _, entry in ipairs(zotero.parse_entries() or {}) do
              if entry.key == key then
                M.add_to_bibliography(buf, entry)
                return
              end
            end
            vim.notify('[citations] ' .. key .. ' not found in the Zotero library', vim.log.levels.WARN)
          end,
        },
      }
    end
  end
  return {}
end

local entry_cache = {}

-- Completion items for a .bib file.
local function bib_items(path)
  return cached(entry_cache, path, function()
    local kind = require('cmp').lsp
    return vim.tbl_map(function(e)
      return {
        label = '@' .. e.key,
        kind = kind.CompletionItemKind.Reference,
        documentation = {
          kind = kind.MarkupKind.Markdown,
          value = ('**%s**\n\n*%s*\n%s'):format(e.title, e.author, e.year),
        },
      }
    end, zotero.parse_entries(path) or {})
  end) or {}
end

--- nvim-cmp source: citation keys from the buffer's bibliographies, plus
--- cross-reference labels defined in the buffer.
function M.cmp_source()
  local source = {}

  function source:is_available()
    return vim.tbl_contains({ 'pandoc', 'markdown', 'rmd', 'quarto' }, vim.bo.filetype)
  end

  function source:get_keyword_pattern()
    return '[@][^[:blank:]]*'
  end

  function source:complete(_, callback)
    local buf = vim.api.nvim_get_current_buf()
    local items = {}
    for _, path in ipairs(M.bibliographies(buf)) do
      vim.list_extend(items, bib_items(path))
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    local kind = require('cmp').lsp.CompletionItemKind.Reference
    for _, pattern in ipairs { '{#(%a+[:%-][%w_-]+)', '#| label: (%a+[:%-][%w_-]+)' } do
      for label in text:gmatch(pattern) do
        table.insert(items, { label = '@' .. label, kind = kind })
      end
    end
    callback(items)
  end

  return source
end

function M.setup()
  local group = vim.api.nvim_create_augroup('citations', { clear = true })
  local function attach(buf)
    if vim.bo[buf].filetype ~= 'quarto' then
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
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.check(buf)
      end
    end)
  end
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'quarto',
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
