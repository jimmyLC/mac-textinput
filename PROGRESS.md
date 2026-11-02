# 開發進度與交接

更新日期：2026-11-02（新加坡時間）

## 目前狀態

專案從設計階段進入開發測試，基於固定版本的 McBopomofo 建立隔離的 ZhuyinLM。**M1 尚未完成驗收；自動中英文混打尚未接入。** 使用者希望直接自動判斷中英文，體驗類似晶晶輸入法。

### 已完成與已驗證

- 上游固定在 `257da536ddaf590aae0e74e6adb9b415988344f6`，以 Git submodule 引入。上游主授權是 MIT，原設計文件的 Apache-2.0 說法有誤；第三方素材另依其授權。
- `scripts/build.sh` 可產生獨立 bundle ID、IMK connection、預設詞庫目錄的 ad-hoc 簽名開發版。建置於 Xcode 27.2、Apple Silicon、macOS 27.0；macOS 15 執行相容性未驗證。
- 測試版已安裝於本機使用者輸入法目錄。重新登入並在系統設定加入後，系統可啟用及選取。使用者以實體鍵盤確認 `su3cl3` + Enter 可上屏「你好」，空白鍵可顯示候選字並用數字鍵選字。
- `./scripts/test.sh` 排除上游需網路的更新 API 測試後，130 個 XCTest 與 86 個 Swift Testing 測試通過。`scripts/check_build.py` 驗證輸入來源身分、更新端點及詞庫路徑等；`scripts/install.sh` 的首次安裝與拒絕覆蓋行為以暫存目錄測試。
- 來源不明的商用 App 英文詞表已自目前檔案移除，但仍存在既有 Git 歷史中；授權與可能的歷史處理仍待釐清。

### 未完成

- M1：TextEdit 以外的 App、瀏覽器、跨視窗/焦點切換、未上屏組字、切換輸入法、其他鍵位及重新啟用的實機驗收。實際輸入測試工具對既有 ZingIME 也送出字母，無法據此判斷 IME 是否正確；需要可靠的真實按鍵測試途徑或使用者協助。
- 自動中英文混打：`Sources/BilingualPrototype/` 已有離線分析器（標準鍵位注音解析、以自建詞庫分段判斷、原始按鍵保留），可用真實詞庫跑測試（見 `docs/BILINGUAL-SPIKE.md`）；分析器已編進開發版並開始控制輸出（`Sources/BilingualInput/`，**尚未實機驗證**）：空白時整段判為英文 → 以原文上屏；`注音含聲調+英文詞`（如 su3cl3hello）→ 注音轉中文後接英文；大寫字母開頭 → 先上屏組字再直接輸出英文直到空白；`http:` 等網址前綴 → 英文直到空白。每次只用原始按鍵緩衝，不記錄打字內容。另有英文補全提示（組字中全小寫字母 ≥3 且像英文時，游標旁以提示框顯示最常見的較長單字，按 Tab 上屏），同樣未實機驗證。組字中單按 Shift（按下放開、中間沒按其他鍵）可翻轉本段的中/英判斷，提示框顯示「English」或「中文」，按空白時照翻轉後的結果處理（同樣未實機驗證）。仍沒有：邊打邊以英文顯示組字區、已上屏後的事後更正、候選 UI。已安裝後的更新與還原見 `scripts/update.sh`（只在暫存目錄測試過，尚未對真實安裝執行）、未決時的使用者確認流程，也不是可用的產品功能。`tests/fixtures/bilingual-cases.json` 是期望案例，尚未端到端通過。
- 英文詞庫來源與散布權利未定；AI reranker 尚未實作。舊設計文件含相互矛盾及未驗證內容，不可當成實作事實。
- 已建置名稱較清楚的測試版，但目前本機已安裝版本仍顯示 `Bopomofo`；更新安裝流程尚未實作，勿覆蓋現有安裝。

## 接手順序

1. 依 `docs/STAGE-0-1.md` 完成 M1 剩餘實機測試，記錄環境與觀察；保持既有輸入法可用並還原測試時的切換。
2. 依 `docs/BILINGUAL-SPIKE.md` 釐清英文與注音鍵序重疊時的行為，建立可重播測試與可散布的詞庫，再將原型整合進輸入法；必須處理未完成組字、退格、取消、焦點切換及不丟字。
3. 依使用者優先順序處理後續功能。發布、簽名公證及更新機制仍需另行規劃與測試。

## 指令

```sh
git submodule update --init --recursive
./scripts/build.sh
./scripts/test.sh
swiftc Sources/BilingualPrototype/*.swift tests/bilingual_resolver.swift -o /tmp/zhuyin-bilingual-tests
/tmp/zhuyin-bilingual-tests
```

`docs/STAGE-0-1.md` 有驗收案例和系統註冊的診斷紀錄；`README.md` 有安裝限制。請依實際環境重新驗證當前狀態。
