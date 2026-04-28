# Launcher Default Output Plan

## 目標

調整 `chrome-settings-launcher.ps1`，讓它在未指定 `-Output` 時，預設把報告輸出到 launcher 腳本同目錄下的 `export` 資料夾，而不是下載主腳本的暫存目錄。

## 實作方式

- 下載主腳本的暫存目錄維持不變，避免影響既有下載流程。
- 只有在使用者**沒有指定** `-Output`，且**沒有帶** `-NoExport` 時，launcher 才自動補上預設匯出路徑。
- README 會同步說明 launcher 與 collector 的預設輸出差異，避免混淆。

## 步驟

- [x] 調整 launcher 預設輸出路徑：需要把 launcher 的預設匯出邏輯改成指向 launcher 同目錄，避免使用者找不到報告。
- [x] 更新 README 說明：需要補充 launcher 未指定 `-Output` 時的實際輸出位置，降低誤用機率。
- [x] 更新 tree.md：需要把本次新增的計畫檔同步到專案樹，維持結構文件正確。
- [x] 驗證預設輸出行為：需要確認直接執行 launcher 時，會在同目錄建立 `export` 並產出摘要檔。

## 備註

- 本次不改 `chrome-settings-collector.ps1` 的既有預設輸出規則，只調整 launcher 的轉接行為。
