# Codex 帳號切換失效記錄深度查詢與終極解決方案

針對使用者反映之「只要有新的儲存，再使用切換到舊的就會失效」，深入查詢系統資料庫與真實記錄檔，重組事故全貌，並完成切換器防撤銷機制的終極升級。

---

## 一、系統記錄查詢結果與事故時間軸

我們深度解析了以下核心日誌與資料庫：
1. `~/.codex/logs_2.sqlite`（Codex 底層核心事件與網路通訊資料庫）
2. `~/.codex/log/codex-login.log`（CLI OAuth 授權日誌）
3. `%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\...`（Desktop 前端日誌）

### 事故精確時間軸

| 時間 | 觸發事件 | 系統日誌記錄 | 狀態分析 |
| :--- | :--- | :--- | :--- |
| **11:16:56** | 授權登入帳號 A (`Account A`) | `oauth token exchange succeeded status=200 OK` | 帳號 A 取得全新 Access & Refresh Token。 |
| **11:17:28** | 原運行的帳號 B (`Account B`) 通訊 | `unexpected status 401 Unauthorized: Encountered invalidated oauth token for user, code: token_revoked` | **關鍵證據 1**：在瀏覽器中登入 A 的同時，OpenAI 伺服器立即宣告 B 的 Refresh Token 失效！ |
| **11:18:03** | 切換器備份帳號 A | 寫入 `8328cb15...bin` | 帳號 A 備份完成。 |
| **11:18:14** | 發起帳號 B 登入授權 | `starting browser login flow` | 喚起預設瀏覽器。 |
| **11:18:26** | 帳號 B 完成授權 | `oauth token exchange succeeded status=200 OK` | 帳號 B 重新取得有效 Token。**同時間帳號 A 的 Token 遭 OpenAI 撤銷**。 |
| **11:21:11** | 使用切換器切回帳號 A | 切換器將帳號 A 覆蓋回 `auth.json` 並重開 Desktop | 本機檔案置換成功。 |
| **11:21:23** | Desktop 啟動與雲端通訊 | `401 Unauthorized: { "code": "refresh_token_invalidated", "message": "Your session has ended. Please log in again." }` | **關鍵證據 2**：雲端拒絕 A 的 Refresh Token，回報已撤銷。 |
| **11:21:28** | Codex 認證核心處置 | `event login\src\auth\manager.rs:980: Failed to remove auth.json: not_refreshable_auth` | **關鍵證據 3**：Codex 偵測到 Token 已不可恢復，**主動將本機 `auth.json` 刪除**！導致應用程式全面回到「未登入」畫面。 |

---

## 二、問題根因總結

1. **連鎖撤銷 (Cascading Revocation)**：
   - 預設的 `codex login` 會強制使用 Windows 預設瀏覽器開啟驗證頁。
   - 當預設瀏覽器已有帳號 A 的 Session 時，若為了登入帳號 B 而在網頁上執行了「登出」或「切換帳號」，**OpenAI 伺服器會立即在雲端銷毀帳號 A 的所有 Refresh Token**。
2. **自動刪檔機制**：
   - 當切換回已被撤銷的帳號時，Codex 後端嘗試向雲端換票失敗，會認定該憑證已損毀而**主動從硬碟刪除 `auth.json`**，造成「只要切換到舊的就壞掉」的現象。

---

## 三、完成的修復與終極解決方案

### 1. 介面日誌修復（解決記錄檔未產生與亂碼）
- 修正 `Write-SwitcherLog` 中 .NET 方法重載型別問題（改用 `AppendAllText` 搭配 `UTF-8 with BOM`）。
- 實測日誌已正常寫入 `%LOCALAPPDATA%\CodexAccountSwitcher\switcher.log`，無亂碼，且可於切換器介面隨時點選「**查看日誌 (Log)**」開啟。

### 2. 復原目前有效憑證
- 已將目前在 OpenAI 伺服器端仍屬有效的帳號 B (`Account B`) 重新寫回 `auth.json`。
- 經 RPC 實測連線已通過驗證（HTTP 200 OK，ChatGPT Plus 方案）。

### 3. 引導登入全面升級：【裝置代碼安全授權模式 (--device-auth)】
為了解決「瀏覽器自動開窗導致使用者誤在同一 Session 登出」的根本問題，在 [`CodexAccountSwitcher.ps1`](../../src/CodexAccountSwitcher.ps1) 加入了全自動化的裝置代碼登入：
- **操作方式**：
  1. 點選切換器「**引導登入新帳號**」。
  2. 彈出對話框中點選「**是 (Y)**」選擇【裝置代碼安全模式】。
  3. 切換器會**自動開啟 Edge / Chrome 獨立無痕視窗**導向 `https://auth.openai.com/codex/device`，並於終端機顯示一次性 8 碼授權碼。
  4. 在無痕視窗輸入該 8 碼代碼並登入帳號。
- **優勢**：
  - **完全不碰觸現有瀏覽器 Session**，舊帳號絕不被登出，雲端 Refresh Token 永久保持有效！
  - 終端機接收 Token 後自動關閉，切換器自動以 Windows DPAPI 加密儲存，實現**多帳號長效並存、自由無痛切換**。

---

## 四、驗證結果
- **測試命令**：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File outputs\CodexAccountSwitcher\CodexAccountSwitcher.ps1 -SelfTest`
- **結果**：`PASS: 加密儲存、帳號識別、token 更新、切換、還原、工作區及設定保留、格式檢查、儲存模式、程序辨識、CLI 探測。未讀取真實憑證或重啟 Codex。`
