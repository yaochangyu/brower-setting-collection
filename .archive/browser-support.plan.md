# Browser Support Plan

## 目標

讓 `chrome-settings-collector.ps1` 與 `chrome-settings-launcher.ps1` 支援 `-Browser Chrome|Edge`，未指定時預設使用 `Chrome`。

## 實作方式

- 在 collector 新增 `-Browser`，依瀏覽器切換預設 `User Data` 路徑與報告文字。
- 在 launcher 新增 `-Browser`，將參數原樣轉交給 collector。
- 更新 README，補上 Chrome / Edge 的使用方式與預設行為。

## 步驟

- [x] 調整 collector 的 `-Browser` 支援：需要依 `Chrome` 或 `Edge` 切換預設 `User Data` 路徑、報告標題與相關文案，並保留未帶參數時預設為 `Chrome`。
- [x] 調整 launcher 的 `-Browser` 支援：需要讓 launcher 接受 `-Browser` 並轉傳給 collector，讓兩支腳本的介面一致。
- [x] 更新 README 說明：需要補上 `-Browser` 參數、Chrome / Edge 範例與預設值說明，避免文件與行為不一致。
- [x] 更新 tree.md：需要把本次新增的計畫檔同步到 tree.md，維持專案結構文件正確。
- [x] 驗證 Chrome / Edge 參數流程：需要確認預設 `Chrome` 仍可執行，並驗證 `-Browser Edge` 會改用 Edge 的 `User Data` 路徑。

## 備註

- 本次不重新命名檔案，仍沿用現有 `chrome-settings-collector.ps1` 與 `chrome-settings-launcher.ps1`。
