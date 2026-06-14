# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal Neovim configuration forked from [quarto-nvim-kickstarter](https://github.com/jmbuhr/quarto-nvim-kickstarter), optimized for working with Quarto documents, R, Python, and data science workflows.

## Architecture

### Entry point and load order

`init.lua` requires four modules in order:
1. `config.global` — all Vim options, highlight groups, diagnostic config, statusline
2. `config.lazy` — bootstraps lazy.nvim and calls `require('lazy').setup('plugins', ...)`
3. `config.autocommands` — global autocommands (yank highlight, terminal keymaps, PDF handler)
4. `config.redir` — output redirection utilities

### Plugin organization

All plugins live under `lua/plugins/` and are auto-discovered by lazy.nvim:

| File | Purpose |
|---|---|
| `lsp.lua` | Mason + nvim-lspconfig + otter.nvim + ltex-ls. All LSP server configs use `vim.lsp.config(name, ...)` / `vim.lsp.enable(name)` pattern (not the legacy `.setup{}` form). |
| `quarto.lua` | quarto-nvim, jupytext (ipynb→qmd), vim-slime (REPL), img-clip, nabla (math preview) |
| `completion.lua` | nvim-cmp with many sources, GitHub Copilot (auto-trigger), CopilotChat |
| `editing.lua` | conform.nvim (format on save), nvim-surround, Comment.nvim, neogen, nvim-prose (word count) |
| `treesitter.lua` | Treesitter with textobjects; Tab toggles folds |
| `ui.lua` | Telescope, oil.nvim, nvim-tree, which-key, toggleterm, headlines.nvim, image.nvim |
| `debugging.lua` | nvim-dap + dapui + neotest (Python) |

### Keymap loading

Keymaps are in `lua/config/keymap.lua` and loaded by which-key's config function in `lua/plugins/ui.lua` via `require 'config.keymap'`. Do not call `require 'config.keymap'` elsewhere — it depends on which-key being initialized.

### ftplugins

`ftplugin/quarto.lua` handles Quarto-specific cell highlighting via Treesitter extmarks and configures vim-slime's cell delimiter. `ftplugin/r.lua` sets the R-style cell delimiter (`# %%`). Both set buffer-local variables that the keymap module reads to switch between R/Python REPL modes.

### Custom Treesitter queries

`after/queries/` overrides and extends queries for markdown, python, R, and rust (highlights and textobjects).

## Formatting conventions

- **Lua**: stylua with `--indent-type Spaces --indent-width 2`
- **Python**: isort then black
- **JS/TS**: prettierd → prettier (first available)
- **Quarto**: conform's `injected` formatter (runs formatters on embedded code blocks by language)
- Format on save is enabled for all the above via conform.nvim

## LSP notes

- LSP servers are managed by Mason; ensure-installed list is in `lua/plugins/lsp.lua`
- ltex-ls (grammar/spell checker) requires Java at `/usr/local/bin/ltex-ls/jdk-11.0.12+7` — set in the plugin config
- marksman needs `~/.config/marksman/config.toml` with `[core] markdown.file_extensions = ["md", "markdown", "qmd"]` to work on `.qmd` files
- Custom dictionaries for ltex live in `dict/en` and `dict/fr`

## Quarto / REPL workflow

- `<leader><cr>` or `<c-cr>` — send current code cell to REPL via vim-slime
- `<leader>cr` / `<leader>cp` — open new R / Python terminal split
- `<m-i>` (insert/normal) — insert R chunk; `<m-I>` — insert Python chunk
- `<leader>qp` — Quarto preview; `<leader>qa` — activate quarto-nvim
- vim-slime target is always a Neovim terminal (`vim.g.slime_target = 'neovim'`)
- The `send_cell` / `send_region` functions in `keymap.lua` handle R↔Python mode switching via `reticulate::repl_python()`

## image.nvim

Requires the **kitty** terminal and system packages: `imagemagick`, `libmagickwand-dev`, `liblua5.1-0-dev`, `lua5.1`, `luajit`. Run `:checkhealth kickstart` to verify.

## Disabled plugins

Several plugins are kept as commented-out examples but disabled (`enabled = false`): lualine (custom statusline is used instead), trouble, indent-blankline, molten-nvim, flash.nvim, fidget.nvim. Enable by setting `enabled = true`.

## Local dev plugins

lazy.nvim's `dev.path` is set to `~/projects` with `fallback = true`, so any plugin spec with `dev = true` loads from `~/projects/<plugin-name>` when available.
