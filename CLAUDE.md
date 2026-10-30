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
| `lsp.lua` | Mason + nvim-lspconfig + otter.nvim + harper_ls (grammar/prose checker; ltex-ls kept installed but disabled — see LSP notes). All LSP server configs use `vim.lsp.config(name, ...)` / `vim.lsp.enable(name)` pattern (not the legacy `.setup{}` form). |
| `quarto.lua` | quarto-nvim, jupytext (ipynb→qmd), vim-slime (REPL), img-clip, nabla (math preview), molten-nvim (Jupyter cell output, `<leader>m…`; renders images via image.nvim) |
| `completion.lua` | nvim-cmp with many sources, GitHub Copilot (auto-trigger), CopilotChat |
| `editing.lua` | conform.nvim (format on save), nvim-surround, Comment.nvim, neogen, nvim-prose (word count) |
| `treesitter.lua` | nvim-treesitter on its `main` branch (the rewrite, not the frozen `master`) + textobjects; Tab toggles folds. See Treesitter below. |
| `ui.lua` | Telescope, oil.nvim, nvim-tree, which-key, toggleterm, headlines.nvim, image.nvim (markdown-link inline preview integration disabled; still used as Molten's image backend) |
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
- Grammar/prose checking is `harper_ls` (native Rust binary, English-only, ~150MB idling), not `ltex-ls`. `ltex-ls` requires Java at `/usr/local/bin/ltex-ls/jdk-11.0.12+7` and costs ~1.2GB RSS just idling — kept installed with its config commented out in `lsp.lua` for a one-line revert (e.g. if harper's handling of embedded French text ever becomes a problem), along with `ltex_extra.nvim` (dormant, gated on ltex being attached). `harper_ls`'s own `SpellCheck` linter is disabled since it's English-only and can't tell French words from typos; spelling is handled by native Neovim spellcheck instead (see below). `isolateEnglish` was tried and rejected — genuinely experimental, it both suppressed a real grammar suggestion and introduced a false positive on a French quote. `harper_ls` supports inline `<!-- harper:ignore -->` comments to skip a line, and a per-project `.harper-dictionary.txt` (auto-created at the project root) for recurring proper nouns.
- Spellcheck is on by default for Quarto buffers (`ftplugin/quarto.lua`), `spelllang=en,fr`. `zg` additions go to `<project root>/.spell/en.utf-8.add` (root = nearest `_quarto.yml`/`.git`), not a config-wide file, so one manuscript's proper nouns don't bleed into another's. Keymaps are `<leader>z?` (toggle) / `<leader>zl` (Telescope spelling suggestions) / `<leader>zd` (define word or selection) / `<leader>zt` (thesaurus; `ctrl-y` swaps the pick in, matching capitalisation) — the last two run the dotfiles repo's `dict` (`~/dotfiles/dict.sh`, sourced via `bash -c` since it's a shell function) in a floating terminal, see `lua/config/dict.lua`; that float passes `<Esc>`/`<C-h/j/k/l>` through to fzf, overriding the global `TermOpen` terminal keymaps — moved off bare `z` since it collides with Vim's native fold commands (`zR`, `zM`, etc.).
- French grammar is Grammalecte, not an LSP: `lua/config/grammalecte.lua` runs `scripts/grammalecte_bridge.py` as one long-lived job (~70MB alone, ~210MB with be-verb hints loaded) on the prose venv's Python (`stdpath('data')/prose-venv`, made by `scripts/setup_prose_venv.sh` with `--system-site-packages` so apt's `python3-grammalecte` stays visible; falls back to `/usr/bin/python3`; `vim.g.grammalecte_python` overrides the interpreter). The bridge finds the French itself: `lang: fr` documents, `::: {lang=fr}` divs, `[…]{lang=fr}` spans, plus auto-detected French quotations, italic titles and sentences (a function-word heuristic). Everything else, code and metadata comments included, is masked out, because Grammalecte over English prose flags nearly every line. Grammalecte's own spellchecker is never used (447MB, and it flags early-modern spelling). A document can declare `lang: fr` (or `fr-FR` etc.) in its first metadata block, either YAML front matter or the line-1 binder/research `<!-- -->` block. Grammalecte then checks the whole text with typography rules on (in all other documents typography rules are off), spelling becomes French-only, and harper_ls stays off: its `root_dir` in `lsp.lua` skips such buffers, which means it must restate lspconfig's `root_markers`. Saving a change to `lang:` detaches harper or re-attaches it. It runs on open, on save, and on `<leader>zc` in Quarto buffers, `research/` markdown and Obsidian vault notes. `<leader>zf` and `<leader>la` (merged into the LSP code action picker in `keymap.lua`) apply a suggestion or ignore the error. A line ignore is a trailing `<!-- grammalecte:ignore [RULE…] -->` comment on that line; a file ignore is a `<!-- grammalecte:ignore-file [RULE…] -->` line, placed after any front matter and the binder/research metadata block, never on line 1, because binder reads its metadata block from there. A project ignore is a line in `<project root>/.grammalecte-ignore`. With no rule IDs, a directive ignores every Grammalecte rule.
- Be-verb hints (`lua/config/beverbs.lua`, `scripts/beverbs.py`) share the Grammalecte bridge process: ops `beverbs`/`suggest`, served on a worker thread, with `beverbs.py` (spaCy `en_core_web_sm`, lemminflect, `wn` + Open English WordNet, data in the venv's `wn_data/`) imported only on first use. HINT diagnostics, source `be-verb`, on real `.md`/`.qmd` files only (not markdown scratch buffers, not `lang: fr` documents), on open, save and `<leader>zc`; `<leader>zb` toggles them for the session (`vim.g.beverbs_enabled`). Rules `BE_PROGRESSIVE`/`BE_PASSIVE`/`BE_COPULA`/`BE_EXISTENTIAL`, kind shown in the message. Progressives get a picker: `<leader>zf`/`<leader>la` → a picker of WordNet troponyms (more specific verbs: walk → trudge, shuffle), inflected to the original tense, replacing the whole span (`was walking` → `trudged`, `had been walking` → `had trudged`); none for questions/negations. Passives get an active rewrite only when the doer is named (`the treaty was signed by Francis` → `Francis signed the treaty`, same tense, pronouns recased, relatives → `which the Venetians built`) and the parse is plain (no doer with a non-`of` prepositional phrase, appositive, or `not by … but by`), plus `need/deserve/require… to be` + participle → gerund or the verb's WordNet noun (`needed redeveloping`/`redevelopment`); copulas and existentials get none. No rewrites inside quotations or parentheses, and the bridge drops any rewrite whose range covers masked text (a citation, comment or footnote marker would be deleted). Datamuse (`rel_gen`, with the neighbouring words as `lc`/`rc`) ranks and widens candidates; a 1s TCP check to `api.datamuse.com` gates every request and a failure holds requests off for 60s, so offline costs nothing. Ignores reuse the `grammalecte:ignore` comments and `.grammalecte-ignore` by rule name, but a bare directive (no rule ids) skips no be-verb or Strunk rule, so quieting a French quotation leaves its English hinted.
- Strunk & White hints (`scripts/strunk.py`) run on the be-verbs' spaCy parse (`beverbs.check(masked, strunk.rules)`, so every paragraph is parsed once be-verb hints are on) and share their toggle, keymaps and ignores; source `strunk`, rules `PARENTHETIC_COMMA` (S&W 3), `COMMA_SPLICE` (5), `DANGLING_MODIFIER` (11), `NEGATIVE_FORM` (15), `NOMINALIZATION` / `VAGUE_VERB` (16), `WEAK_ENDING` (22). Heuristics tuned to miss rather than nag: nothing inside quotation marks or parentheses is checked; proper nouns and WordNet person/group nouns count as doers for dangling modifiers ("Seeking allies, France…"); mid-sentence "nevertheless" without commas is S&W's allowed "slight interruption". Fixed rewrites come back as `fix.choices` (`text`, `note`, optional own range, which the bridge turns into line/col) and each is its own `<leader>zf` action; `VAGUE_VERB` uses the troponym picker (`keep: false` drops the original verb). Negative-form verb fixes come from a hand list (`VERB_ANTONYMS`), not WordNet antonyms ("did not go" → "came").
- Style hints (`scripts/style.py`, source `style`, after Williams's *Style* and Gopen & Swan) run the same way, on the same parse and toggle: `NOMINAL_SUBJECT` (an action noun as subject, "the transformation of the court became…" → "the court transformed"; singular nouns whose WordNet senses are act/event/process, not group/person/artifact, or -ing nouns, "the signing of", which WordNet files under their result; with an `of` object or possessive to promote, the possessive being the doer when both are there: "His signing of the treaty" → "he signed the treaty"; "analysis/comparison of X" suggests "When we analyze X, …", since the doer is the author; message only, no fix, since the clause needs recasting), `GERUND_SUBJECT` (a gerund clause as subject, spaCy's `VBG` `csubj`: "Signing the treaty angered…" → "When [who] signed the treaty, …"; not when it has its own doer), `VAGUE_THIS` ("This shows" → "This refusal shows", nouns from the previous sentence), `SUBJECT_VERB_GAP` (15+ words from subject to verb), `NOUN_STACK`, `OF_CHAIN` (3+ nested "of"s), `ECHO` (a word or its WordNet family three times in two sentences; exempt are the section's metadata `keywords:` and the document's frequent words, its subject matter, computed in the bridge) and `QUOTE_ENDING` (a paragraph's last main-text sentence is mostly quotation; inline footnotes `^[…]` don't count), and `REPORTING_TENSE`: scholars argue, historical actors argued. A scholar is a surname in a `.bib` found upward from the file (`beverbs.lua` sends the paths; the bridge caches them by mtime) or cited narratively (`@key argues`: the bridge writes the surname over the masked citekey so the parse has a subject). A name in a footnote citation dated 1850+ is unsure (scholar, or a modern edition's author) and gets no hint; any other proper-noun subject is a historical actor. Pronouns, common nouns ("historians" may be sixteenth-century ones) and verbs with an auxiliary ("has argued") are left alone. `beverbs.quoted` tracks quotation marks by character, since a quote glued to a footnote (`."^[`) is not its own token.
- Wrong and missed hints are logged to tune the rules (`lua/config/hintlog.lua`): "Wrong hint" in a be-verb/Strunk/style hint's `<leader>zf`/`<leader>la` actions logs a false positive and hides it while its line reads the same; `<leader>zm` (cursor line, or visual selection) logs a false negative under a picked rule, or `OTHER`. Each entry (with an optional note) keeps the whole buffer and its `.bib` paths, so `scripts/replay_hints.py` (`<leader>zr`, in a split) re-checks every entry in its original context and reports, per rule, which the current rules still get wrong; it exits 1 if any are, so it can serve as a regression test. `tests/prose/.prose-hints.jsonl` is this repo's own such log, of invented sentences (so safe to publish): the rules' regression suite, replayed from that directory, with controls that must stay quiet as well as cases that must fire. The log is `.prose-hints.jsonl` at the project root (the `.grammalecte-ignore` one), with paths relative to it, so it is committed and synced with the manuscript's own (private) repo, never this public one, since it holds unpublished prose.
- marksman needs `~/.config/marksman/config.toml` with `[core] markdown.file_extensions = ["md", "markdown", "qmd"]` to work on `.qmd` files
- `dict/en` is now `harper_ls`'s `userDictPath` (previously ltex's dictionary source; both `dict/en` and `dict/fr` were actually empty placeholders, so nothing was lost in the swap). `dict/fr` is currently unused.
- `r_language_server` is explicitly excluded from `automatic_installation`/`automatic_enable` in `lsp.lua`. R is not used in this workflow (see project overview) — nvim-lspconfig ships a default config for it, so leaving mason-lspconfig's blanket auto-detect behavior unrestricted would silently install and attach it (and leak orphaned R processes) the moment any buffer looked R-flavored.
- Copilot's LSP process (`completion.lua`) can survive `:q` as an orphan if it's mid-request when Neovim exits — Neovim's own shutdown escalation only ever sends `SIGTERM`, never `SIGKILL`, and a busy/unresponsive process can ignore or delay `SIGTERM`. A `VimLeavePre` autocmd in `completion.lua` force-kills any lingering copilot child directly (`SIGKILL`) as a backstop.

## Quarto / REPL workflow

- `<leader><cr>` or `<c-cr>` — send current code cell to Python REPL via vim-slime
- `<leader>cp` — open new Python terminal split
- `<m-i>` / `<m-I>` (insert/normal) — insert Python chunk
- `<leader>qp` — Quarto preview; `<leader>qa` — re-scan and activate code-cell LSPs
- Code-cell LSPs (otter.nvim) are activated by `lua/config/otter_fenced.lua` for the languages of **fenced** blocks only (```` ```{python} ````, ```` ```{=html} ````, ```` ``` {.js} ````…), re-scanned on save and `InsertLeave`; servers left serving a removed language are stopped. otter's/quarto-nvim's own activation takes every Treesitter injection, so the binder/research `<!-- -->` metadata (an HTML block) and YAML front matter started html-lsp, emmet, tailwindcss and yamlls for every prose section; quarto-nvim's `lspFeatures.enabled` is off for that reason. Re-activation waits for the old `otter-ls` to exit, since `otter.activate()` otherwise re-attaches to the dying client. @citation completion is `cmp-pandoc-references`, independent of otter.
- vim-slime target is always a Neovim terminal (`vim.g.slime_target = 'neovim'`)
- `<leader>mi` — start Molten on the project's Python env (`lua/config/molten.lua`): the nearest uv `.venv` (or `$VIRTUAL_ENV`), else the active micromamba env (`$CONDA_PREFIX`), else a picker over micromamba envs (base and `nvim-host` excluded). Installs `ipykernel` if missing (`uv pip install` / `micromamba install`) and registers a `venv-<project>` / `mamba-<env>` kernelspec if needed, then `:MoltenInit <kernel>`. `<leader>mI` is plain `:MoltenInit` (pick a registered kernel). Molten is a Python remote plugin: if its commands are "not an editor command", run `:UpdateRemotePlugins` with Molten loaded and restart.

## Treesitter

nvim-treesitter's `main` branch only installs parsers and ships queries — there is no `configs.setup{}` module system. `lua/plugins/treesitter.lua` wires everything up by hand: a `FileType` autocmd calls `vim.treesitter.start()`, sets the treesitter `indentexpr` where an `indents` query exists, and sets buffer-local textobject keymaps (`af`/`if`/`ac`/`ic`, `]m`/`[m`/`]]`/`[[` etc.) where a `textobjects` query exists — buffer-local and set after the ftplugin so they beat e.g. the built-in python ftplugin's `]]`. Parsers in `ensure_installed` install at startup; any other filetype's parser installs on first open (the old `auto_install`). Incremental selection is Neovim 0.12's built-in visual `an`/`in`/`]n`/`[n`; the old `gnn`/`grn`/`grm` keys are kept as aliases (`grc` scope-selection is gone). Folding was already native (`config.global`). bigfile.nvim is respected via its `b:bigfile_disable_treesitter` flag. `norg` isn't supported on `main` (neorg is disabled anyway).

Per-machine requirements: **Neovim 0.12+** (the spec has `cond` on it and errors loudly otherwise), a **tree-sitter CLI 0.26.1+** — Mason's `tree-sitter-cli` (apt's is too old; the spec prepends `mason/bin` to `PATH` so Mason's copy wins, and on a fresh machine waits for `MasonToolsUpdateCompleted` before building parsers), plus a C compiler, `curl`, `tar`. Parsers compile into `stdpath('data')/site/parser`, per machine. `:checkhealth kickstart` checks all of this. Machines are provisioned by `~/dotfiles/install.sh`.

`lazy-lock.json` is committed, so every machine gets the same plugin versions (`:Lazy restore`); a fresh clone of a plugin without a lockfile gets whatever its default branch is that day, which is how the `master`→`main` switch broke this config.

## image.nvim

Requires the **kitty** terminal and system packages: `imagemagick`, `libmagickwand-dev`, `liblua5.1-0-dev`, `lua5.1`, `luajit`. Run `:checkhealth kickstart` to verify.

## Writing environment (`<leader>b…` and `<leader>r…`)

This is the core of the configuration. Two modules — `lua/config/binder.lua` and `lua/config/research.lua` — implement a Scrivener-style non-linear writing workflow for an academic historian. The design theory is that a historian writes arguments, not files: sections are drafted out of order, reorganised as the argument develops, and assembled into a final document only at the end. Research material accumulates alongside the manuscript, organised thematically rather than by source, because retrieval happens by concept ("what did I find about secret diplomacy in 1546?") not by bibliography.

**Scope boundary**: `research.lua` is deliberately scoped to a single manuscript — its `research/` directory lives inside that project, alongside `sections/`, and holds notes gathered in service of *that* book or article's argument. It is not a general-purpose PKM tool and should not grow hierarchy, source-identity schemes, or cross-project linking (see the Research section below). Standing, cross-project secondary-research reading notes (e.g. long-running book note vaults independent of any single manuscript) belong in a separate Obsidian vault, managed via `obsidian.nvim` rather than `research.lua` — see the Obsidian section below.

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

## Obsidian (secondary research vaults)

`lua/plugins/notes.lua` configures `obsidian-nvim/obsidian.nvim` (the maintained community fork — the original `epwalsh/obsidian.nvim` is archived/unmaintained) for two standing vaults, independent of any single manuscript:
- `~/vaults/work` — teaching/data-analytics notes
- `~/vaults/books` — secondary-research reading notes for book projects

This is separate in purpose and data model from `research.lua` (see the scope boundary note under Writing environment above): Obsidian vaults are long-lived and cross-project with wikilinks/backlinks, whereas `research.lua` is per-manuscript and grep-and-heading. The plugin only activates for markdown buffers inside these two workspace paths (no dynamic/catch-all workspace is configured), so it never touches `research.lua`'s `.md` files or binder's `.qmd` sections.

Keymaps (`<leader>n…`, buffer-local, active only inside the two vaults): `nd`/`nt`/`ny` — today/tomorrow/yesterday daily note; `nn` — new note; `no`/`nO` — quick switch / open in Obsidian app; `ns` — search; `nb` — backlinks; `nf` — follow link; `nc` — toggle checkbox; `nw` — switch workspace; `nS` — run `ob sync` (the Obsidian headless CLI, from npm) against whichever vault the current buffer belongs to, resolved by walking up for a `.obsidian/` directory rather than trusting the plugin's active-workspace state.

`conceallevel` is scoped to vault note buffers via `ObsidianNoteEnter`/`ObsidianNoteLeave` autocmds (set to 1 on enter, back to 0 on leave) rather than changed globally — the rest of the config keeps `conceallevel=0` by default with a manual `<leader>hch`/`<leader>hcs` toggle.

## Disabled plugins

Several plugins are kept as commented-out examples but disabled (`enabled = false`): lualine (custom statusline is used instead), trouble, indent-blankline, flash.nvim, fidget.nvim. Enable by setting `enabled = true`.

## Local dev plugins

lazy.nvim's `dev.path` is set to `~/projects` with `fallback = true`, so any plugin spec with `dev = true` loads from `~/projects/<plugin-name>` when available.
