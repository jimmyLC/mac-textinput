# 英文詞庫

## 現況

`english-words.txt` 是本專案自行重建的詞表（TSV：`word<TAB>count`，小寫 a–z，依 count 遞減，約 15 萬詞）。由 `scripts/build_english_wordlist.py` 產生，**不含**任何第三方商用 App 的資料。舊的 ZingIME 詞表仍在 `main` 與 git 歷史中，不可重用。

## 來源

| 項目 | 內容 |
|---|---|
| 詞頻 | [IlyaSemenov/wikipedia-word-frequency](https://github.com/IlyaSemenov/wikipedia-word-frequency) 的 `results/enwiki-2023-04-13.txt`（英文維基百科 2023-04-13 dump 統計，至少出現在 3 篇文章的詞）。該檔 SHA-256：`e2071140a49a6c40c732bd68c36836ef13c0978233fb3d5e1b2a3c2d34faef59` |
| 補充詞 | `data/sources/english-extra.txt`，本專案手寫的工程／口語詞（github、kubectl、tvos、dont 等），count 固定設為 2,000,000 |
| 過濾 | 只留 `[a-z]+`、單字母僅 a／i，取 count 前 150,000 名，再合併補充詞 |

重新產生：

```sh
python3 scripts/build_english_wordlist.py --wiki <enwiki-2023-04-13.txt>
```

## 授權狀態（待確認，勿視為已清白）

- 該工具程式為 MIT；維基百科文字為 CC BY-SA 4.0。詞頻是統計數字，通常著作權保護薄弱，但**尚無法律意見**，且預先產生的結果檔本身未見明確授權聲明。
- 發布前應確認上述結果檔的授權，並在 app 致謝中註明來源（維基百科、該工具）。
- 若要完全規避，可自行下載維基 dump，用同一工具重新產生，再以本腳本轉換。

## 已知品質限制

- 語料偏百科：人名、地名、外語專名偏多；口語、縮寫、網路用語偏少（補充詞僅部分彌補）。
- 沒有縮寫（don't 被拆成 don／t）與帶點縮寫（e.g.、a.m.）。
- 前綴預測命中率低於舊表（見下）；之後可混入真實輸入的使用記憶，或補一份口語語料。

## 與舊表比較（2026-11-02，134 個手選測試詞，取前綴 top-5）

| 前綴長度 | 舊表 | 新表 |
|---|---|---|
| 2 | 36/132 | 24/134 |
| 3 | 103/132 | 91/134 |
| 4 | 121/132 | 116/134 |

新表垃圾詞（無母音、過長、含 www 等）較少：全表 3,413 vs 9,584。測試詞表含幾個補充詞（如 github），對新表略有利。舊表只計入純 a–z 的 227,913 詞。
