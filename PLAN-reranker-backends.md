# ZhuyinLM-IME · Reranker 雙後端實作規劃書

> 版本:v1.0 · 2026-11-02 · 狀態:**規劃完成,尚未執行任何實作**
> 關聯文件:`DESIGN.md` §6.2–§6.6(架構與選型)
> 範圍:兩條後端工作流並行推進,共用一個介面、一個 eval harness、一個驗收門檻。
> 讀者:實作負責人、QA、產品。

---

## 0. 前提與界線

- 本文件只做**規劃**:定義工作分解(WBS)、介面契約、prompt/演算法設計、測試與驗收門檻、排程與風險。
- 不包含程式碼實作、不建立 Xcode 專案、不執行模型推論。
- 兩條後端**平行開發**,但必須先完成 §2 共用介面與 §3 eval harness,才能進入各自的品質調校。
- 核心輸入法(統計引擎、UI、記憶)不在本文件範圍,見 `DESIGN.md` M0–M2.5。

## 1. 目標與成功指標

### 1.1 產品目標
1. 中文選字修正品質:**在 200 句同音字測試集上,top-1 修正率 ≥ 25%**(相對統計 baseline 的首選錯誤被改對)。
2. 不倒退:**不得讓原本正確的 top-1 被改錯超過 2%**(precision guard)。
3. 即時性:rerank 從「停止輸入」到候選更新 **p95 ≤ 250ms**(Apple 後端允許 ≤ 400ms)。
4. 隱私:100% 本機;helper 只 bind `127.0.0.1`;Apple 後端只呼叫 on-device 模型。
5. 可降級:任一後端不可用時,5 秒內回到純統計引擎體驗,且 UI 明確標示 AI 狀態。

### 1.2 量測定義
| 指標 | 定義 | 目標 |
|---|---|---|
| Recall@1 | 金標字在 top-1 的比例(修正後) | ≥ 88% |
| CorrectionRate | 修正前 top-1 錯、修正後 top-1 對的比例 | ≥ 25% |
| RegressionRate | 修正前對、修正後錯的比例 | ≤ 2% |
| MRR | 金標字正確排名的平均倒數 | ≥ 0.90 |
| Latency p50/p95 | 輸入停頓 → 分數套用 | ≤ 150 / 250ms(Apple ≤ 400) |
| Cold start | 首次請求 (含模型載入/暖機) | ≤ 3s(Apple ≤ 500ms) |
| Memory | 主 IME 增量 | ≤ 30MB(Apple ≤ 10MB) |
| Helper RSS | MLX helper 峰值 | ≤ 600MB |
| Energy | 10 分鐘連續輸入耗電增量 | ≤ 1.5 倍 baseline |
| Privacy | 連線目的地白名單測試 | 100% 通過 |

### 1.3 非目標
- 不做句子生成、不改寫已上屏文字(未來功能另案)。
- 不做雲端/Private Cloud Compute(違反 100% 本機)。
- 不支援 Intel Mac 的 LLM 層。

## 2. 共用架構與介面契約(先決條件)

### 2.1 Swift 介面

```swift
/// 所有 reranker 後端共同介面。只做「候選排序」,不做生成。
protocol RerankerBackend {
    var id: RerankerBackendID { get }           // .appleFM / .mlx
    var isAvailable: Bool { get }
    /// 回傳與 candidates 等長的分數;分數僅用於排序,不需跨後端可比。
    func score(candidates: [String], context: String,
               deadline: Duration) async throws -> [Float]
}

enum RerankerBackendID: String { case appleFM, mlx }

enum RerankerError: Error {
    case unavailable, busy, timeout, rateLimited(retryAfter: Duration),
         invalidResponse, modelLoadFailed, contextOverflow
}
```

### 2.2 共用資料模型
- `RerankRequest`: `{ id: UInt64, context: String(≤16字), candidates: [String](≤20), region: Range<Int>, deadlineMs: Int }`
- `RerankResult`: `{ id, scores: [Float], backend, modelVersion, latencyMs }`
- **正規化**:兩後端最終都輸出 `[Float]`,由 `ScoreRankedLanguageModel` 做排序覆蓋;若後端只有排名,使用 `rank→score` 單調映射(§4.3)。

### 2.3 共用調度器(與後端無關)
```
onTextChanged:
  bump(generation)
  debounce(LLMRerankerDelayMs, min 80ms)
  if backendBusy || backoffActive: return
  request(id=generation, deadline=250ms)
onResult(r):
  guard r.id == currentGeneration else drop
  applyScores(regions); convergenceCheck(); oscillationCheck()
onError(e):
  backoff(e); if repeated ≥3 → disableUntilNextLaunch
```
- 沿用 `DESIGN.md` §6.3 的收斂/振盪/退避機制;兩後端不得各自實作一份。

### 2.4 設定與旗標(UserDefaults)
| Key | 型別 | 預設 | 說明 |
|---|---|---|---|
| `AIRerankerEnabled` | Bool | true | 總開關 |
| `AIRerankerBackend` | String | auto | `auto/appleFM/mlx` |
| `AIRerankerDelayMs` | Int | 80 | debounce |
| `AIRerankerShowBadge` | Bool | true | AI 狀態徽章 |
| `AIRerankerDebugLog` | Bool | false | 結構化日誌 |
| `AppleFMMaxCandidates` | Int | 12 | Apple 路徑候選上限(控制輸出長度) |
| `MLXMaxCandidates` | Int | 20 | MLX 路徑候選上限 |
| `MLXPromptSetVersion` | String | v1 | prompt 變體版本 |

### 2.5 目錄與檔案佈局(規劃)
```
Reranker/
├─ Shared/            RerankerBackend.swift, RerankModels.swift, RankNormalizer.swift
├─ AppleFM/           AppleFMReranker.swift, PromptBuilder.swift, ResponseParser.swift
├─ MLX/               MLXClient.swift, HelperProcessManager.swift
└─ Eval/              EvalRunner.swift, Metrics.swift, GoldenSets/
RerankerHelper/       main.swift, ScoreEngine.swift, HTTPServer.swift, ModelLoader.swift
```

## 3. 共用 Eval Harness(第一優先,兩線共用)

### 3.1 測試集設計
- **200 句**繁體中文,涵蓋:
  - 同音異字(min 80):在/再、的/得/地、那/哪、以/已、因/應…
  - 常見詞錯選(min 40)
  - 專有名詞/品牌(min 20)
  - 長句(≥ 15 字,min 30)
  - 英文混打句(min 30)
- 每筆:`{context, 統計 top-10 候選, 金標, 難度標籤, 來源}`
- 來源:公開語料 + 自建(不得使用 ZingIME 私有資料);存 `GoldenSets/zh-Hant-200.jsonl`,附授權說明。
- 切分:**dev 120 / test 80**,test 集凍結,調參不得查看(test 只在里程碑評測時跑)。

### 3.2 指標與報表
- Recall@1/3、CorrectionRate、RegressionRate、MRR、平均排名變化。
- 延遲:p50/p95/max(分 backend、分冷/熱啟動)。
- 記憶體與能耗(Apple:Instruments / `powermetrics`;MLX:helper RSS)。
- 輸出:`eval-report-<backend>-<date>.md` + 機器可讀 JSON;納入 repo(不含私人資料)。

### 3.3 A/B 與回歸流程
1. 任一後端改動 → 跑 dev 集,指標不得低於 baseline - 0.5%。
2. 里程碑 → 跑 test 集一次,留存報告。
3. OS 升級(macOS 26.x)→ 強制重跑 Apple 後端測試集,檢查模型漂移。

## 4. Track A:MLX + Qwen2.5-0.5B-4bit

### 4.1 目標
復刻 ZingIME 驗證過的路線:獨立 helper + loopback HTTP + teacher-forcing logprob 打分;作為 Apple 不可用時的後端與 A/B 對照。

### 4.2 元件與職責
| 元件 | 職責 |
|---|---|
| `RerankerHelper`(Swift 執行檔) | socket server、JSON 解析、模型載入、暖機、批次打分、資源上限 |
| `HelperProcessManager`(主 app) | spawn/kill、埠管理、健康檢查、閒置退出、crash 重啟(有限次) |
| `MLXClient` | HTTP client、timeout、重試、指標上報 |
| `ScoreEngine` | tokenize、prompt 組裝、forward、logprob 聚合、校準 |

### 4.3 打分演算法(規劃規格)
1. **輸入**:`context`(前 16 字)、`candidates`(≤20)。
2. **序列組裝**(v1):`context + candidate`,不加指令文字;模型為 base LM 行為(chat template 僅用於必要時)。
3. **teacher-forcing**:
   - 對每個 candidate 取其在序列中的 token span(需 tokenizer offset 對齊;若候選切分跨 token 邊界,記錄 `boundaryWarn`)。
   - 分數 = 該 span 的 token logprob **平均**(長度歸一化)或總和;兩者列為 prompt set v1/v2 做 A/B。
4. **批次**:一次 `ModelContext` 內把所有候選組成 batch(共享 context KV cache),單次 forward。
5. **校準**:輸出 z-score 或 min-max;與統計 LM 分數融合採 `final = w·z(llm) + (1-w)·z(lm)`,w 由 dev 集掃描(0.2–0.6)。
6. **邊界**:candidate 為空/含控制字元 → 直接回統計分數;context 超過 64 tokens → 截斷至最後 64。
7. **版本**:`promptSetVersion`、`modelVersion`(模型 hash)、`scoringMode` 寫入 log 與結果。

### 4.4 HTTP 協定 v1
```
POST /score
{ "id": 172, "context": "...", "candidates": ["好","棒"], "deadlineMs": 250 }
→ 200 { "id":172, "scores":[0.91,0.42], "model":"qwen2.5-0.5b-4bit", "ms":143 }
錯誤:400 bad_request / 409 busy / 504 timeout / 503 model_unavailable
GET /health → { "ok":true, "modelLoaded":true, "warm":true, "rssMB":420 }
```
- 只 bind `127.0.0.1`;埠由主 app 指定(預設 0 = 系統分配,回報實際埠)。
- 單一 worker;新請求到達時,若前一請求未完成 → 回 409(由 client 端作廢)。

### 4.5 生命週期與資源
- 首次啟用才 spawn;閒置 10 分鐘 → 退出(可設定)。
- 模型載入後執行「暖身句子」1 次(固定短文),完成才回 `warm=true`。
- `MLX cache` 上限 128MB(env `RERANKER_CACHE_MB`)。
- 主 app 退出時 kill;crash 重啟 ≤3 次/小時,之後禁用至下次啟動。
- 日誌:結構化 JSONL 至 `~/Library/Logs/ZhuyinLM-reranker.log`,含請求 id、候選數、ms、backend、錯誤。

### 4.6 工作分解
| ID | 任務 | 產出 | 估時(人日) | 依賴 |
|---|---|---|---|---|
| A1 | Helper 骨架(raw socket + /health + /score 空實作) | 可跑的執行檔 | 3 | — |
| A2 | 模型載入 + tokenizer + 暖機 | `warm=true` 日誌 | 3 | A1 |
| A3 | teacher-forcing 打分 + 批次 + span 對齊 | 單元測試 + 範例分數 | 5 | A2 |
| A4 | HTTP 協定完整化(錯誤碼/超時/409) | 契約測試 | 2 | A1 |
| A5 | `HelperProcessManager`(spawn/health/kill/重啟) | 主 app 可啟停 | 3 | A1 |
| A6 | `MLXClient` + 調度器接入(共用 §2.3) | 端到端可 rerank | 3 | A3,A5 |
| A7 | 分數校準 + 融合權重掃描(w 值) | dev 集報表 | 3 | A3,A6 |
| A8 | 記憶體/延遲優化(batch、KV 重用、cache) | p95 報表 | 3 | A6 |
| A9 | 錯誤/降級/退避完整化 | 故障注入測試 | 2 | A6 |
| A10 | 安全性(僅 loopback、請求大小上限、路徑驗證) | 安全檢查清單 | 1 | A1 |
| A11 | 打包(模型入 bundle、helper 簽名、公證) | 可安裝 app | 2 | A5 |
| A12 | 文件與 runbook | README/ troubleshooting | 1 | 全部 |
| **合計** | | | **31 人日** | |

### 4.7 驗收
- [ ] dev/test 集指標達 §1.2 門檻(MLX 路徑)。
- [ ] 冷啟動 ≤3s;暖機後 p95 ≤250ms。
- [ ] 拔掉 helper / 塞爆埠 / 回傳壞 JSON → 主 IME 不受影響,5 秒內降級。
- [ ] `lsof` 驗證僅 loopback;無任何外連。
- [ ] 連續輸入 30 分鐘,helper RSS 無持續成長(無洩漏)。

## 5. Track B:Apple Foundation Models

### 5.1 目標
以 macOS 26+ 的 on-device ~3B 模型做「生成式排序」:零模型下載、零 helper、系統管理記憶體;作為預設後端。

### 5.2 前置驗證(spike,必須先做)
| ID | 驗證問題 | 方法 | 決策影響 |
|---|---|---|---|
| B0-a | IMK 背景 app 能否呼叫 Foundation Models? | 最小 host app + SimulationHost | 若不行 → 只能走 MLX |
| B0-b | 繁體中文輸入法語境下的實際延遲? | 20 次暖機後量 TTFT/總時 | 決定 deadline 與候選數上限 |
| B0-c | guided generation 能否穩定只輸出索引陣列? | 50 次抽樣,檢查格式合規率 | 決定 parser 防禦等級 |
| B0-d | `availability` 的觸發條件與錯誤型別? | 關閉 Apple Intelligence / 非繁中環境 | 降級策略 |
| B0-e | 是否有 rate limit? 配額為何? | 連續 100 次請求 | 退避參數 |

> 這五項是整條 track 的 go/no-go 門檻;任何一項失敗,Apple 後端降級為「實驗性」,預設後端改回 MLX。

### 5.3 架構
```
Reranker/AppleFM/
├─ AppleFMReranker        ← 實作 RerankerBackend
├─ AvailabilityGate       ← SystemLanguageModel.availability + locale 檢查 + 快取
├─ PromptBuilder          ← 系統指令 + context + 編號候選;token 預算檢查
├─ ResponseParser         ← @Generable 輸出 → 索引陣列 → 驗證/去重/補齊
└─ Metrics               ← 每次請求記錄 tokens/latency/outcome
```

### 5.4 呼叫流程
1. `AvailabilityGate`:
   - `SystemLanguageModel.default.availability == .available`
   - 使用者 locale 支援繁中;若模型語言不支援 → 不啟用。
   - `contextSize` 與 `tokenCount(for:)` 動態檢查(避免硬編 4K)。
2. `PromptBuilder`:
   - 系統指令(中文,固定):「你是繁體中文輸入法選字器。根據上下文,將候選詞依適合程度排序。只輸出索引陣列,不要解釋。」
   - User:`上下文:{context}\n候選:0=好 1=棒 2=薄 …`
   - token 預算:≤ 256 tokens(含指令);超過 → 截斷 context 或減少候選數。
3. 生成:
   - `@Generable struct RankedIndices { var order: [Int] }`(或等價結構化輸出)。
   - greedy sampling(temperature 0);`maximumResponseTokens ≤ 16`。
   - deadline 400ms;超時 → 取消 session 並回 `timeout`。
4. `ResponseParser`:
   - 過濾非法索引、重複、越界;未列出的候選排在後面(按統計分數)。
   - `rank→score`:`score[i] = 1 - position/N`(單調,僅排序用)。
5. 套用:與 MLX 完全相同的 `ScoreRankedLanguageModel` 路徑。

### 5.5 Prompt 設計與變體(規劃)
| 變體 | 指令重點 | 用途 |
|---|---|---|
| P1 | 「依適合程度排序」 | baseline |
| P2 | 「只回傳最適合的前 3 名」 | 降低輸出長度 |
| P3 | 「考慮前後文語意與常見搭配」 | 提升品質 |
| P4 | few-shot 2 例(不超過 token 預算) | 穩定格式 |
- 每個變體跑 dev 集,記錄:格式合規率、延遲、CorrectionRate。
- 禁用「請解釋」類指令(輸出膨脹);禁止把使用者完整輸入歷史放入 prompt(隱私與 token 預算)。

### 5.6 錯誤與降級
| 錯誤 | 行為 |
|---|---|
| `unavailable`(Apple Intelligence 關閉) | 標記後端不可用;切 MLX(若啟用)或關閉 AI |
| `rateLimited` | 指數退避(1s→8s),badge 顯示;不重試同一請求 |
| `contextOverflow` | 減少候選數/截斷 context 後重試一次 |
| guardrail/refusal | 視為 `invalidResponse`,回統計分數,記錄 |
| OS 版本模型行為變更 | eval 回歸失敗 → 降級並回報 |

### 5.7 工作分解
| ID | 任務 | 產出 | 估時(人日) | 依賴 |
|---|---|---|---|---|
| B1 | Spike B0-a~e | 驗證報告 + go/no-go | 4 | — |
| B2 | `AvailabilityGate` + 設定頁狀態 | 可用性矩陣 | 1.5 | B1 |
| B3 | `PromptBuilder` + token 預算 | prompt 產生器 + 單元測試 | 2 | B1 |
| B4 | guided generation + `ResponseParser` | 格式合規率報表 | 3 | B1,B3 |
| B5 | `AppleFMReranker` 接入共用調度器 | 端到端可 rerank | 2 | B4 |
| B6 | 錯誤/退避/降級 | 故障注入測試 | 2 | B5 |
| B7 | Prompt 變體 A/B(P1–P4) | dev 集比較報表 | 2 | B5 |
| B8 | 延遲與 token 優化(候選上限、快取 session) | p95 報表 | 2 | B5 |
| B9 | eval 回歸流程整合(OS 升級) | runbook + 腳本 | 1.5 | B7 |
| B10 | 文件與使用者說明(隱私/需求) | README 段落 | 1 | B5 |
| **合計** | | | **21 人日** | |

### 5.8 驗收
- [ ] Spike 五項全部有結論;go/no-go 決定記錄在案。
- [ ] 繁中環境下 CorrectionRate 不低於 MLX baseline 的 -2%(品質不得明顯較差)。
- [ ] p95 ≤ 400ms;TTFT 可量測。
- [ ] 關閉 Apple Intelligence → 5 秒內降級,無 crash。
- [ ] 格式合規率 ≥ 99%(50 次抽樣)。
- [ ] 隱私:僅 on-device;無網路請求(Instruments/連線監控)。

## 6. 並行排程(建議 6 週)

| 週 | Track A(MLX) | Track B(Apple FM) | 共用 |
|---|---|---|---|
| W1 | A1 helper 骨架 | B1 spike 五項 | 共用介面 §2 + eval 骨架 §3 |
| W2 | A2 模型載入/暖機;A4 協定 | B2/B3 gate + prompt | 測試集 200 句整理(dev/test 切分) |
| W3 | A3 打分核心;A5 進程管理 | B4 guided generation/parser | 指標腳本 + baseline 量測(純統計) |
| W4 | A6 接入;A7 校準 | B5 接入;B6 錯誤處理 | A/B 調度器整合測試 |
| W5 | A8 優化;A9/A10 降級/安全 | B7 prompt A/B;B8 優化 | test 集第一次評測 |
| W6 | A11 打包;A12 文件 | B9/B10 回歸/文件 | 雙後端 A/B 報告;決策:預設後端 |

**里程碑**
- **G1(W1 末)**:共用介面 + eval 骨架可跑(以假後端驗證)。
- **G2(W3 末)**:兩後端各自能產生分數/排序,dev 集有首份報表。
- **G3(W5 末)**:整合進 IME,可實際打字使用;降級路徑演練通過。
- **G4(W6 末)**:test 集報告 + 預設後端決策 + 可發佈建置。

**資源假設**:1 名 Swift 工程師(兩線交替)+ 0.5 名 QA;若只有 1 人,兩線改為 A 先 B 後,總時程 8–9 週。

## 7. 依賴與整合點

| 整合點 | 提供方 | 需求方 | 時機 |
|---|---|---|---|
| `RerankerBackend` 協定凍結 | 共用 | A/B | W1 |
| `ScoreRankedLanguageModel` 可注入 override | 核心(M1) | A/B | W2 |
| `KeyHandler` 取得 context(前 16 字) | 核心(M2) | A/B | W2 |
| `InputState` 候選快照 | 核心(M1) | A/B | W2 |
| 設定頁 AI 區塊 | UI | A/B | W4 |
| 隱私文案與開關 | 產品 | A/B | W5 |

## 8. 測試計畫

### 8.1 單元
- 打分:固定輸入 → 固定分數(MLX);索引解析/越界/重複(Apple)。
- 正規化:rank→score 單調性、等長、NaN 防護。
- 調度器:generation 作廢、debounce、backoff、收斂、振盪。

### 8.2 整合(SimulationHost)
- 模擬打字 100 句 → 檢查候選排序與上屏結果。
- 後端切換(Apple↔MLX↔關閉)即時生效,無需重啟。
- helper crash / 埠被佔 / 模型檔缺失 → 降級。

### 8.3 效能
- 冷/熱啟動延遲分佈;連續輸入 10/30 分鐘記憶體;能耗取樣。
- 大量候選(20)與長 context(64 tokens)壓力測試。

### 8.4 隱私與安全
- 封包擷取:確認僅 Sparkle/lexicon/license 三條外連,無輸入內容。
- helper 請求大小上限(≤ 8KB)、JSON schema 驗證、拒絕非 loopback 綁定。
- Apple 路徑:確認無網路活動。

### 8.5 回歸
- OS 升級(macOS 26.x)後自動重跑 Apple 後端 test 集;指標下降 > 2% → 阻止發佈。

## 9. 風險登記簿

| # | 風險 | 機率 | 影響 | 緩解 |
|---|---|---|---|---|
| R1 | IMK app 無法呼叫 Foundation Models | 低 | 高 | B1 spike 最先做;失敗則 Apple 線終止,MLX 為預設 |
| R2 | Apple 模型繁中品質不如預期 | 中 | 高 | eval 把關;保留 MLX;必要時 Apple 只用於長句/低頻 |
| R3 | 生成式排序延遲 >400ms | 中 | 中 | 限制輸出 ≤3 名、候選 ≤12、greedy;必要時改 prompt P2 |
| R4 | 無 logprob 導致排序不穩 | 中 | 中 | 收斂/振盪機制;只覆蓋 top-K;A/B 驗證 |
| R5 | OS 更新模型行為漂移 | 中 | 中 | test 集回歸 gate;版本化 prompt;可切 MLX |
| R6 | MLX helper 記憶體/冷啟動 | 中 | 中 | 閒置退出、128MB cache、暖機、首次延遲提示 |
| R7 | 模型檔授權/打包體積 | 低 | 中 | Qwen Apache-2.0;模型可選下載;Apple 路線免模型 |
| R8 | 繁中 locale 判斷錯誤 | 低 | 低 | 以 `supportedLanguages` 動態檢查,不硬編 |
| R9 | 使用者關閉 Apple Intelligence | 高 | 低 | 設計即支援;badge 說明 + 一鍵切換 |

## 10. 交付物清單(Definition of Done)

- [ ] `Reranker/Shared/` 介面與正規化,含單元測試。
- [ ] Track A:helper、協定、進程管理、校準報表、打包腳本。
- [ ] Track B:spike 報告、gate/prompt/parser、錯誤處理、prompt A/B 報表。
- [ ] `Eval/` 200 句資料集(dev/test)、指標腳本、兩份 test 報告。
- [ ] 雙後端 A/B 總結與「預設後端」決策記錄。
- [ ] 使用者文件:AI 功能說明、隱私聲明、系統需求、疑難排解。
- [ ] 隱私/安全檢查清單全數通過。
- [ ] 可安裝的簽名建置(Apple Silicon;macOS 26 AI 啟用,macOS 15 核心可用)。

## 11. 明確排除(本規劃不做)

- 模型微調(fine-tuning)與自有模型訓練。
- 雲端推論、Private Cloud Compute、第三方 LLM provider。
- 英文預測的 LLM 化(維持 trie + 記憶)。
- 句子改寫、自動補全整句。
- Windows/Linux 版。

## 12. 待決問題(需在 G1 前拍板)

1. 預設後端策略:`auto`(Apple 優先)是否作為產品預設?或首次啟動詢問?
2. MLX 模型是否隨 app 內建(265MB)或改為選配下載?
3. eval 測試集的資料來源與授權(需可公開或僅內部)。
4. Apple 後端若品質未達標,是否仍保留「實驗性」開關?
5. 是否要把 prompt 版本號暴露給使用者(進階設定/除錯)?
