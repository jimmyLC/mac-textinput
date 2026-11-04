#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_chinese_dict.py — ZhuyinLM-IME 自建中文詞典建置管線

來源(全部為開放授權)
  McBopomofo 官方發布 3.1.1(installer zip)內附的
    McBopomofo.app/Contents/Resources/data.txt                 ← 詞庫(reading word score)
    McBopomofo.app/Contents/Resources/associated-phrases-v2.txt ← 聯想詞
  授權:MIT(github.com/openvanilla/McBopomofo, LICENSE.txt)

處理
  1. 解析 data.txt:`reading word score`;score 為 log10 機率(越接近 0 越常見)。
  2. 跳過控制項(reading 或 word 以 `_` 開頭)與非漢字詞。
  3. 同一詞的多個讀音以 log-sum-exp(底 10)聚合:
        score = max + log10( Σ 10^(s_i - max) )
  4. 依聚合分數降序輸出。

輸出
  data/chinese-common-10000.txt        前 10,000 個常用字詞(一詞一行)
  data/chinese-common-10000.tsv        同順序 `詞<TAB>聚合分數<TAB>讀音(以 | 分隔)`
  data/chinese-lexicon.tsv             全量詞庫 `詞<TAB>聚合分數<TAB>讀音`
  data/chinese-associated-phrases.tsv  聯想詞 `詞<TAB>讀音<TAB>分數`
  data/chinese-manifest.json           來源、SHA-256、統計

用法
  python3 tools/build_chinese_dict.py [--offline] [--check]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
CACHE = DATA / ".cache"

MCB_RELEASE = "3.1.1"
MCB_INSTALLER_URL = (
    "https://github.com/openvanilla/McBopomofo/releases/download/"
    f"{MCB_RELEASE}/McBopomofo-Installer-{MCB_RELEASE}.zip"
)
INSTALLER_NAME = f"McBopomofo-Installer-{MCB_RELEASE}.zip"

DATA_TXT = "data.txt"
ASSOCIATED_TXT = "associated-phrases-v2.txt"

CJK_RE = re.compile(r"[㐀-䶿一-鿿豈-﫿]")
COMMON_SIZE = 10000


def log(msg: str) -> None:
    print(f"[build] {msg}", flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_upstream(offline: bool) -> tuple[Path, Path, dict[str, str]]:
    """取得上游 data.txt 與 associated-phrases-v2.txt,回傳 (path, path, sha256 對照)。"""
    CACHE.mkdir(parents=True, exist_ok=True)
    installer = CACHE / INSTALLER_NAME
    if not installer.exists():
        if offline:
            raise SystemExit(f"[build] offline 模式但缺少快取:{installer}")
        log(f"下載 McBopomofo {MCB_RELEASE} installer")
        subprocess.run(["curl", "-fsSL", "-o", str(installer), MCB_INSTALLER_URL], check=True)

    out_dir = CACHE / "mcbopomofo" / MCB_RELEASE
    digests: dict[str, str] = {}
    needed = [DATA_TXT, ASSOCIATED_TXT]
    missing = [n for n in needed if not (out_dir / n).exists()]
    if missing:
        if offline:
            raise SystemExit(f"[build] offline 模式但缺少解壓後的檔案:{missing}")
        log("解壓 installer(巢狀 zip)")
        tmp = Path(tempfile.mkdtemp(prefix="mcb-"))
        try:
            with zipfile.ZipFile(installer) as z:
                z.extractall(tmp)
            inner = next(tmp.rglob("McBopomofo-r*.zip"))
            with zipfile.ZipFile(inner) as z:
                for name in needed:
                    member = next((n for n in z.namelist() if n.endswith("/" + name)), None)
                    if member is None:
                        continue
                    out_dir.mkdir(parents=True, exist_ok=True)
                    with z.open(member) as src, (out_dir / name).open("wb") as dst:
                        shutil.copyfileobj(src, dst)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    for name in needed:
        path = out_dir / name
        if path.exists():
            digests[name] = sha256_file(path)
    return out_dir / DATA_TXT, out_dir / ASSOCIATED_TXT, digests


def log_sum_exp(scores: list[float]) -> float:
    """以底 10 的 log-sum-exp 聚合多個讀音分數。"""
    m = max(scores)
    return m + math.log10(sum(10 ** (s - m) for s in scores))


def parse_lexicon(path: Path) -> dict[str, dict[str, float]]:
    """回傳 {詞: {讀音: 分數}}。"""
    lexicon: dict[str, dict[str, float]] = {}
    skipped = 0
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            if not line or line.startswith("#"):
                continue
            parts = line.rstrip("\n").split(" ")
            if len(parts) != 3:
                skipped += 1
                continue
            reading, word, raw_score = parts
            if reading.startswith("_") or word.startswith("_"):
                skipped += 1
                continue
            if not CJK_RE.search(word):
                skipped += 1
                continue
            try:
                score = float(raw_score)
            except ValueError:
                skipped += 1
                continue
            lexicon.setdefault(word, {})[reading] = score
    log(f"詞庫解析:唯一漢字詞 {len(lexicon):,}(略過 {skipped:,} 筆控制項/非漢字)")
    return lexicon


def parse_associated(path: Path) -> list[tuple[str, str, float]]:
    """解析 associated-phrases-v2.txt:每行為 `字-注音-字-注音… 分數`。"""
    if not path.exists():
        return []
    out: list[tuple[str, str, float]] = []
    skipped = 0
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            if not line or line.startswith("#"):
                continue
            parts = line.rstrip("\n").split(" ")
            if len(parts) != 2:
                skipped += 1
                continue
            key, raw_score = parts
            fields = key.split("-")
            if len(fields) % 2 != 0:
                skipped += 1
                continue
            chars = fields[0::2]
            readings = fields[1::2]
            phrase = "".join(chars)
            reading = "".join(readings)
            if not phrase or not CJK_RE.search(phrase):
                skipped += 1
                continue
            try:
                score = float(raw_score)
            except ValueError:
                skipped += 1
                continue
            out.append((phrase, reading, score))
    log(f"聯想詞解析:{len(out):,} 筆(略過 {skipped:,} 筆)")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="建置自建中文詞典")
    ap.add_argument("--offline", action="store_true", help="只用本機 cache")
    ap.add_argument("--check", action="store_true", help="重建到暫存並比對既有輸出")
    args = ap.parse_args()

    data_txt, associated_txt, digests = ensure_upstream(args.offline)
    lexicon = parse_lexicon(data_txt)

    # 聚合:詞 → 聚合分數 + 依分數排序的讀音清單
    aggregated: list[tuple[str, float, list[tuple[str, float]]]] = []
    multi_reading = 0
    for word, readings in lexicon.items():
        pairs = sorted(readings.items(), key=lambda kv: (-kv[1], kv[0]))
        if len(pairs) > 1:
            multi_reading += 1
        score = log_sum_exp([s for _, s in pairs])
        aggregated.append((word, score, pairs))
    aggregated.sort(key=lambda t: (-t[1], t[0]))
    log(f"聚合完成:{len(aggregated):,} 詞(其中 {multi_reading:,} 詞有多讀音)")

    top = aggregated[:COMMON_SIZE]
    log(f"第 {COMMON_SIZE} 名門檻:{top[-1][0]} = {top[-1][1]:.6f}")

    # 覆蓋率:前 10,000 名佔全部詞機率質量的比例
    total_mass = sum(10 ** s for _, s, _ in aggregated)
    top_mass = sum(10 ** s for _, s, _ in top)
    coverage = top_mass / total_mass * 100

    outputs = {
        "chinese-common-10000.txt": "".join(f"{w}\n" for w, _, _ in top),
        "chinese-common-10000.tsv": "".join(
            f"{w}\t{s:.8f}\t{'|'.join(r for r, _ in pairs)}\n" for w, s, pairs in top
        ),
        "chinese-lexicon.tsv": "".join(
            f"{w}\t{s:.8f}\t{'|'.join(r for r, _ in pairs)}\n" for w, s, pairs in aggregated
        ),
        # 依讀音索引的 unigram 表:Gramambular 的 unigramsFor(reading) 直接吃這張
        "chinese-unigrams.tsv": "".join(
            f"{r}\t{w}\t{s:.8f}\n"
            for w, _, pairs in aggregated
            for r, s in pairs
        ),
    }
    associated = parse_associated(associated_txt)
    if associated:
        outputs["chinese-associated-phrases.tsv"] = "".join(
            f"{p}\t{r}\t{s:.4f}\n" for p, r, s in associated
        )

    # 自我檢查
    words = [w for w, _, _ in top]
    assert len(words) == len(set(words)), "常用詞表有重複"
    assert words == sorted(words, key=lambda w: -next(s for x, s, _ in aggregated if x == w)), "排序錯誤"
    scores = [s for _, s, _ in aggregated]
    assert all(scores[i] >= scores[i + 1] for i in range(len(scores) - 1)), "詞庫未依分數遞減"
    log("自我檢查通過")

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "generator": "tools/build_chinese_dict.py",
        "model": "zhuyinlm-ime/chinese-dict v1",
        "source": {
            "project": "openvanilla/McBopomofo",
            "license": "MIT",
            "release": MCB_RELEASE,
            "installerUrl": MCB_INSTALLER_URL,
            "files": {name: {"sha256": digest} for name, digest in digests.items()},
        },
        "counts": {
            "uniqueWords": len(aggregated),
            "commonTop": COMMON_SIZE,
            "multiReadingWords": multi_reading,
            "associatedPhrases": len(associated),
            "unigramRows": sum(len(pairs) for _, _, pairs in aggregated),
            "coverageOfMassPercent": round(coverage, 2),
            "thresholdScore": round(top[-1][1], 6),
        },
    }

    if args.check:
        drift = [n for n, c in outputs.items() if not (DATA / n).exists() or (DATA / n).read_text(encoding="utf-8") != c]
        if drift:
            log(f"✗ 輸出與重建結果不一致:{', '.join(drift)}(請重新執行建置)")
            return 1
        log("✓ 輸出與重建結果一致")
        return 0

    for name, content in outputs.items():
        (DATA / name).write_text(content, encoding="utf-8")
        log(f"寫入 data/{name}({len(content.splitlines()):,} 行)")
    (DATA / "chinese-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    log("寫入 data/chinese-manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
