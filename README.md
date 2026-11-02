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

不要使用上游的安裝程式安裝此開發版：它會操作小麥注音的安裝路徑。目前已在開發機安裝隔離測試版，系統啟用及基本注音輸入已確認，跨 App 流程仍待驗證。新機首次安裝可執行 `./scripts/install.sh`；它只會建立新的 `ZhuyinLM.app`，不覆蓋既有檔案。安裝後可用 `swift scripts/check_registration.swift` 檢查註冊狀態。

## 文件

- [目前進度與接手順序](PROGRESS.md)
- [開發狀態與驗收](docs/STAGE-0-1.md)
- [原始設計文件](DESIGN.md)與 [AI 後端規劃](PLAN-reranker-backends.md)：歷史設計草案，與目前實作不一致之處以開發狀態文件為準；AI 尚未實作。
- [英文詞庫來源說明](data/DATA-NOTES.md)

## 上游與授權

輸入法基礎來自 [McBopomofo](https://github.com/openvanilla/McBopomofo)，固定於 `257da536ddaf590aae0e74e6adb9b415988344f6`，採 MIT 授權。完整上游版權及授權見 `vendor/McBopomofo/LICENSE.txt`；其第三方資料與依賴另有各自授權，見上游 `ACKNOWLEDGEMENTS.md` 及相關檔案。原設計文件所稱上游為 Apache-2.0 有誤。

本 repo 自有內容尚未指定開源授權；這不改變上游及其他第三方內容既有的授權。
