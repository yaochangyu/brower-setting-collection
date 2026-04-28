# export-flag-simplify Plan

## 目標

把目前幾乎沒有實際作用的 `-Export` 調整成更合理的介面，改為預設匯出、需要時用 `-NoExport` 關閉。

## 實作步驟

- [x] 步驟 1：盤點 `-Export` 在腳本與 README 的實際使用位置，確認改名影響範圍。
  - 為什麼需要：先找出參數定義、匯出條件與文件描述，避免只改一半造成行為和說明不一致。

- [x] 步驟 2：把腳本參數改成 `-NoExport`，並調整匯出邏輯。
  - 為什麼需要：目前預設已經自動匯出，保留 `-Export` 沒有額外價值；改成 `-NoExport` 才能讓參數真正控制行為。

- [x] 步驟 3：更新 README 與使用範例。
  - 為什麼需要：快速開始、參數表與匯出範例都要跟著改，不然使用者會照舊文件輸入不存在或多餘的參數。

- [x] 步驟 4：執行腳本驗證預設匯出與 `-NoExport` 行為。
  - 為什麼需要：這次變更直接影響主要使用方式，要確認預設仍可匯出，且 `-NoExport` 真的不會寫檔。

- [x] 步驟 5：更新 `tree.md` 並封存計畫檔。
  - 為什麼需要：依專案規則，新增與封存計畫檔都要同步反映在目錄結構文件。

## 預期調整

- `chrome-settings-collector.ps1`
  - `-Export` 改為 `-NoExport`
  - 匯出條件改成「未指定 `-NoExport` 就匯出」

- `README.md`
  - 移除 `-Export` 範例
  - 補上 `-NoExport` 用法

- `tree.md`
  - 新增本計畫檔

## 步驟 1 結果

- 腳本需調整的點：
  - `param()` 裡的 `[switch]$Export = $true`
  - `if ($Export) { ... }` 的匯出條件
  - `Collection Notes` 裡的 `Use -Export ...` 說明

- README 需調整的點：
  - 快速開始中的 `-Export` 範例
  - `-Output` / `-IncludeRawFiles` 範例中的 `-Export`
  - 參數表的 `-Export` 說明
  - `匯出內容` 區塊中的 `使用 -Export 時`

## 步驟 2 結果

- 腳本參數已由 `-Export` 改為 `-NoExport`
- 目前邏輯改為：**預設匯出**，只有指定 `-NoExport` 才不寫檔
- `Collection Notes` 已同步改成目前真實行為

## 步驟 3 結果

- README 已移除 `-Export` 範例
- README 已補上 `-NoExport` 用法
- `-Output` / `-IncludeRawFiles` 範例已改成不依賴 `-Export`

## 步驟 4 結果

- 已驗證預設情況下仍會輸出 `summary.json` 與 `summary.txt`
- 已驗證指定 `-NoExport` 時不會建立輸出資料夾
- 第一次驗證預設匯出時，`Test-Path` 指令寫法重複帶入 `-LiteralPath`，造成驗證判斷失敗；後續已改用分開變數檢查並重跑成功

## 步驟 5 結果

- 已封存本計畫檔到 `.archive`
- `tree.md` 已同步反映封存後的位置
