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


