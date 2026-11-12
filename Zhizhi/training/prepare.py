"""Builds mlx-lm training files from data/*.txt, dropping any sentence that is in the eval sets."""
import glob, json, random, sys
root = "../.."
held = set()
for f in ("eval/homophone_sentences.txt", "eval/mixed_sentences.txt"):
    held |= {l.strip() for l in open(f"{root}/{f}", encoding="utf-8") if l.strip()}
rows = []
for f in sorted(glob.glob("data/*.txt")):
    rows += [l.strip() for l in open(f, encoding="utf-8") if l.strip()]
rows = [r for r in dict.fromkeys(rows) if r not in held]
random.Random(7).shuffle(rows)
cut = max(1, len(rows) // 12)
import os
os.makedirs("work/set", exist_ok=True)
for name, part in (("valid", rows[:cut]), ("train", rows[cut:])):
    with open(f"work/set/{name}.jsonl", "w", encoding="utf-8") as out:
        for r in part:
            out.write(json.dumps({"text": r}, ensure_ascii=False) + "\n")
print(len(rows) - cut, "train;", cut, "valid;", len(held), "eval sentences excluded")
