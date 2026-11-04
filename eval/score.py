#!/usr/bin/env python3
"""Scores a reranker's output. Usage: score.py out.json  (rows with gold/syllables/baseline/model).
A change only counts when the new character is a real homophone (same syllable per the lexicon)."""
import sys, json, collections, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from lexicon_baseline import load_lexicon

EQUIV = {'她': '他', '它': '他', '牠': '他', '儘': '盡', '覆': '復', '複': '復', '週': '周', '裏': '裡', '裡': '裡'}
norm = lambda c: EQUIV.get(c, c)

by_word, _ = load_lexicon()
char_syl = collections.defaultdict(set)
for w, (s, rs) in by_word.items():
    if len(w) == 1:
        for r in rs: char_syl[w].add(r[0])

rows = json.load(open(sys.argv[1]))
wrong = fixed = correct = broken = rejected = unchanged_wrong = changed_sent = bad_len = 0
sent_fixed = sent_broken = 0
examples = {'fixed': [], 'broken': [], 'missed': []}
for r in rows:
    gold, base, syl = r['gold'], r['baseline'], r['syllables']
    model = (r.get('model') or '').rstrip('。.！!，, ') or None
    if not base: continue
    out = list(base)
    if model and len(model) == len(base):
        for i, (b, m) in enumerate(zip(base, model)):
            if b != m:
                if syl[i] in char_syl.get(m, ()): out[i] = m
                else: rejected += 1
    elif model: bad_len += 1
    out = ''.join(out)
    if out != base: changed_sent += 1
    bad_before = bad_after = False
    for g, b, o in zip(gold, base, out):
        if norm(g) != norm(b):
            wrong += 1
            if norm(o) == norm(g): fixed += 1; bad_before = True
            else: unchanged_wrong += 1
        else:
            correct += 1
            if norm(o) != norm(g): broken += 1; bad_after = True
    if bad_before and len(examples['fixed']) < 5: examples['fixed'].append((base, out))
    if bad_after and len(examples['broken']) < 8: examples['broken'].append((gold, base, out))
    if any(norm(g) != norm(o) for g, o in zip(gold, out)) and len(examples['missed']) < 8: examples['missed'].append((gold, out))
print(f'baseline-wrong chars {wrong}; fixed {fixed} -> CorrectionRate {fixed/max(wrong,1):.1%}')
print(f'baseline-right chars {correct}; broken {broken} -> RegressionRate {broken/max(correct,1):.2%}')
print(f'sentences changed {changed_sent}/{len(rows)}; non-homophone edits rejected {rejected}; length mismatch {bad_len}')
for k, v in examples.items():
    print(k); [print('  ', x) for x in v]
