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
- 自動中英文混打（`Sources/BilingualInput/`，路由邏輯有自動測試，**輸入法內行為尚未實機驗證**）：
  - 中文照常組字；組字中游標旁同時提示英文（如 `date ⇥`），按 Tab 保留已打的中文並上屏英文。
  - 全小寫字母湊成常見英文詞（3 字母以上，或 2 字母但前一段是英文／不是注音）時，自動轉為英文直接輸出到空白；`up`＝因 這類 2 字母詞預設仍是中文。
  - 大寫字母開頭、`http:` 等網址前綴 → 英文直到空白。
  - 小麥注音的已轉換中文會一直留在底線組字區到按 Enter，英文上屏時一律先 `handleForceCommit` 保留它（早期版本用 `clear()` 會丟中文，已修）。
  - 切換：Caps Lock 開＝英文模式；閒置時單按 Shift 切換英文模式；組字中有待決字母時單按 Shift 強制那段為英文。
  - 設定視窗固定顯示繁體中文（只影響此 App，不改系統語言）。
- 仍沒有：已上屏後的事後更正、更完整的候選 UI。
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
