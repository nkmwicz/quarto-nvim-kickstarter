-- molten.lua: <leader>mi — start Molten on the current project's Python
-- environment, without having to remember the Jupyter kernel incantations.
--
-- Environment, first match wins:
--   1. the nearest uv `.venv` above the buffer, or $VIRTUAL_ENV;
--   2. the micromamba env active when Neovim started ($CONDA_PREFIX);
--   3. a picker over `micromamba env list`.
-- (micromamba's base env and the nvim-host env from config.global are never
-- offered — the latter is the Neovim Python host, not a project env.)
--
-- On first use per env:
--   1. installs ipykernel into it if missing — `uv pip install` for venvs
--      (uv venvs have no pip; not added to pyproject.toml, so a later
--      `uv sync` may remove it, which just means it's reinstalled next time),
--      `micromamba install` from conda-forge for micromamba envs;
--   2. registers it as a user kernelspec, `venv-<project dir>` or
--      `mamba-<env name>` (re-registered if that name points at a different
--      python);
-- then runs `:MoltenInit <kernel>`. With no env found it falls back to plain
-- `:MoltenInit` (prompts among already-registered kernels).

local M = {}

local kernels_dir = vim.fn.expand '~/.local/share/jupyter/kernels'
local micromamba = vim.env.MAMBA_EXE or 'micromamba'
local mamba_root = vim.env.MAMBA_ROOT_PREFIX or vim.fn.expand '~/micromamba'

local function kernel_name(prefix, name)
  return prefix .. '-' .. name:gsub('[^%w%._-]', '-')
end

local function venv_env()
  local buf_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
  local venv = vim.fs.find('.venv', { path = buf_dir, upward = true, type = 'directory' })[1] or vim.env.VIRTUAL_ENV
  local python = venv and venv .. '/bin/python'
  if not python or vim.fn.executable(python) == 0 then
    return nil
  end
  local project = vim.fs.basename(vim.fs.dirname(venv))
  return {
    python = python,
    kernel = kernel_name('venv', project),
    display = project,
    install = vim.fn.executable 'uv' == 1 and { 'uv', 'pip', 'install', '--python', python, 'ipykernel' }
      or { python, '-m', 'pip', 'install', 'ipykernel' },
  }
end

local function usable_mamba_prefix(prefix)
  return prefix
    and vim.fs.normalize(prefix) ~= vim.fs.normalize(mamba_root)
    and vim.fs.basename(prefix) ~= 'nvim-host'
    and vim.fn.executable(prefix .. '/bin/python') == 1
end

local function mamba_env(prefix)
  local name = vim.fs.basename(prefix)
  return {
    python = prefix .. '/bin/python',
    kernel = kernel_name('mamba', name),
    display = name .. ' (micromamba)',
    install = { micromamba, 'install', '-y', '-p', prefix, '-c', 'conda-forge', 'ipykernel' },
  }
end

-- Calls on_env(env) with the resolved environment, or nil if none.
local function resolve(on_env)
  local env = venv_env()
  if env then
    return on_env(env)
  end
  if usable_mamba_prefix(vim.env.CONDA_PREFIX) then
    return on_env(mamba_env(vim.env.CONDA_PREFIX))
  end
  if vim.fn.executable(micromamba) == 0 then
    return on_env(nil)
  end
  local res = vim.system({ micromamba, 'env', 'list', '--json' }, { text = true }):wait()
  local ok, list = pcall(vim.json.decode, res.stdout or '')
  local prefixes = vim.tbl_filter(usable_mamba_prefix, ok and list.envs or {})
  if #prefixes == 0 then
    return on_env(nil)
  end
  vim.ui.select(prefixes, {
    prompt = 'micromamba env for Molten',
    format_item = vim.fs.basename,
  }, function(prefix)
    if prefix then
      on_env(mamba_env(prefix))
    end
  end)
end

-- True if a kernelspec called `name` already launches `python`.
local function kernel_matches(name, python)
  local f = io.open(kernels_dir .. '/' .. name .. '/kernel.json')
  if not f then
    return false
  end
  local ok, spec = pcall(vim.json.decode, f:read '*a')
  f:close()
  local argv0 = ok and spec.argv and spec.argv[1]
  return argv0 ~= nil and vim.uv.fs_realpath(argv0) == vim.uv.fs_realpath(python)
end

-- Runs cmds one after another, asynchronously; on_done() after the last.
local function run_chain(cmds, on_done)
  if #cmds == 0 then
    return on_done()
  end
  local cmd = table.remove(cmds, 1)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        vim.notify('molten: `' .. table.concat(cmd, ' ') .. '` failed:\n' .. (res.stderr or ''), vim.log.levels.ERROR)
        return
      end
      run_chain(cmds, on_done)
    end)
  end)
end

function M.init()
  resolve(function(env)
    if not env then
      vim.notify('molten: no .venv or micromamba env found — choose a registered kernel', vim.log.levels.WARN)
      vim.cmd 'MoltenInit'
      return
    end

    local cmds = {}
    if vim.system({ env.python, '-c', 'import ipykernel' }):wait().code ~= 0 then
      table.insert(cmds, env.install)
    end
    if #cmds > 0 or not kernel_matches(env.kernel, env.python) then
      table.insert(cmds, { env.python, '-m', 'ipykernel', 'install', '--user', '--name', env.kernel, '--display-name', env.display })
    end

    if #cmds > 0 then
      vim.notify('molten: setting up kernel `' .. env.kernel .. '`…')
    end
    run_chain(cmds, function()
      vim.cmd('MoltenInit ' .. env.kernel)
    end)
  end)
end

return M
