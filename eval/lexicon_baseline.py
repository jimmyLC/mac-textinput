#!/usr/bin/env python3
"""Offline baseline for the homophone eval: unigram Viterbi over the bundled lexicon,
a stand-in for the engine's default choice. Usage: lexicon_baseline.py [sentences.txt]"""
import sys, collections, json, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]

def load_lexicon():
    by_word = {}                                   # word -> (score, [readings])
    by_reading = collections.defaultdict(list)     # tuple(syllables) -> [(word, score)]
    for line in open(ROOT / 'data' / 'chinese-lexicon.tsv', encoding='utf-8'):
        f = line.rstrip('\n').split('\t')
        if len(f) < 3: continue
        word, score, readings = f[0], float(f[1]), f[2].split('|')
        by_word[word] = (score, [tuple(r.split('-')) for r in readings])
        for r in by_word[word][1]:
            if len(r) == len(word): by_reading[r].append((word, score))
    for k in by_reading: by_reading[k].sort(key=lambda x: -x[1])
    return by_word, by_reading

def gold_syllables(text, by_word):
    """Best segmentation of `text` into lexicon words; returns the syllable sequence."""
    n = len(text)
    best = [(-1e9, None)] * (n + 1); best[0] = (0.0, None)
    for i in range(n):
        if best[i][0] <= -1e8: continue
        for j in range(i + 1, min(n, i + 6) + 1):
            w = text[i:j]
            if w in by_word:
                s = best[i][0] + by_word[w][0]
                if s > best[j][0]: best[j] = (s, (i, w))
    if best[n][1] is None: return None
    out, k = [], n
    while k > 0:
        i, w = best[k][1]
        out.append(by_word[w][1][0]); k = i
    return [s for r in reversed(out) for s in r]

def viterbi(syl, by_reading, max_len=6):
    n = len(syl)
    best = [(-1e9, None)] * (n + 1); best[0] = (0.0, None)
    for i in range(n):
        if best[i][0] <= -1e8: continue
        for j in range(i + 1, min(n, i + max_len) + 1):
            c = by_reading.get(tuple(syl[i:j]))
            if c:
                s = best[i][0] + c[0][1]
                if s > best[j][0]: best[j] = (s, (i, c[0][0]))
    if best[n][1] is None: return None
    out, k = [], n
    while k > 0:
        i, w = best[k][1]; out.append(w); k = i
    return ''.join(reversed(out))

if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / 'eval' / 'homophone_sentences.txt')
    by_word, by_reading = load_lexicon()
    rows, skipped = [], 0
    for text in (l.strip() for l in open(path, encoding='utf-8')):
        if not text: continue
        syl = gold_syllables(text, by_word)
        if syl is None or len(syl) != len(text): skipped += 1; continue
        rows.append({'gold': text, 'syllables': syl, 'baseline': viterbi(syl, by_reading)})
    ok = sum(r['gold'] == r['baseline'] for r in rows)
    chars = sum(len(r['gold']) for r in rows)
    wrong = sum(a != b for r in rows for a, b in zip(r['gold'], r['baseline'] or ''))
    print(f'sentences {len(rows)} (skipped {skipped}); baseline sentence-exact {ok}/{len(rows)}; char errors {wrong}/{chars}')
    json.dump(rows, open(ROOT / 'eval' / 'baseline.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
    for r in rows:
        if r['gold'] != r['baseline']: print(' ', r['gold'], '->', r['baseline'])
