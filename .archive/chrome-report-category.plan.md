# Chrome Report Category Plan

## 目標

將 `chrome-settings-collector.ps1` 的報告輸出改成盡量貼近 `chrome://` 頁面分類；若資料無法直接對應到某個 `chrome://` 頁面，再使用其他明確名稱分類。

- [x] 盤點現有輸出與 `chrome://` 頁面對應，因為需要先確認目前已收集的資料可以對應到哪些頁面，避免硬分類造成誤導。
- [x] 重整報告章節結構，因為 `summary.txt` 與 `summary.json` 都要優先使用 `chrome://settings/content/siteData`、`chrome://policy`、`chrome://extensions`、`chrome://prefs-internals`、`chrome://version`、`chrome://system` 這類章節名稱。
- [x] 定義非 `chrome://` 頁面分類，因為有些資料是收集註記或 Profile 補充資訊，應使用清楚的替代名稱而不是硬套到 `chrome://`。
- [x] 驗證新分類輸出，因為需要確認改版後主控台、`summary.txt`、`summary.json` 都採用新分類，且資料沒有遺漏。

## 分類原則

- 能直接對應 `chrome://` 頁面的內容，優先放到對應章節
- 無法直接對應的資料，改用例如 `Profile Metadata`、`Collection Notes` 之類名稱
- 只調整輸出結構與命名，不改變既有收集邏輯的本質

## 注意事項

- `chrome://settings/content/siteData` 與 `chrome://system` 目前未完整收集，若沒有對應資料，章節需明確標示為未收集或部分收集
- 已依使用者「全自動」指示完成實作與驗證
