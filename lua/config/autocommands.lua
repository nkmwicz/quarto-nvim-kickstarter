local function set_terminal_keymaps()
  local opts = { buffer = 0 }
  vim.keymap.set('t', '<esc>', [[<C-\><C-n>]], opts)
  vim.keymap.set('t', '<C-h>', [[<Cmd>wincmd h<CR>]], opts)
  vim.keymap.set('t', '<C-j>', [[<Cmd>wincmd j<CR>]], opts)
  vim.keymap.set('t', '<C-k>', [[<Cmd>wincmd k<CR>]], opts)
  vim.keymap.set('t', '<C-l>', [[<Cmd>wincmd l<CR>]], opts)
end

vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter' }, {
  pattern = { '*' },
  command = 'checktime',
})

vim.api.nvim_create_autocmd({ 'TermOpen' }, {
  pattern = { '*' },
  callback = function(_)
    vim.cmd.setlocal 'nonumber'
    vim.wo.signcolumn = 'no'
    set_terminal_keymaps()
  end,
})

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

-- open PDF files in default PDF viewer on system
vim.api.nvim_create_autocmd({"BufReadPost"}, {
  pattern = "*.pdf",
  command = "silent !xdg-open % &",
})

-- Global gf: resolve ./relative and ../relative paths from the buffer's directory
-- in any filetype. Neovim natively resolves ./ from cwd, which breaks when they differ.
local function gf_open_relative(cfile, dir)
  if not cfile:match('^%.%.?/') then return false end
  local full = vim.fn.resolve(dir .. '/' .. cfile)
  if vim.fn.filereadable(full) == 0 then return false end
  vim.cmd('edit ' .. vim.fn.fnameescape(full))
  return true
end

vim.keymap.set('n', 'gf', function()
  local dir = vim.fn.expand('%:p:h')
  if not gf_open_relative(vim.fn.expand('<cfile>'), dir) then
    vim.cmd('normal! gf')
  end
end, { desc = 'go to file' })

-- Quarto/Markdown: additionally handle {{< include ./path >}} shortcode syntax.
-- Buffer-local, so it takes precedence over the global mapping above.
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'quarto', 'markdown' },
  callback = function()
    vim.keymap.set('n', 'gf', function()
      local line = vim.api.nvim_get_current_line()
      local dir  = vim.fn.expand('%:p:h')

      local inc = line:match('{{<.*include%s+(.-)%s*>}}')
      if inc then
        inc = inc:gsub('^%./', '')
        local full = dir .. '/' .. inc
        if vim.fn.filereadable(full) == 1 then
          vim.cmd('edit ' .. vim.fn.fnameescape(full))
          return
        end
      end

      if not gf_open_relative(vim.fn.expand('<cfile>'), dir) then
        vim.cmd('normal! gf')
      end
    end, { buffer = true, desc = 'go to file' })
  end,
})

-- Quarto/Markdown: peek at {{< include >}} file in a floating window
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'quarto', 'markdown' },
  callback = function()
    vim.keymap.set('n', '<leader>bp', function()
      local line = vim.api.nvim_get_current_line()
      local path = line:match('{{<.*include%s+(.-)%s*>}}')

      if not path then
        print("Not on a Quarto {{< include >}} line.")
        return
      end

      local full_path = vim.fn.expand('%:p:h') .. '/' .. path
      if vim.fn.filereadable(full_path) == 0 then
        print("Include file not found: " .. full_path)
        return
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(full_path))
      vim.bo[buf].filetype = full_path:match('%.qmd$') and 'quarto' or 'markdown'
      vim.bo[buf].modifiable = false

      local width  = math.floor(vim.o.columns * 0.8)
      local height = math.floor(vim.o.lines   * 0.7)
      local win = vim.api.nvim_open_win(buf, true, {
        relative  = 'editor',
        row       = math.floor((vim.o.lines   - height) / 2),
        col       = math.floor((vim.o.columns - width)  / 2),
        width     = width,
        height    = height,
        style     = 'minimal',
        border    = require('misc.style').border,
        title     = ' ' .. vim.fn.fnamemodify(path, ':t') .. ' ',
        title_pos = 'center',
      })

      for _, key in ipairs({ 'q', '<Esc>' }) do
        vim.keymap.set('n', key, function()
          vim.api.nvim_win_close(win, true)
        end, { buffer = buf, silent = true })
      end
    end, { buffer = true, desc = "[p]eek include file" })
  end,
})
