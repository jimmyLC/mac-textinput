"""Builds a private training set from the owner's own sentence history (decrypted by `zhizhi-eval history`).
Reads and writes only inside ~/Library/Application Support/Zhizhi/personal-train; nothing here is ever committed."""
import datetime as dt, json, os, random, re, sys
P = os.path.expanduser("~/Library/Application Support/Zhizhi/personal-train")
rows = []
for l in open(f"{P}/history.tsv", encoding="utf-8"):
    t, _, x = l.rstrip("\n").partition("\t")
    if x: rows.append((dt.datetime.fromisoformat(t.replace("Z", "+00:00")), x))
groups, cur = [], [rows[0]]
for a, b in zip(rows, rows[1:]):
    if (b[0] - a[0]).total_seconds() > 20: groups.append(cur); cur = []
    cur.append(b)
groups.append(cur)
secret = re.compile(r"@|https?:|www\.|\d{6,}|[A-Za-z0-9]{20,}")
clauses = []
for g in groups:
    text = "".join(x for _, x in g)
    for c in re.split(r"[，。？！；、\n,.?!;]+", text):
        c = c.strip().replace("（）", "")
        han = sum(1 for ch in c if "一" <= ch <= "鿿")
        if han >= 4 and len(c) <= 60 and not secret.search(c) and not re.search(r"[ㄅ-ㄩ]", c):
            clauses.append(c)
clauses = list(dict.fromkeys(clauses))
random.Random(11).shuffle(clauses)
cut = max(20, len(clauses) // 10)
os.makedirs(f"{P}/set", exist_ok=True)
base = [l.strip() for f in ("daily", "work", "homophones", "opinion", "school-chat", "more1", "more2")
        if os.path.exists(f"data/{f}.txt") for l in open(f"data/{f}.txt", encoding="utf-8") if l.strip()]
held = {l.strip() for f in ("eval/homophone_sentences.txt", "eval/mixed_sentences.txt") for l in open(f"../../{f}", encoding="utf-8") if l.strip()}
base = [b for b in dict.fromkeys(base) if b not in held]
train = clauses[cut:] * 3 + base          # his own clauses count triple so the spoken base is not forgotten but his words win
random.Random(5).shuffle(train)
for name, part in (("train", train), ("valid", clauses[:cut])):
    with open(f"{P}/set/{name}.jsonl", "w", encoding="utf-8") as o:
        for r in part: o.write(json.dumps({"text": r}, ensure_ascii=False) + "\n")
print(f"{len(groups)} groups -> {len(clauses)} private clauses ({cut} held out); train rows {len(train)}")
