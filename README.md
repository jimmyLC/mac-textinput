# mac-textinput · ZhuyinLM-IME

macOS 注音輸入法的設計與實作規劃:**傳統統計語言模型為核心,LLM reranker 為增量選字層。**
本 repo 目前處於**設計/規劃 + 資料建置階段**,尚無可執行的輸入法程式碼。

## 文件

| 文件 | 內容 |
|---|---|
| [`DESIGN.md`](DESIGN.md) | 系統架構、模組介面、學習系統、LLM reranker 設計、詞庫熱更新、里程碑。含對參考產品 ZingIME 的證據化逆向調查(F1–F14),所有結論標註觀察/推論。 |
| [`PLAN-reranker-backends.md`](PLAN-reranker-backends.md) | 雙後端 reranker 實作規劃:**MLX + Qwen2.5-0.5B** 與 **Apple Foundation Models** 並行;含工作分解、介面契約、prompt/演算法規格、eval harness、6 週排程、風險登記簿。 |
| [`data/ENGLISH-DICT.md`](data/ENGLISH-DICT.md) | **自建英文詞典**:來源、授權、權重模型、分層統計、限制與重build方式。 |
| [`data/CHINESE-DICT.md`](data/CHINESE-DICT.md) | **自建中文詞典**:來源(McBopomofo MIT)、聚合方法、統計、限制與重build方式。 |

## 資料

| 檔案 | 內容 |
|---|---|
| `data/english-words.txt` | 自建英文預測詞頻表,103,452 行 TSV(`word<TAB>count`),count 為單調遞增權重。 |
| `data/english-common-10000.txt` | 高信心核心 10,000 詞(頻率排序)。 |
| `data/english-tech-terms.txt` | 技術 / 品牌 / 縮寫詞 257 筆,供 `includeEngineering` 開關使用。 |
| `data/english-dictionary.txt` | 全量合法英文詞 412,417 筆(驗收用,無權重)。 |
| `data/english-manifest.json` | 英文詞典建置後設:來源 URL、SHA-256、統計、權重參數。 |
| `data/english-words-user.example.txt` | 使用者自訂詞檔格式範例(支援 `#` 註解、存檔熱載)。 |
| `data/chinese-common-10000.txt` / `.tsv` | 自建中文常用字詞 10,000 筆,含聚合分數與注音讀音。 |
| `data/chinese-lexicon.tsv` | 自建全量中文詞庫 160,792 詞(`詞<TAB>分數<TAB>讀音`)。 |
| `data/chinese-associated-phrases.tsv` | 聯想詞 94,784 筆(M2 聯想詞功能用)。 |
| `data/chinese-manifest.json` | 中文詞典建置後設:來源、SHA-256、統計。 |
| `data/sources/` | 詞典建置的輸入:種子詞表、自建技術詞表、遠端來源本機快取(不入版控)。 |

重建詞典:

```bash
python3 -m venv .venv-dict && .venv-dict/bin/pip install wordfreq
.venv-dict/bin/python tools/build_english_dict.py
python3 tools/build_chinese_dict.py
```

## 設計摘要

- **引擎**:沿用開源 [McBopomofo](https://github.com/openvanilla/McBopomofo)(**MIT**)的 C++ 核心 — `Formosa::Mandarin` 注音解析 + `Formosa::Gramambular` Viterbi 選字。
- **AI**:`ScoreRankedLanguageModel` 裝飾器把 LLM 分數覆蓋到 ReadingGrid 候選排序;後端可切換 Apple Foundation Models(零下載)或 MLX Qwen 0.5B(精確 logprob)。
- **隱私**:所有學習資料留本機;helper 僅 bind `127.0.0.1`;不傳送輸入內容。
- **可降級**:關閉 AI 後行為等同純統計注音輸入法。

## 授權

**No license.** 本 repo 未授予任何開源授權,版權所有。文件與資料僅供閱讀參考;如需使用請聯絡作者。

詞典來源的授權狀態逐項列於 [`data/ENGLISH-DICT.md`](data/ENGLISH-DICT.md) 與
[`data/CHINESE-DICT.md`](data/CHINESE-DICT.md);
其中 `data/sources/base-english-100000.txt` 沿用既有第三方詞表,其權利狀態獨立於本專案,若權利人提出要求將移除。
