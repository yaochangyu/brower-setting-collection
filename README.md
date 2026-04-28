# Chrome Settings Collector

這個資料夾提供一支 PowerShell 腳本 `chrome-settings-collector.ps1`，用來收集本機 Chrome 設定、Profile 摘要與外掛資訊，並輸出成接近 `chrome://` 分類的報告。

## 適用環境

- Windows
- PowerShell 5.1+ 或 PowerShell 7+
- 已安裝 Google Chrome

腳本會自動判斷目前 PowerShell 的 `ConvertFrom-Json` 是否支援 `-Depth`。若目前是較舊版 Windows PowerShell，會優先改用已安裝的 `pwsh.exe` 做 JSON fallback 解析，因此可同時相容 PowerShell 5.1 與 PowerShell 7。

預設會讀取：

- `C:\Users\<使用者>\AppData\Local\Google\Chrome\User Data\Local State`
- `C:\Users\<使用者>\AppData\Local\Google\Chrome\User Data\<Profile>\Preferences`
- `C:\Users\<使用者>\AppData\Local\Google\Chrome\User Data\<Profile>\Secure Preferences`
- `C:\Users\<使用者>\AppData\Local\Google\Chrome\User Data\<Profile>\Extensions`

## 快速開始

在 `D:\check_chrome` 執行：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-collector.ps1
```

上面這個指令除了顯示主控台內容，也會**預設匯出**到腳本同目錄下的時間戳記資料夾。若未指定 `-Browser`，預設使用 `Chrome`。

若要處理 Edge，可指定：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-collector.ps1 -Browser Edge
```

如果你只想看主控台結果，不要寫出檔案，可以帶 `-NoExport`：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-collector.ps1 -NoExport
```

只看特定 Profile：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-collector.ps1 -Profiles Default
```

檢查指定網站 origin 的站台資料證據：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-collector.ps1 -Origin https://recruit.1111.com.tw
```

匯出摘要到指定目錄：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-collector.ps1 -Output D:\check_chrome\export
```

匯出摘要與原始設定檔：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-collector.ps1 -IncludeRawFiles -Output D:\check_chrome\export-raw
```

如果你不想先手動下載主腳本，也可以先準備啟動腳本 `chrome-settings-launcher.ps1`，讓它自動從 GitHub 下載 `chrome-settings-collector.ps1` 再執行：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-launcher.ps1
```

若未指定 `-Output`，啟動腳本會預設把報告寫到 **`chrome-settings-launcher.ps1` 同目錄下的 `export` 資料夾**，例如：

```text
D:\check_chrome\export
```

也就是說，`chrome-settings-launcher.ps1` 下載主腳本時雖然會暫存在 `%TEMP%\chrome-settings-collector`，但**報告不會預設寫到 TEMP**，而是寫回 launcher 所在目錄。

若未指定 `-Browser`，啟動腳本也會預設使用 `Chrome`。若要處理 Edge，可指定：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-launcher.ps1 -Browser Edge
```

啟動腳本預設接受這個 GitHub 頁面網址：

```text
https://github.com/yaochangyu/brower-setting-collection/blob/master/chrome-settings-collector.ps1
```

它會自動轉成 raw 下載網址後再下載執行，所以不需要手動改成 `raw.githubusercontent.com`。

若要透傳參數給主腳本，也可以直接帶在啟動腳本後面：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-launcher.ps1 -Profiles Default
```

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-launcher.ps1 -Origin https://recruit.1111.com.tw -NoExport
```

若你想自訂報告位置，仍然可以明確指定 `-Output`：

```powershell
powershell -ExecutionPolicy Bypass -File D:\check_chrome\chrome-settings-launcher.ps1 -Output D:\check_chrome\custom-export
```

## 參數說明

| 參數 | 說明 |
| --- | --- |
| `-ScriptUrl` | 只適用於 `chrome-settings-launcher.ps1`；指定 GitHub blob URL 或 raw URL，未指定時預設下載本 repo 的 `chrome-settings-collector.ps1` |
| `-DownloadDirectory` | 只適用於 `chrome-settings-launcher.ps1`；指定下載暫存目錄，未指定時使用 `%TEMP%\chrome-settings-collector` |
| `-Browser` | 適用於 `chrome-settings-collector.ps1` 與 `chrome-settings-launcher.ps1`；可選 `Chrome` 或 `Edge`，未指定時預設為 `Chrome` |
| `-UserDataPath` | 指定瀏覽器 `User Data` 目錄；未指定時會依 `-Browser` 自動帶入，`Chrome` 為 `%LOCALAPPDATA%\Google\Chrome\User Data`，`Edge` 為 `%LOCALAPPDATA%\Microsoft\Edge\User Data` |
| `-Profiles` | 只收集指定的 Profile，可傳一個或多個名稱，例如 `Default`、`Profile 1` |
| `-Origin` | 指定一個或多個完整 origin（例如 `https://example.com`），額外檢查該站台的 Local Storage / IndexedDB / Session Storage 證據 |
| `-NoExport` | 不寫出 `summary.txt` / `summary.json`；只顯示主控台結果 |
| `-Output` | 指定匯出目錄；對 `chrome-settings-launcher.ps1` 而言，未指定時會輸出到 launcher 同目錄下的 `export`；對 `chrome-settings-collector.ps1` 而言，未指定時會在腳本同目錄建立時間戳記資料夾 |
| `-IncludeRawFiles` | 匯出 `Local State`、`Preferences`、`Secure Preferences` 等原始檔副本 |

## 報告分類

報告會優先依 `chrome://` 分類輸出：

1. `chrome://version`
2. `chrome://policy`
3. `chrome://extensions`
4. `chrome://prefs-internals`
5. `chrome://settings/content/siteData`
6. `chrome://system`

若資料無法直接對應到 `chrome://` 頁面，則使用：

- `Profile Metadata`
- `Collection Notes`
- `Local Storage Risk Assessment`
- `Origin Site Data Checks`

## 目前會收集的內容

### `chrome://version`

- Chrome 版本
- `User Data` 路徑
- `Local State` 路徑
- 最後使用的 Profile
- Profile 數量

### `chrome://policy`

- Enterprise policy key 數量
- Enterprise policy key 名稱

### `chrome://extensions`

- 每個 Profile 的外掛數量
- 外掛 ID、名稱、版本、狀態
- 是否來自 Web Store
- 安裝位置、路徑
- `manifest` 權限與 host permissions

### `chrome://prefs-internals`

- `Preferences` 路徑
- `Secure Preferences` 路徑
- `exitType`
- `cookieControlsMode`
- 部分與清除瀏覽資料相關的設定摘要

### `chrome://settings/content/siteData`

- 僅收集與站點資料有關的設定摘要
- `clearBrowsingDataSelection`
- 站點資料例外設定數量

### `Local Storage Risk Assessment`

- 依 policy、清除瀏覽資料選項、third-party cookie 設定、Profile 關閉狀態做 heuristic 判讀
- 輸出整體與各 Profile 的 `high` / `medium` / `low` 風險摘要
- 列出判讀依據與原始 signals

### `Origin Site Data Checks`

- 只有在指定 `-Origin` 時才會收集
- 檢查指定 origin 的 content setting 例外是否命中
- 檢查 Local Storage / IndexedDB / Session Storage 是否有可辨識的站台證據
- 輸出各 Profile 的 `riskImpact` 與備註

### `chrome://system`

- 目前**未收集**

## 匯出內容

預設情況下會產生：

- `summary.txt`：純文字報告
- `summary.json`：結構化報告

若加上 `-IncludeRawFiles`，還會另外匯出：

- `raw\Local State.json`
- `raw\<Profile>\Preferences.json`
- `raw\<Profile>\Secure Preferences.json`（若存在）

## 已知限制

1. 這支腳本是**讀取底層設定檔**，不是直接抓 `chrome://` 頁面畫面。
2. `chrome://settings/content/siteData` 目前只提供**部分收集**，不是完整逐站 storage inventory。
3. `chrome://system` 目前未收集。
4. Chrome 開啟中仍可讀取，但若某些設定尚未寫回磁碟，結果可能不是最新。
5. 不同 Chrome 版本的欄位可能不同，腳本會盡量容錯，但不能保證所有版本完全一致。
6. 若 Chrome 正在大量寫入設定檔，仍可能遇到暫時性的 JSON 讀取失敗；可先關閉 Chrome 後再重試。
7. `-Origin` 的 Local Storage / Session Storage 檢查目前使用 heuristic token scan；抓到證據時可作為線索，沒抓到時不代表該 origin 一定不存在。
8. `-IncludeRawFiles` 只有在有匯出檔案時才有作用；若同時指定 `-NoExport`，就不會產生 raw 副本。

## 範例輸出目錄

```text
D:\check_chrome
|-- chrome-settings-collector.ps1
|-- chrome-settings-launcher.ps1
|-- README.md
|-- export
|   |-- summary.json
|   `-- summary.txt
|-- export-raw
|   |-- raw
|   |   |-- Default
|   |   |   |-- Preferences.json
|   |   |   `-- Secure Preferences.json
|   |   `-- Local State.json
|   |-- summary.json
|   `-- summary.txt
```
