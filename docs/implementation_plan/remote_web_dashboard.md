# 遠端 Web 儀表板與副機安全切換實作計畫 (方案 A)

## 1. 目標與界線

- **主機 (Windows 11, 192.168.1.168)**：
  - 作為唯一金鑰庫與身分驗證中心 (Single Source of Truth)，儲存並維護所有已加密的 Codex 帳號。
  - 啟動後由使用者決定是否啟動「遠端 Web 儀表板」。
  - 支援自訂監聽 Port（預設 `8998`）及動態生成**隨機 6 碼數字驗證碼 (PIN)**。
- **副機 (CentOS 8, 192.168.1.195)**：
  - 作為副機/工作節點，透過瀏覽器存取 Web 儀表板操作切換，或由主機直接經 SSH/SCP 將選定憑證推送到副機的 `~/.codex/auth.json`。
  - 副機端**零常駐服務、零額外套件依賴**。
- **防衝突安全鎖定 (Collision Lock)**：
  - Web 端與 API 端必須即時識別主機當前正在使用的帳號。
  - **若帳號為主機目前執勤中帳號，必須直接鎖定 (Locked)**：Web 介面反灰禁用切換按鈕，API 端強制攔截並拋出 403 拒絕，防止主副機雙方搶佔同一個 Refresh Token 造成 401 撤銷失效。
- **邊界限制**：
  - 本次範圍專注於 **OpenAI Codex CLI** 的副機切換（因 Linux 伺服器主要運行 Codex CLI）。
  - Antigravity 憑證因依賴 Windows 憑證管理員與桌面版程序，暫不納入 Linux 副機推送範疇。

---

## 2. 現況調查與確認

1. **主機狀態辨識**：
   - 程式已確認：`src/CodexAccountSwitcher.ps1` 內的 `Read-Current` 讀取 `~/.codex/auth.json` 並由 `Get-Identity` 產生 SHA256 Key。此 Key 可精確代表主機當前活躍帳號。
2. **本機加密備份**：
   - 程式已確認：所有備份儲存在 `%LOCALAPPDATA%\CodexAntigravitySwitcher`，副檔名為 `.bin`，使用 Windows DPAPI 加密，可透過 `Read-Backup` 解密。
3. **連線與工具**：
   - 執行測試已確認：`192.168.1.195:22` (CentOS 8 SSH 連接埠) 處於開放連通狀態。
   - 執行測試已確認：Windows 11 具備內建 OpenSSH 用戶端（`C:\windows\System32\OpenSSH\ssh.exe` 與 `scp.exe`）。
4. **網路權限考量**：
   - Windows 原生 `HttpListener` 若綁定 `0.0.0.0` 需 Administrator 權限 (`netsh http add urlacl`)；為維持工具**免系統管理員 (Non-Admin)** 的核心承諾，Web 伺服器將採用 .NET 原生非同步 `System.Net.Sockets.TcpListener` 實作極簡且免提權的 HTTP/1.1 API 伺服器，或在背景 Runspace 中運作。

---

## 3. 模組設計與修改方案

### 3.1 核心模組一：Web 伺服器與 API (`src/WebDashboard.ps1`)
- **生命週期控制**：
  - `Start-WebDashboard -Port [int] -HostCurrentKey [string]`：背景 Runspace 啟動監聽，生成隨機 6 碼 PIN（例如 `100000`~`999999`）。
  - `Stop-WebDashboard`：優雅關閉監聽並釋放 Port 與 Socket。
  - `Get-WebDashboardInfo`：回傳目前狀態 (Stopped/Running)、監聽網址 (如 `http://192.168.1.168:8998`)、當前 PIN。
- **安全性與驗證機制**：
  - 存取任何 API 需攜帶 Cookie `session_token` 或 Header `X-Pin: 123456`。
  - PIN 錯誤次數限制（防止暴力破解）。
- **API 端點**：
  - `POST /api/verify`：校驗 6 碼 PIN，成功核發會話 Token。
  - `GET /api/status`：回傳主機目前狀態、副機 IP 設定、主機目前活躍帳號 Key。
  - `GET /api/accounts`：回傳所有已備份的 Codex 帳號清單（含即時額度快照），並標記：
    ```json
    {
      "key": "sha256...",
      "name": "工作帳號 A",
      "email": "user@example.com",
      "plan": "Plus",
      "primary_quota": "78% (15:08)",
      "secondary_quota": "84% (6.8d)",
      "is_host_active": true,
      "locked": true,
      "lock_reason": "此帳號目前為主機執勤中，已鎖定禁止副機切換"
    }
    ```
  - `POST /api/switch-remote`：
    - 接收參數：`{ "target_key": "sha256...", "remote_host": "192.168.1.195", "remote_user": "vince" }`
    - **安全攔截**：
      ```powershell
      if ($request.target_key -eq $hostCurrentKey) {
          return 403 Forbidden ("此帳號目前正由主機執勤中，已鎖定禁止副機切換。")
      }
      ```
    - **解密與推送**：主機自 DPAPI 讀取並解密目標帳號，產生暫存檔，調用 `scp.exe` 寫入副機 `~/.codex/auth.json`，完成後立即安全刪除主機暫存明文。

### 3.2 核心模組二：自包含 Web 前端介面 (`src/assets/web/index.html`)
- 嵌入單頁應用程式 (SPA)，完全無外部 CDN 依賴（自包含 CSS / Vanilla JS）。
- **PIN 驗證畫面**：首次進入呈現極簡驗證碼輸入鎖屏。
- **戰情室卡片清單**：
  - 渲染各帳號卡片與額度條。
  - **鎖定卡片**：當 `locked == true` 時，卡片邊框呈警示色，標記 `🔒 主機使用中 (鎖定)`，切換按鈕反灰且無法點擊。
  - **切換按鈕**：點擊未鎖定帳號之「切換至 CentOS 副機」，彈出二次確認，呼叫 `/api/switch-remote` 並顯示切換進度與結果。

### 3.3 主機 GUI 介面整合 (`src/CodexAccountSwitcher.ps1`)
- 在視窗下方或專屬區塊新增「遠端 Web 儀表板」面板：
  - **啟動 / 停止切換按鈕**：`[▶ 啟動 Web 儀表板]` / `[■ 停止]`。
  - **監聽 Port**：預設文字方塊 `8998`（啟動前可修改）。
  - **6 碼驗證碼展示框**：大型字體醒目顯示（例：`PIN: 839201`），附帶「重新生成」按鈕。
  - **狀態提示**：顯示 `運行中：http://192.168.1.168:8998`（點擊可本機預覽）。
  - **副機設定區**：可配置目標 IP (預設 `192.168.1.195`) 與 SSH 使用者名稱。

---

## 4. 驗證與測試設計 (Verification Plan)

### 4.1 自動化自我測試 (`tests/Run-SelfTest.ps1`)
1. **PIN 驗證機制測試**：
   - 驗證正確 PIN 可通過並取得有效 Token；錯誤 PIN 回傳 401 Unauthorized。
2. **防衝突鎖定核心測試 (關鍵)**：
   - 模擬主機當前帳號為 Key A，備份有 Key A 與 Key B。
   - 透過 API 請求 `/api/accounts`，確認 Key A 之 `locked == true`。
   - 透過 API 嘗試切換 Key A，確認回傳 403 Forbidden 且錯誤原因明確。
   - 透過 API 嘗試切換 Key B，確認允許放行切換邏輯。
3. **安全清理測試**：
   - 確認推送過程中的臨時明文檔案在傳輸結束（無論成功或異常）均被徹底刪除。

### 4.2 實機整合驗收
1. 主機端啟動主程式，點擊「啟動 Web 儀表板」，取得 6 碼 PIN。
2. 在瀏覽器打開 `http://192.168.1.168:8998`，輸入 PIN 成功登入。
3. 確認主機正在使用的帳號顯示為「主機使用中 (鎖定)」，切換按鈕反灰不可按。
4. 點選另一個備用帳號「切換至 CentOS 副機」，確認推送至 `192.168.1.195:~/.codex/auth.json` 成功，並至 CentOS 8 執行 `codex` 驗證切換結果。

---

## 5. 檔案異動清單

| 檔案路徑 | 動作 | 職責說明 |
| :--- | :--- | :--- |
| `src/WebDashboard.ps1` | 新增 | 微型 HTTP 伺服器、PIN 驗證、API 路由、SSH/SCP 派送及防衝突鎖定 |
| `src/assets/web/index.html` | 新增 | 現代自包含 Web UI 前端（PIN 輸入、卡片流、額度、鎖定徽章） |
| `src/CodexAccountSwitcher.ps1` | 修改 | 新增 Web 儀表板控制介面、生命週期整合、主機活躍狀態同步 |
| `tests/Run-SelfTest.ps1` | 修改 | 新增 Web API 與防衝突鎖定之自我驗證邏輯 |
| `README.md` | 修改 | 更新說明文件，補充遠端 Web 儀表板與 CentOS 副機切換指引 |
| `docs/implementation_plan/remote_web_dashboard.md` | 新增 | 歸檔本實作計畫 |
