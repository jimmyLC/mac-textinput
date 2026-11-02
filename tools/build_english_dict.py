#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_english_dict.py — ZhuyinLM-IME 自建英文詞典建置管線

輸入(基底 + 開放來源)
  data/sources/base-english-100000.txt   第三方種子詞表(既有 english-common-100000.txt,已搬移)
  data/sources/tech-terms.txt            本專案自建技術/品牌詞
  https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt        (Unlicense)
  https://raw.githubusercontent.com/first20hours/google-10000-english/master/...usa.txt (MIT)
  hunspell en_US-large(SCOWL,wordlist.aspell.net)                                   (僅本機快取,衍生使用)
  wordfreq(MIT)                                                                  詞頻權重

輸出
  data/english-words.txt          TSV `word<TAB>count`,引擎內建預測詞頻表(自建權重)
  data/english-common-10000.txt   高信心核心 10,000 詞
  data/english-tech-terms.txt     技術/品牌詞(可含數字,如 mp3、k8s)
  data/english-dictionary.txt     全量合法詞(驗收用,不含權重)
  data/english-manifest.json     建置後設(來源、SHA-256、統計)

權重模型(可重現、無黑箱)
  z  = wordfreq.zipf_frequency(word, 'en')            0..8 的對數詞頻
  z += 0.30 * (1 - base_rank / |base|)                基底詞表的網頁語料順位
  z += 0.25  若在 google-10000(人工挑選的常用詞)
  z += 0.10  若在 hunspell 小寫詞幹(標準英文字典)
  z  = max(z, 2.20)  若為自建技術詞                    技術詞可被預測但不擠掉常用詞
  z  = max(z, 1.10)  若未通過任何字典驗證(多為專名)     保留但排在最末端
  count = round(10 ** z)                              單調遞增,量級與舊表相近

用法
  python3 tools/build_english_dict.py            # 下載(必要時)+ 重建輸出
  python3 tools/build_english_dict.py --offline  # 只用本機 cache
  python3 tools/build_english_dict.py --check    # 重建到暫存並比對,不一致則 exit 1(CI 用)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SOURCES = DATA / "sources"
CACHE = SOURCES / "cache"
BASE_FILE = SOURCES / "base-english-100000.txt"
TECH_FILE = SOURCES / "tech-terms.txt"

WORD_RE = re.compile(r"^[a-z]{1,20}$")
TECH_RE = re.compile(r"^[a-z][a-z0-9]{0,19}$")

REMOTE_SOURCES = {
    "words_alpha.txt": "https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt",
    "google-10000-english-usa.txt": "https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english-usa.txt",
    "hunspell_en_US-large.zip": "https://github.com/en-wl/wordlist/releases/download/rel-2026.02.25/hunspell-en_US-large-2026.02.25.zip",
}

# 權重參數(見模組 docstring)
W_BASE_SPAN = 0.30
W_GOOGLE = 0.25
W_HUNSPELL = 0.10
Z_TECH_FLOOR = 2.20
Z_UNVERIFIED_FLOOR = 1.10
Z_MIN = 1.00
Z_MAX = 9.00
CORE_SIZE = 10000


def log(msg: str) -> None:
    print(f"[build] {msg}", flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(offline: bool) -> dict[str, str]:
    """取得(或沿用 cache 的)遠端來源,回傳 sha256 對照。"""
    CACHE.mkdir(parents=True, exist_ok=True)
    digests: dict[str, str] = {}
    for name, url in REMOTE_SOURCES.items():
        dest = CACHE / name
        if not dest.exists():
            if offline:
                raise SystemExit(f"[build] offline 模式但缺少快取:{dest}")
            log(f"下載 {name}")
            subprocess.run(["curl", "-fsSL", "-o", str(dest), url], check=True)
        digests[name] = sha256_file(dest)
    return digests


def read_words(path: Path, pattern: re.Pattern[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        w = line.strip().lower()
        if not w or w.startswith("#") or not pattern.fullmatch(w):
            continue
        if w in seen:
            continue
        seen.add(w)
        out.append(w)
    return out


def load_hunspell_stems() -> tuple[set[str], set[str]]:
    """回傳 (小寫詞幹集合, 專名/首字母大寫集合)。"""
    import zipfile

    zip_path = CACHE / "hunspell_en_US-large.zip"
    lower: set[str] = set()
    capital: set[str] = set()
    with zipfile.ZipFile(zip_path) as zf:
        name = next(n for n in zf.namelist() if n.endswith(".dic"))
        with zf.open(name) as fh:
            for raw in fh:
                token = raw.decode("utf-8").strip().split("/")[0]
                if not token:
                    continue
                if token.islower():
                    lower.add(token)
                else:
                    capital.add(token)
    return lower, capital


def validate(table: list[tuple[str, int]], dictionary: list[str]) -> None:
    """產出前的自我檢查:唯一性、排序、格式。"""
    words = [w for w, _ in table]
    assert len(words) == len(set(words)), "預測詞頻表有重複詞"
    counts = [c for _, c in table]
    assert all(counts[i] >= counts[i + 1] for i in range(len(counts) - 1)), "預測詞頻表未依 count 遞減"
    assert all(WORD_RE.fullmatch(w) for w in words), "預測詞頻表含非法字元"
    assert len(dictionary) == len(set(dictionary)), "全量詞典有重複詞"
    assert dictionary == sorted(dictionary), "全量詞典未排序"
    log("自我檢查通過")


def main() -> int:
    ap = argparse.ArgumentParser(description="建置自建英文詞典")
    ap.add_argument("--offline", action="store_true", help="只用本機 cache,不連網")
    ap.add_argument("--check", action="store_true", help="重建到暫存並比對既有輸出")
    args = ap.parse_args()

    if not BASE_FILE.exists():
        raise SystemExit(f"[build] 缺少基底詞表:{BASE_FILE}")
    if not TECH_FILE.exists():
        raise SystemExit(f"[build] 缺少技術詞表:{TECH_FILE}")

    try:
        from wordfreq import zipf_frequency
    except ImportError:
        raise SystemExit("[build] 需要 wordfreq:pip install wordfreq")

    source_digests = download(args.offline)

    base = read_words(BASE_FILE, WORD_RE)
    base_rank = {w: i for i, w in enumerate(base)}
    tech = read_words(TECH_FILE, TECH_RE)
    tech_set = set(tech)
    dwyl = set(read_words(CACHE / "words_alpha.txt", WORD_RE))
    google = set(read_words(CACHE / "google-10000-english-usa.txt", WORD_RE))
    hs_lower, hs_capital = load_hunspell_stems()
    log(
        f"來源:base={len(base)} tech={len(tech)} dwyl={len(dwyl)} "
        f"google10k={len(google)} hunspell_lower={len(hs_lower)} hunspell_cap={len(hs_capital)}"
    )

    # 候選集合:基底 ∪ google10k ∪ 技術詞 ∪ 純字母的通用高頻詞
    candidates: set[str] = set(base) | google | {t for t in tech if WORD_RE.fullmatch(t)}
    from wordfreq import top_n_list

    for w in top_n_list("en", 50000):
        if WORD_RE.fullmatch(w):
            candidates.add(w)

    scored: list[tuple[str, float, int]] = []
    stats = {"core": 0, "common": 0, "tech": 0, "extended": 0}
    for w in candidates:
        z = zipf_frequency(w, "en")
        if w in base_rank:
            z += W_BASE_SPAN * (1 - base_rank[w] / max(len(base), 1))
        if w in google:
            z += W_GOOGLE
        if w in hs_lower:
            z += W_HUNSPELL
        if w in tech_set:
            z = max(z, Z_TECH_FLOOR)
        verified = w in hs_lower or w in dwyl or w in google
        if not verified:
            z = max(z, Z_UNVERIFIED_FLOOR)
        z = min(max(z, 0.0), Z_MAX)
        if w in google or (w in hs_lower and z >= 4.0):
            stats["core"] += 1
        elif verified:
            stats["common"] += 1
        elif w in tech_set:
            stats["tech"] += 1
        else:
            stats["extended"] += 1
        scored.append((w, z, base_rank.get(w, 10**9)))

    scored.sort(key=lambda t: (-t[1], t[2], t[0]))
    table = [(w, int(round(10 ** z))) for w, z, _ in scored if z >= Z_MIN]
    log(f"預測詞頻表: {len(table)} 詞;分層 {stats}")

    out_dir = Path(tempfile.mkdtemp(prefix="zhuyindict-")) if args.check else DATA
    dictionary = sorted(dwyl | hs_lower | set(base) | google)
    validate(table, dictionary)
    outputs = {
        "english-words.txt": "".join(f"{w}\t{c}\n" for w, c in table),
        "english-common-10000.txt": "".join(f"{w}\n" for w, _ in table[:CORE_SIZE]),
        "english-tech-terms.txt": "".join(
            f"{w}\n" for w, _ in sorted(
                ((w, c) for w, c in table if w in tech_set), key=lambda t: (-t[1], t[0])
            )
        )
        + "".join(f"{w}\n" for w in tech if not WORD_RE.fullmatch(w)),
        "english-dictionary.txt": "".join(f"{w}\n" for w in dictionary),
    }
    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "generator": "tools/build_english_dict.py",
        "model": "zhuyinlm-ime/english-dict v1",
        "sources": {
            "base-english-100000.txt": {
                "origin": "data/sources/base-english-100000.txt",
                "license": "third-party seed (see data/ENGLISH-DICT.md)",
                "sha256": sha256_file(BASE_FILE),
                "words": len(base),
            },
            "tech-terms.txt": {
                "origin": "data/sources/tech-terms.txt",
                "license": "project-authored",
                "sha256": sha256_file(TECH_FILE),
                "words": len(tech),
            },
            **{
                name: {
                    "url": REMOTE_SOURCES[name],
                    "sha256": digest,
                    "license": {
                        "words_alpha.txt": "Unlicense",
                        "google-10000-english-usa.txt": "MIT",
                        "hunspell_en_US-large.zip": "SCOWL (local cache only, not redistributed)",
                    }[name],
                }
                for name, digest in source_digests.items()
            },
            "wordfreq": {"origin": "pip:wordfreq", "license": "MIT", "version": _pkg_version("wordfreq")},
        },
        "counts": {
            "predictionTable": len(table),
            "core": CORE_SIZE,
            "dictionary": len(outputs["english-dictionary.txt"].splitlines()),
            "techTerms": len(tech),
            "tiers": stats,
        },
        "weights": {
            "baseSpan": W_BASE_SPAN,
            "google": W_GOOGLE,
            "hunspell": W_HUNSPELL,
            "techFloor": Z_TECH_FLOOR,
            "unverifiedFloor": Z_UNVERIFIED_FLOOR,
            "min": Z_MIN,
            "max": Z_MAX,
        },
    }

    if args.check:
        drift = []
        for name, content in outputs.items():
            path = DATA / name
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                drift.append(name)
        if drift:
            log(f"✗ 輸出與重建結果不一致:{', '.join(drift)}(請重新執行建置)")
            shutil.rmtree(out_dir, ignore_errors=True)
            return 1
        log("✓ 輸出與重建結果一致")
        shutil.rmtree(out_dir, ignore_errors=True)
        return 0

    for name, content in outputs.items():
        (out_dir / name).write_text(content, encoding="utf-8")
        log(f"寫入 {out_dir / name}({len(content.splitlines())} 行)")
    (out_dir / "english-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    log("寫入 english-manifest.json")
    return 0


def _pkg_version(name: str) -> str:
    try:
        from importlib.metadata import version

        return version(name)
    except Exception:  # pragma: no cover
        return "unknown"


if __name__ == "__main__":
    sys.exit(main())
