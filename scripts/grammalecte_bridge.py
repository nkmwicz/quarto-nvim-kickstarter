"""Grammalecte bridge for lua/config/grammalecte.lua.

Long-running: reads one JSON request per line on stdin, writes one JSON
response per line on stdout. Only French text in the buffer is checked --
the manuscripts are English prose quoting French, and Grammalecte run over
English flags nearly every line.

Request:  {"id": n, "text": "<whole buffer>", "french": bool,
           "ignore": ["rule_id", ...]}
Response: {"id": n, "errors": [{"lnum", "col", "end_lnum", "end_col",
           "rule", "message", "suggestions"}]}   (0-based, byte columns)

The same process also serves the be-verb, Strunk & White and style
hints (beverbs.py, strunk.py and style.py, imported on first use; see config/beverbs.lua),
answered from a worker thread so a
slow parse never holds up Grammalecte -- responses can come back out of
order, matched by id:
  {"id", "op": "beverbs", "text", "ignore", "bib": [".bib paths"]}
      -> {"id", "errors": [... as above, with "fix" instead of "suggestions"]}
  {"id", "op": "suggest", "fix": {...}}  -> {"id", "suggestions": [...]}
  either -> {"id", "unavailable": "<why>"} when the prose venv is missing.

Which text counts as French:
  - the whole document, if it declares `lang: fr` ("french" in the
    request; grammalecte.lua's doc_lang decides)
  - `::: {lang=fr}` fenced divs and `[...]{lang=fr}` spans (Pandoc markup)
  - otherwise auto-detected: quotations, *italic* titles, and sentences
    whose function words are mostly French

Grammalecte's spellchecker is never used (Neovim's spelllang=en,fr does
spelling, and it would flag every early-modern spelling). French embedded
in English prose follows English typography, so typography rules only run
in `lang: fr` documents.

Ignore directives (HTML comments, so invisible in rendered output):
  <!-- grammalecte:ignore -->              whole line
  <!-- grammalecte:ignore RULE ... -->     those rules on this line
  <!-- grammalecte:ignore-file -->         whole file
  <!-- grammalecte:ignore-file RULE ... -->  those rules in this file
A line directive applies to the line it's on, or to the next line if it
stands alone on its own line. Be-verb, Strunk and style rules are only ignored by
name: a bare directive, usually there to quiet a French quotation, leaves
the English around it hinted.
"""

import json
import os
import queue
import re
import sys
import threading

try:
    import grammalecte
except ImportError as e:
    print(json.dumps({"error": f"cannot import grammalecte ({e}); sudo apt install python3-grammalecte"}), flush=True)
    sys.exit(1)

gce = grammalecte.GrammarChecker("fr").getGCEngine()

# parse(dOptions=...) replaces the option set rather than merging, so both
# sets start from the defaults.
# Always off: whitespace (Markdown wrapping/indentation), apostrophes (Pandoc
# smartens them), inclusive-writing suggestions (anachronistic here).
BASE_OFF = dict(gce.getDefaultOptions(), esp=False, tab=False, apos=False, eepi=False)
# Also off for French embedded in English: typography, capitalisation and
# number formatting follow the host language.
EMBEDDED_OFF = dict(BASE_OFF, typo=False, nbsp=False, unit=False, num=False, maj=False, minis=False, nf=False)

FR_WORDS = set(
    "le la les des du de un une et est que qui ne pas dans pour par sur au aux ce cette ces ceste son sa ses "
    "il elle ils nous vous je leur leurs avec sont ont été esté fait faict roy plus mais ou où en y".split()
)
EN_WORDS = set("the of and to in that is was for with as his he by it be this are were from had which on at an their they not but have".split())
WORD_RE = re.compile(r"[^\W\d_]+(?:'[^\W\d_]+)?")


def looks_french(s):
    words = [w.lower() for w in WORD_RE.findall(s)]
    if len(words) < 4:
        return False
    fr = sum(w in FR_WORDS for w in words)
    en = sum(w in EN_WORDS for w in words)
    return fr >= 2 and fr > 2 * en


def blank(m):
    """Replacement that keeps offsets: every non-newline char becomes a space."""
    return re.sub(r"[^\n]", " ", m.group())


# Markup that is never prose. Masked (not removed) so offsets stay valid.
MASKS = [
    re.compile(r"^(```|~~~).*?^\1[^\n]*$", re.S | re.M),  # code cells
    re.compile(r"<!--.*?-->", re.S),  # binder/research metadata, harper:ignore
    re.compile(r"\{\{<.*?>\}\}", re.S),  # Quarto shortcodes
    re.compile(r"`[^`\n]+`"),  # inline code
    re.compile(r"\$\$.*?\$\$|\$[^$\n]+\$", re.S),  # math
    re.compile(r"\[[^\]\n]*@[^\]\n]*\]|@[\w:.-]+"),  # citations
    re.compile(r"\]\([^)\n]*\)"),  # link targets
    re.compile(r"\[\^[^\]\n]*\]"),  # footnote refs
    re.compile(r"https?://\S+"),
    re.compile(r"^[ \t]*(?:[-*+]|\d+[.)]|>+|#+)[ \t]+", re.M),  # list/quote/heading markers
]

DIRECTIVE = re.compile(r"<!--\s*grammalecte:(ignore-file|ignore)\b(.*?)-->")
FRONT_MATTER = re.compile(r"\A---\n.*?\n(?:---|\.\.\.)\n", re.S)
INLINE_SPAN = re.compile(r"\[([^\]\n]+)\]\{[^}\n]*\blang=\"?fr[\w-]*\"?[^}\n]*\}")
DIV_FENCE = re.compile(r"^(:{3,})[ \t]*(\S.*)?$", re.M)
QUOTED = re.compile(r'"([^"\n]+)"|“([^”]+)”|«([^»]+)»|(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!\w)_([^_\n]+)_(?!\w)')
SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def french_spans(text, doc_french):
    """Returns (masked_text, [(start, end, options)]) in character offsets."""
    fm = FRONT_MATTER.match(text)
    if fm:
        text = blank(fm) + text[fm.end() :]

    spans = []
    # Explicit [..]{lang=fr} spans: record the inner text, and keep it out of
    # auto-detection (`auto` is the text that auto-detection sees).
    for m in INLINE_SPAN.finditer(text):
        spans.append((m.start(1), m.end(1), EMBEDDED_OFF))
    auto = INLINE_SPAN.sub(blank, text)
    # In the checked text, mask just the brackets and attribute block.
    text = INLINE_SPAN.sub(lambda m: " " + m.group(1) + " " * (len(m.group()) - len(m.group(1)) - 1), text)

    for rx in MASKS:
        text = rx.sub(blank, text)
        auto = rx.sub(blank, auto)

    if doc_french:
        return text, [(0, len(text), BASE_OFF)]

    # ::: {lang=fr} divs, with nesting. Fence lines are masked afterwards.
    stack, fr_ranges = [], []
    for m in DIV_FENCE.finditer(text):
        if m.group(2):
            stack.append((m.end(), "lang=fr" in m.group(2).replace('"', "")))
        elif stack:
            start, is_fr = stack.pop()
            if is_fr and not any(s <= start < e for s, e in fr_ranges):
                fr_ranges.append((start, m.start()))
    text = DIV_FENCE.sub(blank, text)
    auto = DIV_FENCE.sub(blank, auto)
    spans += [(s, e, EMBEDDED_OFF) for s, e in fr_ranges]
    for s, e in fr_ranges:
        auto = auto[:s] + re.sub(r"[^\n]", " ", auto[s:e]) + auto[e:]

    # Auto-detect in everything else, paragraph by paragraph.
    pos = 0
    for para in re.split(r"(\n[ \t]*\n)", auto):
        start = pos
        pos += len(para)
        if not para.strip():
            continue
        if looks_french(para) and not QUOTED.search(para):
            spans.append((start, start + len(para), EMBEDDED_OFF))
            continue
        for m in QUOTED.finditer(para):
            g = next(i for i in range(1, 6) if m.group(i) is not None)
            if looks_french(m.group(g)):
                spans.append((start + m.start(g), start + m.end(g), EMBEDDED_OFF))
        rest = QUOTED.sub(blank, para)
        off = 0
        for sent in SENTENCE_END.split(rest):
            i = rest.index(sent, off)
            off = i + len(sent)
            if looks_french(sent):
                spans.append((start + i, start + i + len(sent), EMBEDDED_OFF))
    return text, spans


def to_xy(text):
    """Char offset -> (0-based line, byte column) converter for `text`."""
    starts = [0] + [m.end() for m in re.finditer("\n", text)]

    def xy(off):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo, len(text[starts[lo] : off].encode())

    return xy


ALL = None  # line-ignore value meaning "every rule"


def ignores(rules, rule, style=False):
    """Whether an ignore set (or ALL) covers rule; ALL skips no style
    (be-verb, Strunk, style) rule."""
    return not style if rules is ALL else rule in rules


def directives(text):
    """Returns (file_ignore, line_ignores): file_ignore is ALL or a set of
    rule ids; line_ignores maps 0-based line -> ALL or a set of rule ids."""
    file_ignore, line_ignores = set(), {}
    lines = text.split("\n")
    for i, line in enumerate(lines):
        for m in DIRECTIVE.finditer(line):
            rules = set(m.group(2).split())
            if m.group(1) == "ignore-file":
                file_ignore = ALL if not rules or file_ignore is ALL else file_ignore | rules
                continue
            target = i + 1 if not DIRECTIVE.sub("", line).strip() else i
            prev = line_ignores.get(target, set())
            line_ignores[target] = ALL if not rules or prev is ALL else prev | rules
    return file_ignore, line_ignores


def check(text, doc_french, ignore):
    file_ignore, line_ignores = directives(text)
    if file_ignore is ALL:
        return []
    ignore = ignore | file_ignore
    masked, spans = french_spans(text, doc_french)
    xy = to_xy(text)
    errors = []
    for start, end, opts in spans:
        chunk = masked[start:end].replace("\n", " ")
        for e in gce.parse(chunk, "FR", dOptions=opts):
            if e["sRuleId"] in ignore:
                continue
            lnum, col = xy(start + e["nStart"])
            if lnum in line_ignores and ignores(line_ignores[lnum], e["sRuleId"]):
                continue
            end_lnum, end_col = xy(start + e["nEnd"])
            errors.append(
                {
                    "lnum": lnum,
                    "col": col,
                    "end_lnum": end_lnum,
                    "end_col": end_col,
                    "rule": e["sRuleId"],
                    "message": e["sMessage"],
                    "suggestions": e["aSuggestions"],
                }
            )
    return errors


METADATA = re.compile(r"\A\s*(?:---\n.*?\n(?:---|\.\.\.)\n|<!--.*?-->)", re.S)


def section_keywords(text):
    """Lowercase words of the `keywords:` in the first metadata block (YAML
    front matter or binder's comment), as "a, b" or a YAML list."""
    m = METADATA.match(text)
    if not m:
        return frozenset()
    k = re.search(r"^keywords:[ \t]*(.*(?:\n[ \t]*-[ \t].*)*)", m.group(), re.M)
    return frozenset(re.findall(r"[^\W\d_]+", k.group(1).lower())) if k else frozenset()


def frequent_words(text):
    """The document's subject matter: words (and their -s-less forms) used
    at least 6 times and in 0.3% of all words."""
    counts = {}
    found = re.findall(r"[^\W\d_]{4,}", text.lower())
    for w in found:
        for form in {w, w.removesuffix("s")}:
            counts[form] = counts.get(form, 0) + 1
    least = max(6, 0.003 * len(found))
    return frozenset(w for w, n in counts.items() if n >= least)


BIB_ENTRY = re.compile(r"^@\w+\s*\{\s*([^,\s]+)\s*,(.*?)(?=^@|\Z)", re.S | re.M)
BIB_NAMES = re.compile(r"^\s*(?:author|editor)\s*=\s*[{\"](.*?)[}\"]\s*,?\s*$", re.M | re.I)
NARRATIVE_CITE = re.compile(r"(?<![\w@\[-])@([\w:.-]*\w)")
bib_cache = {}  # path -> (mtime, {citekey: first surname}, {surnames})


def read_bib(path):
    """A .bib file's citekeys -> first author's surname, and every author's
    and editor's surname (lowercase): the secondary literature's scholars."""
    try:
        mtime = os.path.getmtime(path)
        if path in bib_cache and bib_cache[path][0] == mtime:
            return bib_cache[path][1:]
        with open(path, encoding="utf-8") as f:
            data = f.read()
    except OSError:
        return {}, set()
    keys, names = {}, set()
    for key, body in BIB_ENTRY.findall(data):
        for field in BIB_NAMES.findall(body):
            for person in re.split(r"\s+and\s+", field.replace("{", "").replace("}", "")):
                last = person.split(",")[0].strip() if "," in person else (person.split() or [""])[-1]
                if last and last.lower() != "others":
                    keys.setdefault(key, last)
                    names.add(last.lower())
    bib_cache[path] = (mtime, keys, names)
    return keys, names


def name_citations(text, masked, keys):
    """Writes a narrative citation's surname over its mask, "@jensenFrench1974
    argues" -> "Jensen argues", so the parse sees a subject (offsets kept).
    Returns the new text and the (lowercase) names written."""
    out, names = list(masked), set()
    for m in NARRATIVE_CITE.finditer(text):
        if masked[m.start() : m.end()].strip():
            continue  # not masked: an email address or the like
        name = keys.get(m.group(1)) or re.match(r"[a-z]*", m.group(1)).group().capitalize()
        if name and len(name) <= len(m.group()):
            out[m.start() : m.start() + len(name)] = name
            names.add(name.lower())
    return "".join(out), names


FOOTNOTE = re.compile(r"\^\[(?:[^\[\]]|\[[^\]]*\])*\]|^\[\^[^\]]+\]:.*$", re.M)
MODERN = re.compile(r"\b(?:18[5-9]\d|19\d\d|20\d\d)\b")
NAME = re.compile(r"\b[A-Z][\w’'-]+")


def modern_citations(text):
    """Capitalized words in footnote citations dated 1850 or later, as
    lowercase: likely scholars, but maybe the editor of a modern edition
    of a historical actor's work ("Bodin, ... (Paris: Fayard, 1986)")."""
    names = set()
    for note in FOOTNOTE.finditer(text):
        for part in note.group().split(";"):
            if MODERN.search(part):
                names |= {w.lower() for w in NAME.findall(part)}
    return names


def check_beverbs(text, ignore, bibs=()):
    import beverbs  # noqa: PLC0415 -- lazy, see the module docstring
    import strunk  # noqa: PLC0415
    import style  # noqa: PLC0415

    file_ignore, line_ignores = directives(text)
    ignore = ignore | (set() if file_ignore is ALL else file_ignore)
    # English only: blank out the French that Grammalecte would check.
    masked, spans = french_spans(text, False)
    for start, end, _ in spans:
        masked = masked[:start] + re.sub(r"[^\n]", " ", masked[start:end]) + masked[end:]
    # A line masked whole -- a comment or French between two lines of one
    # paragraph (semantic line breaks) -- would read as the blank line that
    # ends it: join it to the line above instead.
    joined, pos = list(masked), 0
    for i, line in enumerate(text.split("\n")):
        if i and line.strip() and not masked[pos : pos + len(line)].strip():
            joined[pos - 1] = " "
        pos += len(line) + 1
    masked = "".join(joined)
    xy = to_xy(text)
    errors = []
    exempt = section_keywords(text) | frequent_words(masked)
    keys, scholars = {}, set()
    for path in bibs:
        k, n = read_bib(path)
        keys.update(k)
        scholars |= n
    masked, cited = name_citations(text, masked, keys)
    scholars |= cited

    unsure = modern_citations(text) - scholars

    def style_rules(doc):
        return style.rules(doc, exempt, scholars, unsure)

    for rule, start, end, message, fix in beverbs.check(masked, strunk.rules, style_rules):
        lnum, col = xy(start)
        if rule in ignore or (lnum in line_ignores and ignores(line_ignores[lnum], rule, style=True)):
            continue
        end_lnum, end_col = xy(end)
        if fix and "choices" in fix:
            # A rewrite over masked text (a citation, comment, footnote
            # marker...) would delete it: drop those.
            fix["choices"] = [c for c in fix["choices"] if masked[c.get("start", start) : c.get("end", end)] == text[c.get("start", start) : c.get("end", end)]]
            if not fix["choices"]:
                fix = None
        for c in (fix or {}).get("choices", []):
            if "start" in c:
                c["lnum"], c["col"] = xy(c.pop("start"))
                c["end_lnum"], c["end_col"] = xy(c.pop("end"))
        errors.append(
            {
                "lnum": lnum,
                "col": col,
                "end_lnum": end_lnum,
                "end_col": end_col,
                "rule": rule,
                "source": "be-verb" if rule.startswith("BE_") else "style" if rule in style.RULES else "strunk",
                "message": message,
                "fix": fix,
            }
        )
    return errors


out_lock = threading.Lock()


def send(resp):
    with out_lock:
        print(json.dumps(resp, ensure_ascii=False), flush=True)


def serve(req):
    """Answers one request; never dies mid-session on one bad buffer."""
    resp = {"id": req.get("id") if isinstance(req, dict) else None}
    try:
        op = req.get("op", "grammar")
        if op == "grammar":
            resp["errors"] = check(req["text"], bool(req.get("french")), set(req.get("ignore", [])))
        elif op == "beverbs":
            resp["errors"] = check_beverbs(req["text"], set(req.get("ignore", [])), req.get("bib", []))
        elif op == "suggest":
            import beverbs  # noqa: PLC0415

            resp["suggestions"] = beverbs.suggest(req["fix"])
    except ImportError as e:  # prose venv missing (scripts/setup_prose_venv.sh)
        resp["unavailable"] = f"{e}; run {sys.path[0]}/setup_prose_venv.sh"
    except Exception as e:
        resp.update(errors=[], warning=repr(e))
    send(resp)


# Be-verb work, in order, off the main thread.
work = queue.Queue()


def worker():
    for req in iter(work.get, None):
        serve(req)


worker_thread = threading.Thread(target=worker)
worker_thread.start()

for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError as e:
        send({"id": None, "errors": [], "warning": repr(e)})
        continue
    if req.get("op") in ("beverbs", "suggest"):
        work.put(req)
    else:
        serve(req)

# Neovim closed stdin (or killed us); finish what's queued.
work.put(None)
worker_thread.join()
