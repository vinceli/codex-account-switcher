# 帳號額度查詢與顯示計畫

## 定案

採非同步、唯讀查詢。開啟工具或按「重新整理帳號與額度」時，使用各帳號現有 Access Token 向 `https://chatgpt.com/backend-api/wham/usage` 發送 GET，帶入 `ChatGPT-Account-Id`；目前帳號優先採用最新 `auth.json`，其他帳號使用加密備份。

查詢不登出、不換發 Token、不修改 `auth.json` 或備份，也不操作工作區、對話或專案。401 可能表示過期或撤銷，只提示重新授權，不重試。失效備份保留。

## 實作

- 主程式：`src/CodexAccountSwitcher.ps1`。使用 .NET HttpClient 的非同步 Task，WinForms Timer 僅收取已完成結果；每次請求最多 3 秒，不跟隨重新導向，不保存 Cookie，不記錄憑證或回應原文。
- 清單增加方案、「5 小時用量」、「週用量」及查詢狀態；內容仍依 API 回傳的實際週期與剩餘比例顯示。
- 重新整理按鈕下方顯示整輪查詢完成時間；剩餘 0% 紅色、低於 30% 黃色、低於 70% 綠色、70% 以上藍色，未知值維持灰色。
- 週剩餘額度為 0% 時，5 小時剩餘額度同步顯示為 0%，兩欄皆套用紅色。
- 剩餘百分比為 `100 - used_percent`，限制在 0–100。缺值顯示未知，缺窗口顯示未提供。
- 優先採 `reset_at` 絕對時間；5 小時用量與小於 12 小時週用量改為顯示具體重置時間點（同日 `HH:mm`，跨日 `MM/dd HH:mm`），週用量大於等於 12 小時保持倒數格式（`>=24h` 顯示 `X.Xd`，`12h~24h` 顯示 `XhXXm`）。提示顯示本地詳細重置時間、查詢時間及 `additional_rate_limits` 中其他額度。
- 每輪查詢附 generation 與帳號 Key。重新整理、儲存、切換、引導登入、還原及關閉視窗均取消舊請求，結果只能更新相同 Key 的當輪資料。
- 連線失敗、逾時、401、403、429 與不支援格式分別顯示狀態；不阻擋本機帳號切換。
- `scripts/build-installer.ps1` 產出 `dist/` 安裝程式、免安裝 ZIP 與 SHA256 校驗檔；同步 README 與架構規格。

## 介面契約與限制

`wham/usage` 是內部端點，其格式與可用性不保證穩定。此處採用的 snake_case 欄位與官方 App Server RPC 的 camelCase 格式不同，不能互換。

[官方 App Server 規格](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt) 記載窗口可缺省、週期不固定及多額度結構。官方 RPC 適用於該 server 的登入帳號；本工具不為查詢不同備份而啟動 server、切換登入或刷新憑證。

## 驗證

1. `tests/Run-SelfTest.ps1`：既有切換／還原／工作區保護，以及 `tests/Quota.Tests.ps1` 的合成 HTTP 測試（正常、缺值、多額度、401/403/429/500、離線、逾時、取消、UI 回應、過期結果與 Key 對應）。
2. `-PreviewPath`：假帳號介面預覽，不讀取真實憑證。
3. 發行包：檢查白名單、機敏特徵、內嵌 ZIP 與原始碼一致性及校驗碼。
4. 實際帳號唯讀查詢另行記錄結果；測試成功不代表舊備份永遠有效，也不代表完成實際登入／切換驗證。

## 本次驗證結果（2026-09-17）

- Windows PowerShell 5.1 下，既有核心 SelfTest 與新增額度測試皆通過；HTTP 回應採模擬資料。
- 假帳號 WinForms 預覽已檢查，新增欄位、正常額度及重新授權狀態可見。
- 安裝程式與免安裝 ZIP 已建置；憑證特徵檢查通過。未安裝、未切換真實帳號或重啟 Desktop。
- 真實連線驗證未完成：此測試程序解密既有備份時出現 CryptographicException；使用目前登入檔查詢時出現 TLS AuthenticationException。未降低 TLS 驗證、未修改認證。比對測試前後登入檔與全部現存備份的 SHA256，內容一致。仍需在正常使用者桌面環境確認實際額度。
