#!/usr/bin/env python3
"""Turns mixed_sentences.txt into typed keys: Chinese by Zhuyin with tones, English in lowercase with no extra spaces."""
import json, re, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from lexicon_baseline import load_lexicon, gold_syllables
KEY = {"ㄅ":"1","ㄆ":"q","ㄇ":"a","ㄈ":"z","ㄉ":"2","ㄊ":"w","ㄋ":"s","ㄌ":"x","ㄍ":"e","ㄎ":"d","ㄏ":"c","ㄐ":"r","ㄑ":"f","ㄒ":"v","ㄓ":"5","ㄔ":"t","ㄕ":"g","ㄖ":"b","ㄗ":"y","ㄘ":"h","ㄙ":"n","ㄧ":"u","ㄨ":"j","ㄩ":"m","ㄚ":"8","ㄛ":"i","ㄜ":"k","ㄝ":",","ㄞ":"9","ㄟ":"o","ㄠ":"l","ㄡ":".","ㄢ":"0","ㄣ":"p","ㄤ":";","ㄥ":"/","ㄦ":"-","ˊ":"6","ˇ":"3","ˋ":"4","˙":"7"}
def keys(s):
    out = "".join(KEY[c] for c in s)
    return out if out[-1] in "3467" else out + " "
by_word, _ = load_lexicon()
rows, here = [], pathlib.Path(__file__).parent
for line in open(here / "mixed_sentences.txt", encoding="utf-8"):
    line = line.strip()
    if not line: continue
    typed, expect, bad = "", "", False
    for part in re.findall(r"[a-zA-Z]+(?: [a-zA-Z]+)*|[^a-zA-Z ]+", line):
        if part[0].isascii():
            typed += part
            if expect: expect += " "
            expect += part
        else:
            syl = gold_syllables(part, by_word)
            if syl is None: bad = True; break
            typed += "".join(keys(s) for s in syl)
            if expect: expect += " "
            expect += part
    if not bad: rows.append({"gold": expect, "keys": typed})
json.dump(rows, open(here / "mixed.json", "w", encoding="utf-8"), ensure_ascii=False, indent=0)
print(len(rows), "mixed rows")
