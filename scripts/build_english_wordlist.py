#!/usr/bin/env python3
"""Build data/english-words.txt (word<TAB>count) from open data.

Inputs
  --wiki   enwiki word-frequency file from IlyaSemenov/wikipedia-word-frequency
           (lines: "word count", derived from English Wikipedia text).
  --extra  data/sources/english-extra.txt, a hand-written supplement.
Output is sorted by count descending. See data/DATA-NOTES.md for provenance.
"""
import argparse, re, sys

p = argparse.ArgumentParser()
p.add_argument("--wiki", required=True)
p.add_argument("--extra", default="data/sources/english-extra.txt")
p.add_argument("--out", default="data/english-words.txt")
p.add_argument("--limit", type=int, default=150000)
p.add_argument("--extra-count", type=int, default=2000000,
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
