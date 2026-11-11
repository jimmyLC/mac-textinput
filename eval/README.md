# Homophone reranker eval (phase 0)

Self-written test set (`homophone_sentences.txt`, 139 punctuation-free Traditional Chinese sentences, no third-party text).
Gold syllables come from the bundled lexicon; the baseline is a unigram Viterbi over the same lexicon (a stand-in for the engine's default choice, weaker than the real engine).

```
python3 eval/lexicon_baseline.py                                   # writes eval/baseline.json
swiftc -parse-as-library eval/apple_fm_eval.swift -o /tmp/fm_eval  # Apple on-device model, no download
/tmp/fm_eval eval/baseline.json eval/apple_fm_out.json
python3 eval/score.py eval/apple_fm_out.json
```

`score.py` accepts a model edit only when the new character is a true homophone of the typed syllable; 她/他/它, 盡/儘 and 復/覆/複 count as equal.

## Results (2026-11-04, M5 / macOS 27, Apple on-device model, temperature 0)
| | baseline | Apple FM |
|---|---|---|
| sentences exactly right | 99/139 | 117/139 |
| CorrectionRate (wrong chars fixed) | - | 17/36 = 47% (target >= 25%) |
| RegressionRate (right chars broken) | - | 1/1356 = 0.07% (target <= 2%) |
| latency | - | about 0.37 s per sentence, sequential, whole sentence generated |

Caveats: only 36 wrong characters, so the rate is +/- 15 points; the baseline is weaker than McBopomofo itself; sentences are my own, not real typing. Misses include the motivating `打完自`, and 再/在.

## Qwen (MLX, teacher-forced log-prob) vs Apple
`qwen_eval.py <mlx repo> <tag>` tries, per position, the other characters sharing the typed syllable (top 8 single characters that occur in multi-character lexicon words, which also drops simplified forms) and keeps a swap only when `log-prob gain + w * lexicon-prior difference >= tau`. Venv with `mlx-lm` needs Python 3.14 (3.15 cannot build sentencepiece). Models: `mlx-community/Qwen2.5-0.5B-4bit` (290 MB), `mlx-community/Qwen2.5-1.5B-4bit` (880 MB).

| backend | setting | CorrectionRate | RegressionRate | latency* | memory | disk |
|---|---|---|---|---|---|---|
| Apple FM | whole-sentence rewrite | 17/36 = 47% | 1/1356 = 0.07% | 370 ms | system | 0 |
| Qwen2.5-0.5B-4bit | w=0.5, tau=2 | 25/36 = 69% | 3/1356 = 0.22% | 334 ms | 332 MB | 290 MB |
| Qwen2.5-1.5B-4bit | w=0, tau=2 | 26/36 = 72% | 1/1356 = 0.07% | 808 ms | 921 MB | 880 MB |
| Qwen2.5-1.5B-4bit | w=0, tau=1 | 30/36 = 83% | 5/1356 = 0.37% | 808 ms | 921 MB | 880 MB |

*per whole sentence, every position and 8 alternatives scored sequentially; a product would score only the position being checked and cache, so real latency should be much lower. Same 36-wrong-character caveat as above. Qwen fixes the motivating `打完自` (to `字`) and 再/在 in some cases; failures include an unrelated swap `就` to `救` at 0.5B.

## Zhizhi engine, stage 1 (2026-11-04, no AI yet)
`cd Zhizhi && swift build -c release && .build/release/zhizhi-eval .. sentences|mixed|replay <log>`. The test set grew to 406 self-written sentences; `mixed_sentences.txt` adds 60 Chinese/English ones typed in lowercase with no spaces.
| measure | old-style unigram baseline | Zhizhi engine |
|---|---|---|
| sentences exactly right (406) | 305 = 75% | 314 = 77% |
| mixed: language split right (60) | - | 57 |
| mixed: exactly right (60) | - | 50 |
| decode per key | - | p95 0.20 ms on the sentence set, 0.18 ms on the replay |
Replaying the owner's key log (private, not in the repo): none of the old wrong auto-English triggers still turns into English; the one English word left (`learning`) is correct. Remaining sentence errors are mostly context homophones (在/再, 分/份, 理/裡), which is what the local-AI stage targets; the 90% gate is not met yet.

## Zhizhi with the local AI, stage 3 (2026-11-04)
`zhizhi-eval .. ai <helper> <model folder>` runs the 406 sentences through the real Swift helper, with the engine's output and at most 8 same-sound characters per position. Whole sentence typed, then scored once.
| threshold | exact | wrong characters fixed | right characters broken |
|---|---|---|---|
| none (engine only) | 314 = 77% | - | - |
| 1.0 | 357 = 87% | 89/115 | 33/3568 |
| 2.0 | 362 = 89% | 82/115 | 21/3568 |
| 2.5 (shipped) | 363 = 89% | 79/115 = 69% | 16/3568 = 0.45% |
| 4.0 | 363 = 89% | 74/115 | 11/3568 |
Helper per sentence: p50 449 ms, p95 1857 ms, off the key path. Peak memory about 1.3 GB while loaded, freed after 5 idle minutes. Swift and Python log-probabilities agree within about 0.1. Caveats: the threshold was picked on this same set, the sentences are self-written, and real typing commits without always pausing, so real-use accuracy will be lower. The 90% gate is not met.

## Apple's on-device model as a choice (2026-11-05)
`zhizhi-eval .. apple` uses the same sentences and engine. The model rewrites the sentence, and only same-sound swaps the plan allows come through; punctuation it adds is ignored, and an answer of another length is dropped (22 of 406 here).
| model | exact | wrong characters fixed | right characters broken | per sentence | memory | disk |
|---|---|---|---|---|---|---|
| engine only | 314 = 77% | - | - | - | - | - |
| Apple on-device | 344 = 84% | 38/115 = 33% | 2/3568 = 0.06% | p50 383 ms, p95 568 ms | system | 0 |
| Qwen 1.5B, threshold 2.5 | 363 = 89% | 79/115 = 69% | 16/3568 = 0.45% | p50 449 ms, p95 1857 ms | about 1.3 GB | 880 MB |
Same caveats as above. Measured from a command-line process; an input method runs in the background, where the system may limit this model more, which is not measured.
