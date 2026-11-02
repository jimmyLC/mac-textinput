# 中文詞典(自建版)

本目錄的中文資料為 **ZhuyinLM-IME 自建詞典**:直接取用
[McBopomofo](https://github.com/openvanilla/McBopomofo) 官方發布內附的開放語料,
在本機重新解析、聚合與排序,取代先前取自商業 app 安裝包的衍生版本。

建置腳本:[`tools/build_chinese_dict.py`](../tools/build_chinese_dict.py)

---

## 1. 產出檔案

| 檔案 | 內容 | 格式 | 規模 |
|---|---|---|---|
| `chinese-common-10000.txt` | 前 10,000 個常用字詞 | 一行一詞,依聚合分數降序 | 10,000 詞 |
| `chinese-common-10000.tsv` | 同順序,含分數與讀音 | `詞<TAB>聚合分數<TAB>讀音(以 \| 分隔)` | 10,000 詞 |
| `chinese-lexicon.tsv` | **全量詞庫**(引擎用) | `詞<TAB>聚合分數<TAB>讀音` | 160,792 詞 |
| `chinese-associated-phrases.tsv` | 聯想詞(M2 聯想詞功能用) | `詞<TAB>讀音<TAB>分數` | 94,784 筆 |
| `chinese-manifest.json` | 來源、SHA-256、統計 | JSON | — |

分數為 **log10 機率**(越接近 0 越常見),與上游 `data.txt` 同義,可直接餵給
Gramambular 的 LM 介面。

---

## 2. 來源與授權

| 來源 | 角色 | 授權 | 是否隨 repo 散布 |
|---|---|---|---|
| McBopomofo 3.1.1 官方發布內的 `Resources/data.txt` | 詞庫母體(reading / word / score) | **MIT** | 否(僅本機快取) |
| McBopomofo 3.1.1 官方發布內的 `Resources/associated-phrases-v2.txt` | 聯想詞母體 | **MIT** | 否(僅本機快取) |

- 母體檔案下載於
  `https://github.com/openvanilla/McBopomofo/releases/download/3.1.1/McBopomofo-Installer-3.1.1.zip`
  (巢狀 zip,內含 `McBopomofo.app/Contents/Resources/`),SHA-256 記於 `chinese-manifest.json`。
- 母體僅存在於本機 `data/sources/cache/`(不入版控);本 repo 只散布**衍生**的統計檔。
- 註:McBopomofo 的授權為 **MIT**(見其 `LICENSE.txt`),非 Apache-2.0;`DESIGN.md` §2 已更正。

---

## 3. 處理方法

```
1. 解析 data.txt:欄位為 `reading word score`
2. 略過:註解行、reading/word 以 `_` 開頭的控制項、非漢字詞
3. 同一詞的多個讀音以 log-sum-exp(底 10)聚合
       score = max + log10( Σ 10^(s_i - max) )
4. 依聚合分數降序輸出;同分以詞的字典序
```

輸出前自我檢查:詞不重複、分數嚴格遞減、排序與分數一致。

---

## 4. 統計

| 指標 | 值 |
|---|---|
| 上游 `data.txt` 總行數 | 175,802 |
| 略過控制項 / 非漢字 | 4,870 |
| 唯一漢字詞 | **160,792** |
| 多讀音詞 | 8,615 |
| 第 10,000 名門檻 | `娛` = **-4.881877** |
| 前 10,000 名覆蓋詞機率質量 | **82.1%** |
| 聯想詞筆數 | 94,784 |

---

## 5. 與舊資料的差異

| 項目 | 舊版 | 新版 |
|---|---|---|
| 母體 | 商業 app 安裝包內的 `data.txt` | **McBopomofo 官方發布(MIT)** |
| 授權 | 未取得散布授權 | MIT,可自由散布 |
| 詞數 | 154,020 | 160,792 |
| 語料偏重 | 新聞/書面語(可見「本報訊」「觀光局」「文化局」) | **字幕口語**(可見「一不小心」「一不做二不休」「高手」) |
| 與新表重疊 | 82.2%(8,223 / 10,000) | — |

> 舊檔(`data/chinese-common-10000.*`)已自版控移除,仍可自 git 歷史取回
> (`git show cd40e41:data/chinese-common-10000.txt`)。

---

## 6. 已知限制

- **語料偏口語**:上游 `phrase.occ` 來自影視字幕,故「我們」「什麼」等高頻口語詞排前,
  正式書面語詞相對靠後;若要公文/新聞取向需另建語料。
- **單字與長詞的比例**由上游決定:單字、二字詞為主,長詞稀少。
- **未含繁簡對應**:簡繁轉換仍依賴 OpenCC(見 `DESIGN.md` §6)。
- **詞頻分數不可跨版本比較**:上游更新詞庫後分數會變,需重build並重新檢視門檻。

---

## 7. 重build

```bash
python3 tools/build_chinese_dict.py            # 下載上游並重建輸出
python3 tools/build_chinese_dict.py --offline  # 只用本機 cache
python3 tools/build_chinese_dict.py --check    # 比對既有輸出,不一致則 exit 1(CI 用)
```

---

## 8. 後續工作

- [ ] 引擎端整合:`chinese-lexicon.tsv` 轉成 Gramambular 可用的 LM 詞庫(需處理多讀音展開)。
- [ ] 依 `DESIGN.md` §5.1 的 selection boost 機制,讓使用者選字回寫既有詞庫分數。
- [ ] 聯想詞表接上 `Shift+Enter` 聯想功能(M2)。
- [ ] 評估是否改用上游 `data-plain-bpmf.txt`(純注音)作為另一套讀音來源。
