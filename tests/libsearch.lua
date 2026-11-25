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

-- Several picks: one citation, a work's pages merged and sorted, order of
-- first pick kept, a work with no printed page cited bare.
local function pk(b, cite_)
  return { book = b, hit = { cite = cite_ } }
end
local b2 = { citekey = 'braudel1972', title = 'The Mediterranean' }
local b3 = { citekey = 'setton1984', title = 'The Papacy' }
local nokey = { citekey = vim.NIL, title = 'Anonymous' }
local c, keys, notes = libsearch.citations { pk(book, 'p. 66'), pk(b2, 'p. 12'), pk(book, 'p. 3'), pk(book, 'p. 66') }
check('merge: cite', c, '[@gurkan2014, pp. 3, 66; @braudel1972, p. 12]')
check('merge: keys', keys, { 'gurkan2014', 'braudel1972' })
check('merge: no notes', notes, {})
c, keys, notes = libsearch.citations { pk(b3, 'PDF p. 9'), pk(book, 'p. xiv'), pk(book, 'p. ix'), pk(nokey, 'p. 1') }
check('bare and roman', c, '[@setton1984; @gurkan2014, pp. xiv, ix]')
check('bare and roman: keys', keys, { 'setton1984', 'gurkan2014' })
check('bare and roman: notes', #notes, 2)
c, keys = libsearch.citations { pk(book, 'PDF p. 1'), pk(book, 'p. 5') }
check('known page beats unknown', c, '[@gurkan2014, p. 5]')
check('single pick', (libsearch.citations { pk(book, 'p. 66') }), '[@gurkan2014, p. 66]')
c, keys, notes = libsearch.citations { pk(nokey, 'p. 1') }
check('no citekey at all', { c, keys, #notes }, { nil, {}, 1 })

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

-- Views: a hit's `type` (from zot's Jev) puts it in one; 'all' has every hit.
local typed = vim.deepcopy(book)
typed.hits[1].type, typed.hits[2].type = 'secondary', 'notes'
local result = { question = 'q', books = { typed } }
check(
  'view: notes',
  vim.tbl_map(function(e)
    return e.hit.unit
  end, libsearch.entries(result, 'notes')),
  { 133 }
)
check('view: all', #libsearch.entries(result, 'all'), 2)
check('views with hits', libsearch.views(result), { 'all', 'secondary', 'notes' })
check('views without types', libsearch.views { question = 'q', books = { book } }, { 'all' })
check('open args in a view: only its hits', libsearch.open_args(typed, typed.hits[2], 'notes')[10], '133.0-')
check('open args in all', libsearch.open_args(typed, typed.hits[2], 'all')[10], '65.2-66.0,133.0-')

if failures > 0 then
  print(failures .. ' failure(s)')
  os.exit(1)
end
print 'ok'
