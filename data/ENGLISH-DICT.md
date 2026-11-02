# 英文詞典(自建版)

本目錄的英文資料為 **ZhuyinLM-IME 自建詞典**:以既有的 100,000 詞基底表為種子,
結合開放來源詞典與詞頻資料重新清洗、補字、重新計權,全程可用腳本重現。

建置腳本:[`tools/build_english_dict.py`](../tools/build_english_dict.py)

---

## 1. 產出檔案

| 檔案 | 內容 | 格式 | 規模 |
|---|---|---|---|
| `english-words.txt` | **引擎內建預測詞頻表**(自建權重) | TSV `word<TAB>count`,依 count 由大到小 | 103,452 詞 |
| `english-common-10000.txt` | 高信心核心詞,給「最常用 10k」用途 | 一行一詞 | 10,000 詞 |
| `english-tech-terms.txt` | 技術 / 品牌 / 縮寫詞,供 `includeEngineering` 開關使用 | 一行一詞 | 257 詞 |
| `english-dictionary.txt` | 全量合法詞(**驗收用**,無權重) | 一行一詞,字典序 | 412,417 詞 |
| `english-manifest.json` | 建置後設:來源 URL、SHA-256、統計、權重參數 | JSON | — |
| `english-words-user.example.txt` | 使用者自訂詞檔格式範例 | 見檔內說明 | — |

> `count` 僅為**單調遞增的權重**,不是真實語料次數。引擎端用法:`rank = usageScore(word) × builtinCount(word)`。

---

## 2. 來源與授權

| 來源 | 角色 | 授權 | 是否隨 repo 散布 |
|---|---|---|---|
| `data/sources/base-english-100000.txt` | **種子詞表**(100k 常用詞) | 第三方(沿革見 §6) | 是(既有資料搬移) |
| `data/sources/tech-terms.txt` | 技術 / 品牌詞補集(257 詞) | 本專案自製 | 是 |
| [dwyl/english-words](https://github.com/dwyl/english-words) `words_alpha.txt` | 合法英文詞全集(369,804) | Unlicense | 否(僅本機快取) |
| [first20hours/google-10000-english](https://github.com/first20hours/google-10000-english) | 人工挑選常用詞(9,989) | MIT | 否(僅本機快取) |
| [hunspell en_US-large](https://github.com/en-wl/wordlist)(SCOWL) | 標準英文字典詞幹(61,448 小寫 / 15,511 專名) | SCOWL 授權 | 否(僅本機快取) |
| [wordfreq](https://github.com/wordfreq/wordfreq) 3.1.1 | 詞頻(Zipf 值) | MIT | 否(pip 安裝) |

所有遠端來源在 `data/sources/cache/` 快取(build 時自動下載),**不進版控**;
派生的詞表屬於事實性資料,不受來源詞典著作權限制。

---

## 3. 權重模型

可重現、無黑箱,全部在 `tools/build_english_dict.py` 中實作:

```
z  = wordfreq.zipf_frequency(word, 'en')          # 0..8 的對數詞頻
z += 0.30 × (1 - base_rank / 100000)              # 基底詞表的網頁語料順位(越前面加成越多)
z += 0.25  若命中 google-10000                    # 人工挑選的常用詞
z += 0.10  若命中 hunspell 小寫詞幹               # 標準英文字典收錄
z  = max(z, 2.20)  若為自建技術詞                 # 技術詞可被預測,但不擠掉常用詞
z  = max(z, 1.10)  若未通過任何字典驗證            # 多為人名/地名:保留但排在最末端
count = round(10 ^ z)                             # 單調遞增
```

排序鍵:`(z 由大到小, 基底順位 由小到大, 字母序)`。輸出門檻 `z ≥ 1.00`。

---

## 4. 分層

| 層 | 定義 | 詞數 | 用途 |
|---|---|---|---|
| core | 命中 google-10000,或命中 hunspell 且 `z ≥ 4.0` | 11,796 | 高信心,預測首選 |
| common | 通過 hunspell / dwyl / google 任一字典驗證 | 51,095 | 一般預測 |
| tech | 命中自建技術詞表 | 121 | 需 `includeEngineering` 開啟 |
| extended | 基底表內但未通過任何字典驗證(人名、地名、罕用詞) | 40,733 | 保留可打,排序最末端 |

`english-common-10000.txt` = 全表前 10,000 名(core 層為主)。

---

## 5. 統計與本次改動

- 種子 100,000 詞 → 最終預測表 **103,452 詞**
  - 保留 99,729 詞(其中 **271 詞**因權重低於門檻被移出預測表,但仍保留在 `english-dictionary.txt`)
  - 補入 3,723 詞(來自 google-10000 / hunspell / wordfreq;含 `wifi`、`abducting` 等先前遺漏者)
- 被移出的 271 詞多為垃圾/成人站點字串(`sexcam`、`milfhunter`、`voyeurweb` 等)與罕見技術字(`currentness`、`unmounting`)。
- 全量合法詞表 **412,417** 詞 = dwyl ∪ hunspell 詞幹 ∪ 種子表 ∪ google-10000(僅驗收用,不含權重)。

---

## 6. 與舊資料的差異(授權沿革)

| 項目 | 舊版 | 新版 |
|---|---|---|
| `data/english-words.txt` | 取自商業 app 安裝包內的 `english-words.txt`(227,921 詞) | **自建**:詞彙基底沿用既有 100k 表,權重與清洗全部改用開放來源重建 |
| 權重 | 第三方網頁語料次數 | 自建 Zipf 混合權重(公式見 §3) |
| 授權風險 | 未取得散布授權,權利人可要求移除 | 權重與驗證資料全來自 MIT/Unlicense 來源;僅「詞彙基底表」沿用既有第三方資料 |
| 雜訊 | 尾段大量非英詞、人名(`radda`、`kanchi`) | 未驗證詞統一降權到表尾,常用詞排序不受影響 |

> 舊檔(`data/english-words.txt` 227,921 詞、`data/english-common-100000.tsv`)已自版控移除,
> 仍可自 git 歷史取回(`git show 182e661:data/english-words.txt`)。

---

## 7. 已知限制

- **僅純字母**:主表只收 `^[a-z]{1,20}$`;縮寫詞(`mp3`、`k8s`、`ipv6`)只存在於 `english-tech-terms.txt`。
- **不含撇號與連字號**:`don't`、`well-known` 不在表內;英文流目前只處理字母序列。
- **無詞形展開**:以原形與常見變化為準,不從 hunspell affix 規則展開(`unboxing` 之類需各別收錄)。
- **Zipf 來自字幕語料**:偏口語;已用基底表的網頁語料順位(0.30 權重)混合,但仍非完美。
- **extended 層 4 萬詞**多為人名/地名,若使用者只想乾淨英文,可把門檻調高或改用 `english-dictionary.txt` + 自訂詞檔。
- `chinese-common-10000.*` 仍是第三方衍生(沿用既有資料),重建方式見 §9。

---

## 8. 重build

```bash
python3 -m venv .venv-dict
.venv-dict/bin/pip install wordfreq
.venv-dict/bin/python tools/build_english_dict.py            # 下載來源並重建輸出
.venv-dict/bin/python tools/build_english_dict.py --offline  # 只用本機 cache
.venv-dict/bin/python tools/build_english_dict.py --check    # 比對既有輸出,不一致則 exit 1(CI 用)
```

---

## 9. 後續工作

- [ ] 依 hunspell affix 展開詞形,涵蓋更多複數 / 過去式 / -ing 變化。
- [ ] 評估把基底表的第三方依賴整段替換掉(改以 SCOWL + 開放語料直接建構),達成「零第三方資料」。
- [ ] 中文常用詞表改由 McBopomofo 開放語料(`data.txt`,Apache-2.0)重建,取代既有第三方衍生版本。
- [ ] 引擎端整合:`english-words.txt` 載入為前綴 trie + top-K 預計算;`english-words-user.txt` 熱載。
