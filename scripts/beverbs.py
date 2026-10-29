"""Be-verb hints for grammalecte_bridge.py (ops "beverbs" and "suggest").

Imported lazily, on the first be-verb request, from the bridge's worker
thread -- loading spaCy takes ~0.6s and ~130MB, so Grammalecte requests
keep being answered meanwhile, and nothing loads while hints are off.

Needs the prose venv (scripts/setup_prose_venv.sh): spaCy with
en_core_web_sm for the parse, lemminflect to conjugate, and wn with Open
English WordNet for troponyms -- the more specific ways of doing a verb
(walk -> trudge, shuffle, amble), which is what a weak progressive wants,
not synonyms. Datamuse's rel_gen ("more general than") ranks and widens
them when the network is up.

Kinds, with their rule ids (ignorable like any Grammalecte rule):
  BE_PROGRESSIVE  "was walking"  -> fix: "trudged", "shuffled", ...
  BE_PASSIVE      "was signed" (by Francis)
  BE_COPULA       "was angry"
  BE_EXISTENTIAL  "there were"
Only progressives get a fix; the others need rewording by hand.
"""

import json
import os
import re
import socket
import sys
import time
import urllib.parse
import urllib.request

import lemminflect
import spacy
import wn

wn.config.data_directory = os.path.join(sys.prefix, "wn_data")
NLP = spacy.load("en_core_web_sm", disable=["ner"])
WORDNET = wn.Wordnet("oewn:2024")

# Cheap prefilter: paragraphs with none of these never reach the parser.
BE_FORMS = re.compile(r"\b(?:am|is|are|was|were|be|been|being)\b|['’](?:m|s|re)\b", re.I)

# Form of "be" -> Penn tag of the simple form that replaces the progressive:
# was walking -> walked, is walking -> walks, had been walking -> had walked,
# will be walking -> will walk.
SIMPLE_TAG = {
    "was": "VBD",
    "were": "VBD",
    "is": "VBZ",
    "'s": "VBZ",
    "am": "VBP",
    "are": "VBP",
    "'m": "VBP",
    "'re": "VBP",
    "been": "VBN",
    "be": "VB",
}


def word_near(doc, i, step):
    """The nearest real word from token i in direction step, for Datamuse's
    context hints (masked text leaves whitespace tokens behind)."""
    i += step
    while 0 <= i < len(doc):
        if doc[i].is_alpha:
            return doc[i].text
        if not doc[i].is_space:
            return None
        i += step
    return None


def progressive_fix(be, verb, doc):
    """The fix for `be ... verb` (verb is the -ing head), or None when the
    words between aren't just adverbs: questions ("was he walking"),
    negations ("was not walking") need rewording by hand."""
    tag = SIMPLE_TAG.get(be.lower_.replace("’", "'"))
    between = doc[be.i + 1 : verb.i]
    if not tag or any(t.dep_ == "neg" or t.pos_ not in ("ADV", "SPACE") for t in between):
        return None
    return {
        "lemma": verb.lemma_.lower(),
        "tag": tag,
        # Kept in place: "was slowly walking" -> "slowly trudged".
        "between": " ".join(t.text for t in between if not t.is_space),
        "contraction": be.text[0] in "'’",
        "lc": word_near(doc, be.i, -1),
        "rc": word_near(doc, verb.i, 1),
    }


def be_verbs(doc):
    """Yields (rule, start, end, message, fix) for the be-verbs in doc, as
    char offsets into its text."""
    seen = set()  # (rule, head) -- "was being built" is one passive, not two
    for tok in doc:
        if tok.lemma_ != "be" or tok.pos_ not in ("AUX", "VERB"):
            continue
        expl = [c for c in tok.children if c.dep_ == "expl"]
        head = tok.head
        if expl:
            first, last, rule, kind = min(expl[0], tok), max(expl[0], tok), "BE_EXISTENTIAL", "existential"
        elif tok.dep_ == "auxpass" or (tok.dep_ == "aux" and head.tag_ == "VBN"):
            first, last, rule, kind = tok, head, "BE_PASSIVE", "passive"
        elif tok.dep_ == "aux" and head.tag_ == "VBG":
            first, last, rule, kind = tok, head, "BE_PROGRESSIVE", "progressive"
        elif tok.dep_ == "aux":
            continue  # "is to sail", tagging slips
        else:
            # The complement ("was angry", "was in Paris"), else an adverb
            # ("was there"), else "was" alone.
            after = [c for c in tok.children if c.i > tok.i]
            comp = [c for c in after if c.dep_ in ("acomp", "attr", "prep", "oprd")] or [c for c in after if c.dep_ == "advmod"]
            last = (comp[0].right_edge if comp[0].dep_ == "prep" else comp[0]) if comp else tok
            first, rule, kind = tok, "BE_COPULA", "copula"
        key = (rule, last.i if rule != "BE_COPULA" else tok.i)
        if key in seen:
            continue
        seen.add(key)
        span = doc[first.i : last.i + 1]
        message = f'{kind}: "{span.text}"'
        if rule == "BE_PASSIVE":
            agent = [c for c in head.children if c.dep_ == "agent"]
            if agent:
                message += " (" + " ".join(t.text for t in agent[0].subtree) + ")"
        fix = progressive_fix(tok, head, doc) if rule == "BE_PROGRESSIVE" else None
        yield rule, span.start_char, span.end_char, message, fix


def check(masked):
    """Be-verbs in `masked` (the bridge's text with code, markup and French
    blanked out), as (rule, start, end, message, fix) in char offsets."""
    paras, pos = [], 0
    for para in re.split(r"(\n[ \t]*\n)", masked):
        if BE_FORMS.search(para):
            # Semantic line breaks: a sentence runs across lines.
            paras.append((para.replace("\n", " "), pos))
        pos += len(para)
    hits = []
    for doc, offset in NLP.pipe(paras, as_tuples=True, batch_size=32):
        for rule, start, end, message, fix in be_verbs(doc):
            hits.append((rule, offset + start, offset + end, message, fix))
    return hits


# --- suggestions -----------------------------------------------------------

offline_until = 0.0  # no Datamuse requests before this time
OFFLINE_BACKOFF = 60
datamuse_cache = {}


def online():
    """Whether api.datamuse.com is reachable; a failure holds requests off
    for OFFLINE_BACKOFF seconds so an offline session never waits on it."""
    global offline_until
    if time.time() < offline_until:
        return False
    try:
        socket.create_connection(("api.datamuse.com", 443), timeout=1).close()
        return True
    except OSError:
        offline_until = time.time() + OFFLINE_BACKOFF
        return False


def datamuse(lemma, lc, rc):
    """Verbs more specific than lemma, best first, ranked by the words on
    either side; [] when offline."""
    key = (lemma, lc, rc)
    if key in datamuse_cache:
        return datamuse_cache[key]
    if not online():
        return []
    q = {"rel_gen": lemma, "md": "p", "max": 40}
    if lc:
        q["lc"] = lc
    if rc:
        q["rc"] = rc
    global offline_until
    try:
        with urllib.request.urlopen("https://api.datamuse.com/words?" + urllib.parse.urlencode(q), timeout=3) as r:
            words = [d["word"] for d in json.load(r) if "v" in d.get("tags", [])]
    except (OSError, ValueError):
        offline_until = time.time() + OFFLINE_BACKOFF
        return []
    datamuse_cache[key] = words
    return words


def troponyms(lemma):
    """WordNet's more specific verbs for every sense of lemma, as
    {word: gloss of that sense}, most common senses first."""
    out = {}
    for synset in WORDNET.synsets(lemma, pos="v"):
        for hyponym in synset.hyponyms():
            for word in hyponym.lemmas():
                if word != lemma:
                    out.setdefault(word, hyponym.definition() or "")
    return out


def inflect(phrase, tag):
    """Conjugates a verb or phrasal verb: ("march on", VBD) -> "marched on"."""
    first, _, rest = phrase.partition(" ")
    form = (lemminflect.getInflection(first, tag) or (first,))[0]
    return form + (" " + rest if rest else "")


def suggest(fix):
    """Replacements for a progressive: the same verb in its simple form,
    then Datamuse's ranking, then the rest of WordNet's troponyms (single
    words before phrasal verbs -- WordNet has no ranking of its own). Each is
    {"text", "word", "note"}: text replaces the whole span."""
    lemma, tag = fix["lemma"], fix["tag"]
    prefix = (" " if fix.get("contraction") else "") + (fix["between"] + " " if fix["between"] else "")
    glosses = troponyms(lemma)
    words = [lemma] + datamuse(lemma, fix.get("lc"), fix.get("rc")) + sorted(glosses, key=lambda w: " " in w)
    out, seen = [], set()
    for word in words:
        word = word.replace("_", " ")
        if word in seen:
            continue
        seen.add(word)
        if word == lemma:
            note = "same verb, simple form"
        else:
            note = glosses.get(word, "Datamuse")
        out.append({"text": prefix + inflect(word, tag), "word": word, "note": note})
    return out
