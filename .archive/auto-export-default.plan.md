# Auto Export Default Plan

## 目標

將 `chrome-settings-collector.ps1` 改成**不帶任何參數執行時，也會自動把結果寫到本地資料夾**，而不是只輸出到主控台。

- [x] 確認目前主控台輸出與匯出流程切點，因為要把「純顯示」改成「預設也寫檔」，需要先找出 `-Export` 目前控制的邏輯位置。
- [x] 修改腳本預設行為，因為你的需求是不帶參數就自動輸出到腳本同目錄，所以要把匯出改成預設開啟，並保留可指定 `-OutputDirectory` 與 `-IncludeRawFiles` 的能力。
- [x] 更新 `README.md` 說明，因為目前文件仍寫成不帶參數只顯示主控台，這要同步改掉。
- [x] 驗證腳本行為，因為要確認 `.\chrome-settings-collector.ps1` 直接執行後，會在腳本同目錄建立匯出資料夾。

## 預期行為

- `.\chrome-settings-collector.ps1`
  - 顯示主控台內容
  - 同時輸出到 `D:\check_chrome\chrome-settings-export-YYYYMMDD-HHMMSS`

- `.\chrome-settings-collector.ps1 -OutputDirectory D:\check_chrome\export`
  - 顯示主控台內容
  - 同時輸出到指定目錄

## 注意事項

- 只調整預設匯出行為，不改變報告內容
- 已依使用者「全自動」指示完成程式、文件修改與驗證
