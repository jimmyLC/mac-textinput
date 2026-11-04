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
  z += 0.10  若命中 hunspell 小寫詞幹(標準英文字典;詞形變化不加權)
  z  = max(z, 2.20)  若為自建技術詞                    技術詞可被預測但不擠掉常用詞
  「標準詞」= hunspell 小寫詞幹 + 依 .aff 規則展開的詞形變化(knot、violates、neatly)
  「已驗證」= 標準詞 / google-10000 / 技術詞;dwyl 不算已驗證(含 wich、untill 等錯字)
  未通過驗證者(多為專名、非標準拼寫與冷僻詞):z < 3.5 一律不進預測表,
    例外:高頻詞(前 30,000 名)的 2–3 字母真前綴(hel ⊂ hello)
  疑似誤字:與常用詞只差一次編輯、常用度差 ≥ 10^2.5(3 字母以內 ≥ 10^2.9)者剔除;
    標準詞與技術詞不受此規則影響;z ≥ 4 者亦豁免,
    z ≥ 2.5 且為常用詞(z ≥ 4)2–7 字母真前綴者亦豁免(nike ⊂ nikes)
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
TYPO_Z_DELTA_SHORT = 2.90   # 3 字母以內的 token 用更嚴的門檻
TYPO_Z_COMMON = 4.00        # 自身已達此常用度的詞不會是誤字
PREFIX_Z_MIN = 2.50         # 前綴豁免誤字規則所需的最低常用度
TYPO_PREFIX_MAX = 7         # 誤字規則的前綴豁免涵蓋 2–7 字母(nike ⊂ nikes、whats ⊂ whatsapp)
SHORT_PREFIX_MAX = 3        # 未驗證 token 只有 2–3 字母的前綴能進表(hel ⊂ hello)
Z_MIN = 1.00
Z_MAX = 9.00
CORE_SIZE = 10000
# 只影響 2–3 字母前綴候選:其餘未驗證詞需 z ≥ 3.5,早落在前兩萬名內,已驗證詞則不靠這份清單。
# 300,000 只多帶進 cyb、irw、khr、zuc 這類 10 個雜訊 token,所以維持 200,000。
WORD_FREQ_TOP = 200000


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


def parse_aff(text: str) -> dict[str, tuple[str, bool, list[tuple[str, str, re.Pattern[str]]]]]:
    """解析 hunspell .aff 的 PFX/SFX,回傳 {旗標: (種類, 可交叉, [(刪除, 加上, 條件)])}。"""
    rules: dict[str, tuple[str, bool, list[tuple[str, str, re.Pattern[str]]]]] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 4 or parts[0] not in ("PFX", "SFX"):
            continue
        kind, flag = parts[0], parts[1]
        if flag not in rules:  # 標頭:SFX 旗標 Y/N 條數
            rules[flag] = (kind, parts[2] == "Y", [])
            continue
        strip = "" if parts[2] == "0" else parts[2]
        add = "" if parts[3] == "0" else parts[3].split("/")[0]
        cond = parts[4] if len(parts) > 4 else "."
        pattern = re.compile(f"{cond}$" if kind == "SFX" else f"^{cond}")
        rules[flag][2].append((strip, add, pattern))
    return rules


def expand_forms(stem: str, flags: str, rules) -> set[str]:
    """把一個 hunspell 詞幹依旗標展開成所有詞形(含詞幹本身)。"""
    forms = {stem}
    suffixed: list[tuple[str, bool]] = []
    for flag in flags:
        rule = rules.get(flag)
        if rule and rule[0] == "SFX":
            for strip, add, pattern in rule[2]:
                if pattern.search(stem) and (not strip or stem.endswith(strip)):
                    suffixed.append((stem[: len(stem) - len(strip)] + add, rule[1]))
    forms.update(w for w, _ in suffixed)
    for flag in flags:
        rule = rules.get(flag)
        if rule and rule[0] == "PFX":
            for strip, add, pattern in rule[2]:
                if pattern.search(stem) and stem.startswith(strip):
                    forms.add(add + stem[len(strip):])
                    if rule[1]:  # 前後綴都可交叉時才能同時套用
                        forms.update(add + w[len(strip):] for w, cross in suffixed if cross and w.startswith(strip))
    return forms


def load_hunspell() -> tuple[set[str], set[str], set[str]]:
    """回傳 (小寫詞幹, 專名/首字母大寫, 小寫詞幹展開後的所有詞形)。"""
    import zipfile

    zip_path = CACHE / "hunspell_en_US-large.zip"
    lower: set[str] = set()
    capital: set[str] = set()
    forms: set[str] = set()
    with zipfile.ZipFile(zip_path) as zf:
        names = zf.namelist()
        rules = parse_aff(zf.read(next(n for n in names if n.endswith(".aff"))).decode("utf-8"))
        with zf.open(next(n for n in names if n.endswith(".dic"))) as fh:
            for raw in fh:
                token, _, flags = raw.decode("utf-8").strip().partition("/")
                if not token:
                    continue
                if token.islower():
                    lower.add(token)
                    forms |= expand_forms(token, flags.split()[0] if flags else "", rules)
                else:
                    capital.add(token)
    return lower, capital, forms


def likely_typos(
    words,
    zmap: dict[str, float],
    delta: float = TYPO_Z_DELTA,
    delta_short: float = TYPO_Z_DELTA_SHORT,
    exempt: set[str] | None = None,
) -> set[str]:
    """找出疑似誤字:與常用詞只差一次編輯,且該常用詞的頻率高出門檻個對數單位。

    3 字母以內用 delta_short:短字很容易撞到常用短詞,門檻過低會殺掉真詞。
    exempt 是「輸入進行中」的前綴,自身常用度夠就不算誤字。
    """
    letters = "abcdefghijklmnopqrstuvwxyz"
    out: set[str] = set()
    for w in sorted(words):
        zw = zmap.get(w, 0.0)
        if zw >= TYPO_Z_COMMON:
            continue  # 明顯常見的詞不會是誤字
        if exempt and w in exempt and zw >= PREFIX_Z_MIN:
            continue  # 常用詞的前綴(輸入進行中),不算誤字
        threshold = delta_short if len(w) <= 3 else delta
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
            if zc is not None and zc >= zw + threshold:
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
    hs_lower, hs_capital, hs_forms = load_hunspell()
    # 引擎只吃 ASCII a-z;hunspell 詞幹含少數帶音符的字(如 émigré),此處濾掉
    hs_lower_ascii = {w for w in hs_lower if WORD_RE.fullmatch(w)}
    standard = {w for w in hs_forms if WORD_RE.fullmatch(w)}
    log(
        f"來源:tech={len(tech)} dwyl={len(dwyl)} google10k={len(google)} "
        f"hunspell_lower={len(hs_lower)}(ascii {len(hs_lower_ascii)}) hunspell_cap={len(hs_capital)} "
        f"標準詞(含詞形變化)={len(standard)}"
    )

    # 候選集合:標準詞 ∪ google-10k ∪ 技術詞 ∪ 通用高頻詞(詞頻語料)。
    # dwyl 不用於預測表(它含大量非標準拼寫與冷僻 token),只用於驗收字典。
    candidates: set[str] = set(standard) | google | {t for t in tech if WORD_RE.fullmatch(t)}
    for w in top_n_list("en", WORD_FREQ_TOP):
        if WORD_RE.fullmatch(w):
            candidates.add(w)

    # 常用詞的 2–3 字母前綴:例如 "hel" 是 "hello" 的前綴,輸入進行中就該顯示英文。
    # 這些短字多半是真實短詞/縮寫,保留可讓「邊打邊判斷英文」規則運作;
    # 其餘只有 dwyl 支持的長字(非標準拼寫、冷僻詞)一律不進預測表。
    short_prefixes: set[str] = set()
    # 同分時以字母序決定,否則第 30,000 名的邊界會隨雜湊種子變動
    for w in sorted(candidates, key=lambda x: (-zipf_frequency(x, "en"), x))[:30_000]:
        # 只取「真前綴」(長度大於前綴本身),避免把 teh 這類 3 字母誤拼當成合法短詞
        for n in range(2, min(len(w), SHORT_PREFIX_MAX + 1)):
            short_prefixes.add(w[:n])

    # 疑似誤字:與常用詞只差一次編輯、且本身夠冷僻的詞。
    # 標準詞與技術詞不檢查:knot/not、hive/have、git/get 都是真詞,不該被當成誤字。
    zmap: dict[str, float] = {}
    for w in candidates:
        zmap[w] = zipf_frequency(w, "en")
    # 「輸入進行中」的 token:常用詞的前綴且自身不算冷僻 → 不是誤字,保留
    # (例:"hel" 是 "hello" 的前綴,使用者打一半時應顯示英文)
    common_prefixes: set[str] = set()
    for w, zw in zmap.items():
        if zw < TYPO_Z_COMMON:
            continue
        for n in range(2, min(len(w), TYPO_PREFIX_MAX + 1)):
            common_prefixes.add(w[:n])
    typos = likely_typos(candidates - standard - tech_set, zmap, exempt=common_prefixes)
    log(f"疑似誤字(1 次編輯鄰居常用度差 ≥ 10^{TYPO_Z_DELTA}、短字 10^{TYPO_Z_DELTA_SHORT}):{len(typos):,} 詞")

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
        # 「已驗證」只認標準來源:hunspell 詞幹與詞形變化 / google-10k / 自建技術詞。
        # dwyl(所有英文字串集合)含大量非標準拼寫(wich、untill、enviroment),
        # 若視為已驗證,拼字修正功能會對這些字失效 → 只作驗收字典,不進預測表。
        verified = w in standard or w in google or w in tech_set
        if not verified:
            is_short_prefix = w in short_prefixes
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
        if w in google or (w in standard and zmap[w] >= 4.0):
            stats["core"] += 1
        elif w in tech_set and w not in standard and w not in dwyl:
            stats["tech"] += 1
        else:
            stats["common"] += 1
    log(
        f"預測詞頻表:{len(table)} 詞;分層 {stats};"
        f"略過 {dropped_unverified} 個未驗證且不常見的詞、{dropped_typos} 個疑似誤字"
    )

    out_dir = Path(tempfile.mkdtemp(prefix="zhuyindict-")) if args.check else DATA
    dictionary = sorted(dwyl | standard | google | {t for t in tech if WORD_RE.fullmatch(t)})
    validate(table, dictionary)
    missing_tech = sorted({t for t in tech if WORD_RE.fullmatch(t)} - {w for w, _ in table})
    assert not missing_tech, f"技術詞沒進預測表:{missing_tech}"
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
            "standardForms": len(standard),
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
            "typoCommon": TYPO_Z_COMMON,
            "prefixZMin": PREFIX_Z_MIN,
            "typoPrefixMax": TYPO_PREFIX_MAX,
            "shortPrefixMax": SHORT_PREFIX_MAX,
            "min": Z_MIN,
            "max": Z_MAX,
            "wordfreqTop": WORD_FREQ_TOP,
        },
    }

    if args.check:
        drift = []
        if _manifest_body(DATA / "english-manifest.json") != _without_timestamp(manifest):
            drift.append("english-manifest.json")
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
    # 內容沒變就沿用舊時間戳,重建結果才能逐位元組相同
    manifest_path = out_dir / "english-manifest.json"
    if _manifest_body(manifest_path) == _without_timestamp(manifest):
        manifest["generatedAt"] = json.loads(manifest_path.read_text(encoding="utf-8"))["generatedAt"]
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    log("寫入 english-manifest.json")
    return 0


def _without_timestamp(manifest: dict) -> dict:
    return {k: v for k, v in manifest.items() if k != "generatedAt"}


def _manifest_body(path: Path) -> dict | None:
    if not path.exists():
        return None
    return _without_timestamp(json.loads(path.read_text(encoding="utf-8")))


def _pkg_version(name: str) -> str:
    try:
        from importlib.metadata import version

        return version(name)
    except Exception:  # pragma: no cover
        return "unknown"


if __name__ == "__main__":
    sys.exit(main())
