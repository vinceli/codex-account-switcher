# Codex 帳號切換工具 - 額度查詢與重置時間顯示成果 (Walkthrough)

本文件記錄 Codex 帳號切換工具新增非同步唯讀額度查詢，以及後續針對使用者體驗調整「重置時間點顯示格式」之實作與驗證成果。

---

## 一、需求背景與變更重點

### 1. 額度查詢基礎功能
- 開啟工具或點擊「重新整理帳號與額度」時，於背景透過 .NET `HttpClient` 向 `https://chatgpt.com/backend-api/wham/usage` 非同步發送 GET 請求。
- 支援雙窗口用量（主要 5 小時窗口與週用量窗口），並提供四色狀態提示（0% 紅色、<30% 黃色、<70% 綠色、≥70% 藍色）。
- 週用量額度達上限（剩餘 0%）時，連鎖標註 5 小時用量為 0%，且倒數不顯示重置時間，改顯示 `-`（例如 `5h 0% (-)`），避免誤導。

### 2. 重置時間格式優化（本次重點）
根據使用者操作習慣優化時間呈現，避免頻繁計算倒數差距：
1. **5 小時用量**：
   - 不顯示剩餘倒數時間（如 `3h08m`）。
   - 改顯示具體**重置時間點**：當日重置顯示 `HH:mm`（例如 `15:08`、`20:02`），跨日重置顯示 `MM/dd HH:mm`。
2. **週用量（7 天窗口）**：
   - 若剩餘時間 **< 12 小時**：比照 5 小時用量改顯示具體**重置時間點**（`HH:mm` 或 `MM/dd HH:mm`）。
   - 若剩餘時間 **≥ 12 小時**：**保持原樣**。
     - $\ge 24$ 小時：顯示天數倒數（如 `6.8d`）。
     - $12 \le \text{小時} < 24$：顯示小時與分鐘倒數（如 `15h00m`）。
3. **精簡標記**：
   - 因欄位標題已明確標示「5 小時用量」與「週用量」，資料行不再重複標記 `5h` 與 `7d`，直接顯示為 `78% (15:08)` 與 `84% (6.8d)`。
   - 週額度用迄時 5 小時額度顯示為 `0% (-)`。
   - 週期詳細資訊（`5h` / `7d`）完整保留於滑鼠懸停之 ToolTip 中。

---

## 二、程式碼異動摘要

### 1. 核心邏輯 (`src/CodexAccountSwitcher.ps1`)
- **`Format-QuotaWindow` 參數與邏輯調整**：
  - 增加 `[switch]$IsPrimary` 參數，明確識別主要窗口。
  - 判斷邏輯：
    ```powershell
    $is5h = $IsPrimary -or ($duration -eq '5h') -or ($seconds -gt 0 -and $seconds -le 18000)
    $showResetTime = $is5h -or ($minutes -lt 720)
    if ($showResetTime) {
        $localReset = $reset.ToLocalTime()
        $countdown = if ($localReset.Date -eq [DateTime]::Today) {
            $localReset.ToString('HH:mm')
        } else {
            $localReset.ToString('MM/dd HH:mm')
        }
    } else {
        $countdown = if ($minutes -ge 1440) {
            "$([Math]::Round($minutes / 1440, 1))d"
        } else {
            '{0}h{1:00}m' -f [Math]::Floor($minutes / 60), ($minutes % 60)
        }
    }
    ```
- **編碼保護**：
  - 檔案維持 **UTF-8 with BOM** 格式儲存，防止 Windows PowerShell 5.1 解析多位元組中文字元時發生語法錯誤。

### 2. 單元測試 (`tests/Quota.Tests.ps1`)
- 擴充斷言項目：
  - 驗證 5 小時用量字串包含精準重置時間點（如 `HH:mm`），且不包含舊格式 `3h00m`。
  - 驗證週用量在剩餘 6 小時（$<12$ 小時）時顯示具體重置時間點，且不包含 `6h00m`。
  - 驗證週用量在剩餘 15 小時（$\ge 12$ 小時且 $<24$ 小時）時保持 `15h00m` 倒數。
  - 驗證週用量在剩餘 3 天時保持 `3d` / `3.0d` 倒數。

---

## 三、驗證結果

1. **自動化自我驗證套件**：
   - 執行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-SelfTest.ps1`
   - **結果**：
     - `PASS: 加密儲存、帳號識別、token 更新、切換、還原、工作區及設定保留、格式檢查、儲存模式、程序辨識、CLI 探測。未讀取真實憑證或重啟 Codex。`
     - `PASS: 額度解析、HTTP 錯誤、逾時、取消、非同步 UI、帳號對應與過期結果隔離；全程合成資料及模擬 HTTP。`
     - `[測試通過] 所有加密、識別、快照、還原與工作區保留測試皆符合預期！`

2. **發行包自動化封裝與安全閘門**：
   - 執行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-installer.ps1`
   - 白名單與 Zero-Credential 敏感特徵掃描 **PASS**（無任何 `.bin`、`auth.json`、真實 Token 或信箱）。
   - 產出檔案：
     - `dist/Setup-CodexAccountSwitcher.exe`
     - `dist/CodexAccountSwitcher-v1.0.0-Portable.zip`
     - `dist/SHA256SUMS.txt`
