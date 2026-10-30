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
  BE_PASSIVE      "was signed" (by Francis) -> fix: "Francis signed the treaty"
                  "needed to be redeveloped" -> fix: "needed redeveloping"
  BE_COPULA       "was angry"
  BE_EXISTENTIAL  "there were"
A passive gets a fix only when the doer is named ("by Francis") or after
need/deserve...; copulas and existentials need rewording by hand.
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


# Pronouns trade case when subject and agent swap: "he was seen by them" ->
# "they saw him".
TO_OBJECT = {"i": "me", "he": "him", "she": "her", "we": "us", "they": "them", "who": "whom"}
TO_SUBJECT = {o: s for s, o in TO_OBJECT.items()}
RELATIVES = {"which", "that", "who"}
# "needed to be redeveloped" -> "needed redeveloping", "needed redevelopment".
NEED_VERBS = {"need", "require", "deserve", "want", "merit", "warrant"}
# What a verb's own noun adds to it: repair, redevelopment, approval...
NOUN_SUFFIXES = {"", "e", "ment", "ation", "ition", "tion", "sion", "al", "ance", "ence", "ing"}

def quoted(doc, parens=True):
    """Whether each token sits inside quotation marks (or parentheses), by
    character, since a quote can be glued to its neighbours ('."^[Sagon').
    A straight quote closes an open one, else opens after a space or
    bracket; else it's a stray, or closes a curly “ typed straight."""
    text = doc.text
    inside, depth, straight = [False] * len(text), 0, False
    for i, ch in enumerate(text):
        was = depth > 0 or straight
        if ch == '"':
            if straight:
                straight = False
            elif i == 0 or text[i - 1] in " \t\n([{—–":
                straight = True
            elif depth:
                depth -= 1
        elif ch in "“«" or parens and ch == "(":
            depth += 1
        elif depth and (ch in "”»" or parens and ch == ")"):
            depth -= 1
        inside[i] = was or depth > 0 or straight
    return [any(inside[tok.idx : tok.idx + len(tok)]) for tok in doc]


def end(tok):
    return tok.idx + len(tok)


def recase(tok, table):
    """tok's text, a pronoun put in the other case."""
    word = table.get(tok.lower_)
    return tok.text if word is None else "I" if word == "i" else word


def plural(tok):
    return tok.tag_ in ("NNS", "NNPS") or tok.lower_ in ("i", "we", "you", "they") or any(c.dep_ == "conj" for c in tok.children)


def verb_nouns(lemma):
    """The verb's own nouns, by WordNet's derivations: redevelop ->
    redevelopment, approve -> approval; not its doers (approver)."""
    stem = lemma[:-1] if lemma.endswith("e") else lemma
    out = []
    for sense in WORDNET.senses(lemma, pos="v")[:3]:
        for d in sense.get_related("derivation"):
            word = d.word()
            noun = word.lemma()
            if word.pos == "n" and noun.startswith(stem) and noun[len(stem) :] in NOUN_SUFFIXES and noun not in out:
                out.append(noun)
    return out


# "made a decision" -> "decided": a light verb whose object is a noun made
# from a verb. Shared with strunk's NOMINALIZATION.
LIGHT_VERBS = {"make", "take", "give", "conduct", "perform", "reach", "undertake"}
NOMINAL_SUFFIXES = ("tion", "sion", "ment", "ance", "ence", "ancy", "ency", "sis", "ure", "al")


def nominal_verbs(noun):
    """Verbs the noun is made from: decision -> decide."""
    out = []
    for sense in WORDNET.senses(noun, pos="n")[:3]:
        for d in sense.get_related("derivation"):
            word = d.word()
            if word.pos == "v" and word.lemma()[:3] == noun[:3] and word.lemma() not in out:
                out.append(word.lemma())
    return out


def passive_fix(be, verb, doc, q):
    """Active rewrites for the passive `be ... verb`, as {"choices"}, or None:
    "the treaty was signed by Francis" -> "Francis signed the treaty"
    (only when the doer is named), "needed to be redeveloped" ->
    "needed redeveloping". None inside quotations or parentheses."""
    if q[be.i] or any(c.dep_ in ("neg", "conj") for c in verb.children):
        return None
    if verb.dep_ == "xcomp" and verb.head.lemma_ in NEED_VERBS:
        to = doc[be.i - 1] if be.i else None
        if to is None or to.lower_ != "to" or any(not t.is_space for t in doc[be.i + 1 : verb.i]):
            return None
        forms = [inflect(verb.lemma_.lower(), "VBG")] + verb_nouns(verb.lemma_.lower())
        notes = ["gerund"] + ["noun"] * (len(forms) - 1)
        return {"choices": [{"text": f, "note": n, "start": to.idx, "end": end(verb)} for f, n in zip(forms, notes)]}

    agent = next((c for c in verb.children if c.dep_ == "agent"), None)
    subj = next((c for c in verb.children if c.dep_ == "nsubjpass"), None)
    objs = [c for c in agent.children if c.dep_ == "pobj"] if agent else []
    if subj is None or len(objs) != 1 or subj.i > be.i:
        return None
    obj = objs[0]
    # Only plain doers: spaCy hangs stray phrases on them ("by a focus on
    # the rivalry", "by the author without any AI assistance"), and
    # "not by X but by Y", "by Estienne, the royal printer" don't flip.
    span = doc[subj.left_edge.i : agent.right_edge.i + 1]
    if any(c.dep_ == "prep" and c.lower_ != "of" for c in obj.children):
        return None
    if any(t.lower_ in ("not", "but") for t in doc[verb.i + 1 : agent.right_edge.i + 1]) or "," in doc[agent.i : agent.right_edge.i + 1].text:
        return None
    if any(c in span.text for c in '[]()^"“”«»'):
        return None
    # The verb group, in the tense of the passive and agreeing with its new
    # subject: was signed -> signed, is -> signs/sign, has been -> has/have,
    # will be -> will sign.
    auxes = [c for c in verb.children if c.dep_ in ("aux", "auxpass") and c.i < verb.i]
    words = [a.lower_ for a in auxes]
    many = plural(obj)

    def verb_group(lemma, participle):
        if words in (["was"], ["were"]):
            return [inflect(lemma, "VBD")]
        if words in (["is"], ["are"], ["am"]):
            return [inflect(lemma, "VBP" if many else "VBZ")]
        if len(words) == 2 and words[0] in ("has", "have", "had") and words[1] == "been":
            return ["had" if words[0] == "had" else "have" if many else "has", participle]
        if len(words) == 2 and auxes[0].tag_ == "MD" and words[1] == "be":
            return [auxes[0].text, inflect(lemma, "VB")]
        return None

    group = verb_group(verb.lemma_, verb.text)
    if group is None:
        return None
    # Only adverbs may sit between the subject and the verb; they stay
    # before the verb ("had been quickly burned" -> "had quickly burned").
    between = [t for t in doc[subj.right_edge.i + 1 : verb.i] if not t.is_space and t.i not in {a.i for a in auxes}]
    if any(t.dep_ != "advmod" or t.head.i != verb.i for t in between):
        return None
    adverbs = [t.text for t in between]
    group[-1:-1] = adverbs

    doer = recase(obj, TO_SUBJECT) if obj.left_edge.i == agent.right_edge.i else doc[obj.left_edge.i : agent.right_edge.i + 1].text
    middle = doc.text[end(verb) : agent.idx].rstrip()  # "taken over by" -> "took ... over"

    if subj.lower_ in RELATIVES and subj.left_edge.i == subj.right_edge.i:
        # "which was built by the Venetians" -> "which the Venetians built"
        text = " ".join([recase(subj, TO_OBJECT), doer, *group]) + middle
    else:
        thing = recase(subj, TO_OBJECT) if subj.left_edge.i == subj.right_edge.i else doc[subj.left_edge.i : subj.right_edge.i + 1].text
        first = subj.left_edge
        if first.is_sent_start and first.pos_ != "PROPN" and first.text != "I":
            thing = thing[:1].lower() + thing[1:]
        text = " ".join([doer, *group, thing]) + middle
    # A reordered span can't keep its line breaks where they were.
    text = re.sub(r"\s+", " ", text).strip()
    choices = [{"text": text, "note": "active voice", "start": subj.left_edge.idx, "end": end(agent.right_edge)}]
    # "The decision was made by the king" -> "the king decided", not "the
    # king made the decision": only for a bare noun ("the decision", not
    # "the final decision") with nothing between the verb and "by".
    if (
        verb.lemma_.lower() in LIGHT_VERBS
        and subj.lower_.endswith(NOMINAL_SUFFIXES)
        and subj.lower_ not in RELATIVES
        and all(t.dep_ == "det" for t in doc[subj.left_edge.i : subj.i])
        and subj.right_edge.i == subj.i
        and not middle.strip()
    ):
        for lemma in nominal_verbs(subj.lower_):
            group = verb_group(lemma, inflect(lemma, "VBN"))
            group[-1:-1] = adverbs
            text = re.sub(r"\s+", " ", " ".join([doer, *group])).strip()
            choices.insert(0, {"text": text, "note": "the verb inside the noun", "start": subj.left_edge.idx, "end": end(agent.right_edge)})
    if subj.left_edge.is_sent_start:
        for c in choices:
            c["text"] = c["text"][:1].upper() + c["text"][1:]
    return {"choices": choices}


def be_verbs(doc):
    """Yields (rule, start, end, message, fix) for the be-verbs in doc, as
    char offsets into its text."""
    seen = set()  # (rule, head) -- "was being built" is one passive, not two
    q = quoted(doc)
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
        fix = progressive_fix(tok, head, doc) if rule == "BE_PROGRESSIVE" else passive_fix(tok, head, doc, q) if rule == "BE_PASSIVE" else None
        yield rule, span.start_char, span.end_char, message, fix


def check(masked, *more):
    """Be-verbs in `masked` (the bridge's text with code, markup and French
    blanked out), as (rule, start, end, message, fix) in char offsets. Each
    of `more` (strunk.rules) is run on the same parse, so then every
    paragraph is parsed, not only those with a be-verb."""
    paras, pos = [], 0
    for para in re.split(r"(\n[ \t]*\n)", masked):
        if BE_FORMS.search(para) if not more else re.search(r"[A-Za-z]", para):
            # Semantic line breaks: a sentence runs across lines.
            paras.append((para.replace("\n", " "), pos))
        pos += len(para)
    hits = []
    for doc, offset in NLP.pipe(paras, as_tuples=True, batch_size=32):
        for rules in (be_verbs, *more):
            for rule, start, end, message, fix in rules(doc):
                if fix and "choices" in fix:
                    for c in fix["choices"]:
                        if "start" in c:
                            c["start"] += offset
                            c["end"] += offset
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
    """Replacements for a progressive: the same verb in its simple form
    (not for a vague verb -- fix["keep"] false), then Datamuse's ranking, then the rest of WordNet's troponyms (single
    words before phrasal verbs -- WordNet has no ranking of its own). Each is
    {"text", "word", "note"}: text replaces the whole span."""
    lemma, tag = fix["lemma"], fix["tag"]
    prefix = (" " if fix.get("contraction") else "") + (fix["between"] + " " if fix["between"] else "")
    glosses = troponyms(lemma)
    words = [lemma] + datamuse(lemma, fix.get("lc"), fix.get("rc")) + sorted(glosses, key=lambda w: " " in w)
    out, seen = [], set() if fix.get("keep", True) else {lemma}
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
