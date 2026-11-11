#!/usr/bin/env python3
"""Homophone reranking with a local Qwen model (teacher-forced log-probability, MLX).
For every position of each baseline sentence, try the other characters that share the typed
syllable and keep the swap that raises the whole-sentence log-prob the most; a swap is
applied only when the gain reaches a threshold. Writes eval/qwen_out_<model>_<tau>.json.
Usage: qwen_eval.py <mlx model repo or path> [tag]"""
import sys, json, time, collections, pathlib
import mlx.core as mx
from mlx_lm import load

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'eval'))
from lexicon_baseline import load_lexicon

repo = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else 'qwen'
TAUS = [0.5, 1.0, 1.5, 2.0, 3.0]
WEIGHTS = [0.0, 0.5, 1.0]   # weight of the lexicon prior added to the model gain
TOP_ALT = 8

by_word, _ = load_lexicon()
in_phrase = {ch for w in by_word if len(w) > 1 for ch in w}   # drops simplified/rare single characters
alts = collections.defaultdict(list)      # syllable -> [(score, char)]
prior = {}                                # char -> best single-character score
for w, (s, rs) in by_word.items():
    if len(w) == 1:
        prior[w] = s
        if w in in_phrase:
            for r in rs: alts[r[0]].append((s, w))
for k in alts: alts[k] = [c for _, c in sorted(alts[k], reverse=True)[:TOP_ALT]]

model, tok = load(repo)
start = tok.encode('\n')                    # Qwen has no BOS: condition on a newline

def logprob(text):
    ids = start + tok.encode(text)
    x = mx.array(ids)[None]
    lp = mx.log(mx.softmax(model(x)[0, :-1].astype(mx.float32), axis=-1))
    tgt = mx.array(ids[1:])
    return mx.take_along_axis(lp, tgt[:, None], axis=1).sum().item()

rows = json.load(open(ROOT / 'eval' / 'baseline.json'))
mx.reset_peak_memory() if hasattr(mx, 'reset_peak_memory') else None
logprob('預熱一下')
gains = []                                  # per row: [(gain, pos, char)]
times = []
for r in rows:
    t0 = time.time()
    base, syl = r['baseline'], r['syllables']
    b = logprob(base)
    found = []                                # (gain, prior difference, position, char)
    for i, ch in enumerate(base):
        for c in alts.get(syl[i], []):
            if c == ch: continue
            g = logprob(base[:i] + c + base[i + 1:]) - b
            found.append((g, prior.get(c, -12) - prior.get(ch, -12), i, c))
    times.append(time.time() - t0)
    gains.append(found)
peak = mx.get_peak_memory() / 1e6 if hasattr(mx, 'get_peak_memory') else -1
print(f'{tag}: {sum(times)/len(times)*1000:.0f} ms/sentence (all positions, sequential), peak memory {peak:.0f} MB')
for w in WEIGHTS:
  for tau in TAUS:
    out = []
    for r, found in zip(rows, gains):
        s = list(r['baseline'])
        best = {}
        for g, dp, i, c in found:
            score = g + w * dp
            if score >= tau and score > best.get(i, (-1e9, None))[0]: best[i] = (score, c)
        for i, (_, c) in best.items(): s[i] = c
        out.append({**r, 'model': ''.join(s)})
    json.dump(out, open(ROOT / 'eval' / f'qwen_out_{tag}_w{w}_t{tau}.json', 'w'), ensure_ascii=False)
