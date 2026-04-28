# README Launcher Output Plan

## 目標

調整 `README.md`，讓 `chrome-settings-launcher.ps1` 的使用方式、預設輸出位置與範例路徑說明一致，避免使用者執行後找不到報告。

## 實作方式

- 補強 launcher 的快速開始說明，明確寫出未指定 `-Output` 時會輸出到 launcher 同目錄下的 `export`。
- 視需要調整範例路徑，避免 `D:\check_chrome` 與目前 repo 目錄混用造成誤解。
- 只更新文件，不變更腳本行為。

## 步驟

- [x] 調整 README 的 launcher 說明：需要把預設輸出位置與使用方式寫清楚，避免使用者誤解。
- [ ] 校正 README 範例路徑：需要檢查與 launcher 相關的範例路徑是否一致，避免文件與實際使用場景不符。
- [ ] 更新 tree.md：需要把本次新增的計畫檔同步到專案樹，維持結構文件正確。

## 備註

- 本次僅修改 `README.md` 與 `tree.md`。
