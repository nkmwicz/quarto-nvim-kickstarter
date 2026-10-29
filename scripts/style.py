"""Clarity hints beyond Strunk & White for grammalecte_bridge.py, run by
beverbs.check on the same spaCy parse (so imported lazily with them), one
paragraph at a time. Mostly after Williams's Style: Lessons in Clarity and
Grace and Gopen & Swan's "The Science of Scientific Writing".

  VAGUE_THIS        "This shows that..."         -> "This refusal shows..."
  SUBJECT_VERB_GAP  a subject kept 15+ words from its verb
  NOUN_STACK        "sixteenth-century French diplomatic correspondence networks"
  OF_CHAIN          "the failure of the policy of the council of the city"
  ECHO              the same word (or its family: diplomacy, diplomatic)
                    three times in two sentences; the section's keywords
                    and its most frequent words are exempt, since the
                    subject matter is meant to recur
  QUOTE_ENDING      a paragraph whose last sentence is mostly quotation:
                    the source gets the last word, not the analysis
  REPORTING_TENSE   scholars argue, historical actors argued: "Mattingly
                    argued" -> "argues", "Bodin argues" -> "argued". A
                    scholar is a surname in the project's .bib or cited
                    narratively (@key argues); a name in a footnote citation
                    dated 1850+ is unsure (a scholar, or a modern edition's
                    author) and left alone; any other named person is a
                    historical actor; pronouns and common nouns are left
                    alone ("historians" may be sixteenth-century ones)

Like strunk.py's, tuned to miss rather than nag, and nothing inside
quotation marks or parentheses is checked (QUOTE_ENDING aside).
"""

from functools import cache

from beverbs import WORDNET, end, inflect, plural, quoted, verb_nouns
from strunk import SUBJECTS, choice

RULES = {"VAGUE_THIS", "SUBJECT_VERB_GAP", "NOUN_STACK", "OF_CHAIN", "ECHO", "QUOTE_ENDING", "REPORTING_TENSE"}

DEMONSTRATIVES = {"this", "that", "these", "those"}
GAP = 15  # words from the start of the subject to its verb
STACK_MODS = {"compound", "amod", "nmod", "npadvmod"}
OF_DEPTH = 3
ECHO_COUNT = 3  # occurrences, in a sentence and the one before it
# Words too common, or too much the subject matter, to count as echoes.
ECHO_SKIP = {
    "be", "have", "do", "say", "make", "take", "give", "go", "come", "become", "seem", "use",
    "other", "such", "many", "much", "more", "most", "first", "last", "new", "same", "own",
    "also", "only", "even", "well", "very", "just", "still", "however", "thus", "then",
    "year", "time", "century",
}  # fmt: skip
# Verbs that report what someone argued or wrote.
REPORTING_VERBS = {
    "argue", "claim", "contend", "assert", "maintain", "suggest", "note", "observe", "write",
    "show", "demonstrate", "emphasize", "emphasise", "stress", "insist", "propose", "conclude",
    "explain", "describe", "state", "acknowledge", "believe", "posit", "remark",
    "point", "highlight", "underline", "reject", "dismiss", "deny", "agree", "disagree",
}  # fmt: skip
QUOTE_SHARE = 0.5  # of the last sentence's characters, for QUOTE_ENDING


# --- vague "this" ----------------------------------------------------------


def nouns_for(sent, plural):
    """Nouns that could name what a "This" after sent points back to: its
    main verb's noun (refused -> refusal), then its subject and object."""
    out = []
    root = sent.root
    if root.pos_ == "VERB" and not plural:
        out += [n for n in verb_nouns(root.lemma_.lower()) if not n.endswith("ing")]
    for dep in ("dobj", "attr", "nsubjpass", "nsubj"):
        for c in root.children:
            if c.dep_ == dep and c.pos_ == "NOUN" and c.is_alpha and (c.tag_ == "NNS") == plural:
                out.append(c.text.lower())
    return list(dict.fromkeys(out))[:3]


def vague_this(sent, prev, q):
    for tok in sent:
        if tok.lower_ not in DEMONSTRATIVES or tok.tag_ != "DT" or tok.dep_ not in ("nsubj", "nsubjpass") or q[tok.i]:
            continue
        if any(c.dep_ in ("det", "predet") for c in tok.children):
            continue  # "all this"
        plural = tok.lower_ in ("these", "those")
        nouns = nouns_for(prev, plural) if prev is not None else []
        fix = {"choices": [choice(tok.text + " " + n, "name it") for n in nouns]} if nouns else None
        yield (
            "VAGUE_THIS",
            tok.idx,
            end(tok),
            f'vague "{tok.text}": name what it points back to' + (f' ("{tok.text} {nouns[0]}")' if nouns else ""),
            fix,
        )


# --- subject far from its verb ---------------------------------------------


def gap_words(span, q):
    """Words in span outside quotations and parentheses, a run of names
    counting as one ("Jacques-Auguste de Thou")."""
    n = 0
    for t in span:
        if t.is_alpha and not q[t.i] and not (t.pos_ == "PROPN" and t.i > span.start and t.doc[t.i - 1].pos_ == "PROPN"):
            n += 1
    return n


def subject_gaps(sent, q, notes):
    doc = sent.doc
    for verb in sent:
        if verb.pos_ not in ("VERB", "AUX") or q[verb.i]:
            continue
        subjs = [c for c in verb.children if c.dep_ in SUBJECTS and c.i < verb.i and c.dep_ != "expl"]
        subj = subjs[0] if len(subjs) == 1 else None  # two: a misparse
        if subj is None or subj.dep_ in ("nsubj", "nsubjpass") and subj.pos_ not in ("NOUN", "PROPN", "PRON", "NUM"):
            continue
        # A fronted phrase the parse hung on the subject ("Unlike X, memoirs
        # discussed") isn't part of the wait: start after its comma.
        start = subj.left_edge
        for t in doc[start.i : subj.i]:
            if t.text == ",":
                start = doc[t.i + 1]
        while start.is_space:
            start = doc[start.i + 1]
        # The verb group begins at its first auxiliary or "not" after the subject.
        stop = min([c.i for c in verb.children if c.dep_ in ("aux", "auxpass", "neg") and c.i > subj.right_edge.i] + [verb.i])
        span = doc[start.i : stop]
        if gap_words(span, q) < GAP or q[start.i] or any(notes[t.i] or any(c in t.text for c in "[]^") for t in span):
            continue
        inner = {t.i for t in subj.subtree}
        if any(t.pos_ in ("VERB", "AUX") or t.dep_ in ("cc", "mark") for t in span if t.i not in inner):
            continue  # another clause in between: the parse lost the real verb
        head = doc[start.i : min(subj.i + 1, start.i + 3)].text if subj.dep_.startswith("nsubj") else doc[start.i : start.i + 3].text
        yield (
            "SUBJECT_VERB_GAP",
            start.idx,
            end(verb),
            f'{gap_words(span, q)} words from the subject ("{head}") to its verb ("{verb.text}"): shorten the subject or move the verb up',
            None,
        )


# --- noun stacks and "of" chains -------------------------------------------


def noun_stacks(sent, q):
    doc = sent.doc
    for head in sent:
        if head.pos_ != "NOUN" or q[head.i] or head.dep_ in STACK_MODS and head.head.i > head.i:
            continue  # only the stack's last noun
        # The unbroken run of modifiers right before the noun; a hyphenated
        # compound ("sixteenth-century") is one word.
        i = head.i - 1
        while i >= sent.start and (
            doc[i].text == "-" or doc[i].dep_ in STACK_MODS and doc[i].pos_ in ("NOUN", "PROPN", "ADJ", "VERB", "NUM") and doc[i].head.i > i
        ):
            i -= 1
        run = doc[i + 1 : head.i + 1]
        if len(run) < 3 or run[0].text == "-" or any(t.pos_ == "PROPN" for t in run):
            continue
        if head.dep_ in ("nsubj", "nsubjpass") and head.head.dep_ == "relcl":
            continue  # "the development [that] residential embassies represented"
        if any(t.pos_ == "NOUN" and not WORDNET.synsets(t.lemma_.lower(), pos="n") for t in run):
            continue  # a typo the parse took for a noun
        parts = []
        for t in run:
            if t.text == "-" or parts and parts[-1].whitespace_ == "" and doc[t.i - 1].text == "-":
                if t.text != "-":
                    parts[-1] = t
                continue
            parts.append(t)
        nouns = sum(t.pos_ == "NOUN" for t in parts)
        if len(parts) >= 5 or len(parts) >= 4 and nouns >= 3:
            yield (
                "NOUN_STACK",
                run[0].idx,
                end(head),
                f'noun stack: "{run.text}": unpack it into phrases ("networks of correspondence among...")',
                None,
            )


def of_object(tok):
    """The common-noun object of tok's "of" phrase, or None."""
    for p in tok.children:
        if p.dep_ == "prep" and p.lower_ == "of":
            obj = next((c for c in p.children if c.dep_ == "pobj"), None)
            if obj is not None and obj.pos_ == "NOUN":
                return obj
    return None


def of_chains(sent, q):
    doc = sent.doc
    for tok in sent:
        if tok.pos_ != "NOUN" or q[tok.i] or tok.dep_ == "pobj" and tok.head.lower_ == "of":
            continue  # each chain once, from its first noun
        chain = [tok]
        while (obj := of_object(chain[-1])) is not None:
            chain.append(obj)
        if len(chain) > OF_DEPTH:
            last = chain[-1]
            span = doc[tok.left_edge.i : last.i + 1]
            yield (
                "OF_CHAIN",
                span.start_char,
                end(last),
                f'{len(chain) - 1} "of"s in a row: "{span.text}": use a possessive, a verb, or two sentences',
                None,
            )


# --- echoes ----------------------------------------------------------------


@cache
def family(lemma):
    """lemma's derivational relatives in WordNet, sharing its first four
    letters: diplomacy -> {diplomatic, diplomat, ...}."""
    out = {lemma}
    for sense in WORDNET.senses(lemma)[:6]:
        for rel in ("derivation", "pertainym"):
            for d in sense.get_related(rel):
                word = d.word().lemma().lower()
                if word[:4] == lemma[:4]:
                    out.add(word)
    return frozenset(out)


def content_lemma(tok, q, exempt):
    if not tok.is_alpha or len(tok) < 4 or q[tok.i] or tok.pos_ not in ("NOUN", "VERB", "ADJ"):
        return None
    if tok.text[0].isupper() and tok.i != tok.sent.start:
        return None  # proper adjectives and names: "French", "Ottoman"
    lemma = tok.lemma_.lower()
    if lemma in ECHO_SKIP or lemma in exempt or tok.lower_ in exempt:
        return None
    return lemma


def echoes(doc, q, exempt):
    sents = list(doc.sents)
    seen = [[(t, content_lemma(t, q, exempt)) for t in s] for s in sents]
    seen = [[(t, lem) for t, lem in s if lem] for s in seen]
    flagged = set()
    for k, sent in enumerate(seen):
        window = (seen[k - 1] if k else []) + sent
        for tok, lemma in sent:
            fam = family(lemma)
            same = [t for t, other in window if other == lemma or other in fam or lemma in family(other)]
            key = min(fam)
            if len(same) >= ECHO_COUNT and same[-1].i == tok.i and key not in flagged:
                flagged.add(key)
                yield (
                    "ECHO",
                    tok.idx,
                    end(tok),
                    f'echo: "{tok.text}", {len(same)} times in two sentences ({", ".join(dict.fromkeys(t.lower_ for t in same))}; thesaurus: <leader>zt)',

                    None,
                )


# --- quotation at the end --------------------------------------------------


def footnoted(doc):
    """Whether each token sits inside an inline footnote, ^[...]. A lone
    "^" counts too: a footnote holding only a citation is masked whole."""
    inside, depth = set(), 0
    text = doc.text
    for i, ch in enumerate(text):
        if ch == "^":
            inside.add(i)
        if depth and ch == "[":
            depth += 1
        elif ch == "[" and i and text[i - 1] == "^":
            depth = 1
            inside.add(i - 1)
        if depth:
            inside.add(i)
            if ch == "]":
                depth -= 1
    return [t.idx in inside for t in doc]


def quote_ending(doc, notes):
    # The paragraph's last sentence of main text, not of its footnotes.
    toks = [t for t in doc if not notes[t.i] and not t.is_space]
    words = [t for t in toks if t.is_alpha]
    if not words:
        return
    sent = words[-1].sent  # not a closing quote the parse split off
    body = [t for t in sent if not notes[t.i] and not t.is_punct]
    if not body or not any(t.is_alpha or t.is_space for t in body):
        return
    inquote = quoted(doc, parens=False)
    size = sum(len(t.text_with_ws) for t in body)
    if sum(len(t.text_with_ws) for t in body if inquote[t.i]) >= QUOTE_SHARE * size:
        first = next(t for t in sent if not t.is_space)
        yield "QUOTE_ENDING", first.idx, end(toks[-1]), "paragraph ends on a quotation: follow it with what it shows", None


# --- reporting tense -------------------------------------------------------


# Proper nouns that aren't people: "the War of ... demonstrates".
NOT_PEOPLE = {
    "war", "wars", "treaty", "peace", "edict", "league", "council", "empire", "crown", "court",
    "church", "parliament", "parlement", "estates", "diet", "porte", "republic", "senate", "papacy",
}  # fmt: skip


def reporting_tense(sent, q, scholars, unsure):
    for verb in sent:
        if verb.lemma_.lower() not in REPORTING_VERBS or verb.tag_ not in ("VBD", "VBZ", "VBP") or q[verb.i]:
            continue
        if any(c.dep_ in ("aux", "auxpass") for c in verb.children):
            continue  # "has argued", "would argue", "did argue": a choice, not a slip
        subj = next((c for c in verb.children if c.dep_ == "nsubj" and c.i < verb.i), None)
        before = sent.doc[verb.i - 1] if verb.i > sent.start else None
        if subj is None and before is not None and before.text.lower() in scholars and before.text[0].isupper():
            subj = before  # a surname the tagger took for something else: "Mattingly" (-ly) as an adverb
        elif subj is None or subj.pos_ != "PROPN":
            continue
        if subj.lower_ in NOT_PEOPLE or subj.lower_ in unsure or any(c.dep_ in ("det", "prep") for c in subj.children):
            continue  # not a person, or a modern name the .bib lacks
        # The head is the surname: "De Lamar Jensen" -> Jensen.
        scholar = subj.text.lower() in scholars
        if not scholar and any(t.text.lower() in scholars for t in subj.subtree if t.pos_ == "PROPN"):
            continue  # "Mattingly and Bodin": mixed, or a surname split off
        if scholar and verb.tag_ == "VBD":
            tag, why, want = "VBP" if plural(subj) else "VBZ", "is in the .bib, a scholar", "present"
        elif not scholar and verb.tag_ in ("VBZ", "VBP"):
            tag, why, want = "VBD", "isn't in the .bib or a modern citation, so a historical actor (if a scholar, cite them)", "past"
        else:
            continue
        word = inflect(verb.lemma_.lower(), tag)
        yield (
            "REPORTING_TENSE",
            verb.idx,
            end(verb),
            f'reporting tense: {subj.text} {why}: "{word}"',
            {"choices": [choice(word, f"{want} tense")]},
        )


def rules(doc, exempt=frozenset(), scholars=frozenset(), unsure=frozenset()):
    """Yields (rule, start, end, message, fix) for doc, one paragraph, as
    char offsets. exempt: lowercase words ECHO lets recur; scholars:
    lowercase surnames from the .bib and narrative citations; unsure: names
    in modern footnote citations, scholars or editors, so left alone."""
    q = quoted(doc)
    notes = footnoted(doc)
    prev = None
    for sent in doc.sents:
        yield from vague_this(sent, prev, q)
        yield from subject_gaps(sent, q, notes)
        yield from noun_stacks(sent, q)
        yield from of_chains(sent, q)
        yield from reporting_tense(sent, q, scholars, unsure)
        prev = sent
    yield from echoes(doc, q, exempt)
    yield from quote_ending(doc, notes)
