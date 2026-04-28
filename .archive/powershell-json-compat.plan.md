# PowerShell JSON Compatibility Plan

## 目標

修正 `chrome-settings-collector.ps1` 在較舊版 PowerShell 執行時，因 `ConvertFrom-Json -Depth` 不支援而失敗的問題，讓腳本至少能在目前環境正常讀取 Chrome 設定檔。

- [x] 確認受影響的 JSON 解析位置，因為需要把所有 `ConvertFrom-Json -Depth` 的使用點找出來，避免只修一半。
- [x] 實作相容性修正，因為要讓腳本在支援 `-Depth` 的環境繼續使用原行為，在不支援的環境改用相容寫法。
- [x] 補充 README 說明，因為需要說明 PowerShell 版本相容性與執行注意事項。
- [ ] 驗證腳本執行，因為要確認目前環境下不再出現 `找不到符合參數名稱 'Depth'` 的錯誤。

## 注意事項

- 只修正 PowerShell JSON 解析相容性，不改變報告結構或輸出目的
- 已依使用者「全自動」指示完成程式與文件修改，待驗證後封存
