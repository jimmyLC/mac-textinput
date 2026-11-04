#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eval_bigram_lm.py — 量化「詞接詞(bigram)統計」對選字的幫助

要回答的問題:只有 unigram(詞頻)時,整句正確率卡在哪裡;
加入 bigram 之後,同音詞的判斷有沒有變好、改善多少。

兩種評估
  A. 手寫歧義句集(tools/eval-cases.tsv):的/得/地、在/再、做/作…
     給定前文,比較「只用 unigram」與「unigram + bigram」能否把正解排第一。
  B. 語料式評估(leave-one-out):從 bigram 表取高頻配對,
     對每個前詞列出所有同讀音候選詞,比較兩種模型排第一的正確率。
     評估某一配對時,先把它自己的計數扣掉 1,避免「答案就在表裡」的假高分。

資料
  data/chinese-unigrams.tsv  `讀音<TAB>詞<TAB>log10 機率`
  data/chinese-bigrams.tsv   `前詞<TAB>後詞<TAB>共現次數`

用法
  python3 tools/eval_bigram_lm.py [--cases tools/eval-cases.tsv] [--sample 20000]
"""

from __future__ import annotations

import argparse
import math
import random
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
UNIGRAM = DATA / "chinese-unigrams.tsv"
BIGRAM = DATA / "chinese-bigrams.tsv"
CASES = ROOT / "tools" / "eval-cases.tsv"
ZHSEG = DATA / ".cache" / "zhsegment"
LEXICON = DATA / "chinese-lexicon.tsv"

ALPHA = 0.10  # bigram 對 unigram 的平滑權重(加 alpha 法)
LAMBDA = 0.60  # 插值係數:有 bigram 計數時的混合權重


def log(msg: str) -> None:
    print(f"[eval] {msg}", flush=True)


def load_unigrams() -> tuple[dict[str, dict[str, float]], dict[str, list[str]]]:
    """回傳 (讀音 → {詞: log10 機率}, 詞 → 讀音清單)。"""
    by_reading: dict[str, dict[str, float]] = defaultdict(dict)
    word_readings: dict[str, list[str]] = defaultdict(list)
    with UNIGRAM.open(encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            reading, word, score = parts
            by_reading[reading][word] = float(score)
            word_readings[word].append(reading)
    return by_reading, word_readings


def load_bigrams() -> tuple[dict[tuple[str, str], int], dict[str, int]]:
    counts: dict[tuple[str, str], int] = {}
    totals: dict[str, int] = defaultdict(int)
    with BIGRAM.open(encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            a, b, c = parts[0], parts[1], int(parts[2])
            counts[(a, b)] = c
            totals[a] += c
    return counts, totals


def segment(text: str) -> list[str]:
    """用 tools/zhsegment 斷詞。"""
    if not ZHSEG.exists():
        raise SystemExit("[eval] 缺少 data/.cache/zhsegment,請先執行 tools/build_chinese_bigrams.py")
    out = subprocess.run(
        [str(ZHSEG), str(LEXICON), "--segment"],
        input=text.encode("utf-8"),
        stdout=subprocess.PIPE,
        check=True,
    ).stdout.decode("utf-8")
    return [w for w in out.strip().split("/") if w]


def prob(log10p: float) -> float:
    return 10 ** log10p


class Scorer:
    """兩種模型:只用 unigram / unigram + bigram。"""

    def __init__(self, by_reading, word_readings, counts, totals):
        self.by_reading = by_reading
        self.word_readings = word_readings
        self.counts = counts
        self.totals = totals

    def unigram(self, word: str, reading: str | None) -> float:
        if reading and word in self.by_reading.get(reading, {}):
            return self.by_reading[reading][word]
        readings = self.word_readings.get(word)
        if readings:
            return max(self.by_reading[r][word] for r in readings if word in self.by_reading.get(r, {}))
        return -12.0

    def candidates(self, word: str) -> list[str]:
        """同讀音的候選詞。"""
        readings = self.word_readings.get(word, [])
        if not readings:
            return [word]
        out: list[str] = []
        for r in readings:
            out.extend(self.by_reading.get(r, {}).keys())
        return sorted(set(out))

    def score_unigram(self, word: str, reading: str | None) -> float:
        return self.unigram(word, reading)

    def score_bigram(self, prev: str | None, word: str, reading: str | None, holdout: bool = False) -> float:
        if not prev:
            return self.unigram(word, reading)
        total = self.totals.get(prev, 0)
        c = self.counts.get((prev, word), 0)
        if holdout:
            c = max(c - 1, 0)
            total = max(total - 1, 0)
        pu = prob(self.unigram(word, reading))
        if total == 0:
            return self.unigram(word, reading)
        pb = (c + ALPHA * pu) / (total + ALPHA)
        pmix = LAMBDA * pb + (1 - LAMBDA) * pu
        return math.log10(max(pmix, 1e-12))


def rank(scores: dict[str, float]) -> list[str]:
    return sorted(scores, key=lambda w: (-scores[w], w))


def eval_cases(scorer: Scorer, path: Path) -> dict:
    rows = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            prefix, gold, alts_raw = parts[0], parts[1], parts[2]
            suffix = parts[3] if len(parts) > 3 else ""
            alts = [a for a in alts_raw.split("|") if a and a != gold]
            prefix_words = segment(prefix) if prefix else []
            prev = prefix_words[-1] if prefix_words else None
            cands = [gold] + alts
            u = {c: scorer.score_unigram(c, None) for c in cands}
            b = {c: scorer.score_bigram(prev, c, None) for c in cands}
            ru, rb = rank(u), rank(b)
            rows.append(
                {
                    "sentence": prefix + gold + suffix,
                    "gold": gold,
                    "alts": alts,
                    "prev": prev,
                    "rank_unigram": ru.index(gold) + 1,
                    "rank_bigram": rb.index(gold) + 1,
                }
            )
    return {
        "rows": rows,
        "u_top1": sum(1 for r in rows if r["rank_unigram"] == 1),
        "b_top1": sum(1 for r in rows if r["rank_bigram"] == 1),
        "n": len(rows),
    }


def eval_corpus(scorer: Scorer, counts, totals, sample: int, seed: int = 42) -> dict:
    """leave-one-out:對每個高頻配對,比較兩種模型在同讀音候選中的排序。"""
    rng = random.Random(seed)
    items = [(a, b, c) for (a, b), c in counts.items() if c >= 2]
    if sample and sample < len(items):
        items = rng.sample(items, sample)
    u_hit = b_hit = 0
    n = 0
    buckets: dict[str, list[int]] = defaultdict(list)  # 每筆存 [unigram hit, bigram hit]
    for prev, cur, c in items:
        cands = scorer.candidates(cur)
        if len(cands) < 2:
            continue
        readings = scorer.word_readings.get(cur, [])
        reading = readings[0] if readings else None
        u = {w: scorer.score_unigram(w, reading) for w in cands}
        b = {w: scorer.score_bigram(prev, w, reading, holdout=(w == cur)) for w in cands}
        ru, rb = rank(u), rank(b)
        n += 1
        hit_u = int(ru[0] == cur)
        hit_b = int(rb[0] == cur)
        u_hit += hit_u
        b_hit += hit_b
        bucket = "2-4" if c < 5 else ("5-19" if c < 20 else ("20-99" if c < 100 else "100+"))
        buckets[bucket].append(hit_u * 2 + hit_b)
    return {
        "n": n,
        "u_top1": u_hit,
        "b_top1": b_hit,
        "buckets": {
            k: (
                len(v),
                sum(1 for x in v if x in (2, 3)),   # unigram 命中(打包值 2 或 3)
                sum(1 for x in v if x in (1, 3)),   # bigram 命中(打包值 1 或 3)
            )
            for k, v in sorted(buckets.items())
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="評估 bigram 對選字的幫助")
    ap.add_argument("--cases", default=str(CASES))
    ap.add_argument("--sample", type=int, default=20000, help="語料式評估抽樣的配對數")
    args = ap.parse_args()

    if not BIGRAM.exists():
        raise SystemExit(f"[eval] 缺少 {BIGRAM},請先執行 tools/build_chinese_bigrams.py")

    log("載入 unigram…")
    by_reading, word_readings = load_unigrams()
    log("載入 bigram…")
    counts, totals = load_bigrams()
    log(f"unigram 讀音 {len(by_reading):,} / 詞 {len(word_readings):,};bigram 配對 {len(counts):,}")
    scorer = Scorer(by_reading, word_readings, counts, totals)

    log("A. 手寫歧義句集…")
    cases = eval_cases(scorer, Path(args.cases))
    log("B. 語料式 leave-one-out…")
    corpus = eval_corpus(scorer, counts, totals, args.sample)

    print()
    print("=" * 72)
    print("A. 手寫歧義句集")
    print("=" * 72)
    print(f"{'句子':<24}{'正解':<6}{'unigram 排名':>12}{'bigram 排名':>12}")
    for r in cases["rows"]:
        flag_u = "✓" if r["rank_unigram"] == 1 else " "
        flag_b = "✓" if r["rank_bigram"] == 1 else " "
        print(f"{r['sentence']:<24}{r['gold']:<6}{flag_u}{r['rank_unigram']:>10}{flag_b}{r['rank_bigram']:>10}")
    print("-" * 72)
    print(f"命中正解:unigram {cases['u_top1']}/{cases['n']}  |  bigram {cases['b_top1']}/{cases['n']}")

    print()
    print("=" * 72)
    print("B. 語料式 leave-one-out(同讀音候選中,正解排第一的比例)")
    print("=" * 72)
    print(f"{'共現次數':<12}{'樣本數':>10}{'unigram':>12}{'bigram':>12}{'提升':>10}")
    for bucket, (n, u, b) in corpus["buckets"].items():
        print(f"{bucket:<12}{n:>10,}{u/n*100:>11.1f}%{b/n*100:>11.1f}%{(b-u)/n*100:>+9.1f}pp")
    n = corpus["n"]
    print("-" * 72)
    print(
        f"全部:{n:,} 組  unigram {corpus['u_top1']/n*100:.1f}%  "
        f"bigram {corpus['b_top1']/n*100:.1f}%  "
        f"({(corpus['b_top1']-corpus['u_top1'])/n*100:+.1f}pp)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
