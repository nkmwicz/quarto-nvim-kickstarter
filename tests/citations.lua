-- Regression test for config/citations.lua, from the repo root:
--   nvim -u NONE --cmd 'set rtp^=.' -l tests/citations.lua
-- Exits 1 on any failure. Works in a temporary directory; touches nothing else.

local citations = require 'config.citations'

local failures = 0
local function check(name, got, want)
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

-- What counts as a citation (each expectation checked against Pandoc's parser).
local function keys(text)
  return vim.tbl_map(function(c)
    return c.key
  end, citations.find_citations(vim.split(text, '\n')))
end

for text, want in pairs {
  ['See @smith2000.'] = { 'smith2000' },
  ['^[@smith2000, p. 155.]'] = { 'smith2000' },
  ['[-@smith2000; @jones1999]'] = { 'smith2000', 'jones1999' },
  ['@{smith2000}'] = { 'smith2000' },
  ['@smith2000: yes'] = { 'smith2000' },
  ['@a.b and @c:d and @e-'] = { 'a.b', 'c:d', 'e' },
  ['@abou-el-haj1969 argues'] = { 'abou-el-haj1969' },
  ['“@smith2000” and @smith2000’s claim'] = { 'smith2000', 'smith2000' },
  ['*@smith2000*'] = { 'smith2000' },
  ['@éluard1950'] = { 'éluard1950' },
  ['mail x@smith2000 or a.@smith2000 or \\@smith2000'] = {},
  ['@fig-map and [@tbl-counts]'] = {},
  ['`@code` and ``@more ` code``'] = {},
  ['{{< include @x.qmd >}}'] = {},
  ['https://medium.com/@someone and [t](https://x.y/@z)'] = {},
  ['<!-- @hidden --> @shown'] = { 'shown' },
  ['(@label) an example-list item'] = {},
  ['    @indented'] = {},
  ['---\nnocite: |\n  @smith2000\n---\n@jones1999'] = { 'jones1999' },
  ['<!--\nstatus: draft @x\n-->\n---\nnocite: "@y"\n---\n@z'] = { 'z' },
  ['```{python}\n@decorator\n```\n@after'] = { 'after' },
  ['~~~\n@decorator\n~~~\n@after'] = { 'after' },
  ['before <!-- open\n@inside\nclose --> @after'] = { 'after' },
} do
  check('citations in: ' .. text, keys(text), want)
end

-- Columns: 0-based, end exclusive, covering the @, past multi-byte text.
check('span', citations.find_citations { 'é ^[@ab, p. 1]' }[1], { key = 'ab', lnum = 0, col = 5, end_col = 8 })

-- Finding bibliographies.
local root = vim.fn.tempname()
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(root .. '/' .. path), 'p')
  vim.fn.writefile(lines, root .. '/' .. path)
end
local function buffer(path, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, root .. '/' .. path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  return buf
end
local function bibs(path, lines)
  return vim.tbl_map(function(p)
    return p:sub(#root + 2)
  end, citations.bibliographies(buffer(path, lines)))
end

root = vim.fs.normalize(root)
write('_quarto.yml', { '# bibliography: wrong.bib', 'project:', '  type: website', 'bibliography: ./refs.bib' })
write('sub/sections/.keep', {})
check('project bib, relative to the root from a subdirectory', bibs 'sub/sections/a.qmd', { 'refs.bib' })
check(
  'document bib, relative to the document',
  bibs('sub/b.qmd', { '<!-- status: draft -->', '---', 'title: x', 'bibliography: own.bib', '---' }),
  { 'sub/own.bib' }
)
check('list of bibs', bibs('c.qmd', { '---', 'bibliography:', '  - "one.bib"', '  - two.bib', '---' }), { 'one.bib', 'two.bib' })
check('inline list of bibs', bibs('d.qmd', { '---', 'bibliography: [one.bib, two.bib]', '---' }), { 'one.bib', 'two.bib' })
write('sub/_metadata.yml', { 'bibliography: meta.bib' })
check('_metadata.yml beats _quarto.yml', bibs 'sub/sections/e.qmd', { 'sub/meta.bib' })
vim.fn.delete(root .. '/sub/_metadata.yml')

-- Adding entries: an exact key match, whatever is in the key.
local bib = root .. '/refs.bib'
local function count(key)
  local n = 0
  for _, line in ipairs(vim.fn.readfile(bib)) do
    if line == '@book{' .. key .. ',' then
      n = n + 1
    end
  end
  return n
end
local function add(key)
  citations.add_to_bibliography(buffer(('sub/sections/add%d.qmd'):format(vim.uv.hrtime())), {
    key = key,
    raw = '@book{' .. key .. ',\n  title = {T},\n}\n\n',
  })
end

vim.fn.writefile({ '@book{BBCRadio4a,', '  title = {T},', '}' }, bib, 'b') -- no final newline
add 'BBCRadio4'
check('a key inside another key is still added', count 'BBCRadio4', 1)
check('and the last line kept its own line', count 'BBCRadio4a', 1)
add 'abou-el-haj1969'
add 'abou-el-haj1969'
check('a hyphenated key is added once', count 'abou-el-haj1969', 1)

-- Undefined citations.
local function warnings(lines)
  local buf = buffer(('sub/sections/w%d.qmd'):format(vim.uv.hrtime()), lines)
  vim.bo[buf].filetype = 'quarto'
  citations.check(buf)
  return vim.tbl_map(function(d)
    return d.user_data.key
  end, vim.diagnostic.get(buf))
end
check('only missing keys warn', warnings { '@BBCRadio4 and @nope and @fig-map' }, { 'nope' })
check('inline references: stay quiet', warnings { '---', 'references:', '  - id: nope', '---', '@nope' }, {})

vim.fn.delete(root, 'rf')
if failures > 0 then
  print(failures .. ' failed')
  os.exit(1)
end
print 'ok'
