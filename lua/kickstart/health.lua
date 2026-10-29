-- adapted from <https://github.com/nvim-lua/kickstart.nvim/>
--[[
--
-- This file is not required for your own configuration,
-- but helps people determine if their system is setup correctly.
--
--]]

local check_version = function()
  if not vim.version.cmp then
    vim.health.error(string.format("Neovim out of date: '%s'. Upgrade to latest stable or nightly", tostring(vim.version())))
    return
  end

  -- nvim-treesitter's `main` branch (lua/plugins/treesitter.lua) needs 0.12
  if vim.version.cmp(vim.version(), { 0, 12, 0 }) >= 0 then
    vim.health.ok(string.format("Neovim version is: '%s'", tostring(vim.version())))
  else
    vim.health.error(string.format("Neovim out of date: '%s'. Upgrade to latest stable or nightly", tostring(vim.version())))
  end
end

local check_external_reqs = function()
  -- Basic utils: `git`, `make`, `unzip`
  for _, exe in ipairs { 'git', 'make', 'unzip', 'rg', 'cc', 'curl', 'tar' } do
    local is_executable = vim.fn.executable(exe) == 1
    if is_executable then
      vim.health.ok(string.format("Found executable: '%s'", exe))
    else
      vim.health.warn(string.format("Could not find executable: '%s'", exe))
    end
  end

  return true
end

-- nvim-treesitter (main) compiles every parser with the tree-sitter CLI.
-- Mason's `tree-sitter-cli` is the intended copy; apt's lags behind.
local check_tree_sitter_cli = function()
  local path = vim.fn.exepath 'tree-sitter'
  if path == '' then
    vim.health.error 'tree-sitter CLI not found. Install it with :MasonInstall tree-sitter-cli'
    return
  end
  local out = vim.fn.system { 'tree-sitter', '--version' }
  local v = vim.version.parse(out:match '(%d+%.%d+%.%d+)' or '')
  if v and vim.version.ge(v, '0.26.1') then
    vim.health.ok(string.format('tree-sitter CLI %s (%s)', tostring(v), path))
  else
    vim.health.error(
      string.format("tree-sitter CLI at %s is %s; need 0.26.1+. Use Mason's copy (:MasonInstall tree-sitter-cli)", path, v and tostring(v) or 'unknown')
    )
  end
end

-- French grammar checking (lua/config/grammalecte.lua) and the be-verb hints
-- (lua/config/beverbs.lua) share one bridge process, on the prose venv's
-- Python (scripts/setup_prose_venv.sh), which sees apt's python3-grammalecte.
local check_grammalecte = function()
  local python = require('config.grammalecte').python()
  local res = vim.system({ python, '-c', 'import grammalecte' }):wait()
  if res.code == 0 then
    vim.health.ok(string.format('grammalecte importable from %s', python))
  else
    vim.health.warn(string.format('grammalecte not importable from %s. Install it with: sudo apt install python3-grammalecte', python))
  end
  local setup = vim.fn.stdpath 'config' .. '/scripts/setup_prose_venv.sh'
  local probe = 'import os, sys, lemminflect, en_core_web_sm, wn; wn.config.data_directory = os.path.join(sys.prefix, "wn_data"); wn.Wordnet("oewn:2024")'
  res = vim.system({ python, '-c', probe }):wait()
  if res.code == 0 then
    vim.health.ok(string.format('be-verb hints: spaCy, lemminflect and Open English WordNet available from %s', python))
  else
    vim.health.warn(string.format('be-verb hints unavailable from %s. Run %s', python, setup))
  end
end

local function maybe_system(command)
  local success, obj = pcall(vim.system, command, { text = true })
  if not success then
    return nil
  end
  local res = obj:wait()
  if res.code ~= 0 then
    return nil
  end
  return res.stdout
end

local check_image_dependencies = function()
  local backend = 'kitty'

  local shell
  if vim.fn.has 'nvim-0.10.0' == 1 then
    shell = function(command)
      return maybe_system(command)
    end
  else
    vim.health.warn 'nvim < 0.10'
    shell = function(command)
      command = table.concat(command, ' ')
      local handle = io.popen(command)
      if handle == nil then
        return nil
      end
      local result = handle:read '*a'
      handle:close()
      return result
    end
  end

  -- check if imagemagick is available
  if shell { 'convert', '-version' } == nil then
    vim.health.warn 'imagemagick is not available'
    return
  end

  if backend == 'kitty' then
    -- check if kitty is available
    print 'kitty'
    local out = shell { 'kitty', '--version' }
    if out == nil then
      vim.health.warn 'kitty is not available'
      return
    end
    local kitty_version = out:match '(%d+%.%d+%.%d+)'
    if kitty_version == nil then
      vim.health.warn 'kitty version is not available'
      return
    end
    local v = vim.version.parse(kitty_version)
    local minimal = vim.version.parse '0.30.1'
    if v and vim.version.cmp(v, minimal) < 0 then
      vim.health.warn 'kitty version is too old'
      return
    end
  end
  local tmux = vim.fn.getenv 'TMUX'
  if tmux ~= vim.NIL then
    -- tmux uses number.number.(maybe letter)
    -- e.g. 3.3a
    -- but 3.3 comes before 3.3a
    -- so we replace a with 1
    local offset = 96
    local out = shell { 'tmux', '-V' }
    if out == nil then
      vim.health.warn 'tmux is not available'
      return
    end
    out = out:gsub('\n', '')
    local letter = out:match 'tmux %d+%.%d+([a-z])'
    local number
    if letter == nil then
      number = 0
    else
      number = string.byte(letter) - offset
    end
    local version = out:gsub('tmux (%d+%.%d+)([a-z])', '%1.' .. number)
    local v = vim.version.parse(version)
    local minimal = vim.version.parse '3.3.1'
    if v and vim.version.cmp(v, minimal) < 0 then
      vim.health.warn 'tmux version is too old'
      return
    end
  end

  -- check if magick luarock is available
  local ok, magick = pcall(require, 'magick')
  if not ok then
    vim.health.warn 'magick luarock is not available'
    return
  end

  vim.health.ok 'image.nvim dependencies are available'
  return true
end

return {
  check = function()
    vim.health.start 'kickstart.nvim'

    vim.health.info [[NOTE: Not every warning is a 'must-fix' in `:checkhealth`

  Fix only warnings for plugins and languages you intend to use.
    Mason will give warnings for languages that are not installed.
    You do not need to install, unless you want to use those languages!]]

    local uv = vim.uv or vim.loop
    vim.health.info('System Information: ' .. vim.inspect(uv.os_uname()))

    check_version()
    check_external_reqs()
    check_tree_sitter_cli()
    check_grammalecte()
    check_image_dependencies()
  end,
}
