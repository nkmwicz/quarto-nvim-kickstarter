-- dict.lua: <leader>zd / <leader>zt — the dotfiles repo's `dict` command
-- (~/dotfiles/dict.sh: Webster's 1913 + Wiktionary definitions, WordNet
-- thesaurus) for the word under the cursor, or the visual selection, in a
-- floating terminal.
--
-- `dict` is a bash function, not a binary, so it's run as
-- `bash -c 'source ~/dotfiles/dict.sh && dict ...'` — Neovim's own shells
-- never read ~/.bashrc.
--
-- <leader>zt opens dict's interactive thesaurus (fzf); ctrl-y there swaps
-- the picked word in for the original (matching its capitalisation).
-- dict writes the pick to $DICT_PICK_FILE, read back here once the
-- terminal exits.

local M = {}

local dict_sh = vim.fn.expand '~/dotfiles/dict.sh'

-- Word under the cursor, or the visual selection (joined onto one line).
local function target()
  local mode = vim.fn.mode()
  if mode:match '[vV\22]' then
    local lines = vim.fn.getregion(vim.fn.getpos 'v', vim.fn.getpos '.', { type = mode })
    vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
    return vim.trim(table.concat(lines, ' ')), true
  end
  return vim.fn.expand '<cword>', false
end

-- Runs `dict <args>` in a centred floating terminal. on_pick(word), if
-- given, receives the word picked with ctrl-y in the thesaurus.
local function open(args, on_pick)
  if vim.fn.filereadable(dict_sh) == 0 then
    vim.notify('dict: ' .. dict_sh .. ' not found', vim.log.levels.ERROR)
    return
  end
  local width = math.floor(vim.o.columns * 0.85)
  local height = math.floor(vim.o.lines * 0.8)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' dict ' .. args[#args] .. ' ',
    title_pos = 'center',
  })
  local pick_file = on_pick and vim.fn.tempname() or nil
  local env = { DICT_PAGER = 'less -R', COLUMNS = tostring(width) }
  if pick_file then
    env.DICT_PICK_FILE = pick_file
  end
  vim.fn.jobstart({ 'bash', '-c', 'source "$0" && dict "$@"', dict_sh, unpack(args) }, {
    term = true,
    env = env,
    on_exit = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        if pick_file then
          local ok, lines = pcall(vim.fn.readfile, pick_file)
          os.remove(pick_file)
          if ok and lines[1] and lines[1] ~= '' then
            on_pick(lines[1])
          end
        end
      end)
    end,
  })
  -- The global TermOpen autocmd (config.autocommands) maps <Esc> and
  -- <C-h/j/k/l> to leave terminal mode / switch windows; fzf needs them
  -- (Esc to cancel, C-j/C-k to move), so pass them straight through here.
  for _, key in ipairs { '<Esc>', '<C-h>', '<C-j>', '<C-k>', '<C-l>' } do
    vim.keymap.set('t', key, key, { buffer = buf, nowait = true })
  end
  vim.cmd.startinsert()
end

function M.define()
  local word = target()
  if word == '' then
    return
  end
  open { '--', word }
end

function M.thesaurus()
  local word, visual = target()
  if word == '' then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  open({ '-t', '--', word }, function(pick)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_set_current_win(win)
    if not vim.bo.modifiable then
      vim.notify('dict: buffer is not modifiable', vim.log.levels.WARN)
      return
    end
    if word:match '^%u%u' then
      pick = pick:upper()
    elseif word:match '^%u' then
      pick = pick:sub(1, 1):upper() .. pick:sub(2)
    end
    if visual then
      vim.cmd('normal! gv"_c' .. pick)
    else
      vim.api.nvim_win_set_cursor(win, cursor)
      vim.cmd('normal! "_ciw' .. pick)
    end
  end)
end

return M
