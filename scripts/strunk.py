"""Strunk & White hints for grammalecte_bridge.py, run by beverbs.check on
the same spaCy parse as the be-verbs (so imported lazily with them).

Rules, by their number in The Elements of Style (ignorable by id like any
Grammalecte rule):
  PARENTHETIC_COMMA  3   "My brother, a soldier came home"     -> add the comma
  COMMA_SPLICE       5   "It is nearly dark, we cannot reach town" -> ";" / "." / ", and"
  DANGLING_MODIFIER  11  "Walking home, the rain began"
  NEGATIVE_FORM      15  "was not honest" -> "was dishonest", "did not remember" -> "forgot"
  NOMINALIZATION     16  "made a decision" -> "decided"
  VAGUE_VERB         16  "got", "made", "did"...               -> troponym picker
  WEAK_ENDING        22  "The treaty failed, of course."       -> "Of course, the treaty failed."

Each is a heuristic over a small statistical parse, tuned to miss rather
than nag: a rule stays quiet unless the parse shows the pattern plainly.
Nothing inside quotation marks is checked -- quoted sources are someone
else's prose -- nor inside parentheses, often clipped notes ("(beta = -0.17,
p = 0.31)").

A fix is either the be-verb troponym fix (VAGUE_VERB, via the "suggest"
op) or {"choices": [{"text", "note"[, "start", "end"]}]}: text replaces the
hint's span, or the start..end char range when given (the bridge turns
those into line/column).
"""

import re

from beverbs import WORDNET, LIGHT_VERBS, NOMINAL_SUFFIXES, end, inflect, nominal_verbs, passive_fix, quoted, word_near

SUBJECTS = {"nsubj", "nsubjpass", "expl", "csubj", "csubjpass"}
WH_TAGS = {"WDT", "WP", "WP$", "WRB"}

# Verbs that introduce speech or thought: "he came home, I think" and
# "the war, he said, was over" aren't splices.
REPORTING = {
    "say", "think", "believe", "suppose", "guess", "know", "hope", "fear", "imagine", "write",
    "note", "claim", "argue", "suggest", "report", "tell", "reply", "answer", "add", "insist",
    "admit", "remark", "observe", "complain", "explain", "declare", "warn", "ask", "wonder",
}  # fmt: skip

# Conjunctive adverbs and stock interrupters S&W want set off by commas.
# Kept short: "therefore", "thus", "indeed" often go without.
MARKERS = [
    ("however",), ("moreover",), ("nevertheless",), ("nonetheless",), ("furthermore",),
    ("of", "course"), ("for", "example"), ("for", "instance"), ("in", "fact"),
    ("on", "the", "other", "hand"), ("in", "other", "words"),
]  # fmt: skip

# What a sentence shouldn't trail off on, after a comma.
WEAK_ENDINGS = [
    ("however",), ("though",), ("too",), ("perhaps",), ("then",), ("therefore",), ("nevertheless",),
    ("indeed",), ("certainly",), ("apparently",), ("obviously",), ("clearly",), ("generally",),
    ("of", "course"), ("in", "fact"), ("as", "well"), ("at", "least"), ("after", "all"),
    ("for", "example"), ("for", "instance"), ("in", "general"), ("in", "particular"),
    ("in", "my", "opinion"), ("in", "my", "view"), ("so", "to", "speak"),
    ("i", "think"), ("i", "believe"), ("it", "seems"), ("it", "appears"),
]  # fmt: skip
# Looked up by a token's first/last word, not tried at every token.
MARKERS_BY_FIRST = {}
for _phrase in MARKERS:
    MARKERS_BY_FIRST.setdefault(_phrase[0], []).append(_phrase)
WEAK_LAST_WORDS = {phrase[-1] for phrase in WEAK_ENDINGS}
CLAUSE_ENDINGS = {("i", "think"), ("i", "believe"), ("it", "seems"), ("it", "appears")}
# Mean something else up front ("Though, ...", "Then, ..."): hinted, not moved.
STAY_ENDINGS = {("though",), ("too",), ("then",), ("as", "well")}

# Openers of a participial phrase: "While walking...", "After reading...".
PARTICIPLE_OPENERS = {"after", "before", "by", "in", "on", "upon", "since", "through", "when", "while", "without"}
# Participles grown into prepositions, fine dangling: "Considering the cost, ...".
STOCK_PARTICIPLES = {
    "accord", "assume", "bar", "base", "compare", "concern", "consider", "exclude", "fail",
    "follow", "give", "grant", "include", "judge", "own", "provide", "regard", "speak", "suppose",
}  # fmt: skip
ANIMATE_LEXFILES = {"noun.person", "noun.animal", "noun.group"}
# "Having read the dispatches, the alliance appears...": a research act on
# an observer's verb, whose doer is the author.
RESEARCH_LEXFILES = {"verb.cognition", "verb.perception"}
OBSERVED_VERBS = {"appear", "seem", "look", "emerge", "prove"}

# "did not X" -> one positive verb. A list rather than WordNet's antonyms,
# which turn "did not go to Paris" into "came" and "did not live" into "died".
VERB_ANTONYMS = {
    "remember": ["forget"], "include": ["exclude"], "like": ["dislike"], "agree": ["disagree"],
    "accept": ["reject", "refuse"], "succeed": ["fail"], "obey": ["disobey"], "trust": ["distrust"],
    "believe": ["doubt", "disbelieve"], "approve": ["disapprove"], "allow": ["forbid", "refuse"],
    "permit": ["forbid"], "admit": ["deny"], "have": ["lack"], "notice": ["overlook", "miss"],
    "consider": ["ignore", "overlook"], "heed": ["ignore"], "favor": ["oppose"], "favour": ["oppose"],
    "support": ["oppose"], "attend": ["miss", "skip"],
}  # fmt: skip
DO_TAG = {"did": "VBD", "does": "VBZ", "do": "VBP"}
UNCONTRACT = {"ca": "can", "wo": "will", "sha": "shall"}  # "can't" is "ca" + "n't"


# General verbs with more specific troponyms. Not "go"/"come": a historian's
# "went to Rome" is concrete enough.
VAGUE_VERBS = {"do", "get", "make", "put", "take", "give", "deal"}


def prev_word(doc, i):
    """The nearest non-space token before i, or None."""
    i -= 1
    while i >= 0 and doc[i].is_space:
        i -= 1
    return doc[i] if i >= 0 else None


def next_word(doc, i):
    i += 1
    while i < len(doc) and doc[i].is_space:
        i += 1
    return doc[i] if i < len(doc) else None


def capitalize(s):
    return s[:1].upper() + s[1:]



def match_phrase(sent, i, phrases):
    """The phrase from phrases starting at sentence token i, as (a, b) token
    indices, or None. phrases maps a first word to its phrases."""
    for phrase in phrases.get(sent.doc[i].lower_, ()):
        toks = sent.doc[i : i + len(phrase)]
        if i + len(phrase) <= sent.end and tuple(t.lower_ for t in toks) == phrase:
            return i, i + len(phrase) - 1
    return None


def choice(text, note, start=None, stop=None):
    c = {"text": text, "note": note}
    if start is not None:
        c.update(start=start, end=stop)
    return c


# --- 3: parenthetic expressions --------------------------------------------


def parenthetic(sent, q):
    doc = sent.doc
    # Appositives, non-restrictive relatives and adverbial clauses between
    # a subject and its verb, with a comma on one side only. Neither side
    # may be restrictive ("my brother John came"), so that's left alone.
    for verb in sent:
        for subj in (c for c in verb.children if c.dep_ in ("nsubj", "nsubjpass") and c.i < verb.i):
            inner = [x for x in subj.children if x.i > subj.i and x.dep_ == "appos"]
            inner += [
                x
                for x in subj.children
                if x.dep_ == "relcl" and any(t.tag_ in WH_TAGS and t.lower_ != "that" for t in list(x.subtree)[:2])
            ]
            inner += [x for x in verb.children if x.dep_ == "advcl" and subj.i < x.i < verb.i]
            for x in inner:
                a, b = x.left_edge, x.right_edge
                while b.i > a.i and (b.is_punct or b.is_space or b.dep_ == "cc"):
                    b = doc[b.i - 1]  # the parse ran on to the next comma or "and"
                before, after = prev_word(doc, a.i), next_word(doc, b.i)
                if b.i >= verb.i or before is None or after is None or any(q[a.i : b.i + 1]):
                    continue
                if any(c in t.text for t in doc[a.i : b.i + 1] for c in "()[]^"):
                    continue  # ran into a footnote or an aside
                # Only where the parse is plainly right: the verb (or its
                # auxiliary) comes straight after.
                if after.i != verb.i and not (after.head.i == verb.i and after.dep_ in ("aux", "auxpass", "neg", "advmod")):
                    continue
                # The parse may cut the phrase short; a comma anywhere
                # between it and the subject (or verb) still encloses it.
                opened = any(t.text == "," for t in doc[subj.i + 1 : a.i])
                closed = any(t.text == "," for t in doc[b.i + 1 : verb.i])
                if opened == closed:
                    continue
                at = end(b) if opened else end(before)
                side = "after" if opened else "before"
                yield (
                    "PARENTHETIC_COMMA",
                    a.idx,
                    end(b),
                    f'parenthetic (S&W 3): "{doc[a.i : b.i + 1].text}" needs a comma {side} it too',
                    {"choices": [choice(",", f"add the comma {side}", at, at)]},
                )
    # "however", "of course"...: set off on both sides (after, at the start).
    i = sent.start
    while i < sent.end:
        m = match_phrase(sent, i, MARKERS_BY_FIRST)
        if not m:
            i += 1
            continue
        a, b = doc[m[0]], doc[m[1]]
        i = b.i + 1
        before, after = prev_word(doc, a.i), next_word(doc, b.i)
        first = before is None or before.i < sent.start
        if after is None or after.i >= sent.end or after.is_punct and after.text not in (",", ";") or q[a.i]:
            continue  # trailing: WEAK_ENDING's business
        if a.lower_ == "however" and (after.pos_ in ("ADJ", "ADV") or first and after.pos_ == "PRON"):
            continue  # "however hard he tried", "However you look at it"
        if not first and (before.dep_ in ("cc", "mark") or before.text in ("(", "—", "–")):
            continue  # "but in fact", "(of course"
        opened = first or before.text in (",", ";")
        closed = after.text in (",", ";")
        if opened and closed:
            continue
        # S&W: "If the interruption to the flow of the sentence is but
        # slight, the writer may safely omit the commas" -- "it nevertheless
        # provides". Not "however", which then reads as "in whatever way".
        if not first and not opened and not closed and a.lower_ != "however":
            continue
        phrase = doc[a.i : b.i + 1].text
        start = a.idx if opened else end(before)
        text = ("" if opened else ", ") + phrase + ("" if closed else ",")
        yield (
            "PARENTHETIC_COMMA",
            a.idx,
            end(b),
            f'parenthetic (S&W 3): "{phrase}" should be set off by commas',
            {"choices": [choice(text, "add the commas" if not (opened or closed) else "add the comma", start, end(b))]},
        )


# --- 5: comma splices ------------------------------------------------------


def has_subject(v):
    return any(c.dep_ in SUBJECTS and c.i < v.i for c in v.children)


def parenthetical(v, other):
    """Whether v is a bare reporting clause on the clause `other`: "he came
    home, I think", not "Braudel argues that..., his argument has been..."
    or "she knew that..., she said nothing", which report something else."""
    return v.lemma_ in REPORTING and not any(x.dep_ in ("ccomp", "dobj", "xcomp") and x.i != other.i for x in v.children)


def splices(sent, q):
    doc = sent.doc
    for c in sent:
        h = c.head
        if c.dep_ not in ("ccomp", "parataxis", "conj") or c.pos_ not in ("VERB", "AUX") or h.pos_ not in ("VERB", "AUX"):
            continue
        if not (has_subject(c) and has_subject(h)):
            continue
        if any(x.dep_ in ("cc", "preconj") for x in (*h.children, *c.children)):
            continue  # "I came, I saw, and I conquered"
        if c.dep_ != "conj" and (parenthetical(h, c) or parenthetical(c, h)):
            continue
        # spaCy may hang either clause off the other.
        if c.i < h.i:
            comma = next_word(doc, c.right_edge.i)
            nxt = comma and next_word(doc, comma.i)
            if nxt is None or nxt.i > h.i:
                continue
        else:
            nxt = c.left_edge
            if nxt.text == ",":  # the comma itself may hang on the clause
                nxt = next_word(doc, nxt.i)
            comma = prev_word(doc, nxt.i)
        if comma is None or comma.text != "," or q[comma.i] or comma.i < sent.start:
            continue
        lo, hi = min(c.left_edge.i, h.left_edge.i), max(c.right_edge.i, h.right_edge.i)
        if any(t.text in (".", "?", "!", ";") for t in doc[lo:hi]):
            continue  # one clause belongs to another sentence (footnotes confuse the split)
        if nxt.dep_ in ("cc", "mark") or nxt.tag_ in WH_TAGS:
            continue
        # S&W allow a comma between short clauses alike in form: "Man proposes, God disposes."
        inner = {t.i for t in c.subtree}
        words_c = sum(t.is_alpha for t in c.subtree)
        words_h = sum(t.is_alpha and t.i not in inner for t in h.subtree)
        if words_c <= 4 and words_h <= 4:
            continue
        gap = doc.text[end(comma) : nxt.idx]
        choices = [
            choice(";" + gap + nxt.text, "semicolon"),
            choice("." + gap + capitalize(nxt.text), "two sentences"),
        ]
        if nxt.pos_ != "ADV":
            choices.append(choice(", and" + gap + nxt.text, "comma and conjunction"))
        yield "COMMA_SPLICE", comma.idx, end(nxt), "comma splice (S&W 5): two independent clauses joined by a comma", {
            "choices": choices
        }


# --- 11: dangling participles ----------------------------------------------


def animate(tok, senses=3):
    """Whether tok could be the doer of an action, by its first `senses`
    WordNet senses. Proper nouns count: "Seeking allies, France turned to
    the Porte" is how history is written."""
    if tok.pos_ == "PRON":
        return tok.lower_ not in ("it", "this", "that", "these", "those", "there")
    if tok.pos_ == "PROPN":
        return True
    synsets = WORDNET.synsets(tok.lemma_.lower(), pos="n")[:senses]
    return not synsets or any(s.lexfile() in ANIMATE_LEXFILES for s in synsets)


def research(v, main):
    """Whether participle v is a research act on an observer's verb: there
    "alliance", "city" count by their usual sense, not as groups of people."""
    senses = WORDNET.synsets(v.lemma_.lower(), pos="v")[:1]
    return main.lemma_.lower() in OBSERVED_VERBS and bool(senses) and senses[0].lexfile() in RESEARCH_LEXFILES


def dangling(sent, q):
    doc = sent.doc
    comma = next((t for t in sent if t.text == ","), None)
    if comma is None or comma.i - sent.start < 2 or q[comma.i]:
        return
    opening = doc[sent.start : comma.i]
    roots = [t for t in opening if not t.is_space and not opening.start <= t.head.i < opening.end]
    if len(roots) != 1:
        return
    r = roots[0]
    main = r.head
    if r.tag_ in ("VBG", "VBN"):
        v = r
    elif r.lower_ in PARTICIPLE_OPENERS:
        v = next((c for c in r.children if c.dep_ == "pcomp" and c.tag_ == "VBG"), None)
    else:
        return
    if v is None or v.lemma_.lower() in STOCK_PARTICIPLES or any(c.dep_ in SUBJECTS for c in v.children):
        return  # absolute constructions ("The work done, we left") have their own subject
    auxes = [c for c in v.children if c.dep_ in ("aux", "auxpass") and c.lower_ in ("having", "being")]
    first = next(t for t in opening if not t.is_space)
    if first not in (v, *auxes) and not (first.lower_ in PARTICIPLE_OPENERS and first.i < v.i):
        return
    subj = next((c for c in main.children if c.dep_ in SUBJECTS and c.i > comma.i), None)
    if subj is None:
        return  # imperative: "Having read this, go home."
    # "Written in 1546, the letter..." is fine: a bare past participle
    # describes what's done to the subject, so only its being "it" dangles.
    active = v.tag_ == "VBG" or bool(auxes)
    if subj.lower_ in ("it", "there"):
        why = f'"{subj.text}" can\'t be its doer'
    elif active and not animate(subj, senses=1 if research(v, main) else 3):
        why = f'"{doc[subj.left_edge.i : subj.i + 1].text}" can\'t be its doer'
    else:
        return
    phrase = doc[first.i : comma.i]
    yield "DANGLING_MODIFIER", first.idx, end(prev_word(doc, comma.i)), f'dangling modifier (S&W 11): "{phrase.text.strip()}": {why}', None


# --- 15: positive form -----------------------------------------------------


def adjective_antonyms(lemma):
    out = []
    for pos in ("a", "s"):
        for sense in WORDNET.senses(lemma, pos=pos)[:3]:
            for ant in sense.get_related("antonym"):
                word = ant.word().lemma()
                if word not in out:
                    out.append(word)
    return out


def negatives(sent, q):
    doc = sent.doc
    if sent.text.rstrip().endswith("?"):
        return
    for neg in sent:
        if neg.dep_ != "neg" or neg.lower_ not in ("not", "n't", "n’t") or q[neg.i]:
            continue
        after = next_word(doc, neg.i)
        if after is None or after.lower_ in ("only", "just", "merely", "even", "un"):
            continue
        if any(t.lower_ in ("but", "rather", "instead") for t in doc[neg.i : sent.end]):
            continue  # S&W's own antithesis: "Not charity, but simple justice."
        h = neg.head
        prev = prev_word(doc, neg.i)
        glued = prev is not None and prev.whitespace_ == ""  # "wasn't", "cannot"
        prefix = UNCONTRACT.get(prev.lower_, prev.text) + " " if glued else ""
        start = prev.idx if glued else neg.idx
        if h.lemma_ == "be":
            comp = next((c for c in h.children if c.dep_ == "acomp" and c.pos_ == "ADJ"), None)
            if comp is None or comp.i != after.i:
                continue
            words = adjective_antonyms(comp.lemma_.lower())
            target = comp
        elif h.pos_ == "VERB" and h.i == after.i and h.lemma_ in VERB_ANTONYMS:
            if any(c.dep_ in ("xcomp", "ccomp", "prt") for c in h.children):
                continue  # "did not have to"
            do = next((c for c in h.children if c.dep_ == "aux" and c.lemma_ == "do" and c.i < neg.i), None)
            if do is not None:
                start, prefix, tag = do.idx, "", DO_TAG.get(do.lower_, "VBD")
            else:
                tag = h.tag_
            words = [inflect(w, tag) for w in VERB_ANTONYMS[h.lemma_]]
            target = h
        else:
            continue
        if not words:
            continue
        span = doc.text[start : end(target)]
        yield "NEGATIVE_FORM", start, end(target), f'negative form (S&W 15): "{span}" -> "{prefix + words[0]}"', {
            "choices": [choice(prefix + w, "positive form") for w in words]
        }


# --- 16: definite, specific, concrete --------------------------------------


def concrete(sent, q):
    doc = sent.doc
    for v in sent:
        if v.pos_ != "VERB" or q[v.i]:
            continue
        lemma = v.lemma_.lower()
        if any(c.dep_ in ("prt", "xcomp", "ccomp") for c in v.children):
            continue  # "give up", "made him leave", "got to know"
        be = next((c for c in v.children if c.dep_ == "auxpass"), None)
        if lemma in LIGHT_VERBS and be is not None:
            # "The decision was made by the king" -> "the king decided"
            fix = passive_fix(be, v, doc, q)
            nominal = [c for c in fix["choices"] if c["note"] == "the verb inside the noun"] if fix else []
            if nominal:
                subj = next(c for c in v.children if c.dep_ == "nsubjpass")
                span = doc.text[subj.left_edge.idx : end(v)]
                yield "NOMINALIZATION", subj.left_edge.idx, end(v), f'nominalization (S&W 16): "{span}"', {"choices": nominal}
                continue
        if lemma in LIGHT_VERBS:
            obj = next((c for c in v.children if c.dep_ == "dobj"), None)
            if obj is not None and obj.lower_.endswith(NOMINAL_SUFFIXES):
                between = [t for t in doc[v.i + 1 : obj.i] if not t.is_space]
                verbs = nominal_verbs(obj.lower_) if all(t.dep_ == "det" for t in between) else []
                if verbs:
                    stop = obj
                    after = next_word(doc, obj.i)
                    if after is not None and after.lower_ in ("of", "to"):
                        stop = after  # "gave consideration to the plan" -> "considered the plan"
                    span = doc.text[v.idx : end(stop)]
                    yield "NOMINALIZATION", v.idx, end(stop), f'nominalization (S&W 16): "{span}"', {
                        "choices": [choice(inflect(w, v.tag_), "the verb inside the noun") for w in verbs]
                    }
                    continue
        if lemma in VAGUE_VERBS:
            if v.dep_ in ("amod", "acl", "prep", "pcomp", "advcl") and v.tag_ in ("VBN", "VBG"):
                continue  # "a given year", "given that", "taking stock,"
            if v.tag_ == "VBN" and not any(c.dep_ == "aux" and c.lemma_ == "have" for c in v.children):
                continue  # passives are BE_PASSIVE's
            yield "VAGUE_VERB", v.idx, end(v), f'vague verb (S&W 16): "{v.text}"', {
                "lemma": lemma,
                "tag": v.tag_,
                "between": "",
                "keep": False,
                "lc": word_near(doc, v.i, -1),
                "rc": word_near(doc, v.i, 1),
            }


# --- 22: emphatic words at the end -----------------------------------------


def weak_endings(sent, q):
    doc = sent.doc
    last = sent.end - 1
    while last >= sent.start and (doc[last].is_punct or doc[last].is_space):
        last -= 1
    if last < sent.start or doc[last].lower_ not in WEAK_LAST_WORDS:
        return
    for phrase in WEAK_ENDINGS:
        a = last - len(phrase) + 1
        if a <= sent.start or tuple(t.lower_ for t in doc[a : last + 1]) != phrase:
            continue
        comma = prev_word(doc, a)
        if comma is None or comma.text != "," or q[a]:
            return
        text = doc[a : last + 1].text
        first = doc[sent.start]
        while first.is_space:
            first = doc[first.i + 1]
        fix = None
        if first.is_alpha and first.i < comma.i and phrase not in STAY_ENDINGS:
            body = doc.text[first.idx : comma.idx]
            if not (first.pos_ == "PROPN" or first.text == "I" or first.is_upper and len(first) > 1):
                body = body[:1].lower() + body[1:]
            moved = capitalize(text) + (" " if phrase in CLAUSE_ENDINGS else ", ") + re.sub(r"\s+", " ", body)
            fix = {"choices": [choice(moved, "move it to the front", first.idx, end(doc[last]))]}
        yield "WEAK_ENDING", comma.idx, end(doc[last]), f'weak ending (S&W 22): "{text}" -- end on the emphatic words', fix
        return


def rules(doc):
    """Yields (rule, start, end, message, fix) for doc, as char offsets."""
    q = quoted(doc)
    for sent in doc.sents:
        for check in (parenthetic, splices, dangling, negatives, concrete, weak_endings):
            yield from check(sent, q)
