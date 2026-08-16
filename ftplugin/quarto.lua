local api = vim.api
local ts = vim.treesitter

vim.b.slime_cell_delimiter = '```'
vim.bo.commentstring = '<!-- %s -->'
vim.b['quarto_is_r_mode'] = nil
vim.b['reticulate_running'] = false

-- wrap text, but by word no character
-- indent the wrappped line
vim.wo.wrap = true
vim.wo.linebreak = true
vim.wo.breakindent = true
vim.wo.showbreak = '>>> '

-- Native spellcheck, on by default (z? still toggles it off/back on).
-- Two-tier 'spellfile' list: entry 1 (plain zg/<leader>zg) is scoped to the
-- current manuscript's project root (walking up for _quarto.yml/.git, same
-- marker pattern used for per-project state elsewhere in this config), so
-- recurring names/terms for one project don't bleed into another. Entry 2
-- (2zg/<leader>zG) is a config-wide dictionary in dict/, for vocabulary that
-- isn't project-specific (period descriptors like "sixteenth-century",
-- recurring personal terms) -- add once, available everywhere.
vim.opt_local.spelllang = 'en,fr'
do
  local markers = { '_quarto.yml', '_quarto.yaml', '.git' }
  local buf_path = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.dirname(vim.fs.find(markers, { upward = true, path = buf_path })[1]) or vim.fn.getcwd()
  local project_spellfile = root .. '/.spell/en.utf-8.add'
  local global_spellfile = vim.fn.stdpath 'config' .. '/dict/en.utf-8.add'
  vim.fn.mkdir(vim.fs.dirname(project_spellfile), 'p')
  vim.opt_local.spellfile = project_spellfile .. ',' .. global_spellfile
end
vim.opt_local.spell = true

-- don't run vim ftplugin on top
vim.api.nvim_buf_set_var(0, 'did_ftplugin', true)

-- markdown vs. quarto hacks
local ns = vim.api.nvim_create_namespace 'QuartoHighlight'
vim.api.nvim_set_hl(ns, '@markup.strikethrough', { strikethrough = false })
vim.api.nvim_set_hl(ns, '@markup.doublestrikethrough', { strikethrough = true })
vim.api.nvim_win_set_hl_ns(0, ns)

-- ts based code chunk highlighting uses a change
-- only availabl in nvim >= 0.10
if vim.fn.has 'nvim-0.10.0' == 0 then
  return
end

-- highlight code cells similar to
-- 'lukas-reineke/headlines.nvim'
-- (disabled in lua/plugins/ui.lua)
local buf = api.nvim_get_current_buf()
if not vim.api.nvim_buf_is_loaded(buf) then return end

local parsername = 'markdown'
local parser = ts.get_parser(buf, parsername)
local tsquery = '(fenced_code_block)@codecell'

-- vim.api.nvim_set_hl(0, '@markup.codecell', { bg = '#000055' })
vim.api.nvim_set_hl(0, '@markup.codecell', {
  link = 'CursorLine',
})

local function clear_all()
  local all = api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  for _, mark in ipairs(all) do
    vim.api.nvim_buf_del_extmark(buf, ns, mark[1])
  end
end

local function highlight_range(from, to)
  for i = from, to do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 0, {
      hl_eol = true,
      line_hl_group = '@markup.codecell',
    })
  end
end

local function highlight_cells()
  clear_all()

  local query = ts.query.parse(parsername, tsquery)
  local tree = parser:parse()
  local root = tree[1]:root()
  for _, match, _ in query:iter_matches(root, buf, 0, -1, { all = true }) do
    for _, nodes in pairs(match) do
      for _, node in ipairs(nodes) do
        local start_line, _, end_line, _ = node:range()
        pcall(highlight_range, start_line, end_line - 1)
      end
    end
  end
end

highlight_cells()

vim.api.nvim_create_autocmd({ 'ModeChanged', 'BufWrite' }, {
  group = vim.api.nvim_create_augroup('QuartoCellHighlight', { clear = true }),
  buffer = buf,
  callback = highlight_cells,
})
