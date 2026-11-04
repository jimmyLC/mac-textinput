#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_chinese_bigrams.py — ZhuyinLM-IME 中文詞接詞(bigram)統計建置

為什麼需要這一支:現有 `data/chinese-lexicon.tsv` 只有「詞本身的頻率」(unigram),
沒有「詞接詞的頻率」(bigram)。整句正確率取決於上下文,
`Formosa::Gramambular` 的 LM 介面本來就要 `bigramsFor(prevWords)`,目前是空的。

來源
  中文維基百科 dump(繁體,CC BY-SA 4.0),依日期固定版本以確保可重現:
    https://dumps.wikimedia.org/zhwiki/<date>/zhwiki-<date>-pages-articles-multistream.xml.bz2
  multistream 格式:檔案由數百萬個獨立 bz2 stream 串接,index 檔格式為
  `pageid:byteOffset:title`,可據以平行解壓縮。

處理
  1. 依 index 切分 stream 成 N 個連續區塊,平行作業。
  2. 每個區塊解壓縮後,交給 tools/zhsegment(Swift,最長匹配斷詞)抽出 <text> 內文並計 bigram。
  3. 各批次輸出「依 (前詞,後詞) 排序」的計數檔 → 主程式 k-way merge 後加總。
  4. 套用次數門檻,輸出前 N 組配對。

輸出
  data/chinese-bigrams.tsv        「前詞<TAB>後詞<TAB>次數」,依次數由大到小
  data/chinese-bigram-stats.json  來源、SHA-256、統計

用法
  python3 tools/build_chinese_bigrams.py [--streams N] [--workers W]
                                         [--min-count C] [--max-pairs M]
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import heapq
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
CACHE = DATA / ".cache"
ZH_CACHE = CACHE / "zhwiki"
ZHSEG_SRC = ROOT / "tools" / "zhsegment" / "main.swift"
LEXICON = DATA / "chinese-lexicon.tsv"
S2T_MAP = ROOT / "tools" / "s2t-map.txt"
S2T_PHRASES = ROOT / "tools" / "s2t-phrases.txt"
OUT_TSV = DATA / "chinese-bigrams.tsv"
OUT_MANIFEST = DATA / "chinese-bigram-stats.json"

DUMP_DATE = "20261101"
DUMP_BASE = f"https://dumps.wikimedia.org/zhwiki/{DUMP_DATE}"
DUMP_FILE = f"zhwiki-{DUMP_DATE}-pages-articles-multistream.xml.bz2"
INDEX_FILE = f"zhwiki-{DUMP_DATE}-pages-articles-multistream-index.txt.bz2"

FLUSH_BYTES = 200 << 20  # 每批送給斷詞器的文字量(批次越大,「只出現一次」的配對流失越少)


def log(msg: str) -> None:
    print(f"[bigram] {msg}", flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def remote_size(url: str) -> int:
    out = subprocess.run(["curl", "-sSI", "-L", url], stdout=subprocess.PIPE, check=True).stdout.decode()
    for line in out.splitlines():
        if line.lower().startswith("content-length:"):
            return int(line.split(":", 1)[1].strip())
    return 0


def ensure_downloads() -> tuple[Path, Path]:
    """下載(或續傳)dump 與 index;以遠端 Content-Length 驗證完整性。"""
    ZH_CACHE.mkdir(parents=True, exist_ok=True)
    out = {}
    for name in (DUMP_FILE, INDEX_FILE):
        dest = ZH_CACHE / name
        url = f"{DUMP_BASE}/{name}"
        expected = remote_size(url)
        have = dest.stat().st_size if dest.exists() else 0
        if not dest.exists() or (expected and have != expected):
            log(f"下載 {name}(目標 {expected/1e9:.2f} GB,已存在 {have/1e9:.2f} GB)")
            subprocess.run(["curl", "-fL", "--retry", "5", "-C", "-", "-o", str(dest), url], check=True)
            if expected and dest.stat().st_size != expected:
                raise SystemExit(f"[bigram] {name} 大小不符:期望 {expected},實際 {dest.stat().st_size}")
        out[name] = dest
    return out[DUMP_FILE], out[INDEX_FILE]


def build_s2t_resolved() -> Path:
    """產生「簡體 → 繁體」的字形對照表。

    維基百科 dump 為簡體,而本專案詞庫以繁體為主,故計 bigram 前必須轉換。
    歧義字(如 万→萬/万、后→後/后)以**詞庫分數**消歧:取分數最高者,
    同分時取 OpenCC 的建議值(第一個候選)。
    """
    scores: dict[str, float] = {}
    with LEXICON.open(encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                try:
                    scores[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    resolved: dict[str, str] = {}
    ambiguous = 0
    with S2T_MAP.open(encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2:
                continue
            key = parts[0].strip()
            cands = parts[1].split()
            if not cands:
                continue
            if len(cands) == 1:
                resolved[key] = cands[0]
                continue
            ambiguous += 1
            resolved[key] = max(cands, key=lambda c: (scores.get(c, -20.0), -cands.index(c)))
    path = CACHE / "s2t-resolved.tsv"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as out:
        for k, v in resolved.items():
            out.write(f"{k}\t{v}\n")
    log(f"簡繁字形對照:{len(resolved)} 字(其中 {ambiguous} 個歧義字依詞庫分數消歧)")
    return path


def build_s2t_phrases_resolved() -> Path:
    """產生「簡→繁」片語對照表(多候選以詞庫分數消歧)。"""
    scores: dict[str, float] = {}
    with LEXICON.open(encoding="utf-8") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2:
                try:
                    scores[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    resolved: dict[str, str] = {}
    ambiguous = 0
    with S2T_PHRASES.open(encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2:
                continue
            key = parts[0].strip()
            cands = parts[1].split()
            if not cands:
                continue
            if len(cands) == 1:
                resolved[key] = cands[0]
                continue
            ambiguous += 1
            resolved[key] = max(cands, key=lambda c: (scores.get(c, -20.0), -cands.index(c)))
    path = CACHE / "s2t-phrases-resolved.tsv"
    with path.open("w", encoding="utf-8") as out:
        for k, v in resolved.items():
            out.write(f"{k}\t{v}\n")
    log(f"簡繁片語對照:{len(resolved)} 條(其中 {ambiguous} 條多候選依詞庫分數消歧)")
    return path


def build_zhsegment() -> Path:
    """編譯 Swift 斷詞器(輸出到快取目錄,不進版控)。"""
    CACHE.mkdir(parents=True, exist_ok=True)
    binary = CACHE / "zhsegment"
    src_mtime = ZHSEG_SRC.stat().st_mtime
    if binary.exists() and binary.stat().st_mtime > src_mtime:
        return binary
    log("編譯 tools/zhsegment(Swift)")
    subprocess.run(["swiftc", "-O", "-o", str(binary), str(ZHSEG_SRC)], check=True)
    return binary


def read_offsets(index_path: Path) -> list[int]:
    """從 multistream index 取出各個 bz2 stream 的起始偏移。

    index 格式為 `offset:pageid:title`;一個 stream 約含 100 個頁面,
    因此需對相重複的 offset 去重(保留出現順序)。
    """
    offsets: list[int] = []
    prev = -1
    with bz2.open(index_path, "rt", encoding="utf-8") as fh:
        for line in fh:
            parts = line.split(":", 2)
            if len(parts) < 2:
                continue
            try:
                offset = int(parts[0])
            except ValueError:
                continue
            if offset != prev:
                offsets.append(offset)
                prev = offset
    if not offsets or offsets[0] != 0:
        offsets.insert(0, 0)  # 第一個 stream(檔頭)
    return offsets


def decompress_stream(fh, offset: int) -> bytes:
    """解壓縮單一 bz2 stream(從 offset 開始;stream 各自獨立)。"""
    fh.seek(offset)
    dec = bz2.BZ2Decompressor()
    chunks: list[bytes] = []
    while not dec.eof:
        raw = fh.read(1 << 20)
        if not raw:
            break
        chunks.append(dec.decompress(raw))
    return b"".join(chunks)


def worker(task: tuple) -> list[str]:
    """處理一段 stream 索引範圍。

    每批文字單獨交給斷詞器,輸出成一個「已依 (前詞,後詞) 排序」的計數檔;
    記憶體不隨語料量成長,合併交由主程式做 k-way merge。
    """
    tag, offsets, dump_path, binary, lexicon, outdir, s2t, s2t_phrases = task
    files: list[str] = []
    buf: list[bytes] = []
    buf_size = 0
    seq = 0

    def flush() -> None:
        nonlocal buf, buf_size, seq
        if not buf:
            return
        data = b"".join(buf)
        buf = []
        buf_size = 0
        result = subprocess.run(
            [
                binary, lexicon, "--wiki", "--by-key",
                "--s2t", str(s2t), "--s2t-phrases", str(s2t_phrases),
            ],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        path = Path(outdir) / f"{tag}-{seq:05d}.tsv"
        seq += 1
        path.write_bytes(result.stdout)
        files.append(str(path))

    with open(dump_path, "rb") as fh:
        for offset in offsets:
            text = decompress_stream(fh, offset)
            buf.append(text)
            buf_size += len(text)
            if buf_size >= FLUSH_BYTES:
                flush()
    flush()
    return files


def part_files_iter(paths: list[str]):
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 3:
                    continue
                yield (parts[0], parts[1], int(parts[2]))


def group(sorted_iter):
    """把以 (a,b) 排序的 (a,b,count) 串流合併成 ((a,b), total)。"""
    cur_key = None
    cur_total = 0
    for a, b, c in sorted_iter:
        key = (a, b)
        if key != cur_key:
            if cur_key is not None:
                yield cur_key, cur_total
            cur_key = key
            cur_total = c
        else:
            cur_total += c
    if cur_key is not None:
        yield cur_key, cur_total


def main() -> int:
    ap = argparse.ArgumentParser(description="建置中文詞接詞(bigram)統計")
    ap.add_argument("--streams", type=int, default=0, help="只處理前 N 個 stream(0 = 全部)")
    ap.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 4))
    ap.add_argument("--min-count", type=int, default=2, help="保留的最小共現次數")
    ap.add_argument("--max-pairs", type=int, default=2_000_000, help="輸出前 N 組配對")
    ap.add_argument("--skip-download", action="store_true", help="跳過下載檢查,直接用本機檔案(測試用)")
    args = ap.parse_args()

    if not LEXICON.exists():
        raise SystemExit(f"[bigram] 缺少詞庫:{LEXICON}(請先執行 tools/build_chinese_dict.py)")

    if args.skip_download:
        dump_path = ZH_CACHE / DUMP_FILE
        index_path = ZH_CACHE / INDEX_FILE
    else:
        dump_path, index_path = ensure_downloads()
    binary = build_zhsegment()
    s2t_path = build_s2t_resolved()
    s2t_phrases_path = build_s2t_phrases_resolved()
    offsets = read_offsets(index_path)
    total_streams = len(offsets)
    if args.streams:
        total_streams = min(total_streams, args.streams)
    log(f"stream 數:{total_streams}(索引共 {len(offsets):,}),dump {dump_path.stat().st_size/1e9:.2f} GB")

    chunk = (total_streams + args.workers - 1) // args.workers
    tasks = []
    tmpdir = Path(tempfile.mkdtemp(prefix="zhbigram-"))
    for i in range(args.workers):
        start = i * chunk
        end = min(start + chunk, total_streams)
        if start >= end:
            continue
        tasks.append(
            (
                f"w{i}", offsets[start:end], str(dump_path), str(binary),
                str(LEXICON), str(tmpdir), str(s2t_path), str(s2t_phrases_path),
            )
        )

    log(f"開始計數:{len(tasks)} 個工作單元,{args.workers} 路平行")
    part_files: list[str] = []
    if args.workers == 1:
        for t in tasks:
            part_files.extend(worker(t))
    else:
        import multiprocessing as mp

        with mp.get_context("spawn").Pool(len(tasks)) as pool:
            for files in pool.map(worker, tasks):
                part_files.extend(files)
    log(f"各批次計數檔:{len(part_files)} 個")

    # 合併策略(全程磁碟,記憶體不隨語料成長):
    #   1. 各批次檔已依 (前詞,後詞) 排序 → sort -m 直接 k-way merge
    #   2. awk 以串流方式把同 key 的次數加總(不建關聯陣列)
    #   3. 依次數排序後取前 N 組,再依 key 排序輸出(引擎端可循序載入)
    merged_file = tmpdir / "merged.tsv"
    agg_file = tmpdir / "agg.tsv"
    log("合併(k-way merge)…")
    env = {**os.environ, "LC_ALL": "C"}
    subprocess.run(
        ["sort", "-m", "-t", "\t", "-k1,1", "-k2,2", "-S", "25%", "-o", str(merged_file), *part_files],
        check=True, env=env,
    )
    log("加總同 key…")
    with agg_file.open("w", encoding="utf-8") as out:
        proc = subprocess.run(
            [
                "awk", "-F", "\t", "-v", f"MIN={args.min_count}",
                'BEGIN{prev=""; c=0}'
                '{k=$1 "\t" $2; if(k!=prev){ if(prev!="" && c>=MIN) print prev "\t" c; prev=k; c=$3 } else { c+=$3 }}'
                'END{ if(prev!="" && c>=MIN) print prev "\t" c }',
                str(merged_file),
            ],
            stdout=out,
            check=True,
        )
    total_pairs = sum(1 for _ in agg_file.open(encoding="utf-8"))
    log(f"合併後(≥{args.min_count} 次):{total_pairs:,} 組")

    log("取前 N 組…")
    top_file = tmpdir / "top.tsv"
    with top_file.open("w", encoding="utf-8") as out:
        subprocess.run(
            f"LC_ALL=C sort -t'\t' -k3,3nr -S 25% --parallel={args.workers} {agg_file} | head -n {args.max_pairs}",
            shell=True, stdout=out, check=True,
        )
    # 最終輸出依 key 排序(引擎端循序載入用)
    with OUT_TSV.open("w", encoding="utf-8") as out:
        subprocess.run(
            ["sort", "-t", "\t", "-k1,1", "-k2,2", str(top_file)],
            stdout=out, check=True, env=env,
        )
    kept = sum(1 for _ in OUT_TSV.open(encoding="utf-8"))
    log(f"寫入 {OUT_TSV}({kept:,} 組,{OUT_TSV.stat().st_size/1e6:.1f} MB)")

    manifest = {
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "generator": "tools/build_chinese_bigrams.py",
        "corpus": {
            "name": "Chinese Wikipedia",
            "license": "CC BY-SA 4.0",
            "dumpDate": DUMP_DATE,
            "url": f"{DUMP_BASE}/{DUMP_FILE}",
            "sha256": sha256_file(dump_path),
            "streams": total_streams,
            "variant": "繁體(zh-tw)",
        },
        "segmenter": "tools/zhsegment(最長匹配,詞典=data/chinese-lexicon.tsv)",
        "counts": {
            "distinctPairs": total_pairs,
            "keptPairs": kept,
            "minCount": args.min_count,
            "maxPairs": args.max_pairs,
        },
    }
    OUT_MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    log(f"寫入 {OUT_MANIFEST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
