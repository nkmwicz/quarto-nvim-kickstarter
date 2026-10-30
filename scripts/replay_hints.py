"""Re-checks the hint log (lua/config/hintlog.lua) with the current rules.

    replay_hints.py [LOG]    (default: ~/.local/share/nvim/prose-hints.jsonl)

Each entry holds the whole document as it was when logged, so the check runs
in the same context: the same frequent words for ECHO, the same footnotes and
.bib files for REPORTING_TENSE. A false positive is fixed once its rule no
longer fires over the logged range, a false negative once it does; an OTHER
entry lists whatever fires there now. Prints a table per rule, then the
entries still wrong; exits 1 if any are.
"""

import json
import os
import subprocess
import sys
from collections import Counter

BRIDGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "grammalecte_bridge.py")
DEFAULT = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "nvim", "prose-hints.jsonl"
)


def overlaps(e, r):
    """Whether hint e touches range r (line/col pairs, ends exclusive)."""
    return (e["lnum"], e["col"]) < (r["end_lnum"], r["end_col"]) and (r["lnum"], r["col"]) < (
        e["end_lnum"],
        e["end_col"],
    )


def short(s, n=70):
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    with open(path, encoding="utf-8") as f:
        entries = [json.loads(line) for line in f if line.strip()]
    reqs = "".join(
        json.dumps({"id": i, "op": "beverbs", "text": e["text"], "ignore": [], "bib": e.get("bib", [])}) + "\n"
        for i, e in enumerate(entries)
    )
    out = subprocess.run([sys.executable, BRIDGE], input=reqs, capture_output=True, text=True, check=False)
    hints = {}
    for line in out.stdout.splitlines():
        resp = json.loads(line)
        if "warning" in resp or "unavailable" in resp:
            print("bridge:", resp.get("warning") or resp.get("unavailable"))
        hints[resp["id"]] = resp.get("errors", [])

    counts = Counter()  # (rule, kind, still wrong?) -> n
    wrong = []
    for i, e in enumerate(entries):
        there = sorted({h["rule"] for h in hints.get(i, []) if overlaps(h, e)})
        if e["rule"] == "OTHER":
            still = not there
        else:
            still = (e["rule"] in there) == (e["kind"] == "false_positive")
        counts[e["rule"], e["kind"], still] += 1
        if still or e["rule"] == "OTHER":
            wrong.append((e, there, still))

    print(f"{len(entries)} logged hints in {path}\n")
    print(f"{'rule':18} {'false +':>12} {'false −':>12}")
    for rule in sorted({r for r, _, _ in counts}):
        cells = []
        for kind in ("false_positive", "false_negative"):
            still, fixed = counts[rule, kind, True], counts[rule, kind, False]
            cells.append(f"{still} ({fixed} fixed)" if still + fixed else "")
        print(f"{rule:18} {cells[0]:>12} {cells[1]:>12}")

    if wrong:
        print("\nStill wrong:")
    for e, there, still in wrong:
        kind = "false +" if e["kind"] == "false_positive" else "false −"
        where = f"{os.path.basename(e['file'])}:{e['lnum'] + 1}"
        print(f"\n{e['rule']} ({kind}) {where}  {e['time'][:10]}")
        print(f"  [{short(e['flagged'])}]")
        if e.get("note"):
            print(f"  note: {e['note']}")
        if e["rule"] == "OTHER":
            print(f"  fires now: {', '.join(there) or 'nothing'}")
    sys.exit(1 if any(still for _, _, still in wrong) else 0)


if __name__ == "__main__":
    main()
