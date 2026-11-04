#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_english_dict.py — ZhuyinLM-IME 自建英文詞典建置管線

輸入(全部為開放授權,可自由散布)
  https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt         (Unlicense)
  https://raw.githubusercontent.com/first20hours/google-10000-english/master/...usa.txt (MIT)
  hunspell en_US-large(SCOWL,wordlist.aspell.net)                                    (僅本機快取)
  wordfreq(MIT)                                                                     詞頻權重
  tools/tech-terms.txt                                                               本專案自建技術/品牌詞

輸出
  data/english-words.txt          TSV `word<TAB>count`,引擎內建預測詞頻表
  data/english-common-10000.txt   高信心核心 10,000 詞
  data/english-tech-terms.txt     技術/品牌詞(可含數字,如 mp3、k8s)
  data/english-dictionary.txt     全量合法詞(驗收用,不含權重)
  data/english-manifest.json      建置後設(來源、SHA-256、統計、權重參數)

權重模型(可重現、無黑箱)
  z  = wordfreq.zipf_frequency(word, 'en')            0..8 的對數詞頻
  z += 0.25  若命中 google-10000(人工挑選的常用詞)
  z += 0.10  若命中 hunspell 小寫詞幹(標準英文字典)
  z  = max(z, 2.20)  若為自建技術詞                    技術詞可被預測但不擠掉常用詞
  「已驗證」= 標準字典(hunspell)/ google-10000 / 技術詞;dwyl 不算已驗證
  未通過驗證者(多為非標準拼寫與冷僻詞):z < 3.5 一律不進預測表
  count = round(10 ** z)                              單調遞增

用法
  python3 tools/build_english_dict.py            # 下載(必要時)+ 重建輸出
  python3 tools/build_english_dict.py --offline  # 只用本機 cache
  python3 tools/build_english_dict.py --check    # 重建到暫存並比對,不一致則 exit 1(CI 用)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
CACHE = ROOT / "data" / ".cache"
TECH_FILE = ROOT / "tools" / "tech-terms.txt"

WORD_RE = re.compile(r"^[a-z]{1,20}$")
TECH_RE = re.compile(r"^[a-z][a-z0-9]{0,19}$")

REMOTE_SOURCES = {
    "words_alpha.txt": "https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt",
    "google-10000-english-usa.txt": "https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english-usa.txt",
    "hunspell_en_US-large.zip": "https://github.com/en-wl/wordlist/releases/download/rel-2026.02.25/hunspell-en_US-large-2026.02.25.zip",
}

# 權重參數(見模組 docstring)
W_GOOGLE = 0.25
W_HUNSPELL = 0.10
Z_TECH_FLOOR = 2.20
Z_UNVERIFIED_MIN = 3.50
# 「疑似誤字」判定:若某詞與一個常用詞只差一次編輯,且常用詞的頻率高
# 10^TYPO_Z_DELTA 倍以上,則該詞視為誤字,不進預測表(但保留於驗收字典)。
# 這同時解決兩件事:
#   1. 拼字修正:打 enviroment / untill / wich 時不再因為「詞表裡有這個錯字」而無法提示
#   2. 組字路由:rul(rule 的誤字)這類冷僻 token 不會在第 3 個字母就把中文組字打成英文
TYPO_Z_DELTA = 2.50
TYPO_Z_DELTA_SHORT = 2.90   # 3 字母 token 用更嚴的門檻
Z_MIN = 1.00
Z_MAX = 9.00
CORE_SIZE = 10000
WORD_FREQ_TOP = 300000


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


def likely_typos(words, zmap: dict[str, float], delta: float, exempt: set[str] | None = None) -> set[str]:
    """找出疑似誤字:與常用詞只差一次編輯,且該常用詞的頻率高出 delta 個對數單位。"""
    letters = "abcdefghijklmnopqrstuvwxyz"
    out: set[str] = set()
    for w in words:
        zw = zmap.get(w, 0.0)
        # 3 字母以內的 token 判定更嚴(delta 更高):因為短字很容易撞到常用短詞
        # ("hel"→"he"、"teh"→"the"),門檻過低會把真詞("hel")也殺掉,
        # 害得「輸入進行中顯示英文」失效。
        if zw >= 4.0:
            continue  # 明顯常見的詞不會是誤字
        if len(w) <= 3:
            delta = TYPO_Z_DELTA_SHORT
        if exempt and w in exempt and zw >= 2.5:
            continue  # 常用詞的前綴(輸入進行中),不算誤字
        near: set[str] = set()
        for i in range(len(w) + 1):
            if i < len(w):
                near.add(w[:i] + w[i + 1:])                      # 刪除
            if i + 1 < len(w):
                near.add(w[:i] + w[i + 1] + w[i] + w[i + 2:])      # 換位
            for c in letters:
                if i < len(w):
                    near.add(w[:i] + c + w[i + 1:])                # 替換
                near.add(w[:i] + c + w[i:])                        # 插入
        for c in near:
            zc = zmap.get(c)
            if zc is not None and zc >= zw + delta:
                out.add(w)
                break
    return out


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

    if not TECH_FILE.exists():
        raise SystemExit(f"[build] 缺少技術詞表:{TECH_FILE}")

    try:
        from wordfreq import top_n_list, zipf_frequency
    except ImportError:
        raise SystemExit("[build] 需要 wordfreq:pip install wordfreq")

    source_digests = download(args.offline)

    tech = read_words(TECH_FILE, TECH_RE)
    tech_set = set(tech)
    dwyl = set(read_words(CACHE / "words_alpha.txt", WORD_RE))
    google = set(read_words(CACHE / "google-10000-english-usa.txt", WORD_RE))
    hs_lower, hs_capital = load_hunspell_stems()
    # 引擎只吃 ASCII a-z;hunspell 詞幹含少數帶音符的字(如 émigré),此處濾掉
    hs_lower_ascii = {w for w in hs_lower if WORD_RE.fullmatch(w)}
    log(
        f"來源:tech={len(tech)} dwyl={len(dwyl)} google10k={len(google)} "
        f"hunspell_lower={len(hs_lower)}(ascii {len(hs_lower_ascii)}) hunspell_cap={len(hs_capital)}"
    )

    # 候選集合:標準字典 ∪ google-10k ∪ 技術詞 ∪ 通用高頻詞(詞頻語料)。
    # dwyl 不用於預測表(它含大量非標準拼寫與冷僻 token),只用於驗收字典。
    candidates: set[str] = set(hs_lower_ascii) | google | {t for t in tech if WORD_RE.fullmatch(t)}
    for w in top_n_list("en", WORD_FREQ_TOP):
        if WORD_RE.fullmatch(w):
            candidates.add(w)

    # 常用詞的 2–3 字母前綴:例如 "hel" 是 "hello" 的前綴,輸入進行中就該顯示英文。
    # 這些短字多半是真實短詞/縮寫,保留可讓「邊打邊判斷英文」規則運作;
    # 其餘只有 dwyl 支持的長字(非標準拼寫、冷僻詞)一律不進預測表。
    short_prefixes: set[str] = set()
    for w in sorted(candidates, key=lambda x: -zipf_frequency(x, "en"))[:30_000]:
        # 只取「真前綴」(長度大於前綴本身),避免把 teh 這類 3 字母誤拼當成合法短詞
        for n in (2, 3):
            if len(w) > n:
                short_prefixes.add(w[:n])

    # 疑似誤字:與常用詞只差一次編輯、且本身夠冷僻的詞
    zmap: dict[str, float] = {}
    for w in candidates:
        zmap[w] = zipf_frequency(w, "en")
    # 「輸入進行中」的 token:常用詞的前綴且自身不算冷僻 → 不是誤字,保留
    # (例:"hel" 是 "hello" 的前綴,使用者打一半時應顯示英文)
    common_prefixes: set[str] = set()
    for w, zw in zmap.items():
        if zw < 4.0:
            continue
        for n in range(2, min(len(w), 8)):
            common_prefixes.add(w[:n])
    typos = likely_typos(candidates, zmap, TYPO_Z_DELTA, common_prefixes)
    log(f"疑似誤字(1 次編輯鄰居常用度差 ≥ 10^{TYPO_Z_DELTA}):{len(typos):,} 詞")

    scored: list[tuple[str, float]] = []
    stats = {"core": 0, "common": 0, "tech": 0}
    dropped_unverified = 0
    dropped_typos = 0
    for w in candidates:
        if w in typos:
            dropped_typos += 1
            continue
        z = zipf_frequency(w, "en")
        if w in google:
            z += W_GOOGLE
        if w in hs_lower:
            z += W_HUNSPELL
        if w in tech_set:
            z = max(z, Z_TECH_FLOOR)
        z = min(max(z, 0.0), Z_MAX)
        # 「已驗證」只認標準來源:hunspell 標準詞幹 / google-10k / 自建技術詞。
        # dwyl(所有英文字串集合)含大量非標準拼寫(wich、untill、enviroment),
        # 若視為已驗證,拼字修正功能會對這些字失效 → 只作驗收字典,不進預測表。
        verified = w in hs_lower_ascii or w in google or w in tech_set
        if not verified:
            is_short_prefix = 2 <= len(w) <= 3 and w in short_prefixes
            if z < Z_UNVERIFIED_MIN and not is_short_prefix:
                dropped_unverified += 1
                continue
        scored.append((w, z))

    scored.sort(key=lambda t: (-t[1], t[0]))
    table = [(w, int(round(10 ** z))) for w, z in scored if z >= Z_MIN]
    # 分層僅統計實際進入預測表的詞
    table_words = {w for w, _ in table}
    zmap = dict(scored)
    for w in table_words:
        if w in google or (w in hs_lower_ascii and zmap[w] >= 4.0):
            stats["core"] += 1
        elif w in tech_set and w not in hs_lower_ascii and w not in dwyl:
            stats["tech"] += 1
        else:
            stats["common"] += 1
    log(
        f"預測詞頻表:{len(table)} 詞;分層 {stats};"
        f"略過 {dropped_unverified} 個未驗證且不常見的詞、{dropped_typos} 個疑似誤字"
    )

    out_dir = Path(tempfile.mkdtemp(prefix="zhuyindict-")) if args.check else DATA
    dictionary = sorted(dwyl | hs_lower_ascii | google | {t for t in tech if WORD_RE.fullmatch(t)})
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
        "model": "zhuyinlm-ime/english-dict v2",
        "sources": {
            "tech-terms.txt": {
                "origin": "tools/tech-terms.txt",
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
            "dictionary": len(dictionary),
            "techTerms": len(tech),
            "tiers": stats,
            "droppedUnverified": dropped_unverified,
            "droppedLikelyTypos": dropped_typos,
        },
        "weights": {
            "google": W_GOOGLE,
            "hunspell": W_HUNSPELL,
            "techFloor": Z_TECH_FLOOR,
            "unverifiedMin": Z_UNVERIFIED_MIN,
            "typoDelta": TYPO_Z_DELTA,
            "typoDeltaShort": TYPO_Z_DELTA_SHORT,
            "min": Z_MIN,
            "max": Z_MAX,
            "wordfreqTop": WORD_FREQ_TOP,
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
