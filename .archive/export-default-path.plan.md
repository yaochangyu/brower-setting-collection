# Export Default Path Plan

## 目標

將 `chrome-settings-collector.ps1` 的預設匯出行為改成：當使用者加上 `-Export` 但**沒有**指定 `-OutputDirectory` 時，輸出目錄預設建立在**腳本所在目錄**，而不是目前工作目錄。

- [x] 確認目前預設輸出路徑邏輯，因為現在是用 `Get-Location` 決定目錄，必須先明確定位修改點，避免影響其他參數行為。
- [x] 修改腳本預設輸出路徑，因為需求是「不加參數時，預設輸出的路徑就是跟著腳本相同」，所以要改成以腳本實際所在路徑為基準。
- [x] 更新 `README.md` 使用說明，因為文件目前仍描述為建立時間戳記資料夾，但沒有明確說明它應該跟腳本同目錄。
- [x] 驗證匯出結果，因為要確認 `-Export` 在未指定 `-OutputDirectory` 時，真的會輸出到腳本同目錄，而且既有指定路徑行為不受影響。

## 預期行為

- `.\chrome-settings-collector.ps1 -Export`
  - 預設輸出到 `D:\check_chrome\chrome-settings-export-YYYYMMDD-HHMMSS`
- `.\chrome-settings-collector.ps1 -Export -OutputDirectory D:\check_chrome\export`
  - 仍輸出到使用者指定目錄

## 注意事項

- 只調整預設匯出目錄邏輯，不改其他參數語意
- 已依使用者「全自動」指示完成程式、文件修改與驗證
