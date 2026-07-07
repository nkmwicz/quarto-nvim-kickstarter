# Quarto Nvim Kickstarter

Companion to <https://github.com/quarto-dev/quarto-nvim>.

This requires Neovim >= **v0.9.5** (https://github.com/neovim/neovim/releases/tag/stable)

## Videos

Check out this playlist for a full guide and walkthrough:
https://youtube.com/playlist?list=PLabWm-zCaD1axcMGvf7wFxJz8FZmyHSJ7

## Setup

Clone this repo into `~/.config/nvim/` or copy-paste just the parts you like.

If you already have your own configuration, check out `lua/plugins/quarto.lua`
for the configuration of plugins directly relevant to your Quarto experience.
The comments in this file will also point to to other plugins required for
the full functionality.

This configuration can make use of a "Nerd Font" for icons and symbols.
Download one here: <https://www.nerdfonts.com/> and set it as your terminal font.

### Unix, Linux Installation

```bash
git clone https://github.com/nkmwicz/quarto-nvim-kickstarter.git ~/.config/nvim
```

For displaying images in your terminal a recent version of [kitty](https://sw.kovidgoyal.net/kitty/) or [wezterm](https://wezfurlong.org/wezterm/index.html) is required
as well as the dependecies of [image.nvim](https://github.com/3rd/image.nvim) (see `./lua/plugins/ui.lua`).
Additionally, if you plan to use this through [tmux](https://github.com/tmux/tmux) make sure to have version >= 3.3a.

If you are unable to install those in your enviroment, disable the plugin by setting `enabled = false`.

Example dependencies install on ubuntu-based systems:

```bash
sudo apt install imagemagick
sudo apt install libmagickwand-dev
sudo apt install liblua5.1-0-dev
sudo apt install luajit
sudo apt install tree-sitter-cli
```

Manually installing luarocks and the magick rock is no longer required, this is handled by [luarocks.nvim](https://github.com/vhyrro/luarocks.nvim).

> [!NOTE] Do this before opening nvim, otherwise `luarocks.nvim`
> might pick up the wrong luarocks version.
> If you forgot this step, you can do `:Lazy build luarocks.nvim` again manually after installation
> to fix it.


### Windows Powershell Installation

```bash
git clone https://github.com/jmbuhr/quarto-nvim-kickstarter.git "$env:LOCALAPPDATA\nvim"
```

The telescope file finder uses `fzf` for fuzzy finding via the [telescope-fzf-native](https://github.com/nvim-telescope/telescope-fzf-native.nvim) extension.
It will automatically install `fzf`, but needs some requirements which are not pre-installed on Windows.
Check out the previous link for those (or comment out the extension in `./lua/plugins/ui.lua`).

Now you are good to go!

## Updating

Certain updates to plugins may leave behind unused plugin data. If this configuration produces an error on startup, try removing those first, allowing the lazy.nvim package manager to recreate the correct plugin structure:

```bash
rm -r ~/.local/share/nvim
rm -r ~/.local/state/nvim
```

## Binder (`<leader>b…`)

A Scrivener-style non-linear writing environment for Quarto manuscript projects, implemented in `lua/config/binder.lua`. The design premise is that a historian writes arguments, not files: sections are drafted out of order, reorganised as the argument develops, and assembled into a final document only at the end.

### Project structure

The binder expects this layout:

```
project/
├── manuscript.qmd          ← parent document (assembles sections via {{< include >}})
├── sections/
│   ├── introduction.qmd
│   ├── chapter-one.qmd
│   └── ...
└── .binder.json            ← optional, stores word count targets
```

The parent document controls reading order via Quarto shortcodes:

```markdown
{{< include sections/introduction.qmd >}}
{{< include sections/chapter-one.qmd >}}
```

The binder reads and writes these lines to track and modify section order. Sections not referenced in the parent are treated as **orphans** — visible in the corkboard and outliner but excluded from the assembled manuscript.

### Section metadata

Each section file carries metadata in an HTML comment block at the top:

```markdown
<!--
status: todo
summary: One-sentence description of this section's argument.
keywords: diplomacy, Ottoman, 1546
-->
```

This block is written automatically when you create a section with `<leader>bn`. Status, summary, and keywords can be updated in-file or via the inspector commands. The metadata lives in the file itself — no external database.

**Status lifecycle:** `todo` → `draft` → `review` → `done`

### Keymaps

| Key | Description |
|---|---|
| `<leader>bs` | Telescope picker of all section files |
| `<leader>bn` | Create a new section (prompts for name, creates the `.qmd` with metadata block) |
| `<leader>bb` | Jump back to the parent document, cursor on the include line for the current section |
| `<leader>bl` | Set status for the current section (`todo` / `draft` / `review` / `done`) |
| `<leader>bm` | Reorder sections in the parent document (float editor, see below) |
| `<leader>bo` | Outliner — table view of all sections with status, word count, and summary |
| `<leader>bc` | Corkboard — card view of all sections (see below) |
| `<leader>bf` | Focus mode — open the file under the cursor in a centred float with a dimmed backdrop |
| `<leader>bh` | Git history for the current section file |
| `<leader>bN` | Open (or create) a section-local notes file in a vertical split |
| `<leader>bir` | Status report — breakdown of all sections by status with percentages |
| `<leader>biw` | Word count — total and session words with optional progress bars |
| `<leader>bis` | Live grep across `sections/` pre-filled with `status:` |
| `<leader>bik` | Live grep across `sections/` pre-filled with `keywords:` |

### Reorder (`<leader>bm`)

Opens a float listing all manuscript sections in their current order with status badges. Navigate with `j`/`k`, move sections up/down with `K`/`J`, press `<Enter>` to write the new order back to the parent document, `q` to cancel.

### Corkboard (`<leader>bc`)

Displays each section as a card showing its filename, status icon, word count, summary, and keywords. Cards above a separator line are in the manuscript; cards below are orphans.

- `j`/`k` — navigate between cards
- `m` — toggle move mode (card border changes to double-line when active)
- `K`/`J` in move mode — reorder cards; crossing the separator promotes/demotes a section to/from the manuscript
- `<Enter>` in move mode — write the new order to the parent document
- `<Enter>` in normal mode — open the section for editing
- `e` — edit the current card's summary inline
- `n` — create a new section
- `q` / `<Esc>` — close

### Focus mode (`<leader>bf`)

Position your cursor on an `{{< include sections/... >}}` line in the parent document (or on any file path in a section) and press `<leader>bf`. The referenced file opens in a centred float with a dimmed backdrop — no splits, no distractions. Press `<leader>bf` again or `q` to close and return to the parent.

### Word count (`<leader>biw`)

Counts prose words only: YAML front matter, HTML comment metadata blocks, and code fences are excluded. Shows total manuscript words and session words (words written since the current Neovim session started, or since the last reset).

In the word count float:
- `t` — set a manuscript word target (stored in `.binder.json`)
- `s` — set a session word target
- `r` — reset the session counter

Progress bars appear automatically once targets are set.

---

## Zotero integration (`<leader>fz`)

`<leader>fz` opens a Telescope picker backed by a Better BibTeX automatic export of your Zotero library. Selecting an entry does two things:

1. Inserts `@citekey` at the cursor in the current buffer.
2. Appends the full BibTeX entry to the project's `references.bib` file (located by reading `bibliography:` from the document's YAML front matter or the project's `_quarto.yml`). If `references.bib` does not yet exist, you are prompted to create it. If the entry is already present, nothing is appended.

Because entries come directly from the BBT export file, field names are already proper BibTeX (`journal`, `author`, `address`, etc.) — no manual remapping is needed. The preview pane shows the full raw BibTeX entry so you can distinguish between duplicates or entries with incomplete metadata before selecting.

### Setup

**Better BibTeX** must be installed in Zotero. Configure an automatic export of your whole library:

- Zotero → Tools → Better BibTeX → Automatic Export
- Format: **BibTeX**
- Output file: `~/home/zotero-plugins/zotero-library.bib` (or the platform path that maps to it)

The picker reads from `~/home/zotero-plugins/zotero-library.bib`. If that file is not found, a warning is shown in the status bar with the expected path.

### WSL note

On WSL, create a symlink from the WSL path to the Windows export location rather than symlinking directly to the Zotero SQLite databases (SQLite requires POSIX file locks which NTFS does not support; plain `.bib` files have no such constraint):

```bash
mkdir -p ~/home/zotero-plugins
ln -s /mnt/c/Users/<you>/home/zotero-plugins/zotero-library.bib ~/home/zotero-plugins/zotero-library.bib
```

### Reverting to the SQLite-based picker

The original `telescope-zotero` SQLite-backed implementation is preserved as a commented-out block in `lua/plugins/ui.lua`. To restore it, uncomment the block inside the `jmbuhr/telescope-zotero.nvim` config function, remove the `zotero_bib_picker` function from the telescope config, and re-enable `telescope.load_extension 'zotero'`.

## Screenshots

![image](https://user-images.githubusercontent.com/17450586/210392419-3ee2b3e3-e805-4e36-99ab-6922abe3a66b.png)
![image](https://user-images.githubusercontent.com/17450586/210392573-57c0ad1c-5db0-4f2a-9119-608bd2398494.png)

Use the integrated neovim terminal to execute code chunks:

![image](https://user-images.githubusercontent.com/17450586/211403680-c60e8e89-ea9b-48bd-881d-37df2bc924a3.png)


