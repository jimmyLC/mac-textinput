#!/usr/bin/env python3
"""Build data/english-words.txt (word<TAB>count) from open data.

Inputs
  --wiki   enwiki word-frequency file from IlyaSemenov/wikipedia-word-frequency
           (lines: "word count", derived from English Wikipedia text).
  --extra  data/sources/english-extra.txt, a hand-written supplement.
  --common data/sources/english-common.txt, a hand-written list of everyday
           words whose counts are multiplied by --common-boost.
  --scowl  optional SCOWL/Hunspell en_US.dic; words it lists (with simple
           inflections) get their count multiplied by --boost, which pushes
           ordinary vocabulary above proper nouns from Wikipedia.
Output is sorted by count descending. See data/DATA-NOTES.md for provenance.
"""
import argparse, re, sys

p = argparse.ArgumentParser()
p.add_argument("--wiki", required=True)
p.add_argument("--extra", default="data/sources/english-extra.txt")
p.add_argument("--out", default="data/english-words.txt")
p.add_argument("--limit", type=int, default=150000)
p.add_argument("--common")
p.add_argument("--common-boost", type=int, default=20)
p.add_argument("--scowl")
p.add_argument("--boost", type=int, default=10)
p.add_argument("--extra-count", type=int, default=400000,
               help="floor count for supplement words (about the top few thousand wiki ranks)")
a = p.parse_args()

WORD = re.compile(r"[a-z]+")
counts = {}
for line in open(a.wiki, encoding="utf-8"):
    parts = line.split()
    if len(parts) != 2 or not parts[1].isdigit():
        continue
    w, c = parts[0], int(parts[1])
    if WORD.fullmatch(w) and (len(w) > 1 or w in ("a", "i")):
        counts[w] = c

SUFFIXES = (("s", ""), ("es", ""), ("ed", ""), ("ed", "e"), ("d", ""), ("ing", ""), ("ing", "e"),
            ("ly", ""), ("er", ""), ("er", "e"), ("est", ""), ("est", "e"), ("ies", "y"),
            ("ied", "y"), ("ier", "y"), ("ness", ""))
stems = set()
if a.scowl:
    with open(a.scowl, encoding="utf-8", errors="ignore") as f:
        next(f)
        stems = {l.split("/")[0].strip() for l in f if l[:1].islower()}

def known(w):
    if w in stems:
        return True
    for suf, add in SUFFIXES:
        if w.endswith(suf) and len(w) > len(suf) + 2:
            b = w[: -len(suf)] + add
            if b in stems or (len(b) > 2 and b[-1] == b[-2] and b[:-1] in stems):
                return True
    return False

if stems:
    counts = {w: c * (a.boost if known(w) else 1) for w, c in counts.items()}

if a.common:
    for line in open(a.common, encoding="utf-8"):
        if line.strip() and not line.startswith("#"):
            for w in line.split():
                if w in counts:
                    counts[w] *= a.common_boost

top = sorted(counts.items(), key=lambda x: (-x[1], x[0]))[: a.limit]
words = dict(top)
added = 0
for line in open(a.extra, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    for w in line.split():
        if WORD.fullmatch(w):
            if words.get(w, 0) < a.extra_count:
                added += 1
            words[w] = max(words.get(w, 0), a.extra_count)

with open(a.out, "w", encoding="utf-8") as f:
    for w, c in sorted(words.items(), key=lambda x: (-x[1], x[0])):
        f.write(f"{w}\t{c}\n")
print(f"wrote {len(words)} words ({added} supplement entries applied) to {a.out}", file=sys.stderr)
