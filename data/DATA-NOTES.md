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
