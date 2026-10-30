-- The markdown parser is registered for quarto, rmd, pandoc… (here and in
-- quarto-nvim's ftplugin), and native `gc` picks a prose line's
-- commentstring from whichever of those filetypes `pairs()` yields last —
-- random per session. Vim's rmd ftplugin sets `# %s`, so quarto prose was
-- sometimes commented with `#`. R chunks still get `#` from their own
-- injected tree.
vim.bo.commentstring = '<!-- %s -->'
