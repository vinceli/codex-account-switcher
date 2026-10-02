# Codex／Antigravity 分頁切換實作計畫

## 目標與界線

- 同一視窗以 Codex、Antigravity 分頁管理帳號；兩個分頁均顯示額度。
- Codex 維持只替換 `auth.json`。Antigravity 只處理 Windows Generic Credential `gemini:antigravity`。
- 不備份、覆寫或重建 Antigravity 的 `app_storage.json`、`state.vscdb`、工作區、對話、`.gemini` 目錄。
- 所有備份以 DPAPI CurrentUser 加密；新版使用獨立的 `%LOCALAPPDATA%\CodexAntigravitySwitcher`，兩種產品使用不同備份目錄與還原點。新版啟動時只補入缺少的舊版 Codex 備份，舊版原件保持原位。

## 已確認的依據

1. 人工 A→B→A 測試後，Antigravity 工作區及對話仍存在，但每次官方登出後切回 A 都需重新瀏覽器授權。
2. `%APPDATA%\Antigravity\User\globalStorage\state.vscdb` 的兩個登入相關欄位在 B 登入後未變；資料庫同時含工作區索引，不能整檔替換。
3. Windows 認證管理員存在 `gemini:antigravity`。目前登入項目為 Generic Credential，可解析 `token`、`auth_method`、`id_token`，且 ID Token 有可供辨識的身分欄位。這是目前版本的本機觀察，應視為版本相依。

## 執行步驟

1. 新增 Antigravity 認證管理員讀寫與身分驗證；拒絕不支援格式或未知屬性。
2. 儲存目前認證及切換前還原點，讀回驗證加密備份。
3. 確認其他 Antigravity 用戶端未運作，關閉桌面版；只替換認證項目，讀回核對，失敗則還原原認證，再重新啟動。
4. WinForms 加入兩個 Tab，Antigravity 顯示目前帳號、備份清單、儲存、切換、還原與重新整理。兩頁籤均有方案、五小時與每週額度欄。
5. 新增 Antigravity 引導登入：先備份，清除本機認證以啟動官方登入，完成後自動儲存；取消時還原。
6. 提供獨立測試資料目錄，測試模式不讀取已安裝版 Codex 帳號；正式模式自動驗證並繼承舊版備份，遇新版同名備份不覆寫。
7. 封裝加入新腳本，更新 README 與架構文件。
8. 新版桌面與開始功能表捷徑使用舊版相同的金鑰圖示。

## 驗收

- 合成資料：認證管理員讀寫、DPAPI 備份往返、帳號識別、最新 Token 保存、切換及還原通過；測試項目不使用真實目標且結束後刪除。
- 預覽：兩個 Tab 控制項不重疊，Codex 原有欄位及動作可見。
- 實際帳號：先備份 A，官方登入 B 並備份 B；從工具切回 A 時不用瀏覽器重新授權，Account 頁顯示 A、原工作區與對話仍在；再切回 B，同樣確認。若其中一步失敗，恢復原認證或使用官方登入，不宣稱可用。
- 獨立測試模式不得載入已安裝版的 Codex 備份或 `auth.json`；Codex 操作按鈕停用。
- 舊版三份 Codex 備份在新版首次啟動後出現於清單；舊版原件保持相同，新版已存在的備份不被覆寫。
- 2026-09-24 實機驗收：使用者確認兩個真實帳號切換免瀏覽器登入，工作區與對話仍在；引導登入並自動儲存、切回原帳號也成功。切換後 WinForms 按鈕狀態例外已修正，重新測試無除錯視窗。

## 額度顯示評估

Antigravity 分頁直接以各備份的存取權杖呼叫 `retrieveUserQuotaSummary`，解析 Gemini 與 Claude/GPT 各自的五小時及每週額度；`loadCodeAssist` 提供方案。短期權杖過期時，在記憶體中以刷新權杖換發，OAuth 用戶端設定取自本機已安裝的 Antigravity 程式。兩份真實備份均已成功取得四個額度，其中一份需刷新。資料來源屬內部介面，失敗時只顯示查詢狀態，不影響憑證與帳號切換。
