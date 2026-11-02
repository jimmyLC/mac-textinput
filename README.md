# mac-textinput · ZhuyinLM-IME

macOS 注音輸入法的設計與實作規劃:**傳統統計語言模型為核心,LLM reranker 為增量選字層。**
本 repo 目前處於**設計/規劃階段**,尚無可執行的程式碼。

## 文件

| 文件 | 內容 |
|---|---|
| [`DESIGN.md`](DESIGN.md) | 系統架構、模組介面、學習系統、LLM reranker 設計、詞庫熱更新、里程碑。含對參考產品 ZingIME 的證據化逆向調查(F1–F14),所有結論標註觀察/推論。 |
| [`PLAN-reranker-backends.md`](PLAN-reranker-backends.md) | 雙後端 reranker 實作規劃:**MLX + Qwen2.5-0.5B** 與 **Apple Foundation Models** 並行;含工作分解、介面契約、prompt/演算法規格、eval harness、6 週排程、風險登記簿。 |
| [`data/DATA-NOTES.md`](data/DATA-NOTES.md) | 內建英文詞頻表的格式、來源、完整性與授權注意。 |
| `data/english-words.txt` | 227,921 行 TSV(`word<TAB>count`),英文預測用詞頻表。 |
| `data/english-common-10000.txt` / `.tsv` | 由詞頻表整理出的 10,000 個常用詞(頻率排序),方法與限制見 `data/DATA-NOTES.md`。 |

## 設計摘要

- **引擎**:沿用開源 [McBopomofo](https://github.com/openvanilla/McBopomofo)(Apache-2.0)的 C++ 核心 — `Formosa::Mandarin` 注音解析 + `Formosa::Gramambular` Viterbi 選字。
- **AI**:`ScoreRankedLanguageModel` 裝飾器把 LLM 分數覆蓋到 ReadingGrid 候選排序;後端可切換 Apple Foundation Models(零下載)或 MLX Qwen 0.5B(精確 logprob)。
- **隱私**:所有學習資料留本機;helper 僅 bind `127.0.0.1`;不傳送輸入內容。
- **可降級**:關閉 AI 後行為等同純統計注音輸入法。

## 授權

**No license.** 本 repo 未授予任何開源授權,版權所有。文件與資料僅供閱讀參考;如需使用請聯絡作者。

`data/english-words.txt` 為第三方來源的詞頻資料(詳見 `data/DATA-NOTES.md`),其權利狀態獨立於本專案;若權利人提出要求將移除。
