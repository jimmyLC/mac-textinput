# data/english-words.txt — 內建英文詞頻表

## 檔案事實

| 項目 | 值 |
|---|---|
| 來源 | 從本機已安裝的 ZingIME.app v3.1 (build 2026102701) 的 `Contents/Resources/english-words.txt` 取出,供設計/原型使用 |
| 大小 | 3.3 MB,ASCII |
| 行數 | 227,921 |
| 格式 | TSV:`word<TAB>count`,count 為整數詞頻,無表頭 |
| 完整性 | 全部 227,921 行皆為 2 欄、第 2 欄全為數字(0 列例外) |
| SHA-256 | `acebeca02e45ccbda39df5263c0aaa11fe77cc7390302e160204cee3c398846e` |

## 用途

作為 `EnglishPredictionEngine` 的內建詞庫來源:啟動時載入為前綴 trie,排序權重 = `word_count`(再乘本機 usage 記憶的衰減分數);使用者自訂詞以 `english-words-user.txt` 覆蓋在最前。


## ⚠️ 授權與散布注意

此檔是從第三方商業 app 的安裝包中取出的資料,原始來源在上游程式的致謝中指向
[hallelujahIM](https://github.com/dongyuwei/hallelujahIM) 的英文詞庫。**本 repo 依專案決定公開收錄此檔**
(僅供研究/設計參考),這不代表取得散布授權;若權利人提出要求,將立即移除。

若要正式發佈衍生產品,建議二選一:

1. 改從 hallelujahIM 上游取同源詞表(確認其授權條款),或
2. 以開放資料重建:如 `google-10000-english`、`wordfreq`、SCOWL 等,再轉成同一 TSV 格式。

## 載入器約定(供 M2 實作)

```
- 逐行 split('\t') → (word, Int(count))
- 忽略空行與格式不符的行(此檔為 0 筆,但仍要防禦)
- trie 節點只存子節點 map + 該前綴前 K 名的 (word, count)(top-K 可在 build 時預計算)
- 228k 詞預估記憶體 < 20 MB;載入 < 150 ms,可背景載入而不阻塞 IME 啟動
```

## 衍生清單:english-common-10000(2026-11 產生)

| 檔案 | 內容 |
|---|---|
| `english-common-10000.txt` | 10,000 個常用詞,一行一詞,**依詞頻由高到低排序** |
| `english-common-10000.tsv` | 同順序,`word<TAB>count`(供引擎載入權重) |

**產生方法**
```bash
sort -t$'\t' -k2,2nr english-words.txt | awk -F'\t' '
  $1 ~ /^[a-z]+$/ && length($1) <= 20 &&
  (length($1) > 1 || $1 == "a" || $1 == "i") &&
  $1 !~ /^(www|http|https)$/ { print $1"\t"$2 }
' | head -10000
```

**統計**
- 來源 227,921 詞 → 通過基本格式過濾 220,798 詞 → 取詞頻前 10,000。
- 第 10,000 名詞頻門檻:`bypass` = 4,856,691。
- 覆蓋率:這 10,000 詞占來源語料總詞頻的 **89.10%**。
- 全部為小寫 ASCII(`^[a-z]+$`),長度 1–20;保留 `a`/`i` 兩個單字母。
- SHA-256:
  - `.txt`:`bbbf9ba6bc8d33758c89ef8298a6022abbd6c8d4d1869f21a5a6b0a8e77f7bd4`
  - `.tsv`:`b97c5d6f5f61fe53e7b06a16469d5a96b68cc3e8c3c5bf29a4ec7d4fc824214f`

**已知限制(使用前請讀)**
- 來源是網頁語料詞頻,含**專有名詞/地名/人名**(例:rita、fresno、che)、**品牌**(vw、radeon)、**拼寫變體/錯字**(erotik),以及刻意保留的技術縮寫(tv、dvd、rss、pdf、html、sql 等)。
- 這是一份**種子清單**,不是人工校對過的金標;若要對外發佈英文預測品質,建議再跑一次人工/詞典校對。
- 若需要不同數量(例如 5,000 或 20,000),用上方同一條命令改 `head -N` 即可重現。
