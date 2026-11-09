-- Git history of one file (<leader>bh for sections, <leader>gh for any file):
-- a float of the commits touching it, with word-level diffs — prose
-- paragraphs are single long lines, so line diffs mark whole paragraphs.
--   <CR> word diff against the previous version   d  word diff against the file now
--   r    restore that version into the buffer (unsaved; u undoes)

local M = {}

local function git(root, args, opts)
  opts = opts or {}
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { text = true }):wait()
  if r.code ~= 0 then return nil, r.stderr end
  if opts.raw then return r.stdout or '' end
  return vim.trim(r.stdout or '')
end

-- Repo root and repo-relative path of fpath, or nil outside a repository.
local function locate(fpath)
  fpath = vim.fn.resolve(vim.fn.fnamemodify(fpath, ':p'))
  local root = git(vim.fs.dirname(fpath), { 'rev-parse', '--show-toplevel' })
  if not root or root == '' then return nil end
  root = vim.fn.resolve(root)
  if fpath:sub(1, #root + 1) ~= root .. '/' then return nil end
  return root, fpath:sub(#root + 2)
end

local function notify(msg, level)
  vim.notify('[history] ' .. msg, level or vim.log.levels.INFO)
end

local function term(root, args)
  vim.cmd 'botright new'
  local cmd = { 'git', '-C', root, '--no-pager' }
  vim.list_extend(cmd, args)
  vim.fn.jobstart(cmd, { term = true })
end

function M.show(fpath)
  fpath = vim.fn.fnamemodify(fpath, ':p')
  local root, rel = locate(fpath)
  if not root then
    notify('not in a git repository', vim.log.levels.WARN)
    return
  end
  local commits = {}
  for _, l in ipairs(vim.split(git(root, { 'log', '--format=%h%x09%ct%x09%s', '--', rel }) or '', '\n',
    { trimempty = true })) do
    local hash, ct, subj = l:match '^(%x+)\t(%d+)\t(.*)$'
    if hash then commits[#commits + 1] = { hash = hash, time = tonumber(ct), subject = subj } end
  end
  if #commits == 0 then
    notify('no git history for ' .. rel, vim.log.levels.WARN)
    return
  end

  local lines, rowmap = { '  ' .. rel, '' }, {}
  for _, c in ipairs(commits) do
    lines[#lines + 1] = string.format('  %s  %s  %s', os.date('%Y-%m-%d %H:%M', c.time), c.hash, c.subject)
    rowmap[#lines] = c
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  <Enter> diff previous   d diff now   r restore   q close'

  local binder = require 'config.binder'
  local buf, win = binder.open_float(lines, 'File History')
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  local function map(key, fn)
    vim.keymap.set('n', key, function()
      local c = rowmap[vim.api.nvim_win_get_cursor(win)[1]]
      if not c then return end
      vim.api.nvim_win_close(win, true)
      fn(c)
    end, { buffer = buf, silent = true })
  end

  map('<CR>', function(c) term(root, { 'show', '--word-diff=color', c.hash, '--', rel }) end)
  map('d', function(c) term(root, { 'diff', '--word-diff=color', c.hash, '--', rel }) end)
  map('r', function(c)
    local text = git(root, { 'show', c.hash .. ':' .. rel }, { raw = true })
    if not text then
      notify('could not read ' .. c.hash, vim.log.levels.ERROR)
      return
    end
    if vim.fn.confirm(string.format('Replace %s with the %s version?', vim.fn.fnamemodify(rel, ':t'),
          os.date('%Y-%m-%d %H:%M', c.time)), '&Yes\n&No', 2) ~= 1 then
      return
    end
    if vim.fn.expand '%:p' ~= fpath then vim.cmd('edit ' .. vim.fn.fnameescape(fpath)) end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split((text:gsub('\n$', '')), '\n', { plain = true }))
    notify('restored ' .. c.hash .. ' (unsaved; u to undo)')
  end)
  binder.close_keys(buf, win)
end

return M
