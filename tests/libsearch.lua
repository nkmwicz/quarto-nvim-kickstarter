-- Regression test for config/libsearch.lua's pure parts, from the repo root:
--   nvim -u NONE --cmd 'set rtp^=.' -l tests/libsearch.lua
-- Exits 1 on any failure. Made-up JSON in zot -s --json's shape; runs nothing.

local libsearch = require 'config.libsearch'

local failures = 0
local function check(name, got, want)
  if not vim.deep_equal(got, want) then
    failures = failures + 1
    print(('FAIL %s\n  got:  %s\n  want: %s'):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local book = {
  item_key = 'ITEM1',
  attachment_key = 'ATT1',
  citekey = 'gurkan2014',
  hits_arg = '65.2-66.0,133.0-',
  title = 'My Money or Your Life',
  authors = { 'Emrah Safa Gürkan' },
  year = '2014',
  hits = {
    { cite = 'p. 66', unit = 65, para = 2, score = 0.74, text = 'Uluç Ali, a self-made frontier man' },
    { cite = 'PDF p. 134', unit = 133, para = 0, score = 0.61, text = 'Far-away Istanbul' },
  },
}
local other = vim.deepcopy(book)
other.citekey, other.hits = vim.NIL, { book.hits[1] }

-- One entry per hit, best book first, each book's hits in order.
local entries = libsearch.entries { question = 'q', books = { book, other } }
check(
  'entries',
  vim.tbl_map(function(e)
    return { e.book.item_key, e.hit.unit }
  end, entries),
  { { 'ITEM1', 65 }, { 'ITEM1', 133 }, { 'ITEM1', 65 } }
)
check('no books', libsearch.entries { question = 'q', books = {} }, {})

-- A printed page is cited; the file's own page never is.
check('printed page', { libsearch.citation(book, book.hits[1]) }, { '[@gurkan2014, p. 66]' })
local cite, why = libsearch.citation(book, book.hits[2])
check('pdf page: bare citekey', cite, '[@gurkan2014]')
check('pdf page: says why', why ~= nil and why:match 'PDF p%. 134' ~= nil, true)
check('roman page', libsearch.citation(book, { cite = 'p. xiv' }), '[@gurkan2014, p. xiv]')
check('no citekey', libsearch.citation(other, other.hits[1]), nil)

-- zot --open at the hit, with the book's hits.
check('open args', libsearch.open_args(book, book.hits[1]), {
  '--open',
  'ITEM1',
  '--attachment',
  'ATT1',
  '--page',
  '66',
  '--para',
  '2',
  '--hits',
  '65.2-66.0,133.0-',
})

if failures > 0 then
  print(failures .. ' failure(s)')
  os.exit(1)
end
print 'ok'
