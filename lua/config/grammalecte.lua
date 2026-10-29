-- grammalecte.lua: French grammar checking with Grammalecte
-- (apt: python3-grammalecte), shown as diagnostics with source "grammalecte".
-- harper_ls is English-only and ltex is too heavy, so this fills the gap.
--
-- scripts/grammalecte_bridge.py runs as one long-lived job (~70MB), started
-- by the first check, on the prose venv's Python when it exists
-- (scripts/setup_prose_venv.sh) and the system Python otherwise. The job is
-- shared with the be-verb hints (config/beverbs.lua, via M.request). It is sent the whole buffer and finds the French in it
-- itself: `lang: fr` documents, `::: {lang=fr}` divs, `[...]{lang=fr}` spans,
-- and auto-detected French quotations, italic titles and sentences. Code,
-- metadata comments and citations are skipped. See the bridge for the rules
-- switched off.
--
-- Runs in Quarto buffers, markdown under a research/ directory, and Obsidian
-- vault notes: on open, on save, and on <leader>zc.
-- <leader>zf (and <leader>la, alongside LSP actions): apply one of
-- Grammalecte's suggestions for the error under the cursor, or ignore it --
-- on this line / in this file (`<!-- grammalecte:ignore[-file] [RULE...] -->`
-- comments, see the bridge) or in the project (<root>/.grammalecte-ignore,
-- one rule id per line, # comments).

local M = {}

local bridge = vim.fn.stdpath 'config' .. '/scripts/grammalecte_bridge.py'
local ns = vim.api.nvim_create_namespace 'grammalecte'

local job = nil
local failed = false -- set once the bridge can't start; stops retrying
local next_id = 0
local pending = {} -- request id -> callback(response)

-- The venv has apt's grammalecte too (--system-site-packages), plus what
-- the be-verb hints need. vim.g.grammalecte_python overrides both.
local venv_python = vim.fn.stdpath 'data' .. '/prose-venv/bin/python'
function M.python()
  return vim.g.grammalecte_python or (vim.fn.executable(venv_python) == 1 and venv_python) or '/usr/bin/python3'
end

-- The document's declared language: `lang:` in its first metadata block --
-- YAML front matter, or the line-1 <!-- --> block binder/research use (the
-- same first-block rule as binder's parse_meta).
function M.doc_lang(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 40, false)
  local close
  if lines[1] == '---' then
    close = '^%-%-%-'
  elseif lines[1] and lines[1]:match '^<!%-%-' then
    close = '%-%->'
    lines[1] = lines[1]:gsub('^<!%-%-%s*', '')
  else
    return nil
  end
  for i, line in ipairs(lines) do
    local lang = line:match '^lang:%s*["\']?([%w-]+)'
    if lang then
      return lang
    end
    if (i > 1 or close == '%-%->') and line:match(close) then
      return nil
    end
  end
end

-- `lang: fr` documents get Grammalecte for the whole text instead of
-- harper_ls (see its root_dir in plugins/lsp.lua) and French-only spelling.
function M.is_french(buf)
  local lang = M.doc_lang(buf)
  return lang ~= nil and lang:match '^fr' ~= nil
end

-- Applies a change of declared language (on open, and when a save changes
-- it): spelllang, and detaching/re-attaching harper_ls.
local function sync_lang(buf)
  local french = M.is_french(buf)
  local was = vim.b[buf].grammalecte_french
  if was == french then
    return
  end
  vim.b[buf].grammalecte_french = french
  if french then
    vim.bo[buf].spelllang = 'fr'
  elseif was ~= nil then
    vim.bo[buf].spelllang = 'en,fr'
  end
  if was == nil then
    return -- on open, harper's root_dir already decided
  end
  if french then
    for _, client in ipairs(vim.lsp.get_clients { bufnr = buf, name = 'harper_ls' }) do
      vim.lsp.buf_detach_client(buf, client.id)
    end
  else
    -- Re-run vim.lsp.enable's attach logic (its FileType autocmd) for this
    -- buffer; harper's root_dir now lets it through.
    pcall(vim.api.nvim_exec_autocmds, 'FileType', { group = 'nvim.lsp.enable', buffer = buf })
  end
end

local function applies(buf)
  local ft = vim.bo[buf].filetype
  if ft == 'quarto' then
    return true
  end
  if ft ~= 'markdown' then
    return false
  end
  return vim.api.nvim_buf_get_name(buf):find('/research/', 1, true) ~= nil or vim.fs.root(buf, '.obsidian') ~= nil
end

-- Same root markers as the per-project spellfile (ftplugin/quarto.lua), plus
-- the vault root for Obsidian notes.
function M.ignore_file(buf)
  local root = vim.fs.root(buf, { '_quarto.yml', '_quarto.yaml', '.obsidian', '.git' }) or vim.fn.getcwd()
  return root .. '/.grammalecte-ignore'
end

function M.read_ignores(buf)
  local ok, lines = pcall(vim.fn.readfile, M.ignore_file(buf))
  if not ok then
    return {}
  end
  local rules = {}
  for _, l in ipairs(lines) do
    l = vim.trim(l)
    if l ~= '' and not l:match '^#' then
      table.insert(rules, l)
    end
  end
  return rules
end

local function handle(line)
  local ok, resp = pcall(vim.json.decode, line)
  if not ok then
    return
  end
  if resp.error then
    failed = true
    vim.notify('[grammalecte] ' .. resp.error, vim.log.levels.ERROR)
    return
  end
  if resp.warning then
    vim.notify('[grammalecte] ' .. resp.warning, vim.log.levels.WARN)
  end
  local cb = pending[resp.id]
  pending[resp.id] = nil
  if cb then
    cb(resp)
  end
end

local function show(buf, tick, resp)
  -- Drop results for text that has changed since; the next save re-checks.
  if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].changedtick ~= tick then
    return
  end
  local diags = {}
  for _, e in ipairs(resp.errors) do
    table.insert(diags, {
      lnum = e.lnum,
      col = e.col,
      end_lnum = e.end_lnum,
      end_col = e.end_col,
      severity = vim.diagnostic.severity.INFO,
      source = 'grammalecte',
      code = e.rule,
      message = e.message,
      user_data = { suggestions = e.suggestions },
    })
  end
  vim.diagnostic.set(ns, buf, diags)
end

local function start()
  if job or failed then
    return job
  end
  if vim.fn.filereadable(bridge) == 0 then
    failed = true
    vim.notify('[grammalecte] ' .. bridge .. ' not found', vim.log.levels.ERROR)
    return nil
  end
  local partial = ''
  local id = vim.fn.jobstart({ M.python(), bridge }, {
    on_stdout = function(_, data)
      data[1] = partial .. data[1]
      partial = table.remove(data)
      for _, line in ipairs(data) do
        if line ~= '' then
          vim.schedule(function()
            handle(line)
          end)
        end
      end
    end,
    on_exit = function()
      job = nil
      pending = {}
    end,
  })
  if id <= 0 then
    failed = true
    vim.notify('[grammalecte] could not start the bridge (is ' .. M.python() .. ' there?)', vim.log.levels.ERROR)
    return nil
  end
  job = id
  return job
end

-- Sends one request (a table, minus its id) to the bridge; cb(response) runs
-- on the main loop. Returns false if the bridge isn't running.
function M.request(req, cb)
  if not start() then
    return false
  end
  next_id = next_id + 1
  pending[next_id] = cb
  req.id = next_id
  vim.fn.chansend(job, vim.json.encode(req) .. '\n')
  return true
end

function M.check(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local tick = vim.b[buf].changedtick
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  M.request({ text = text, french = M.is_french(buf), ignore = M.read_ignores(buf) }, function(resp)
    show(buf, tick, resp)
  end)
end

-- The grammalecte diagnostic under the cursor, else the first on the line.
local function diagnostic_at_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local diags = vim.diagnostic.get(0, { namespace = ns, lnum = row - 1 })
  for _, d in ipairs(diags) do
    if d.col <= col and (col < d.end_col or d.end_lnum > d.lnum) then
      return d
    end
  end
  return diags[1]
end

-- Adds `rule` (nil = every rule) to the `<!-- grammalecte:<kind> ... -->`
-- directive matched on line `lnum`. Returns the new line, or nil if `line`
-- has no such directive.
local function merge_directive(line, kind, rule)
  -- The %s after the kind keeps `ignore` from matching `ignore-file`.
  local pat = '<!%-%-%s*grammalecte:' .. vim.pesc(kind) .. '(%s.-)%-%->'
  local rules = line:match(pat)
  if not rules then
    return nil
  end
  rules = vim.trim(rules)
  local new
  if rules == '' or not rule then
    new = '' -- every rule (already, or now)
  elseif vim.tbl_contains(vim.split(rules, '%s+'), rule) then
    new = rules
  else
    new = rules .. ' ' .. rule
  end
  local repl = '<!-- grammalecte:' .. kind .. (new ~= '' and ' ' .. new or '') .. ' -->'
  return (line:gsub(pat, function()
    return repl
  end, 1))
end

-- Line-wise: a trailing comment on the error's line (a line of its own
-- would break lists and blockquotes).
function M.ignore_on_line(buf, lnum, rule)
  local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
  local merged = merge_directive(line, 'ignore', rule)
  if not merged then
    merged = line .. ' <!-- grammalecte:ignore' .. (rule and ' ' .. rule or '') .. ' -->'
  end
  vim.api.nvim_buf_set_lines(buf, lnum, lnum + 1, false, { merged })
end

-- File-wise: one directive line, after any YAML front matter and leading
-- metadata comment. Never line 1 -- binder reads its metadata block from there.
function M.ignore_in_file(buf, rule)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local merged = merge_directive(line, 'ignore-file', rule)
    if merged then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { merged })
      return
    end
  end
  local at = 0
  if lines[1] == '---' then
    for i = 2, #lines do
      if lines[i] == '---' or lines[i] == '...' then
        at = i
        break
      end
    end
  end
  if lines[at + 1] and lines[at + 1]:match '^<!%-%-' then
    for i = at + 1, #lines do
      if lines[i]:find('-->', 1, true) then
        at = i
        break
      end
    end
  end
  vim.api.nvim_buf_set_lines(buf, at, at, false, { '<!-- grammalecte:ignore-file' .. (rule and ' ' .. rule or '') .. ' -->' })
end

-- Actions for the grammalecte diagnostic under the cursor, as
-- { label, fn } items. Shared by <leader>zf and the <leader>la picker.
function M.code_actions(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local d = diagnostic_at_cursor()
  if not d then
    return {}
  end
  local function act(label, fn)
    return {
      label = '⟨grammalecte⟩ ' .. label,
      fn = function()
        fn()
        M.check(buf)
      end,
    }
  end
  local items = {}
  for _, s in ipairs(d.user_data.suggestions or {}) do
    table.insert(
      items,
      act('Replace with "' .. s .. '"', function()
        vim.api.nvim_buf_set_text(buf, d.lnum, d.col, d.end_lnum, d.end_col, vim.split(s, '\n'))
      end)
    )
  end
  vim.list_extend(items, {
    act('Ignore ' .. d.code .. ' on this line', function()
      M.ignore_on_line(buf, d.lnum, d.code)
    end),
    act('Ignore ' .. d.code .. ' in this file', function()
      M.ignore_in_file(buf, d.code)
    end),
    act('Ignore ' .. d.code .. ' in this project', function()
      vim.fn.writefile({ d.code }, M.ignore_file(buf), 'a')
    end),
    act('Ignore all French grammar on this line', function()
      M.ignore_on_line(buf, d.lnum, nil)
    end),
    act('Disable Grammalecte for this file', function()
      M.ignore_in_file(buf, nil)
    end),
  })
  return items
end

-- <leader>zf: Grammalecte's and the be-verb hints' actions for the cursor.
function M.fix()
  local items = vim.list_extend(M.code_actions(0), require('config.beverbs').code_actions(0))
  if #items == 0 then
    vim.notify('no French grammar error or be-verb on this line', vim.log.levels.INFO)
    return
  end
  local d = diagnostic_at_cursor() or require('config.beverbs').diagnostic_at_cursor()
  vim.ui.select(items, {
    prompt = d.message,
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      item.fn()
    end
  end)
end

function M.setup()
  local group = vim.api.nvim_create_augroup('grammalecte', { clear = true })
  local function attach(buf)
    if not applies(buf) then
      return
    end
    -- FileType can fire again for the same buffer (:set ft=...).
    vim.api.nvim_clear_autocmds { group = group, event = 'BufWritePost', buffer = buf }
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = group,
      buffer = buf,
      callback = function()
        sync_lang(buf)
        M.check(buf)
      end,
    })
    -- Deferred: FileType fires mid-load, and later loading steps bump
    -- changedtick, which would make handle() drop the result as stale.
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        sync_lang(buf)
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
  -- setup() runs from which-key's config, possibly after the first file's
  -- FileType has already fired.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      attach(buf)
    end
  end
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      if job then
        vim.fn.jobstop(job)
      end
    end,
  })
end

return M
