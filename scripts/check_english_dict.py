#!/usr/bin/env python3
"""Regression checks for the English word list (tools/build_english_dict.py).

Default mode needs only the standard library and the committed data/ files.
--rebuild also regenerates under several PYTHONHASHSEED values and fails when any
output differs; that needs wordfreq and data/.cache (see README), so point --python
at the interpreter that has wordfreq.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
BUILD = ROOT / "tools" / "build_english_dict.py"

# Real words the typo and verification rules must not drop.
REAL_WORDS = "knot hive axe nod wax fog violates neatly stacks hel".split()
TECH_WORDS = "git ui cdn udp amd gpt qr webp".split()
# Misspellings and stray tokens that must stay out, with a correct word that must stay in.
MISSPELLINGS = {
    "teh": "the",
    "recieve": "receive",
    "seperate": "separate",
    "definately": "definitely",
    "occured": "occurred",
    "wich": "which",
    "enviroment": "environment",
    "untill": "until",
    "begining": "beginning",
    "adress": "address",
    "rul": "rule",
}

failures: list[str] = []


def check(ok: bool, message: str) -> None:
    if not ok:
        failures.append(message)


def lines(name: str) -> list[str]:
    return (DATA / name).read_text(encoding="utf-8").splitlines()


def load_build_module():
    spec = importlib.util.spec_from_file_location("build_english_dict", BUILD)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def check_word_lists() -> None:
    table = {line.split("\t")[0] for line in lines("english-words.txt")}
    for word in REAL_WORDS + TECH_WORDS:
        check(word in table, f"missing real word: {word}")
    for typo, correct in MISSPELLINGS.items():
        check(typo not in table, f"misspelling in table: {typo}")
        check(correct in table, f"correct word missing: {correct}")
    dictionary = set(lines("english-dictionary.txt"))
    for word in REAL_WORDS + TECH_WORDS:
        check(word in dictionary, f"missing from dictionary: {word}")

    terms = [
        line.strip().lower()
        for line in (ROOT / "tools" / "tech-terms.txt").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]
    alpha = {t for t in terms if re.fullmatch(r"[a-z]{1,20}", t)}
    check(alpha <= table, f"tech terms missing from table: {sorted(alpha - table)}")
    check(set(terms) == set(lines("english-tech-terms.txt")), "english-tech-terms.txt differs from tools/tech-terms.txt")


def check_manifest_and_docs() -> None:
    counts = json.loads((DATA / "english-manifest.json").read_text(encoding="utf-8"))["counts"]
    check(counts["predictionTable"] == len(lines("english-words.txt")), "manifest predictionTable differs from file")
    check(counts["dictionary"] == len(lines("english-dictionary.txt")), "manifest dictionary differs from file")
    check(counts["techTerms"] == len(lines("english-tech-terms.txt")), "manifest techTerms differs from file")

    table = f"{counts['predictionTable']:,}"
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    design = (ROOT / "DESIGN.md").read_text(encoding="utf-8")
    for label, value in {
        "predictionTable": table,
        "dictionary": f"{counts['dictionary']:,}",
        "standardForms": f"{counts['standardForms']:,}",
        "core tier": f"{counts['tiers']['core']:,}",
        "common tier": f"{counts['tiers']['common']:,}",
        "tech tier": f"{counts['tiers']['tech']:,}",
        "droppedUnverified": f"{counts['droppedUnverified']:,}",
        "droppedLikelyTypos": f"{counts['droppedLikelyTypos']:,}",
    }.items():
        check(value in readme, f"README does not state {label} = {value}")
    check(design.count(f"{table} 詞") == 2, f"DESIGN.md should state {table} 詞 twice")


def check_likely_typos(build) -> None:
    # "wordy" sits 2.7 under "words": a typo at the 2.5 threshold, not at 2.9.
    # "cat" sits 2.7 under "car": kept, because short tokens use 2.9. "ab" comes first in
    # sorted order, so a threshold leaking from short tokens would keep "wordy".
    zmap = {"ab": 0.5, "cat": 1.0, "car": 3.7, "wordy": 1.0, "words": 3.7}
    got = build.likely_typos(["words", "wordy", "car", "cat", "ab"], zmap)
    check(got == {"wordy"}, f"likely_typos thresholds wrong: {sorted(got)}")
    got = build.likely_typos(["wordy"], zmap, exempt={"wordy"})
    check("wordy" in got, "prefix exemption ignored the z minimum")
    got = build.likely_typos(["wordy"], {**zmap, "wordy": 2.5, "words": 5.2}, exempt={"wordy"})
    check(not got, "prefix exemption not applied")


def check_inflections(build) -> None:
    rules = build.parse_aff(
        "SFX S Y 2\nSFX S   y  ies  [^aeiou]y\nSFX S   0  s   [aeiou]y\n"
        "SFX D Y 2\nSFX D   0  d   e\nSFX D   0  ed  [^e]\n"
        "PFX U Y 1\nPFX U   0  un  .\n"
    )
    check(build.expand_forms("tie", "D", rules) == {"tie", "tied"}, "suffix on e-stem wrong")
    check(build.expand_forms("spy", "S", rules) == {"spy", "spies"}, "suffix with strip wrong")
    check(build.expand_forms("knot", "UD", rules) == {"knot", "knoted", "unknot", "unknoted"}, "prefix cross wrong")


def check_rebuild(python: str) -> None:
    for seed in ("0", "1", "98765"):
        result = subprocess.run(
            [python, str(BUILD), "--offline", "--check"],
            env={**os.environ, "PYTHONHASHSEED": seed},
            capture_output=True,
            text=True,
        )
        check(result.returncode == 0, f"seed {seed}: rebuild differs from data/\n{result.stdout[-400:]}{result.stderr[-400:]}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rebuild", action="store_true", help="also regenerate under several hash seeds")
    parser.add_argument("--python", default=sys.executable, help="interpreter with wordfreq, for --rebuild")
    args = parser.parse_args()

    build = load_build_module()
    check_word_lists()
    check_manifest_and_docs()
    check_likely_typos(build)
    check_inflections(build)
    if args.rebuild:
        check_rebuild(args.python)

    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    if failures:
        return 1
    print("English word list checks passed" + (" (with hash-seed rebuilds)" if args.rebuild else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
