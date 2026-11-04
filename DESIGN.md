> **歷史設計草案：**此文件包含尚未驗證的假設及衝突。上游目前採 MIT 授權，不是本文所稱的 Apache-2.0；實際開發狀態與優先事項以 [階段 0–1 文件](docs/STAGE-0-1.md) 為準。

# ZhuyinLM-IME 設計文件 v1.1

> ✳ v1.1 變更:補齊 ZingIME 全部主要特色 → 對照表(§1.1);新增混打引擎(§5.4)、
> 自動全半形(§5.5)、聰明輸入 InputMacro(§5.6)、喵喵守門員(§5.7)、
> FloatingComposition 相容清單(§7.4);勘誤 MeowBouncer 定性;里程碑表擴充。

> 一款 macOS 注音輸入法:傳統統計語言模型為核心,LLM reranker 為增量選字層。
> 專案代號 `ZhuyinLM-IME`,本文件為單一真實來源(single source of truth),變更請更新版本號。

---

## 0. 依據(Evidence base)

本設計立足於對商用參考產品 **ZingIME v3.1 (build 2026102701)** 的逆向調查,關鍵已證事實:

| # | 事實 | 證據位置 |
|---|------|----------|
| F1 | ZingIME 為開源 McBopomofo 的衍生品 | 主二進位內嵌 DerivedData 路徑 `McBopomofo-*`、字典行 `# format org.openvanilla.mcbopomofo.sorted` |
| F2 | C++ 核心 = `Formosa::Mandarin`(注音解析)+ `Formosa::Gramambular`(ReadingGrid Viterbi) | nm 符號表 |
| F3 | LLM reranker 為獨立 helper,raw socket HTTP `127.0.0.1:<port>/score` | 字串 `http://127.0.0.1:%ld/score`、`rerankerd.sockaddr_in/handleClient/sendResponse` |
| F4 | 模型 = `mlx-community/Qwen2.5-0.5B-4bit`(265MB,4-bit Metal) | `RerankerModel/{config.json,README.md}` |
| F5 | reranker 以 `ScoreRankedLanguageModel` 裝飾 `Gramambular2`(`Formosa::Gramambular`)的 `ReadingGrid` LM 接口 | mangled 符號 `...ReadingGrid24ScoreRankedLanguageModelE` |
| F6 | 主程式含防抖狀態機:`_rerankGeneration`、`_rerankBackoffUntil`、`_rerankConvergenceRounds`、oscillation memory | nm 符號 |
| F7 | 學習系統:selection boost 寫回 LM、句子記憶、英文 Tab 預測 | `ChineseSelectionMemory.pushBoostsToLanguageModel` 等 |
| F8 | 詞庫獨立熱更新(manifest 版本化、staged 安裝、quarantine) | `LexiconUpdater.*`、`~/Library/Application Support/ZingIME/Lexicon/*.json` |
| F9 | 明文隱私宣告 "This data is local to this Mac and is never uploaded" | 二進位字串 |
| F10 | 混打 = "Bilingual typing" 且**僅 Standard 注音鍵位支援**;Caps Lock 不跳出系統英文鍵盤,`Caps Lock` 直通英文、`Caps Lock+Shift` 輸大寫;另有可自訂快捷鍵的 **Pure English Mode**,切換時以 badge 提示 | 字串 "Bilingual typing works with the Standard layout only"、"Caps Lock keeps typing Chinese; Caps Lock + Shift types a capital letter."、"EnglishModeBadgeController"、"Focus-in reminder badge" |
| F11 | 聰明輸入 = `InputMacroController` + `InputMacro` 巨集族:date/year/gan-zhi(干支)/zodiac(生肖)/date-time/time-zone/day-of-week/**ChineseNumbers(中文大寫)/RomanNumbers/單位換算("N to N units")**,以**候選字單**形式呈現(`InputMacroController.P` 遵循 `CandidateProviderP`) | mangled 符號 `$s7ZingIME14InputMacroDate…`、`$s7ZingIME16InputMacroGanZhi…` 等 |
| F12 | **勘查勘誤**:前回合我曾誤判 `MeowBouncer` 為授權鎖定面板;結合行銷描述「偵測異常高速連續輸入」,**MeowBouncer = 喵喵守門員**(貓咪打字保護),`MeowLockPanel` / `MeowBouncerLockWindowController` 為觸發時的鎖定 UI | 行銷頁面 + nm 符號覆核 |
| F13 | 針對特定 app 的組字相容措施:**FloatingComposition** 為 per-app 選項,需使用者到選單開啟,提示文案「can drop or duplicate text while composing」,已提示清單持久化(`FloatingCompositionPromptedHosts`) | 二進位字串 |
| F14 | 英文預測資料與互動全貌:227,921 行 TSV 詞表;usage 記憶為 `word→{updated,score}` 可重置;Tab 接受、RightArrow 可選、中文下一字僅 Tab;`bopomofoPreview` 在英文流同時預覽注音;Limit/Page 設定;自訂詞檔支援 # 註解、存檔熱載、恆排內建之前 | `english-words.txt`(227,921 行)、`english-usage.json` 欄位、nm `EnglishPredictionEngine.predict(prefix:limit:includeEngineering:)`、字串 "Chinese next-character suggestions are accepted with Tab only."、自訂詞檔頭註解 |

本產品**不使用** ZingIME 的任何程式碼、資源與模型;血統來自開源 MIT 專案(McBopomofo)。

## 1. 產品定位

- **一句話**:與小麥注音同級的統計引擎 + 本機 LLM 幫你把真正的用字排到最前的注音輸入法。
- **目標平台**:macOS 15+(Apple Silicon 為一級公民;Intel 版不含 LLM 層)。AI 層優先在 **macOS 26+ 用 Apple Foundation Models**(零下載、系統管理記憶體);MLX 0.5B 後端保留為舊 OS/可選下載。
- **差異化**:全本機、零上傳、LLM 可完整關閉(降級為純統計引擎,與小麥注音功能對齊)。
- **明確不做**:雲端同步、帳號、學習資料離機傳輸。

### 1.1 功能覆蓋對照(ZingIME 主要特色 → 本專案模組)

| # | ZingIME 主要特色 | 已證依據 | 本專案模組 | 里程碑 | 覆蓋 |
|---|------------------|---------|-----------|--------|------|
| 1 | 中英文直接混打 | F10 | Bilingual Engine(§5.4) | M1.5 | ✅ |
| 2 | AI 選字修正 | F3–F6 | RerankedLanguageModel + helper(§6) | M3 | ✅ |
| 3 | 100% 本機 AI | F9 | loopback-only 協議 + 隱私條款(§7.5) | M3 | ✅ |
| 4 | 英文單字預測(~22 萬詞) | §5.3 | EnglishPredictionEngine(trie + usage 記憶) | M2 | ✅ |
| 5 | 自動全形/半形 | (行銷;組字上下文規則) | SmartWidth(§5.5) | M2 | ✅ |
| 6 | 聰明輸入(日期/單位/符號/大寫數字) | F11 | InputMacroController + Macro 族(§5.6) | M2 | ✅ |
| 7 | 喵喵守門員 | F12 | MeowGuard打字速率守門(§5.7) | M3(輕) | ✅ |
| 8 | 標準注音配置 | F2 | 直沿用 Mandarin BopomofoKeyboardLayout 全族 | M1 | ✅ |
| 9 | 詞庫熱更新 | F8 | LexiconDispatcher(§7.3) | M4 | ✅ |
| 10 | FloatingComposition per-app 相容 | F13 | 相容清單 + 提示一次(FloatingPromptedHosts) | M4 | ✅ |
| 11 | 純英文模式 + 自訂切換快捷鍵 | F10 | PureEnglishMode + Badge(§5.4) | M1.5 | ✅ |
| 12 | 簡繁雙向轉換/異體字 | §6 周邊 | SwiftyOpenCC(匯入時的一項依賴) | M4 | ✅(可選)|
| 13 | 查詞典(MoE 字典/萌典/教育部…) | §6 資源 | DictionaryServices | M4 | ✅ |
| 14 | 注音點字 | nm 符號 `BopomofoBraille` | backlog | — | 🔶 backlog |
| 15 | iPhone 鍵中繼("sends them straight to the phone" + Accessibility 權限) | 二進位字串(功能全貌未證) | 不規劃(範圍外且細節未證) | — | ❌ 刻意排除 |
| 16 | 詞編輯器/自訂詞組/Snippets | nm 符號 | VocabularyManagerWindowController | M2 | ✅ |

## 2. 法律與素材

| 組件 | 來源 | 授權 | 使用方式 |
|------|------|------|---------|
| 注音解析、ReadingGrid、LM 數值核心 | github.com/openvanilla/McBopomofo 的 `Source/Engine/gramambular2`(`Formosa::Gramambular`)/ `Source/Engine/Mandarin` C++ 庫 | **MIT** | SPM 依賴,原樣沿用 |
| 基礎輸入流/候選窗骨架 | 同上 Swift 端(`McBopomofoInputController`、`CandidateUI`) | **MIT** | fork 後修改,保留版權聲明 |
| 注音詞庫母體 | McBopomofo 發布內 `Resources/data.txt`、`associated-phrases-v2.txt` | **MIT** | 本機解析成 `data/chinese-lexicon.tsv` 等衍生檔(見 README〈詞典建置〉) |
| LLM runtime | ml-explore/mlx-swift、huggingface/swift-transformers、huggingface/swift-jinja | MIT/Apache-2.0 | SPM 依賴 |
| 基底模型 | mlx-community `Qwen2.5-0.5B-Instruct-4bit`(或同期更小者) | Apache-2.0(Qwen 系) | 隨 app 打包;若供微調版需個別評估 |
| 自動更新 | Sparkle 2 | MIT | SPM 依賴 |
| 繁簡/異體轉換 | SwiftyOpenCC(含OpenCC字典) | Apache-2.0/MIT | 按需 |

> 紅線:不得反編譯 ZingIME 作為實作依據;本文件僅記錄其公開可觀察行為與架構級啟發。

## 3. 系統架構

```
~/Library/Input Methods/ZhuyinLM.app
├─ Contents/MacOS/ZhuyinLM            主 IME(Swift + C++ 橋接)
│   ├─ IMKServer/InputController      ← 註冊進系統的入口
│   ├─ KeyHandler + InputState 機     ← 組字、選字、英文模式全部狀態
│   ├─ CandidateUI                    ← 直/橫式候選窗
│   ├─ Core(橋接 C++)
│   │   ├─ formosa::Mandarin          ← 鍵→注音
│   │   └─ formosa::Gramambular       ← ReadingGrid:注音串→Viterbi拆詞
│   │       └─ LM trait ←──┐
│   │                      │ Souce: 統計LM(詞庫頻率+使用者boost)
│   │                      └─ 【RerankedLanguageModel 裝飾器】← M3 起
│   ├─ Memory                         ← 學習模型(§5)
│   └─ LexiconDispatcher              ← 詞庫版本化快取
└─ Contents/MacOS/zhuyin-helper       ← 獨立執行檔,不佔主 IME 記憶額度
    ├─ raw-socket HTTP, loopback on ~127.0.0.1:<port>:/score
    ├─ mlx-swift + swift-transformers + jinja
    ├─ 量化模型(reader: bundle path 可被覆蓋)
    └─ scoreBatchSync(candidates, context) -> [Float]
```

**為什麼 helper 分離**(F3,原因有三):
1. macOS 背景程序記憶體上限低;IME 主行程常駐不能塞 265MB 模型。
2. helper 崩潰不拖垮輸入體驗,可乾淨降級回純統計引擎。
3. helper 只用本機 socket,無 XPC 服務註冊、無 framework 幾乎零依賴。

## 4. 主流程:輸入 → 選字

```mermaid
sequence
  Keystroke("一聲一聲") --> KeyHandler(state=Composing)
  KeyHandler --> BopomofoReadingBuffer   (組注音音節:ㄧㄤㄧㄤ…)
  KeyHandler --> ReadingGrid.add(reading)
  ReadingGrid --> StatisticsLM.walk      (Viterbi: 最短路徑,內點為詞)
  ReadingGrid --> 若STEAL: RerankedLM 排序
  ReadingGrid --> CandidateList
  CandidateUI 顯示                     ← 直式Tab/橫式數字鍵
  Enter       --> controller.commit
  Memory.recordSelection(reading, value)   → 觸發 pushBoostsToLanguageModel()
```

### 4.1 InputState 狀態機(唯一真實來源)

```
Deactivated
  → Composing{-1}                 注音buffer非空
  → Marking{span}                 位於選字時ourging起點
  → ChoosingCandidate
  → CandidateAssistantMode(streams)
  → EnglishPredicting{prefix}     Tab-預測英文
  → EnglishMode                   全英文直通
  → AssociatedPhrasesMode         Shift+Enter 聯想詞
  → ChineseNextCharacterPrediction    ← 可選
```
每個狀態攜帶不可變 snapshot(`InputState` protocol + value types),UI 與 reranker 都只消費小快照 —— 這是 DOS 防抖設計的基礎。

## 5. 學習系統

> **詞庫來源**:統計層的初始語料為本專案**自建**的三套資料——
> 中文詞庫取自 McBopomofo 官方發布(MIT)的 `data.txt`,本機解析成
> `data/chinese-lexicon.tsv`(160,792 詞,含多讀音與 log10 分數);
> 中文**詞接詞(bigram)**統計由 `tools/build_chinese_bigrams.py` 自中文維基百科
> (CC BY-SA 4.0)語料建置,見 `data/chinese-bigrams.tsv`;
> 英文詞庫見 `data/english-words.txt`(113,092 詞,自建 Zipf 混合權重)。
> 各檔的來源、授權、統計與重建方式見 README〈詞典建置〉。

### 5.0 統計層資料契約(LM 的三張表)

Gramambular 的 LM 介面需要 `unigramsFor(reading)` 與 `bigramsFor(prevWords)`,
本專案對應三張純文字表(引擎啟動時載入,不需要二進位格式):

| 檔案 | 格式 | 對應介面 |
|---|---|---|
| `data/chinese-unigrams.tsv` | `讀音<TAB>詞<TAB>log10 機率` | `unigramsFor(reading)` |
| `data/chinese-bigrams.tsv` | `前詞<TAB>後詞<TAB>共現次數` | `bigramsFor(prevWords)` |
| `data/english-words.txt` | `詞<TAB>權重` | 英文預測引擎的前綴 trie |

**融合公式**(bigram 有計數時才啟用,否則純 unigram):

```
P_u(w)      = unigram 機率(讀音條件下)
P_b(w|prev) = (count(prev,w) + α·P_u(w)) / (count(prev) + α)      # 加 α 平滑 + 回退
score(w)    = log10[ λ·P_b(w|prev) + (1-λ)·P_u(w) ]                # λ = 0.60,α = 0.10
```

- `λ`、`α` 由 `tools/eval_bigram_lm.py` 在 dev 集掃描,結果見 README〈詞典建置〉。
- **bigram 只做詞與詞的排序**,不影響讀音層;讀音仍由 `Formosa::Mandarin` 決定。
- 這一層是 LLM reranker 之前的**免費上下文訊號**:延遲為 0(查表),不需模型。

### 5.1 統計層:selection boost(先用,最重要)
- `ChineseSelectionMemory.recordSelection(reading:value:)` → 內存 `key=(reading,value) -> count`
- 四域合併(placeholder `Dictionary<String, [String: Double]>`)
- `pushBoostsToLanguageModel()` 將 count 轉為 LM 的 score 加成(`grammbular++ 語意`:score += log(boost/decay))
- decay 曲線入倉:boost_t = 1 + α·e^(-t/τ),τ 預設 30 天,確保近期用字向上浮而非永久鎖定

### 5.2 句子記憶
- `SentenceMemory.record(text, readings)` 存「文本+讀音」對
- Shift+Enter 聯想:游標前字的注音查 continuations(prefix) → 候選出現

### 5.3 英文邊打邊預測引擎(呈 F14 實證)
- `english-words.txt`:**本專案自建的預測詞頻表**,TSV(`word<TAB>count`),count 為**單調遞增的權重**(非真實語料次數);共 113,092 詞,另附 `english-tech-terms.txt`(257 筆技術/品牌詞,對應 `includeEngineering` 開關)。建置來源、授權、權重模型(Zipf + 字典驗證加權)與分層統計見 README〈詞典建置〉,可用 `tools/build_english_dict.py` 完整重現。
- `english-usage.json`(本機記憶):`word → {updated: timestamp, score: Float}` — score 有使用累加(**使用一次 +1**)與**時間衰減**(score≈1.999x/1.99x 且 updated 隨之變動,推斷為隨時間 tick 的半衰式衰減);偏好可整體重置("Forgetting them puts the predictions back to the bundled order")。
- `english-words-user.txt`:可用 **# 註解**、**存檔即熱載**(字串 "改完存檔後,下次組字時自動重新載入"),**總是排在內建詞庫之前**(自訂品牌/術語優先)。

**執行層**
- 每次英文按鍵 → `EnglishPredictionEngine.predict(prefix:limit:includeEngineering:)`(前綴 trie;`includeEngineering` 可關工程詞)。
- 狀態 `InputState.EnglishPredicting` 攜帶**(composingBuffer, predictions, bopomofoPreview)** — `bopomofoPreview` 意謂混打流中**同時預覽「若改按注音會組成什麼」**,讓使用者滑移不糾結。
- 接受:**Tab**(英文 + 中文 next-character);**RightArrow 可選**偏好 `RightArrowAcceptsEnglishPrediction`(中文 next-character 僅 Tab,不佔游標移動)。
- 顯示數量 `EnglishPredictionLimit`、翻頁 `EnglishPredictionPage`。
- 接受一次即更新 usage 記憶(score+1、updated=now),下次同前綴提升。

**排序公式(本專案採用的推斷復刻)**
```
rank(word) = userFileOrder > usageScore(word, recency decay) × builtinCount(word)
```
- 純字詞統計,無 LLM 依賴(不呼叫 /score)— LLM reranker 屬於中文選字;英文預測必須永遠高效能、零感知延遲。
- 效能預算:此引擎需在單鍵後 ≤ 5ms 內出 prediction(前綴 trie + 228k 詞數據表,常駐記憶)。

### 5.4 中英文混打引擎(Bilingual Engine,呈 F10)

設計原則:**中文為主語境,英文為直通流**,零手動切換心願(Caps Lock 不再生效為媒體切換)。

```
規則(僅在 Standard 注音鍵位下啟用;Non-standard 鍵位自動退化為切鍵盤式)
  buffer 為空時:
      ← 字母鍵 → 開啟英文流(仍可被 Tab 預測)
      Shift+字母 → 大寫英文(與「Windows 式 Shift」規則合流)
  buffer 非空時:
      ← 按鍵一律歸注音解析;聲調落定後 commit 前緣英文
  Caps Lock 按下時(系統內建開關已關):
      ← 直通 buffer 清空 → 切 Pure English Mode(佔用同一鍵)
      Caps Lock + Shift → 輸出一個大寫字母(不切換)
      顯示「EnglishModeBadgeController」:輪圈提示 + 「Focus-in reminder badge」
        (前景 app 切換時顯示當前模式小徽章,防「入錯欄位打了半行英文」)
  純英文模式 Power modalità:
      ← 可自訂全局熱鍵切入;狀態列/徽章顯示
      ← 無聯想詞/無巨集(「No word suggestions in Pure English Mode」)
```
- 強制守:系統建議的**停用 macOS 內建 Caps Lock → 英文鍵盤**引導文案(「Turn off the macOS Caps Lock switch first…」)落地為首啟 Onboarding 之一鍵開關。
- 邊界:Bilingual typing 關閉時 → Shift+字母 = 小寫英文(和 macOS 內建注音一致),保留雙樣式。

### 5.5 自動全形/半形(SmartWidth)

規則驅動,無 LLM 依賴:

| 語境 | 輸出 | 例 |
|------|------|---|
| 全中文字元旁 | 全形標點 | 你好，請看 |
| 英文單字/URL 前後 | 半形標點與空格 | 這是 https://a.b,好 |
| 數字推疊 | 半形阿拉伯數字 | 2026 年 |
| 純英文句末 | 半形句點 | OK. Done. |
| 感嘆/問句於中文 | 全形 !? | 天啊！ |
| `TISDoubleSpaceSubstitution`(F: Info.plist)| 雙空格 → 全形句號「。」(可關) | |

- 實作:組字提交階段的後處理 pass;提供偏好 `SmartPunctuationEnabled` 逐項可關。

### 5.6 聰明輸入(InputMacro,呈 F11)

- 觸發:在英文流/中文組字區外輸入**縮字或數字 token** → `InputMacroController` 以 `CandidateProviderP` 回應,**以候選字單形式展開**:逐項 Enter 上屏;巨集可關。
- Macro 族(MVP 排序):Date、DateTime、Year、DayOfTheWeek、TimeZone、**GanZhi(干支)**、**Zodiac(生肖)**、**ChineseNumbers(阿拉伯→中文大寫/一般大寫)**、RomanNumbers、單位換算(`"N to N units"`,長度/重量/溫度等)。
- 實作類型:`protocol InputMacro { func candidates(forToken:) -> [Candidate] }` + `InputMacroTransform`(格式化層);全為**本機即時計算**,不走 LLM(延遲零)。

### 5.7 喵喵守門員(MeowGuard,呈 F12 勘誤)

| 偵測 | 反應 |
|------|------|
| 持續鍵率 ≥ 門檻(預設 > 25 keys/sec 連續 400ms,可調)| **凍結輸入**:所有鍵被吞下、不進組字區 |
| 偵測觸發中組字 | buffer 保留快照;凍結結束前不上屏 |
| 觸發 UI | `MeowLockPanel`:貓咪插畫的鍵盤鎖 + 倒數(預設 3 s),貓走完自動解鎖;可靜音關閉 |
| 誤判保險 | 「我知道我在打字」按鍵序列(如 Esc+Esc)即手動解鎖;偏好總開關 |
- 定性:與授權機制**完全無關**(F12);純 UX 守門。

## 6. LLM Reranker 設計(M3 核心成本點)

### 6.1 進程模型
| 項目 | 決策 |
|------|------|
| 生命週期 | 閒置 10s → SIGTERM 退出;首次請求 spawn;主 app 退出時 kill |
| 單一實例 | helper 只 spawn 一次;adapter 以鎖與埠佔用檢查避免 fork-bomb |
| 跨程序 | HTTP/1.0 over 127.0.0.1,單一 request 內完成 full-batch |
| 併發 | 單 worker 併發;新請求抵達未完 → Cancel + 併發集合重執行 |
| 記憶體 | 快取上限 env `HELPER_CACHE_MB` 預設 128MB(與 F4 日誌一致) |
| 降級 | helper spawn 失敗/timeout 3 次 → 標記 disabled 直到下次 app 啟動 |

### 6.2 `/score` 協定(本專案自有設計,不受 ZingIME 逆向限制)

```jsonc
// 請求
POST /score
{
  "id": "r-172",              // 用來作廢舊回覆的 sequence/generation id
  "context": "今天天氣真",      // 欲評估字 前 N(≤16)已確定文字
  "candidates": ["好", "棒", "薄"], // 待排序詞, 通常 ≤20
  "region": {"start": 0, "end": 5}, // 可選: 組字區內重評區段,
  "deadlineMs": 250           // 硬時限, 超過省略即回 partial
}
// 回應
{
  "id": "r-172",              // client 側驗證落後 generation 即丟棄 (F6)
  "scores":    [0.91, 0.72, 0.03],
  "model": "qwen2.5-0.5b-4bit@v3",
  "ms": 142
}
```

- 打分協定:用 LM 自評任選一種──
  - 首選:`teacher-force` 法。把 `context + candidate` 一次餵入,取 candidate 首 token 對數機率;batch 一次 forward。
  - 備案:每案重複取最終 token(hidden)→ cosine distance。不採生成式(無法估時)。
- **邊界守則**:LLM 只排序不造詞;無法管到 out-of-vocab 的展候選(統計 LM 造的)一律只剩 fallback。

### 6.3 防抖與收斂(呈 F6 的可觀察行為,本專案原造)
```
scheduleRerank():
    if inflight generation ≠ current → cancel + reset
    delay = max(LLMDelayMs, 80ms)               # 停頓後才牽動 GPU
    after(delay) { inflight = gen; queryHelper() }

onResponse(scores):
    if response.id < currentGeneration → drop  # 使用者已散步
    applyScoresToReadingGrid(regions)
    if Δrank < ε for k (=2) consecutive rounds → convergence: 停止重排
    if |perm(t)-perm(t-1)| ∞次在A/B間振荡 → oscillation memory: 該區段 lock
    else → scheduleRerank()                     # 已命中的往蔘若鎬會層層變好
```
- backoff:helper 429/timeout → 指數 backoff 500ms→8s,期間顯示 "AI 未參與" 徽章(可關)
- 所有數值留在 `UserRules.plist` 偏好:Enabled / Port / DelayMs / ShowBadge / ShowHint / DebugLog

### 6.4 ScoreRankedLanguageModel 裝飾器(F5 啟發,本專案原造)
```swift
protocol LM {
    func unigramsFor(reading) -> [Unigram]              // (value, score)
    func score(bigrams: [(prev: String, cur: String)]) -> [Double]
}
final class RerankedLanguageModel: LM {
    private celleblet base: LM        // StatisticsLM (詞庫+boost)
    private var override: [String: [Int: Double]] = [:]   // 分數覆蓋快取
    func unigramsFor(r) { if let o = override[r] { return base.unigramsFor(r).sorted(by: o) }; return base.unigramsFor(r) }
}
```
- 裝飾器持 "input override",重排結果不進回 Viterbi 統計 LM;使用者選擇才入 boost,避免 LLM 打分汙染長期分布。

### 6.5 Reranker 後端選型:MLX Qwen vs Apple Foundation Models

**現況事實(2026-11 查證,見 §6.6 來源)**
- Foundation Models framework(macOS 26+):可存取 Apple Intelligence 的**約 3B 參數 on-device 模型**,開發者使用**免費**、離線、隱私;支援**繁體中文**(macOS 26.1 起);context 4096 tokens(新世代 8192,`SystemLanguageModel.contextSize` 可查);提供 `@Generable` guided generation、tool calling、greedy/隨機取樣;**沒有公開的 token logprob / 分數 API**(截至 WWDC26 資料)。
- WWDC26 起框架以 `LanguageModel` 協定開放第三方模型(含 Private Cloud Compute 32K),但本專案**只採 on-device**,PCC 不符合 100% 本機承諾。

**比較**

| 維度 | MLX + Qwen2.5-0.5B-4bit(現行 ZingIME 路線) | Apple Foundation Models |
|---|---|---|
| 模型能力(zh-Hant) | 0.5B,上下文理解有限 | **~3B,明顯更強**(但繁體語感仍需 eval) |
| 打分粒度 | **可取 log-prob,可做 teacher-forcing 精確排序**(我們 §6.2 首選) | **無 logprob**,只能「生成式選出/排序」 |
| 延遲 | 批次 forward,實測級 ~140ms(參考 log) | 生成式;選 1 名約數個 token,估 200–500ms;比 forward 慢 |
| 記憶體 | 需 helper 行程 + 265MB 模型 + cache | **系統管理,app 記憶體近乎零**,無 helper |
| 發佈體積 | +265MB(+MLX/swift-transformers 依賴) | **0**,不隨 app 下載模型 |
| 系統需求 | macOS 15+,Apple Silicon | **macOS 26+**,需開啟 Apple Intelligence |
| 更新 | 每次模型升級要重新打包 | **隨 OS 升級免費變強** |
| 確定性 | 高(固定 forward) | greedy 可確定,但模型隨 OS 版本變 → 需要 eval 回歸 |
| 限流 | 自行控制 | 系統有 rate limit(`LanguageModelError`),需 backoff(§6.3 已有) |
| 授權/法務 | 模型 Apache-2.0,可打包 | 系統 API,無散布問題 |

**決策(採用混合後端,Apple 優先)**

```
RerankerBackend 協定
├─ AppleFMReranker     macOS 26+ 且 availability == .available → 優先
│    guided generation:@Generable 輸出「排序後 top-K 候選索引」
│    取 greedy sampling;回應轉成 rank→score 映射(僅排序,不是機率)
│    context budget:<=200 tokens(eval 於 4K 內極度安全)
└─ MLXReranker         可用時作為對照/備援(舊 OS、或 Apple 不可用)
     §6.2 teacher-forcing logprob 精確打分(維持原演算法)

選擇器:Apple 可用 → Apple(使用者可強制切 MLX 做 A/B)
        Apple 不可用 → MLX(若已下載)→ 否則關閉 AI(純統計)
```

**關鍵設計因應**
1. **Apple 路徑沒有機率分數** → 定義 `rankScore(k) = 1 - k/N` 這種單調映射進 `ScoreRankedLanguageModel`;只覆蓋「排序」,不假裝有 confidence。
2. **輸出必須極短** → prompt 要求只回 `["3","0","7"]` 這種索引陣列(guided generation 約束),把 decode 成本壓到 <10 tokens;禁止長篇解釋。
3. **模型會隨 OS 更新改變行為** → 建 eval harness:固定 200 句同音字測試集,記錄 top-1/top-3 修正率;OS 升級後回歸,守住不收退化。
4. **rate limit / 不可用** → 沿用 §6.3 backoff;helper 不存在時 Apple 路徑免 spawn,反而更省。
5. **相容性** → 核心 IME 仍支援 macOS 15+;AI 功能在 macOS 26+ 自動啟用,其餘版本可選 MLX 或關閉(維持「可完全降級」賣點)。

**結論**:不是「Apple 一定比較好」,而是**分工**:
- 追求「零下載、零維護、語意更強」→ Apple FM 是首選,適合以 macOS 26+ 為主的市場;
- 追求「可精確打分、可重現、可跨 OS」→ MLX 0.5B 仍值得保留;
- 最務實:先以 AppleFMReranker 做 MVP(M3a),MLX 後端列為 M3b(下載式選配)。

> 📋 雙後端的完整工作分解、prompt/演算法規格、eval harness、排程與風險,見 **[`PLAN-reranker-backends.md`](PLAN-reranker-backends.md)**。

### 6.6 選型來源(2026-11)

- Apple Foundation Models 文件:context 4096、token 計數、語言支援(繁中)、`contextSize` / `tokenCount(for:)`:developer.apple.com/documentation/foundationmodels
- Apple「Foundation Models」框架總覽與 3B on-device 模型、免費推論:apple.com/hk newsroom(2025-11 繁中上線)、arXiv 2507.13575
- WWDC26「What's new in the Foundation Models framework」「Bring an LLM provider」:新 on-device 模型、context 8192、`LanguageModel` 協定開放、rate limit 錯誤型別

## 7. 主程序環境細節

### 7.1 Info.plist(輸入模式註冊)骨架
```xml
<key>ComponentInputModeDict</key>
<dict>
  <key>tsInputModeListKey</key>
  <dict>
    <key>tw.example.ZhuyinLM.Bopomofo</key>
    <dict>
      <key>TISIntendedLanguage</key><string>zh-Hant</string>
      <key>tsInputModeScriptKey</key><string>smTradChinese</string>
      <key>TISDoubleSpaceSubstitution</key><string>。</string>
      <key>tsInputModeDefaultStateKey</key><true/>
    </dict>
  </dict>
</dict>
```

### 7.2 簽名與安裝
1. 簽名(`codesign -s -- --deep` 本地可測;分發需 Developer ID)
2. copy 至 `~/Library/Input Methods/`
3. 觸發系統登錄:登入/登出 或 `TISCopyInputSourceFilter` 補捉(文件沿用小麥)
4. **開發模擬**:`SimulationHost.app`(內嵌 IMKServer 的 host app)讓你不裝 IME 也能打字 ── 首個里程碑(M0)就位

### 7.3 詞庫熱更新(呈 F8)
- `~/Library/Application Support/ZhuyinLM/Lexicon/{installed-manifest.json, last-check.json}`
- 伺服器 (static JSON): `modules: [data.txt, associated-phrases-v2.txt, …]`
- 流程:periodicCheck → 比版本 → 以 Gzip 壓縮的 staged `pending/` → `codesign_spctl` 驗證所有批次 → quarantine 檢測 → 下次視窗切換 atomic swap
- 撫神:與 app 版本同走 Sparkle

## 8. 測試策略

| 層 | 作法 |
|----|------|
| C++ LM 網格 | golden tests:固定拼音序列 → 期望候選列表(小麥或開源觸接既有) |
| reranker helper | 對 /score 進行 producer:固定 context 預記分數快照;延遲求 p95 |
| 狀態機 | `InputState` 純泛型+command紀錄重放 |
| E2E(模擬) | SimulationHost + 預錄 sequence 影碆一套 |
| 效能 | 儀表板:輸入到候選 p95 ≤ 30ms(純統計);rerank 到位 p95 ≤ 250ms |

## 9. 里程碑

| M | 內容 | 驗收 |
|---|------|------|
| M0 | 倉庫骨架 + SimulationHost | 模擬視窗可接收keydown |
| M1 | 純統計引擎**可打字** | 注音→候選→上屏;5 種鍵位 |
| M1.5 | 混打引擎 + Pure English Mode + Badge | Caps Lock/Shift 語意全對齊 F10 |
| M2 | 學習層(選字boost+句記憶+英文Tab) | 選 "是" ×3 → 該字穩定座落第一位 |
| M2.5 | SmartWidth + InputMacro + 詞彙管理 | 六巨集族皆可展開候選;全半形規則通過 golden tests |
| M3a | **AppleFMReranker**(Foundation Models)+ 防抖 + MeowGuard | macOS 26+ 上 top-3 修正率不低於 MLX baseline;rate limit 降級正常 |
| M3b | **MLXReranker**(MLX 0.5B,選配下載)+ 後端切換 UI | 無 Apple FM 的機器仍可選用;p95 ≤ 250ms;可完全關閉 |
| M3c | eval harness(200 句同音字集)+ 兩後端 A/B | OS 升級回歸可量化,守住 0 退化 |
| M4 | 詞庫熱更新 + Sparkle + FloatingComposition + 打包簽名 | 可安裝到真系統輸入 |
| M5 | (可選)啟用器、Onboarding(含 Caps Lock 引導頁) | |

## 10. 開放問題(要先量測才有答案)

1. helper 首次載入模型耗時(Metal 壓縮、頁快取)→ 決定常駐策略;
2. `teacher-force` 打分在 4-bit 0.5B 上實際延遲 → 決定 batch 上限;
3. LLM 分數搭配統計路徑的最優介入幅度(全部重排 vs 只前 5 名)→ A/B;
4. macOS 未來版本對背景程序記憶上限是否再縮 → helper 常駐的保險條款。
