# Codex 帳號切換工具 - 引導登入與帳號儲存功能完成記錄

為 `CodexAccountSwitcher` 新增了**「引導登入新帳號」**互動流程，直接於切換器介面一鍵發起官方授權，自動偵測新憑證並引導命名儲存，徹底消除手動 CLI 操作與誤按「登出」導致 Token 失效的問題。

---

## 異動項目清單

### 1. 核心腳本 [`CodexAccountSwitcher.ps1`](../../src/CodexAccountSwitcher.ps1)
- **`Get-CodexCliPath`**：
  - 動態尋找最新版 `codex.exe`（掃描 `%LOCALAPPDATA%\OpenAI\Codex\bin` 依最後修改時間排序，或退回系統 PATH）。
- **`Prompt-AccountName`**：
  - 專用 WinForms 命名對話框，顯示授權的 Email，並預設帶入 Email 作為顯示名稱供使用者自訂。
- **`Start-GuidedLogin` 引導登入流程**：
  1. 檢查獨立用戶端衝突（`Assert-NoOtherClients`）。
  2. 自動備份當前有效憑證（`Backup-Current`）。
  3. 關閉 Codex Desktop（`Stop-Desktop`）。
  4. 彈出事前防呆提醒（提示使用者若瀏覽器延用舊 Cookie 時點選「切換帳號」，切勿在 Desktop 內登出）。
  5. 啟動 `codex login` 獨立終端視窗並喚起預設瀏覽器。
  6. 授權完成後自動讀取新憑證、彈出命名視窗並以 **Windows DPAPI CurrentUser** 加密儲存。
  7. 即時刷新清單，並詢問是否立即重啟 Codex Desktop。
- **介面配置重構**：
  - 底部功能列擴充為 4 個按鈕，對稱排列：
    - `切換並重新啟動` (寬 160)
    - `引導登入新帳號` (寬 160)
    - `還原上次切換` (寬 150)
    - `重新整理` (寬 186)
- **相容性修復**：
  - `-PreviewPath` 模式繞過互斥鎖阻擋，支援背景快速產生介面截圖。
  - 全檔案採用 UTF-8 with BOM 格式儲存，確保 Windows PowerShell 5.1 繁體中文環境無亂碼。

### 2. 操作指引 [`使用說明.md`](../../README.md)
- 新增「第一次使用 / 新增帳號」的引導登入 SOP。
- 更新「舊備份失效（401 Unauthorized / token_revoked）時」的快速重新授權指南。

---

## 驗證結果

### 1. 自動化測試 (`-SelfTest`)
執行自我驗證模式，全部通過：
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File outputs\CodexAccountSwitcher\CodexAccountSwitcher.ps1 -SelfTest
```
輸出：
```text
PASS: 加密儲存、帳號識別、token 更新、切換、還原、工作區及設定保留、格式檢查、儲存模式、程序辨識、CLI 探測。未讀取真實憑證或重啟 Codex。
```

### 2. 環境診斷 (`-CheckEnvironment`)
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File outputs\CodexAccountSwitcher\CodexAccountSwitcher.ps1 -CheckEnvironment
```
輸出：
```json
{
    "Application": "OpenAI.Codex_2p2nqsd0c76g0!App",
    "DesktopProcesses": 0,
    "RelatedProcesses": 0,
    "AuthFileExists": true,
    "CredentialsRead": false
}
```

### 3. 介面預覽截圖更新
已重新輸出更新後的 WinForms 介面預覽至 [`switcher-preview.png`](../../work/switcher-preview.png)。
底部按鈕已包含「引導登入新帳號」，介面排版均衡對稱。
