"""First mentions of people across a manuscript (config/people.lua, <leader>bp).

Names are runs of proper nouns from the be-verbs parse (beverbs.NLP), joined
across particles ("Anne de Montmorency", "Henry of Navarre") and followed by
a regnal numeral ("Francis I", which spaCy tags as a pronoun). spaCy's small
model is poor at early-modern names, so its entity recognizer only helps
decide which names are people: a name counts if any mention of it is tagged
PERSON, carries a title ("King", "Cardinal"), or has a particle or numeral.

A name's core is its tokens minus titles and particles. A short core inside
exactly one longer one ("Francis" in "Francis I") is the same person; inside
several ("Francis I", "Francis II") it is ambiguous. Reported:
  late       first mention is a short form; the full name comes later
  ambiguous  a short form that could be several people
  single     only ever one word, never given in full (bib surnames excluded)
"""

import re

PARTICLES = {"de", "du", "des", "d'", "d’", "la", "le", "van", "von", "der", "den", "of", "y", "da", "di", "del", "della", "dei", "dos", "das"}
TITLES = {
    "king", "queen", "emperor", "empress", "pope", "cardinal", "duke", "duchess", "constable", "admiral",
    "bishop", "archbishop", "prince", "princess", "sultan", "saint", "st", "st.", "sir", "lord", "lady",
    "marshal", "chancellor", "president", "count", "countess", "marquis", "baron", "dauphin", "dauphine",
    "abbot", "abbess", "father", "brother", "sister", "friar", "master", "madame", "monsieur", "mr", "mr.",
    "mrs", "mrs.", "dr", "dr.", "general", "captain", "governor", "ambassador", "elector", "landgrave",
    "margrave", "doge", "grand", "vizier", "pasha", "mademoiselle", "seigneur", "sieur", "maître", "frère",
}
ROMAN = re.compile(r"^(?=[IVX])X{0,2}(?:IX|IV|V?I{0,3})$")


def is_name(tok):
    return tok.pos_ == "PROPN" and tok.text[:1].isupper()


def name_spans(doc):
    """Proper-name runs in doc, as (start, end) token indices."""
    out, i, n = [], 0, len(doc)
    while i < n:
        if not is_name(doc[i]):
            i += 1
            continue
        j = i + 1
        while j < n:
            if is_name(doc[j]):
                j += 1
            elif doc[j].lower_ in PARTICLES and j + 1 < n and is_name(doc[j + 1]):
                j += 2
            else:
                break
        if j < n and ROMAN.match(doc[j].text) and doc[j - 1].whitespace_:
            j += 1
        out.append((i, j))
        i = j
    return out


def people(paras, scholars=frozenset()):
    import beverbs  # noqa: PLC0415 -- lazy: spaCy loads on first use

    ner = beverbs.NLP.get_pipe("ner")
    mentions = []  # (para, order, core, text, personish, place, name without titles)
    order = 0
    for p, doc in enumerate(beverbs.NLP.pipe(paras)):
        doc = ner(doc)
        ents = [(e.start, e.end, e.label_) for e in doc.ents]
        for start, end in name_spans(doc):
            toks = list(doc[start:end])
            titled = start > 0 and doc[start - 1].lower_ in TITLES
            while toks and toks[0].lower_ in TITLES:
                titled = True
                toks = toks[1:]
            core = tuple(t.text for t in toks if t.lower_ not in PARTICLES)
            if not core:
                continue
            labels = {lab for s, e, lab in ents if s < end and start < e}
            personish = "PERSON" in labels or titled or len(core) < len(toks) or bool(ROMAN.match(core[-1]))
            place = bool(labels & {"GPE", "LOC", "FAC", "NORP"})
            mentions.append((p, order, core, doc[start:end].text, personish, place, " ".join(t.text for t in toks)))
            order += 1

    by_core = {}
    for m in mentions:
        c = by_core.setdefault(m[2], {"mentions": [], "personish": False, "place": False})
        c["mentions"].append(m)
        c["personish"] |= m[4]
        c["place"] |= m[5]

    cores = list(by_core)
    sets = {c: set(c) for c in cores}
    supersets = {c: [f for f in cores if sets[c] < sets[f]] for c in cores}
    maximal = {c: [f for f in supersets[c] if not supersets[f]] for c in cores}

    def first(ms):
        return min(ms, key=lambda m: m[1])

    def entry(m, **more):
        return {"para": m[0], "text": m[3], **more}

    late, ambiguous, single = [], [], []
    persons = {}  # full core -> mentions of it and its unambiguous short forms
    for c in cores:
        fulls = maximal[c]
        if not fulls:
            persons.setdefault(c, []).extend(by_core[c]["mentions"])
        elif len(fulls) == 1:
            persons.setdefault(fulls[0], []).extend(by_core[c]["mentions"])
        elif by_core[c]["personish"] or any(by_core[f]["personish"] for f in fulls):
            ambiguous.append(entry(first(by_core[c]["mentions"]),
                                   candidates=sorted(by_core[f]["mentions"][0][6] for f in fulls),
                                   count=len(by_core[c]["mentions"])))

    for full, ms in persons.items():
        group = [c for c in cores if c == full or (len(maximal[c]) == 1 and maximal[c][0] == full)]
        if not any(by_core[c]["personish"] for c in group):
            continue
        if all(by_core[c]["place"] and not by_core[c]["personish"] for c in group):
            continue
        f = first(ms)
        if f[2] != full:
            full_first = first(by_core[full]["mentions"])
            late.append(entry(f, full=full_first[3], full_para=full_first[0], count=len(ms)))
        elif len(full) == 1 and full[0].lower() not in scholars:
            single.append(entry(f, count=len(ms)))

    late.sort(key=lambda e: e["para"])
    ambiguous.sort(key=lambda e: e["para"])
    single.sort(key=lambda e: -e["count"])
    return {"late": late, "ambiguous": ambiguous, "single": single}
