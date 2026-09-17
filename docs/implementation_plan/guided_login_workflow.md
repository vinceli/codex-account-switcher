# Codex 帳號切換工具 - 引導登入與帳號儲存功能實作計畫

為 `CodexAccountSwitcher` 新增「引導登入新帳號 / 重新授權」功能，提供一鍵喚起官方登入、自動捕獲新憑證、防呆提示、自訂命名與 DPAPI 加密儲存的完整流程，徹底解決手動操作或誤按「登出」導致 Refresh Token 失效（`401 Unauthorized: token_revoked`）的問題。

---

## User Review Required

> [!IMPORTANT]
> **登入互動採用「彈出終端視窗 + 瀏覽器 OAuth」架構**
> 1. 執行登入時，切換器會自動先將目前使用中的帳號建立安全備份並關閉 Codex Desktop。
> 2. 隨後彈出精簡終端視窗執行官方 `codex login`，系統會自動喚起預設瀏覽器開啟 OpenAI 登入頁面。
> 3. 使用者於瀏覽器登入完成後，終端視窗自動關閉，切換器自動偵測到新憑證並跳出對話框讓使用者自訂名稱儲存。
> 4. 終端視窗保留的好處：若瀏覽器因系統安全性阻擋未自動開啟，終端視窗內會即時顯示登入網址供手動複製，避免流程卡死。

> [!WARNING]
> **多帳號瀏覽器 Session 提示**
> 若使用者在同一個瀏覽器登入第二個帳號，OpenAI 授權頁可能自動延用第一個帳號的 Cookie。工具會在啟動登入前跳出提示，提醒使用者在網頁上點選「切換帳號 / Switch Account」，且**絕對不要在 Codex Desktop 內部按登出**。

---

## Proposed Changes

### 切換器腳本與介面

#### [MODIFY] [CodexAccountSwitcher.ps1](file:///C:/Users/vince/Documents/Codex/2026-09-17/new-chat/outputs/CodexAccountSwitcher/CodexAccountSwitcher.ps1)
- **新增 CLI 探測函式 `Get-CodexCliPath`**：
  - 動態尋找 `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`（選取最新版本），若無則降級尋找系統 `PATH`。
- **新增 `Start-GuidedLogin` 引導登入流程**：
  1. 檢查現有環境與運作中程序（`Assert-NoOtherClients`）。
  2. 若目前 `auth.json` 包含有效帳號，自動執行 `Backup-Current` 進行保護。
  3. 優雅關閉 Codex Desktop（`Stop-Desktop`）。
  4. 彈出事前提示視窗（說明瀏覽器切換注意事項）。
  5. 啟動 `codex login`（透過 `Start-Process powershell.exe -Wait`）。
  6. 檢查 `auth.json` 變更與 JWT payload，擷取新帳號之 `email` 與 `account_id`。
  7. 彈出輸入對話框引導命名（預設帶入 `email`），確認後立即呼叫 `Save-Backup` 存為 DPAPI 加密檔。
  8. 重新整理清單，並詢問是否立即啟動 Codex Desktop。
- **WinForms 介面按鈕重構**：
  - 調整底部操作列版面，新增「引導登入新帳號」按鈕（寬度與間距最佳化排版）：
    - `切換並重新啟動` (x=26, w=160)
    - `引導登入新帳號` (x=196, w=160)
    - `還原上次切換` (x=366, w=150)
    - `重新整理` (x=526, w=110)
  - 狀態列與文字提示更新。
- **更新 `-SelfTest`**：
  - 補充 `Get-CodexCliPath` 的路徑探測與模擬登入引導邏輯驗證。

---

### 文件與指引

#### [MODIFY] [使用說明.md](file:///C:/Users/vince/Documents/Codex/2026-09-17/new-chat/outputs/CodexAccountSwitcher/%E4%BD%BF%E7%94%A8%E8%AA%AA%E6%98%8E.md)
- 新增「新增或重新授權帳號（引導登入）」章節。
- 說明工具內直接點選「引導登入新帳號」的操作步驟與注意事項。
- 更新常見問題與失效排除說明。

---

## Verification Plan

### 自動化測試
1. 執行切換工具自檢模式，確保既有憑證解析、DPAPI 加密備份、原子寫入均未受破壞：
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File outputs\CodexAccountSwitcher\CodexAccountSwitcher.ps1 -SelfTest
   ```
2. 執行環境診斷檢查：
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File outputs\CodexAccountSwitcher\CodexAccountSwitcher.ps1 -CheckEnvironment
   ```

### 人工驗證
1. 開啟 `CodexAccountSwitcher.exe` 檢視更新後的 WinForms 介面與按鈕排版。
2. 點擊「引導登入新帳號」：
   - 驗證是否出現防呆提示。
   - 驗證 Codex Desktop 是否被正確關閉。
   - 驗證是否順利開啟瀏覽器並進入 OpenAI OAuth 認證。
   - 完成登入後，驗證切換器是否正確讀出新帳號之 email、提供命名並成功存檔。
   - 驗證帳號清單是否即時更新，並能順利切換回原本的帳號。
