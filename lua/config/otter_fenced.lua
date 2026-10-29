-- otter_fenced.lua: activate otter.nvim in Quarto buffers for the languages
-- of their fenced code blocks only.
--
-- otter's own activate() (and quarto-nvim's, which wraps it) takes every
-- language Treesitter injects. In a manuscript that means the binder/research
-- `<!-- -->` metadata (an HTML block to the markdown parser) and the YAML
-- front matter, so every prose section started html-lsp, emmet and yamlls
-- (~255MB) for nothing. Here a language counts only if a ``` / ~~~ fence
-- names it: ```{python}, ```python, ```{=html}, ``` {.js}. Once html is in,
-- otter also takes the HTML comments, which is harmless.
--
-- Re-scanned on save and on leaving insert mode, so a newly added block's
-- language gets its server without reopening the file; <leader>qa re-scans
-- on demand. quarto-nvim's own activation is off (lspFeatures.enabled in
-- plugins/quarto.lua).

local M = {}

-- Fence names otter knows by another name (Neovim's markdown injection
-- applies the same aliases before resolving the filetype).
local ALIASES = { sh = 'bash', ts = 'typescript', js = 'javascript', py = 'python' }

-- Fence opener -> language: ```{python echo=false}, ```{=html}, ```python,
-- ``` {.js .numberLines}. Closing fences and bare ``` give nil.
local function fence_lang(line)
  local rest = line:match '^%s*```+%s*(.*)$' or line:match '^%s*~~~+%s*(.*)$'
  if not rest or rest == '' then
    return nil
  end
  return rest:match '^{=?%.?([%w_+-]+)' or rest:match '^([%w_+-]+)'
end

-- Sorted, de-duplicated languages of buf's fenced blocks, under both the
-- fence's name and the parser name it resolves to (otter skips any it
-- doesn't find injected, so extras are harmless).
function M.languages(buf)
  local seen = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local lang = fence_lang(line)
    if lang then
      lang = lang:lower()
      seen[lang] = true
      local alias = ALIASES[lang] or lang
      local ft = vim.filetype.match { filename = 'a.' .. alias } or alias
      seen[vim.treesitter.language.get_lang(ft) or ft] = true
    end
  end
  local langs = vim.tbl_keys(seen)
  table.sort(langs)
  return langs
end

-- (Re)activates otter for buf's fenced languages; a no-op when they haven't
-- changed since the last call, unless force.
function M.activate(buf, force)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local langs = M.languages(buf)
  local key = table.concat(langs, ',')
  if not force and vim.b[buf].otter_fenced == key then
    return
  end
  local was_active = vim.b[buf].otter_fenced ~= nil
  vim.b[buf].otter_fenced = key
  local otter = require 'otter'
  -- The servers on the old otter buffers: any left with no buffer once the
  -- new set is up served a language that's gone (Neovim never stops an
  -- idle client itself).
  local old_clients = {}
  local raft = require('otter.keeper').rafts[buf]
  for _, otter_nr in pairs(raft and raft.buffers or {}) do
    vim.list_extend(old_clients, vim.lsp.get_clients { bufnr = otter_nr })
  end
  local function stop_idle()
    for _, client in ipairs(old_clients) do
      if not client:is_stopped() and next(client.attached_buffers) == nil then
        client:stop()
      end
    end
  end
  vim.api.nvim_buf_call(buf, function()
    if was_active or force then
      otter.deactivate()
    end
  end)
  if #langs == 0 then
    vim.defer_fn(stop_idle, 1000)
    return
  end
  -- deactivate() only asks the old otter-ls to stop (and deletes the old
  -- otter buffers in vim.schedule callbacks); activate() would re-attach to
  -- that dying client while it's still listed. So wait until it's gone.
  local name = 'otter-ls[' .. buf .. ']'
  local tries = 40 -- x 50ms
  local function go()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if tries > 0 and #vim.lsp.get_clients { name = name } > 0 then
      tries = tries - 1
      vim.defer_fn(go, 50)
      return
    end
    vim.api.nvim_buf_call(buf, function()
      otter.activate(langs)
    end)
    -- The new otter buffers attach their servers on their FileType.
    vim.defer_fn(stop_idle, 1000)
  end
  vim.schedule(go)
end

function M.setup()
  local group = vim.api.nvim_create_augroup('otter_fenced', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'quarto',
    callback = function(ev)
      -- Only real files: otter writes its buffers next to the main file.
      if vim.bo[ev.buf].buftype ~= '' then
        return
      end
      M.activate(ev.buf)
      vim.api.nvim_clear_autocmds { group = group, buffer = ev.buf }
      vim.api.nvim_create_autocmd({ 'BufWritePost', 'InsertLeave' }, {
        group = group,
        buffer = ev.buf,
        callback = function()
          M.activate(ev.buf)
        end,
      })
    end,
  })
end

return M
