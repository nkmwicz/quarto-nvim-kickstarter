# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal Neovim configuration forked from [quarto-nvim-kickstarter](https://github.com/jmbuhr/quarto-nvim-kickstarter), built as a permanent PDE for an academic historian who also teaches Python and data analytics at university. Two distinct workflows coexist:

- **Historical writing**: long-form manuscript production in Quarto — books and articles written non-linearly, section by section, assembled from archival research and secondary sources. This is the purpose of the `<leader>b…` and `<leader>r…` systems.
- **Data analytics**: Python-driven analysis, database work, and teaching materials. Quarto is used here too, as the document format for reproducible notebooks and course materials.

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

`ftplugin/quarto.lua` handles Quarto-specific cell highlighting via Treesitter extmarks and configures vim-slime's cell delimiter. It sets buffer-local variables that the keymap module reads for Python REPL mode.

### Custom Treesitter queries

`after/queries/` overrides and extends queries for markdown, python, and rust (highlights and textobjects).

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

- `<leader><cr>` or `<c-cr>` — send current code cell to Python REPL via vim-slime
- `<leader>cp` — open new Python terminal split
- `<m-i>` / `<m-I>` (insert/normal) — insert Python chunk
- `<leader>qp` — Quarto preview; `<leader>qa` — activate quarto-nvim
- vim-slime target is always a Neovim terminal (`vim.g.slime_target = 'neovim'`)

## image.nvim

Requires the **kitty** terminal and system packages: `imagemagick`, `libmagickwand-dev`, `liblua5.1-0-dev`, `lua5.1`, `luajit`. Run `:checkhealth kickstart` to verify.

## Writing environment (`<leader>b…` and `<leader>r…`)

This is the core of the configuration. Two modules — `lua/config/binder.lua` and `lua/config/research.lua` — implement a Scrivener-style non-linear writing workflow for an academic historian. The design theory is that a historian writes arguments, not files: sections are drafted out of order, reorganised as the argument develops, and assembled into a final document only at the end. Research material accumulates alongside the manuscript, organised thematically rather than by source, because retrieval happens by concept ("what did I find about secret diplomacy in 1546?") not by bibliography.

### Binder (`lua/config/binder.lua`, `<leader>b…`)

The unit of work is a **section** — a `.qmd` file in a `sections/` subdirectory. The manuscript is assembled by Quarto `{{< include >}}` directives in a parent `.qmd` file. The binder reads and writes that parent file to control order.

**Metaphor**: a section is a index card in a physical binder. You can write them in any order, pin a summary and status to each one, lay them out on a corkboard to see the argument's shape, drag them into a new order, and only then produce the final document.

Commands:
- `<leader>bo` — open the manuscript parent file
- `<leader>bs` — open a section by name (Telescope picker)
- `<leader>bm` — move/reorder sections
- `<leader>bc` — corkboard (card view of all sections with summaries and status)
- `<leader>bl` — outliner (table view of sections with status and word counts)
- `<leader>bf` — focus mode (distraction-free writing in a centred float)
- `<leader>bN` — open/create a section-local notes file
- `<leader>bii` — inspector: edit status, summary, keywords for current section
- `<leader>biw` — word count with manuscript target and session target progress bars

Design constraints:
- Section metadata (`status`, `summary`, `keywords`) lives **in-file** in HTML comment blocks — no external database.
- The parent document is authoritative for reading order; the outliner and corkboard reflect and write back to it.
- Status values (`todo → draft → review → done`) model a writing lifecycle.
- Word counts exclude YAML front matter, HTML comment blocks, and code fences — prose only.
- Session word count resets on `r` in the word count float, or automatically on each new Neovim session.
- `<leader>b…` commands are scoped to the manuscript. Do not extend them for general file management.

### Research (`lua/config/research.lua`, `<leader>r…`)

Research lives in a `research/` directory sibling to `sections/`. It contains thematically organised `.md` files — one file per theme or argument strand, each potentially drawing on many sources. Sources can be archival (manuscript sources with archive, series, and folio references) or published (citekeys). This is not a bibliography manager; Zotero handles that. This is a place for the historian's own reading notes, transcriptions, and thematic syntheses organised around the arguments of the current project.

**Organisation principle**: files are named by theme (`secret-ottoman-meetings.md`, `popular-religion-resistance.md`), not by source. Within each file, individual snippets are anchored by `##` headings that identify the source:

```markdown
## BnF ms. fr. 14223, fol. 123r (1546-05-12)
"Quote or transcription..."
Note: interpretation or relevance to the argument.

## @dubellay1569 p. 22
"Published source quote..."
```

Metadata block at the top of each file (same in-file comment pattern as sections):

```markdown
<!-- type: thematic
keywords: diplomacy, Ottoman, 1546
-->
```

`type` values: `thematic`, `archive`, `transcription`, `reading`, `scratch`.

Commands:
- `<leader>rs` — open `scratch.md` instantly (for fleeting notes; created on first use)
- `<leader>ro` — Telescope picker: select an existing research file or type a new name to create one
- `<leader>rn` — quick `vim.ui.input` to name and create a new research note
- `<leader>rf` — live grep across all of `research/` (find by any word in text or metadata)
- `<leader>rh` — snippet picker: flat list of every `##` heading across all research files, shown as `filename › heading`, with preview — the primary way to locate a specific source note while writing

The `research/` directory is created automatically on first use. All commands open files in a vertical split so the manuscript section remains visible alongside the research note.

When extending this code: the retrieval model is grep-and-heading, not hierarchy. Do not add subdirectory structure or source-identity schemes (citekey filenames, archive folders). The thematic file with `##` snippet headings is the intentional unit.

## Disabled plugins

Several plugins are kept as commented-out examples but disabled (`enabled = false`): lualine (custom statusline is used instead), trouble, indent-blankline, molten-nvim, flash.nvim, fidget.nvim. Enable by setting `enabled = true`.

## Local dev plugins

lazy.nvim's `dev.path` is set to `~/projects` with `fallback = true`, so any plugin spec with `dev = true` loads from `~/projects/<plugin-name>` when available.
