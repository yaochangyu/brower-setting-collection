# localstorage-risk-origin-check Plan

## 目標

在既有 `chrome-settings-collector.ps1` 上新增兩項能力：

1. localStorage / site data 風險判讀摘要
2. 指定網站 origin 的站台資料檢查

## 實作步驟

- [x] 步驟 1：盤點現有報告結構與可重用欄位，定義風險判讀規則。
  - 為什麼需要：先確認目前 `summary.json` 已有哪些欄位可直接引用，避免重複取資料，也避免新增判讀時和既有 `chrome://...` 分類衝突。

- [x] 步驟 2：在腳本加入 localStorage / site data 風險判讀邏輯，輸出統一的風險摘要。
  - 為什麼需要：把目前人工判讀的線索，例如 `clearBrowsingDataSelection`、policy、cookie 控制模式，整理成可重複執行的規則結果，讓報告能直接指出高 / 中 / 低風險與依據。

- [x] 步驟 3：在腳本加入指定 origin 的站台資料檢查功能。
  - 為什麼需要：只看全域設定還不夠，還要能針對某個網站確認對應 origin 是否存在、是否可能受第三方 cookie 或站台資料設定影響，才能更接近 localStorage 消失的實際原因。

- [x] 步驟 4：把新結果接到 `summary.txt`、`summary.json` 與 README。
  - 為什麼需要：新功能不只要算出結果，還要能在文字版與 JSON 版報告都看得到，同時補上參數與使用方式，避免功能做完但不易使用。

- [x] 步驟 5：執行腳本驗證輸出，確認 `tree.md` 與計畫狀態同步更新。
  - 為什麼需要：這次會改動腳本與文件，需要確認輸出格式、欄位命名與使用流程都一致，並依專案規則同步維護目錄結構與計畫勾選狀態。

## 預計新增/調整

- 腳本新增站台風險判讀區塊
- 腳本新增 origin 輸入參數與檢查結果
- `summary.txt` / `summary.json` 增加新章節
- `README.md` 補充新參數與範例
- `tree.md` 更新新計畫檔

## 暫定輸入方式

建議先以「完整 origin」作為站台檢查輸入，例如：

- `https://example.com`
- `https://app.example.com:8443`

這樣可以避免只輸入網域時，遇到 `http/https`、port、subdomain 不同而誤判。

## 步驟 1 結果

### 可直接重用的欄位

- `chrome://policy.enterprisePolicyKeyCount`
- `chrome://prefs-internals.exitType`
- `chrome://prefs-internals.exitedCleanly`
- `chrome://prefs-internals.cookieControlsMode`
- `chrome://prefs-internals.cookieControlsModeRaw`
- `chrome://prefs-internals.blockThirdPartyCookies`
- `chrome://settings/content/siteData.clearBrowsingDataSelection`
- `chrome://settings/content/siteData.siteSettingExceptionCounts`
- `Collection Notes`

### 風險判讀規則草案

- `high`
  - 有 enterprise policy keys
  - 後續若在站台檢查中發現指定 origin 對應資料不存在，且同時有明確清除/限制線索，則提升為 high

- `medium`
  - `clearBrowsingDataSelection.cookies = true`
  - `clearBrowsingDataSelection.siteSettings = true`
  - `clearBrowsingDataSelection.hostedAppsData = true`
  - `cookieControlsModeRaw = 2`
  - `blockThirdPartyCookies = true`
  - `exitType != Normal`
  - `exitedCleanly = false`

- `low`
  - 未命中上述 high / medium 條件

### 指定 origin 檢查輸出草案

- 輸入：完整 origin，例如 `https://example.com`
- 輸出至少包含：
  - `origin`
  - `profileDirectory`
  - `matchedExceptions`
  - `localStorageEvidence`
  - `indexedDbEvidence`
  - `sessionStorageEvidence`
  - `riskImpact`
  - `notes`

## 步驟 2 結果

- 已新增 `Local Storage Risk Assessment` 章節
- 目前會依 enterprise policy、clear browsing data 選項、third-party cookie 設定、profile 關閉狀態做 heuristic 判讀
- 目前驗證結果：現有環境判定為 `medium`

## 步驟 3 結果

- 已新增 `-Origin` 參數，接受完整 origin，例如 `https://example.com`
- 已新增 `Origin Site Data Checks` 章節
- 目前會檢查：
  - content setting exceptions 是否命中指定 origin
  - IndexedDB 目錄名稱是否命中指定 origin
  - Local Storage / Session Storage LevelDB 檔案是否有 heuristic token evidence
- 目前驗證結果：`https://recruit.1111.com.tw` 可找到 IndexedDB 與 Local Storage 線索

## 步驟 4 結果

- `summary.txt` / `summary.json` 已接上新章節
- `README.md` 已補上 `-Origin` 用法、輸出說明與限制

## 步驟 5 結果

- 已驗證：
  - 不帶 `-Origin` 時，報告會顯示 `Origin Site Data Checks = not-requested`
  - 帶 `-Origin https://recruit.1111.com.tw` 時，報告會輸出對應站台證據
- 已同步封存本計畫檔並更新 `tree.md`
