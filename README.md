# mac-textinput · ZhuyinLM-IME

macOS 繁體中文注音輸入法。目前階段為基於小麥注音的隔離開發版；已安裝並註冊本機測試版，已確認基本實際打字，尚未完成跨 App 驗收，也不是正式發行版。

## 開發與建置

需求：macOS 26 以上與 Xcode 26 以上（上游開發環境需求），Python 3；建置時需能解析 Swift 套件。產品目標為 macOS 15 以上，實際相容性尚待測試。

```sh
git submodule update --init --recursive
./scripts/build.sh
./scripts/test.sh
```

產物：`.build/products/ZhuyinLM.app`。建置會在 `.build/` 產生上游副本，套用獨立的輸入來源與程序識別碼、獨立的 Application Support 目錄，並停用上游更新檢查。此版本使用臨時簽名，尚未公證，不應當作正式散布版。

不要使用上游的安裝程式安裝此開發版：它會操作小麥注音的安裝路徑。目前已在開發機安裝隔離測試版，系統啟用及基本注音輸入已確認，跨 App 流程仍待驗證。新機首次安裝可執行 `./scripts/install.sh`；它只會建立新的 `ZhuyinLM.app`，不覆蓋既有檔案。安裝後可用 `swift scripts/check_registration.swift` 檢查註冊狀態。已安裝後要換新版用 `./scripts/update.sh`：先備份到 `~/Library/Application Support/ZhuyinLM-backups/`，只替換 `ZhuyinLM.app`；`--restore <備份路徑>` 可還原。

## 文件

- [目前進度與接手順序](PROGRESS.md)
- [開發狀態與驗收](docs/STAGE-0-1.md)
- [原始設計文件](DESIGN.md)與 [AI 後端規劃](PLAN-reranker-backends.md)：歷史設計草案，與目前實作不一致之處以開發狀態文件為準；AI 尚未實作。
- [詞庫來源與建置方式](#詞庫data)

## 詞庫（data）

`data/` 僅存本專案自建詞表。

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
| `data/chinese-unigrams.tsv` | 依讀音索引的 unigram 表 170,926 列(`讀音<TAB>詞<TAB>log10 機率`),對應 `unigramsFor(reading)`。 |
| `data/chinese-bigrams.tsv` | **詞接詞統計**(bigram)1,500,000 組(`前詞<TAB>後詞<TAB>共現次數`),對應 `bigramsFor(prevWords)`。 |
| `data/chinese-bigram-stats.json` | bigram 建置後設:語料來源、SHA-256、統計。 |

### 詞典建置

兩套詞表皆為**本專案自建**,來源全部為開放授權資料;建置腳本可完整重現:

```bash
python3 -m venv .venv-dict && .venv-dict/bin/pip install wordfreq
.venv-dict/bin/python tools/build_english_dict.py    # 英文詞典
python3 tools/build_chinese_dict.py                   # 中文詞典(詞庫 + unigram 表)
python3 tools/build_chinese_bigrams.py                # 中文詞接詞(bigram)統計
python3 tools/eval_bigram_lm.py                       # 量化 bigram 對選字的幫助
# --offline:只用本機 cache;--check:比對既有輸出,不一致則 exit 1(CI 用)
```

#### 英文詞典

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

#### 中文詞典

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

#### 中文詞接詞(bigram)統計

**為什麼需要**:`chinese-lexicon.tsv` 只有「詞本身的頻率」(unigram),沒有「詞接詞的頻率」。
`Formosa::Gramambular` 的 LM 介面本來就要 `bigramsFor(prevWords)`;缺了這一層,
同音詞只能靠詞頻猜,整句正確率會卡在瓶頸上。

**來源**:中文維基百科 dump(CC BY-SA 4.0),依日期固定版本:

```
https://dumps.wikimedia.org/zhwiki/20261101/zhwiki-20261101-pages-articles-multistream.xml.bz2
```

multistream 格式由數萬個獨立 bz2 stream 串接,index 檔(`pageid:byteOffset:title`)可據以平行解壓縮。

**管線**:

```
tools/build_chinese_bigrams.py
  ├─ 依 index 切 8 個連續區塊,平行解壓縮
  ├─ tools/zhsegment(Swift):抽 <text> 內文 → 簡繁轉換 → 最長匹配斷詞
  │   (詞典=data/chinese-lexicon.tsv)→ 計 bigram;批次檔依 (前詞,後詞) 排序輸出
  ├─ sort -m(k-way merge)+ awk 串流加總(全程磁碟,記憶體不隨語料成長)
  └─ 依次數取前 N 組 → data/chinese-bigrams.tsv
```

**引擎端融合公式**(bigram 有計數時才啟用,否則純 unigram):

```
P_u(w)      = unigram 機率(讀音條件下)
P_b(w|prev) = (count(prev,w) + α·P_u(w)) / (count(prev) + α)     # α = 0.10
score(w)    = log10[ λ·P_b(w|prev) + (1-λ)·P_u(w) ]              # λ = 0.60
```

**產出規模**:

| 指標 | 值 |
|---|---|
| 語料 | 中文維基百科 20261101(49,830 個 bz2 stream,3.64 GB) |
| 共現 ≥ 2 次的配對 | 10,982,388 組 |
| 輸出(前 N 組,依 key 排序) | 1,500,000 組 / 22.3 MB |

**效果量測**(`tools/eval_bigram_lm.py`,leave-one-out:評估某配對時先扣掉它自己的 1 次計數):

| 指標 | unigram only | unigram + bigram |
|---|---|---|
| 同讀音候選詞中正解排第一的比例 | 59.2% | **82.5%**(+23.3pp) |
| 共現 20–99 次的配對 | 59.0% | 79.8%(+20.9pp) |
| 共現 100+ 次的配對 | 59.6% | 86.1%(+26.5pp) |
| 手寫歧義句集(的/得/地、在/再、做/作…) | 14/33 | **17/33** |

→ bigram 這一層是 LLM reranker 之前的**免費上下文訊號**:純查表、延遲為 0、不需模型。

**兩個關鍵工程細節**(踩過的坑):

1. **維基百科 dump 是簡體**,而本專案詞庫是繁體(國 -2.71 vs 国 -7.90)。
   直接計 bigram 會得到「中/国 = 203 萬次」這種對繁體 IME 毫無意義的統計。
   故計數前先做簡→繁轉換:字形層用 OpenCC `STCharacters`、片語層用 `STPhrases`
   (解決 里/裡、發/髮、布/佈 等單字歧義),歧義字再以**本專案詞庫的分數**消歧。
2. **詞彙單位與詞庫一致**:切分用的是 `data/chinese-lexicon.tsv` 的詞(McBopomofo 的詞),
   所以 bigram 的詞單位與 LM 的詞單位可直接對接,不需再對齊。

## 上游與授權

輸入法基礎來自 [McBopomofo](https://github.com/openvanilla/McBopomofo)，固定於 `257da536ddaf590aae0e74e6adb9b415988344f6`，採 MIT 授權。完整上游版權及授權見 `vendor/McBopomofo/LICENSE.txt`；其第三方資料與依賴另有各自授權，見上游 `ACKNOWLEDGEMENTS.md` 及相關檔案。原設計文件所稱上游為 Apache-2.0 有誤。

本 repo 自有內容尚未指定開源授權；這不改變上游及其他第三方內容既有的授權。
