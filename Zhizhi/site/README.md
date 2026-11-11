# 知之官網

純靜態頁加一個 Cloudflare Worker，網址 `https://zhizhi.jimmy-tools.com`。公開內容只有 `public/`。

- 不寫開源字樣、不放 GitHub 連結、不放聯絡信箱；`npm run check` 會擋。
- 下載：`worker.js` 只提供 `releases.json` 列出的檔案，從 R2 bucket `zhizhi-releases`（binding `RELEASES`）讀取。`releases.json` 是 `{}` 時，頁面按鈕顯示「即將開放」。

## 部署

```sh
cd Zhizhi/site
npm install
npm run deploy
```

需在最新 `main` 上部署。Cloudflare 帳號固定在 `wrangler.toml` 的 `account_id`（Jimmy 的帳號）。

## 發布新版本

1. 打包 `知之.app`（`Zhizhi/scripts/build-app.sh`）成 `Zhizhi-macos.dmg`，算 sha256 與大小。
2. 第一次：`npx wrangler r2 bucket create zhizhi-releases`，並取消 `wrangler.toml` 裡 `r2_buckets` 的註解。
3. `npx wrangler r2 object put zhizhi-releases/vX.Y.Z/Zhizhi-macos.dmg --file Zhizhi-macos.dmg --remote`
4. 在 `releases.json` 加：`"vX.Y.Z": { "Zhizhi-macos.dmg": { "name": "Zhizhi-macos.dmg", "bytes": 123, "sha256": "…" } }`（最後一個版本即最新版）。
5. `npm run deploy`，再到正式網址確認按鈕與下載。
