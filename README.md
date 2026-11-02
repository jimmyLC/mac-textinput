# mac-textinput · ZhuyinLM-IME

macOS 注音輸入法的設計與實作規劃:**傳統統計語言模型為核心,LLM reranker 為增量選字層。**
本 repo 目前處於**設計/規劃 + 資料建置階段**,尚無可執行的輸入法程式碼。

## 文件

| 文件 | 內容 |
|---|---|
| [`DESIGN.md`](DESIGN.md) | 系統架構、模組介面、學習系統、LLM reranker 設計、詞庫熱更新、里程碑。含對參考產品 ZingIME 的證據化逆向調查(F1–F14),所有結論標註觀察/推論。 |
| [`PLAN-reranker-backends.md`](PLAN-reranker-backends.md) | 雙後端 reranker 實作規劃:**MLX + Qwen2.5-0.5B** 與 **Apple Foundation Models** 並行;含工作分解、介面契約、prompt/演算法規格、eval harness、6 週排程、風險登記簿。 |

## 資料(`data/` 僅存本專案自建詞表)

| 檔案 | 內容 |
|---|---|
| `data/english-words.txt` | 自建英文預測詞頻表,113,092 行 TSV(`word<TAB>count`),count 為單調遞增權重。 |
| `data/english-common-10000.txt` | 高信心核心 10,000 詞(頻率排序)。 |
| `data/english-tech-terms.txt` | 技術 / 品牌 / 縮寫詞 257 筆,供 `includeEngineering` 開關使用。 |
| `data/english-dictionary.txt` | 全量合法英文詞 373,359 筆(驗收用,無權重)。 |
| `data/english-words-user.example.txt` | 使用者自訂詞檔格式範例(支援 `#` 註解、存檔熱載)。 |
| `data/english-manifest.json` | 英文詞典建置後設:來源 URL、SHA-256、統計、權重參數。 |
| `data/chinese-lexicon.tsv` | 自建全量中文詞庫 160,792 詞(`詞<TAB>分數<TAB>讀音`)。 |
| `data/chinese-common-10000.txt` / `.tsv` | 自建中文常用字詞 10,000 筆,含聚合分數與注音讀音。 |
| `data/chinese-associated-phrases.tsv` | 聯想詞 94,784 筆(M2 聯想詞功能用)。 |
| `data/chinese-manifest.json` | 中文詞典建置後設:來源、SHA-256、統計。 |

## 詞典建置

兩套詞表皆為**本專案自建**,來源全部為開放授權資料;建置腳本可完整重現:

```bash
python3 -m venv .venv-dict && .venv-dict/bin/pip install wordfreq
.venv-dict/bin/python tools/build_english_dict.py    # 英文詞典
python3 tools/build_chinese_dict.py                   # 中文詞典
# --offline:只用本機 cache;--check:比對既有輸出,不一致則 exit 1(CI 用)
```

### 英文詞典

| 來源 | 角色 | 授權 |
|---|---|---|
| [dwyl/english-words](https://github.com/dwyl/english-words) `words_alpha.txt` | 合法英文詞全集(369,804) | Unlicense |
| [first20hours/google-10000-english](https://github.com/first20hours/google-10000-english) | 人工挑選常用詞(9,989) | MIT |
| [hunspell en_US-large](https://github.com/en-wl/wordlist)(SCOWL) | 標準英文字典詞幹(60,796 小寫 / 15,511 專名) | SCOWL |
| [wordfreq](https://github.com/wordfreq/wordfreq) 3.1.1 | 詞頻(Zipf 值) | MIT |
| `tools/tech-terms.txt` | 技術 / 品牌 / 縮寫詞(257 詞) | 本專案自製 |

權重模型(`tools/build_english_dict.py`):

```
z  = wordfreq.zipf_frequency(word, 'en')     # 0..8 的對數詞頻
z += 0.25  若命中 google-10000               # 人工挑選的常用詞
z += 0.10  若命中 hunspell 小寫詞幹          # 標準英文字典收錄
z  = max(z, 2.20)  若為自建技術詞            # 技術詞可被預測,但不擠掉常用詞
未通過任何字典驗證者(多為人名/地名):z < 3.5 一律不進預測表
count = round(10 ^ z)
```

分層(僅計入實際進表者):core 10,534 / common 102,437 / tech 121;
另略過 91,372 個「未經字典驗證且不常見」的詞(人名地名長尾)。
遠端來源只存於本機 `data/.cache/`(不入版控),本 repo 僅散布**衍生**統計檔。

已知限制:僅純字母(縮寫如 `mp3`、`k8s` 只在 `english-tech-terms.txt`)、不含撇號與連字號、
無詞形展開、Zipf 來自字幕語料(偏口語)。

### 中文詞典

母體取自 **McBopomofo 官方發布 3.1.1**(MIT)內附的
`Resources/data.txt` 與 `Resources/associated-phrases-v2.txt`,
本機解析後產生衍生檔(SHA-256 記於 `data/chinese-manifest.json`):

```
解析 data.txt:欄位為 `reading word score`(score 為 log10 機率,越接近 0 越常見)
略過:註解行、reading/word 以 `_` 開頭的控制項、非漢字詞
同一詞的多個讀音以 log-sum-exp(底 10)聚合:score = max + log10( Σ 10^(s_i - max) )
依聚合分數降序輸出
```

| 指標 | 值 |
|---|---|
| 上游 `data.txt` 總行數 | 175,802 |
| 略過控制項 / 非漢字 | 4,870 |
| 唯一漢字詞 | 160,792 |
| 多讀音詞 | 8,615 |
| 第 10,000 名門檻 | `娛` = -4.881877 |
| 前 10,000 名覆蓋詞機率質量 | 82.1% |
| 聯想詞筆數 | 94,784 |

已知限制:上游語料來自影視字幕,偏口語(「我們」「什麼」等高頻,書面公文詞相對靠後);
分數不可跨上游版本比較,更新詞庫後需重build。

## 設計摘要

- **引擎**:沿用開源 [McBopomofo](https://github.com/openvanilla/McBopomofo)(**MIT**)的 C++ 核心 — `Formosa::Mandarin` 注音解析 + `Formosa::Gramambular` Viterbi 選字。
- **AI**:`ScoreRankedLanguageModel` 裝飾器把 LLM 分數覆蓋到 ReadingGrid 候選排序;後端可切換 Apple Foundation Models(零下載)或 MLX Qwen 0.5B(精確 logprob)。
- **隱私**:所有學習資料留本機;helper 僅 bind `127.0.0.1`;不傳送輸入內容。
- **可降級**:關閉 AI 後行為等同純統計注音輸入法。

## 授權

**No license.** 本 repo 未授予任何開源授權,版權所有。文件與資料僅供閱讀參考;如需使用請聯絡作者。

詞典來源的授權狀態逐項列於上方〈詞典建置〉:英文為 Unlicense / MIT / SCOWL,中文母體為 MIT;
本 repo 只散布由這些來源**衍生**的統計檔,母體檔案不入版控。
