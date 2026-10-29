-- required in which-key plugin spec in plugins/ui.lua as `require 'config.keymap'`
local wk = require 'which-key'
local ms = vim.lsp.protocol.Methods

P = vim.print


local nmap = function(key, effect)
  vim.keymap.set('n', key, effect, { silent = true, noremap = true })
end

local vmap = function(key, effect)
  vim.keymap.set('v', key, effect, { silent = true, noremap = true })
end

local imap = function(key, effect)
  vim.keymap.set('i', key, effect, { silent = true, noremap = true })
end

local cmap = function(key, effect)
  vim.keymap.set('c', key, effect, { silent = true, noremap = true })
end

-- Code action picker. Appends non-LSP actions to the standard LSP action list:
-- Grammalecte's fixes/ignores for a French grammar error under the cursor
-- (config/grammalecte.lua), rewrites/ignores for a be-verb, Strunk or style hint
-- (config/beverbs.lua), and, when ltex is attached, <!-- ltex: ... -->
-- magic comments.
local function code_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local ltex_clients = vim.lsp.get_clients { bufnr = bufnr, name = 'ltex' }
  local grammalecte_items = require('config.grammalecte').code_actions(bufnr)
  vim.list_extend(grammalecte_items, require('config.beverbs').code_actions(bufnr))

  if #ltex_clients == 0 and #grammalecte_items == 0 then
    vim.lsp.buf.code_action()
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local word = vim.fn.expand '<cword>'

  -- d.code lives in d.code (Neovim 0.10+) or d.user_data.lsp.code (older builds).
  local function diag_code(d)
    return d.code or (d.user_data and d.user_data.lsp and d.user_data.lsp.code)
  end

  -- Request code actions from all attached clients synchronously.
  local clients = vim.lsp.get_clients { bufnr = bufnr }
  local params = vim.lsp.util.make_range_params(0, clients[1] and clients[1].offset_encoding or 'utf-16')
  params.context = {
    triggerKind = 1,
    diagnostics = vim.tbl_map(function(d)
      return {
        range    = { start = { line = d.lnum, character = d.col },
                     ['end'] = { line = d.end_lnum, character = d.end_col } },
        severity = d.severity,
        code     = diag_code(d),
        source   = d.source,
        message  = d.message,
      }
    end, vim.diagnostic.get(bufnr, { lnum = lnum })),
  }

  local results = vim.lsp.buf_request_sync(bufnr, 'textDocument/codeAction', params, 3000)
  local items = {}

  for client_id, result in pairs(results or {}) do
    for _, action in ipairs(result.result or {}) do
      table.insert(items, { label = action.title, kind = 'lsp', client_id = client_id, action = action })
    end
  end

  for _, item in ipairs(grammalecte_items) do
    table.insert(items, { label = item.label, kind = 'magic', fn = item.fn })
  end

  -- ltex magic comment options (inserted above the current line).
  if #ltex_clients > 0 then
    local ins = lnum  -- nvim_buf_set_lines uses 0-indexed insert-before
    table.insert(items, {
      label = '⟨ltex⟩ Add "' .. word .. '" to inline dictionary',
      kind  = 'magic',
      fn    = function()
        vim.api.nvim_buf_set_lines(bufnr, ins, ins, false,
          { '<!-- ltex: dictionary=[' .. word .. '] -->' })
      end,
    })
  end

  if #items == 0 then
    vim.notify('No code actions available', vim.log.levels.INFO)
    return
  end

  vim.ui.select(items, {
    prompt      = 'Code action:',
    format_item = function(item) return item.label end,
  }, function(item)
    if not item then return end
    if item.kind == 'magic' then
      item.fn()
      return
    end
    -- Execute the LSP action.
    local client = vim.lsp.get_client_by_id(item.client_id)
    if not client then return end
    local action = item.action
    -- Resolve if the action has neither edit nor command yet.
    if not action.edit and action.command == nil then
      client.request('codeAction/resolve', action, function(err, resolved)
        if err then return end
        if resolved.edit then
          vim.lsp.util.apply_workspace_edit(resolved.edit, client.offset_encoding)
        end
        if resolved.command then
          client:exec_cmd(resolved.command, { bufnr = bufnr })
        end
      end, bufnr)
    else
      if action.edit then
        vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
      end
      if action.command then
        local cmd = type(action.command) == 'table' and action.command or action
        client:exec_cmd(cmd, { bufnr = bufnr })
      end
    end
  end)
end

-- open code actions with ctrl-. in normal mode
nmap('<C-.>', code_action)

-- move in command line
cmap('<C-a>', '<Home>')

-- save with ctrl+s
imap('<C-s>', '<esc>:update<cr><esc>')
nmap('<C-s>', '<cmd>:update<cr><esc>')

-- move  up and down softwrapped text
nmap('<leader>k', function()
  vim.lsp.buf.hover { border = require('misc.style').border }
end)
nmap('J', 'gj')
nmap('K', 'gk')

-- Move lines up and down in visual mode
vmap('J',  ":m '>+1<CR>gv=gv")
vmap('K', ":m '<-2<CR>gv=gv")

-- Move between windows using <ctrl> direction
nmap('<C-j>', '<C-W>j')
nmap('<C-k>', '<C-W>k')
nmap('<C-h>', '<C-W>h')
nmap('<C-l>', '<C-W>l')

-- Resize window using <shift> arrow keys
nmap('<S-Up>', '<cmd>resize +2<CR>')
nmap('<S-Down>', '<cmd>resize -2<CR>')
nmap('<S-Left>', '<cmd>vertical resize -2<CR>')
nmap('<S-Right>', '<cmd>vertical resize +2<CR>')

-- Add undo break-points
imap(',', ',<c-g>u')
imap('.', '.<c-g>u')
imap(';', ';<c-g>u')

nmap('Q', '<Nop>')

local function send_cell()
  vim.fn['slime#send_cell']()
end

local slime_send_region_cmd = ':<C-u>call slime#send_op(visualmode(), 1)<CR>'
slime_send_region_cmd = vim.api.nvim_replace_termcodes(slime_send_region_cmd, true, false, true)
local function send_region()
  vim.cmd('normal' .. slime_send_region_cmd)
end

-- send code with ctrl+Enter
-- just like in e.g. RStudio
-- needs kitty (or other terminal) config:
-- map shift+enter send_text all \x1b[13;2u
-- map ctrl+enter send_text all \x1b[13;5u
nmap('<c-cr>', send_cell)
nmap('<s-cr>', send_cell)
imap('<c-cr>', send_cell)
imap('<s-cr>', send_cell)

-- keep selection after indent/dedent
vmap('>', '>gv')
vmap('<', '<gv')

-- center after search and jumps
nmap('n', 'nzz')
nmap('<c-d>', '<c-d>zz')
nmap('<c-u>', '<c-u>zz')

-- move between splits and tabs
nmap('<c-h>', '<c-w>h')
nmap('<c-l>', '<c-w>l')
nmap('<c-j>', '<c-w>j')
nmap('<c-k>', '<c-w>k')
nmap('H', '<cmd>tabprevious<cr>')
nmap('L', '<cmd>tabnext<cr>')

local function toggle_light_dark_theme()
  if vim.o.background == 'light' then
    vim.o.background = 'dark'
  else
    vim.o.background = 'light'
  end
end

local is_code_chunk = function()
  local current, _ = require('otter.keeper').get_current_language_context()
  if current then
    return true
  else
    return false
  end
end

--- Insert code chunk of given language
--- Splits current chunk if already within a chunk
--- @param lang string
local insert_code_chunk = function(lang)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<esc>', true, false, true), 'n', true)
  local keys
  if is_code_chunk() then
    keys = [[o```<cr><cr>```{]] .. lang .. [[}<esc>o]]
  else
    keys = [[o```{]] .. lang .. [[}<cr>```<esc>O]]
  end
  keys = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(keys, 'n', false)
end

local insert_py_chunk = function()
  insert_code_chunk 'python'
end

local insert_lua_chunk = function()
  insert_code_chunk 'lua'
end

local insert_julia_chunk = function()
  insert_code_chunk 'julia'
end

local insert_bash_chunk = function()
  insert_code_chunk 'bash'
end

local insert_ojs_chunk = function()
  insert_code_chunk 'ojs'
end

-- Reflows the lines currently marked '< / '> (a visual selection, or a
-- text object like `ip` already applied) to one sentence per line -
-- "semantic linefeeds": each sentence becomes its own git-diffable line,
-- while Markdown/Quarto's actual paragraph separator (a real blank line,
-- left untouched since only the marked range is ever touched) still
-- renders identically. `:join` (not `J`) collapses the range's existing
-- line wraps into one line first, with smart spacing; the substitute
-- then re-splits on sentence-ending punctuation followed by whitespace,
-- inserting a real newline (`\r` on the replacement side) at each split.
local function reflow_marks_to_sentences()
  local start_line = vim.fn.line "'<"
  local end_line = vim.fn.line "'>"
  if end_line > start_line then
    vim.cmd(string.format('%d,%djoin', start_line, end_line))
  end
  vim.cmd(start_line .. [[s/\([.!?]\)\s\+/\1\r/g]])
end

-- Normal-mode entry point: selects the current paragraph (`vip`) as if
-- typed by hand, exits visual mode (so '< '> are finalized the same way
-- a manual selection would leave them), then reflows it.
local function reflow_paragraph_to_sentences()
  vim.cmd 'normal! vip\27'
  reflow_marks_to_sentences()
end

-- Registered as real keymaps directly, not via wk.add() below: wk.add()
-- only queues a spec into which-key's own internal registry/trigger
-- tree (confirmed in which-key/init.lua - M.add is just `table.insert(
-- M._queue, ...)`), not a real `vim.keymap.set` call - which-key's own
-- popup still discovers and displays real keymaps via
-- `nvim_get_keymap`/`nvim_buf_get_keymap` (see which-key/buf.lua), so
-- this loses nothing from the popup while making dispatch verifiable.
--
-- The visual-mode mapping below deliberately does NOT pass
-- reflow_marks_to_sentences as a Lua function value directly (confirmed
-- by direct testing: `'<`/`'>` read as 0/unset the moment a Lua-callback
-- RHS runs synchronously off a visual-mode keypress - the marks aren't
-- committed yet at that point, so a fresh selection's first press
-- silently no-ops on line 0 and only "works" on a second press once
-- something coincidentally leaves the marks populated). Routing through
-- a `:<C-u>lua ...<CR>` command-line RHS instead is the long-standing,
-- reliable idiom for this exact problem (same one vim-surround/
-- vim-commentary use) - pressing `:` from Visual mode is what natively,
-- synchronously converts the selection into the `'<,'>` marks before
-- any of the command line's own content runs; `<C-u>` just clears the
-- `'<,'>` range text Vim auto-inserts on that command line, since we
-- don't want it literally, only the marks it sets as a side effect.
_G.__reflow_marks_to_sentences = reflow_marks_to_sentences

vim.keymap.set('n', '<leader>ss', reflow_paragraph_to_sentences,
  { desc = '[s]entence-per-line reflow (current paragraph)' })
vim.keymap.set('x', '<leader>ss', ':<C-u>lua __reflow_marks_to_sentences()<CR>',
  { desc = '[s]entence-per-line reflow (selection)' })

--show kepbindings with whichkey
--add your own here if you want them to
--show up in the popup as well

-- normal mode
wk.add({
    {"<leader>ccq", function ()
      local input = vim.fn.input("Quick Chat: ")
      if input ~= "" then
        require("CopilotChat").ask(input, { selection = require("CopilotChat.select").buffer })
      end
    end,
    desc = "CopilotChat - Quick chat"},
    { "<c-LeftMouse>", "<cmd>lua vim.lsp.buf.definition()<CR>", desc = "go to definition" },
    { "<c-q>", "<cmd>q<cr>", desc = "close buffer" },
    { "<cm-i>", insert_py_chunk, desc = "python code chunk" },
    { "<esc>", "<cmd>noh<cr>", desc = "remove search highlight" },
    { "<m-I>", insert_py_chunk, desc = "python code chunk" },
    { "<m-i>", insert_py_chunk, desc = "python code chunk" },
    { "[q", ":silent cprev<cr>", desc = "[q]uickfix prev" },
    { "]q", ":silent cnext<cr>", desc = "[q]uickfix next" },
    { "gN", "Nzzzv", desc = "center search" },
    { "gf", ":e <cfile><CR>", desc = "edit file" },
    { "gl", "<c-]>", desc = "open help link" },
    { "n", "nzzzv", desc = "center search" },
}, { mode = 'n', silent = true })

-- visual mode
wk.add({
    {
      mode = { "v" },
      { ".", ":norm .<cr>", desc = "repat last normal mode command" },
      { "<M-j>", ":m'>+<cr>`<my`>mzgv`yo`z", desc = "move line down" },
      { "<M-k>", ":m'<-2<cr>`>my`<mzgv`yo`z", desc = "move line up" },
      { "<cr>", send_region, desc = "run code region" },
      { "q", ":norm @q<cr>", desc = "repat q macro" },
    },
})

-- visual with <leader>
wk.add({
    { "<leader>d", '"_d', desc = "delete without overwriting reg", mode = "v" },
    { "<leader>p", '"_dP', desc = "replace without overwriting reg", mode = "v" },
    { "<leader>zd", function() require('config.dict').define() end, desc = "[d]efine selection (dict)", mode = "v" },
    { "<leader>zt", function() require('config.dict').thesaurus() end, desc = "[t]hesaurus for selection (ctrl-y swaps it in)", mode = "v" },
}, { mode = 'v' })

-- insert mode
wk.add({
    {
      mode = { "i" },
      { "<c-x><c-x>", "<c-x><c-o>", desc = "omnifunc completion" },
      { "<cm-i>", insert_py_chunk, desc = "python code chunk" },
      { "<m-I>", insert_py_chunk, desc = "python code chunk" },
      { "<m-i>", insert_py_chunk, desc = "python code chunk" },
    },
}, { mode = 'i' })

local function new_terminal(lang)
  vim.cmd('vsplit term://%:p:h//' .. lang)
end

local function new_terminal_python()
  new_terminal 'python'
end

local function new_terminal_ipython()
  new_terminal 'ipython --no-confirm-exit'
end

local function new_terminal_julia()
  new_terminal 'julia'
end

local function new_terminal_shell()
  new_terminal '$SHELL'
end

local function get_otter_symbols_lang()
  local otterkeeper = require'otter.keeper'
  local main_nr = vim.api.nvim_get_current_buf()
  local langs = {}
  for i,l in ipairs(otterkeeper.rafts[main_nr].languages) do
    langs[i] = i .. ': ' .. l
  end
  -- promt to choose one of langs
  local i = vim.fn.inputlist(langs)
  local lang = otterkeeper.rafts[main_nr].languages[i]
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(),
    otter = {
      lang = lang
    }
  }
  -- don't pass a handler, as we want otter to use it's own handlers
  vim.lsp.buf_request(main_nr, ms.textDocument_documentSymbol, params, nil)
end

vim.keymap.set("n", "<leader>os", get_otter_symbols_lang, {desc = "otter [s]ymbols"})


-- normal mode with <leader>
wk.add({
  {
    { "<leader><cr>", send_cell, desc = "run code cell" },
    { "<leader>c", group = "[c]ode / [c]ell / [c]hunk" },
    { "<leader>ci", new_terminal_ipython, desc = "new [i]python terminal" },
    { "<leader>cj", new_terminal_julia, desc = "new [j]ulia terminal" },
    { "<leader>cn", new_terminal_shell, desc = "[n]ew terminal with shell" },
    { "<leader>cp", new_terminal_python, desc = "new [p]ython terminal" },
    { "<leader>d", group = "[d]ebug" },
    { "<leader>dt", group = "[t]est" },
    { "<leader>e", group = "[e]dit" },
    { "<leader>f", group = "[f]ind (telescope)" },
    { "<leader>f<space>", "<cmd>Telescope buffers<cr>", desc = "[ ] buffers" },
    { "<leader>fM", "<cmd>Telescope man_pages<cr>", desc = "[M]an pages" },
    { "<leader>fb", "<cmd>Telescope current_buffer_fuzzy_find<cr>", desc = "[b]uffer fuzzy find" },
    { "<leader>fc", "<cmd>Telescope git_commits<cr>", desc = "git [c]ommits" },
    { "<leader>fd", "<cmd>Telescope buffers<cr>", desc = "[d] buffers" },
    { "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "[f]iles" },
    { "<leader>fg", "<cmd>Telescope live_grep<cr>", desc = "[g]rep" },
    { "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "[h]elp" },
    { "<leader>fj", "<cmd>Telescope jumplist<cr>", desc = "[j]umplist" },
    { "<leader>fk", "<cmd>Telescope keymaps<cr>", desc = "[k]eymaps" },
    { "<leader>fl", "<cmd>Telescope loclist<cr>", desc = "[l]oclist" },
    { "<leader>fm", "<cmd>Telescope marks<cr>", desc = "[m]arks" },
    { "<leader>fq", "<cmd>Telescope quickfix<cr>", desc = "[q]uickfix" },
    { "<leader>g", group = "[g]it" },
    { "<leader>gb", group = "[b]lame" },
    { "<leader>gbb", ":GitBlameToggle<cr>", desc = "[b]lame toggle virtual text" },
    { "<leader>gbc", ":GitBlameCopyCommitURL<cr>", desc = "[c]opy" },
    { "<leader>gbo", ":GitBlameOpenCommitURL<cr>", desc = "[o]pen" },
    { "<leader>gc", ":GitConflictRefresh<cr>", desc = "[c]onflict" },
    { "<leader>gd", group = "[d]iff" },
    { "<leader>gdc", ":DiffviewClose<cr>", desc = "[c]lose" },
    { "<leader>gdh", ":DiffviewFileHistory %<cr>", desc = "[h]istory (current file)" },
    { "<leader>gdo", ":DiffviewOpen<cr>", desc = "[o]pen" },
    {
      "<leader>gh",
      function() require('config.binder').git_history(vim.fn.expand '%:p') end,
      desc = "[h]istory (current file)",
    },
    { "<leader>gs", ":Gitsigns<cr>", desc = "git [s]igns" },
    { "<leader>gwc", ":lua require('telescope').extensions.git_worktree.create_git_worktree()<cr>", desc = "worktree create" },
    { "<leader>gws", ":lua require('telescope').extensions.git_worktree.git_worktrees()<cr>", desc = "worktree switch" },
    { "<leader>h", group = "[h]elp / [h]ide / debug" },
    { "<leader>hc", group = "[c]onceal" },
    { "<leader>hch", ":set conceallevel=1<cr>", desc = "[h]ide/conceal" },
    { "<leader>hcs", ":set conceallevel=0<cr>", desc = "[s]how/unconceal" },
    { "<leader>ht", group = "[t]reesitter" },
    { "<leader>htt", vim.treesitter.inspect_tree, desc = "show [t]ree" },
    { "<leader>i", group = "[i]mage" },
    { "<leader>l", group = "[l]anguage/lsp" },
    { "<leader>la", code_action, desc = "code [a]ction" },
    { "<leader>ld", group = "[d]iagnostics" },
    { "<leader>ldd", function() vim.diagnostic.enable(false) end, desc = "[d]isable" },
    { "<leader>lde", vim.diagnostic.enable, desc = "[e]nable" },
    { "<leader>le", vim.diagnostic.open_float, desc = "diagnostics (show hover [e]rror)" },
    { "<leader>lg", ":Neogen<cr>", desc = "neo[g]en docstring" },
    { "<leader>m", group = "[m]olten" },
    { "<leader>o", group = "[o]tter & c[o]de" },
    { "<leader>oa", require'otter'.activate, desc = "otter [a]ctivate" },
    { "<leader>ob", insert_bash_chunk, desc = "[b]ash code chunk" },
    { "<leader>oc", "O# %%<cr>", desc = "magic [c]omment code chunk # %%" },
    { "<leader>od", require'otter'.activate, desc = "otter [d]eactivate" },
    { "<leader>oj", insert_julia_chunk, desc = "[j]ulia code chunk" },
    { "<leader>ol", insert_lua_chunk, desc = "[l]lua code chunk" },
    { "<leader>oo", insert_ojs_chunk, desc = "[o]bservable js code chunk" },
    { "<leader>op", insert_py_chunk, desc = "[p]ython code chunk" },
    { "<leader>q", group = "[q]uarto" },
    { "<leader>qE", function() require('otter').export(true) end, desc = "[E]xport with overwrite" },
    { "<leader>qa", function() require('config.otter_fenced').activate(0, true) end, desc = "[a]ctivate code-cell LSPs (fenced languages)" },
    { "<leader>qe", require('otter').export, desc = "[e]xport" },
    { "<leader>qh", ":QuartoHelp ", desc = "[h]elp" },
    { "<leader>qp", ":lua require'quarto'.quartoPreview()<cr>", desc = "[p]review" },
    { "<leader>qq", ":lua require'quarto'.quartoClosePreview()<cr>", desc = "[q]uiet preview" },
    { "<leader>qr", group = "[r]un" },
    { "<leader>qra", ":QuartoSendAll<cr>", desc = "run [a]ll" },
    { "<leader>qrb", ":QuartoSendBelow<cr>", desc = "run [b]elow" },
    { "<leader>qrr", ":QuartoSendAbove<cr>", desc = "to cu[r]sor" },
    { "<leader>v", group = "[v]im" },
    { "<leader>vc", ":Telescope colorscheme<cr>", desc = "[c]olortheme" },
    { "<leader>vh", ':execute "h " . expand("<cword>")<cr>', desc = "vim [h]elp for current word" },
    { "<leader>vl", ":Lazy<cr>", desc = "[l]azy package manager" },
    { "<leader>vm", ":Mason<cr>", desc = "[m]ason software installer" },
    { "<leader>vs", ":e $MYVIMRC | :cd %:p:h | split . | wincmd k<cr>", desc = "[s]ettings, edit vimrc" },
    { "<leader>vt", toggle_light_dark_theme, desc = "[t]oggle light/dark theme" },
    { "<leader>x", group = "e[x]ecute" },
    { "<leader>xx", ":w<cr>:source %<cr>", desc = "[x] source %" },
    { "<leader>z", group = "[z]pell" },
    { "<leader>z?", ":setlocal spell!<cr>", desc = "toggle spellcheck" },
    { "<leader>zl", ":Telescope spell_suggest<cr>", desc = "[l]ist spelling suggestions" },
    -- Aliases for native zg/zw (mark word under cursor good/wrong), just for
    -- discoverability in the [z]pell group -- zg/zw stay mapped natively too,
    -- since they don't collide with anything (unlike zl did with fold cmds).
    { "<leader>zg", "zg", desc = "mark word [g]ood" },
    { "<leader>zw", "zw", desc = "mark word [w]rong" },
    -- ~/dotfiles/dict.sh in a float; see config/dict.lua.
    { "<leader>zd", function() require('config.dict').define() end, desc = "[d]efine word (dict)" },
    { "<leader>zt", function() require('config.dict').thesaurus() end, desc = "[t]hesaurus: pick a synonym (ctrl-y swaps it in)" },
    -- French grammar (Grammalecte) and be-verb hints; both also run on
    -- open/save. See config/grammalecte.lua and config/beverbs.lua.
    { "<leader>zc", function() require('config.grammalecte').check(); require('config.beverbs').check() end, desc = "[c]heck grammar now (French, be-verbs, Strunk, style)" },
    { "<leader>zf", function() require('config.grammalecte').fix() end, desc = "[f]ix grammar error / stronger verb (or ignore rule)" },
    { "<leader>zb", function() require('config.beverbs').toggle() end, desc = "toggle [b]e-verb, Strunk & style hints" },
  }
}, { mode = 'n'})

require('config.binder').setup()
require('config.research').setup()
require('config.grammalecte').setup()
require('config.beverbs').setup()
