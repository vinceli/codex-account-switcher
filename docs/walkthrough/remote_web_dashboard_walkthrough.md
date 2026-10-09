# 遠端 Web 儀表板與 CentOS 8 副機安全切換功能驗證記錄 (Walkthrough)

## 1. 變更總覽

本次實作成功新增了**遠端 Web 儀表板**與**CentOS 8 副機安全切換通道 (方案 A)**，滿足以下核心需求：
1. **主機端可選啟動 Web 儀表板**：主機 (Windows 11) 啟動後，使用者可自由選擇是否啟動 Web 服務，避免無謂佔用通訊埠。
2. **可自訂監聽 Port 與隨機 6 碼動態驗證碼 (PIN)**：預設 Port 為 `8998`，每次啟動或點擊按鈕皆可重新生成隨機 6 碼 PIN，並於主機視窗高亮展示。
3. **防衝突安全鎖定 (Collision Lock)**：
   - 實時識別主機當前活躍帳號（`Read-Current` 之 SHA256 Key）。
   - Web 儀表板視圖中，主機執勤中帳號高亮標記為 `🔒 主機使用中（鎖定保護）`，切換按鈕強制反灰停用。
   - 後端 API 端點 (`POST /api/switch-remote`) 強制校驗：若副機試圖切換主機活躍帳號，立即回傳 **HTTP 403 Forbidden** 並拒絕推送，徹底杜絕主副機雙方搶佔同一個 Refresh Token 造成的 401 撤銷問題。
4. **OpenSSH 安全通道派送**：
   - 副機（CentOS 8: 192.168.1.195）**零安裝、零背景守護服務**。
   - 憑證由主機 Windows DPAPI 解密後，經由 Windows 內建 OpenSSH (`ssh.exe` / `scp.exe`) 安全通道推送至副機暫存檔，再以 `mv -f` 原子覆蓋至 `~/.codex/auth.json` 並設定 `chmod 600`。
   - 主機本機暫存明文於傳輸後立即以空位元組覆寫並銷毀。

---

## 2. 異動與新增檔案清單

| 檔案路徑 | 狀態 | 職責說明 |
| :--- | :--- | :--- |
| `src/WebDashboard.ps1` | 新增 | 非同步免提權 .NET Socket 微型 HTTP 伺服器、PIN 鑑權、防衝突鎖定及安全推送邏輯 |
| `src/assets/web/index.html` | 新增 | 自包含現代暗色戰情 Web UI 前端（PIN 鎖屏、帳號卡片流、額度條、鎖定徽章） |
| `src/CodexAccountSwitcher.ps1` | 修改 | 新增「遠端副機 (Web)」分頁、主機活躍狀態同步、快捷跳轉與資源釋放 |
| `tests/WebDashboard.Tests.ps1` | 新增 | 包含 PIN 鑑權、未授權阻擋、清單鎖定狀態、防衝突 403 攔截與派送之單元測試 |
| `tests/Run-SelfTest.ps1` | 修改 | 整合 WebDashboard 測試至全自動化自我驗證流程 |
| `scripts/build-installer.ps1` | 修改 | 將 `WebDashboard.ps1` 納入白名單與打包檢查閘門 |
| `README.md` | 修改 | 同步核心特色、專案目錄結構與遠端 Web 儀表板操作手冊 |
| `docs/implementation_plan/remote_web_dashboard.md` | 新增 | 實作規劃存檔文件 |

---

## 3. 測試與驗證結果

### 3.1 自動化測試套件驗證 (`Run-SelfTest.ps1`)
執行指令：
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-SelfTest.ps1
```
輸出結果：
```text
=== 執行 CodexAccountSwitcher 核心邏輯自我驗證 ===
PASS: 加密儲存、舊版備份繼承、帳號識別、token 更新、切換、還原、工作區及設定保留、格式檢查、儲存模式、程序辨識、CLI 探測。未讀取真實憑證或重啟 Codex。
PASS: Antigravity 合成憑證讀寫、身分解析、DPAPI 備份、切換與還原。未讀寫真實憑證。
PASS: Antigravity 雙模型組五小時與每週額度、方案、重置資訊及錯誤狀態。
PASS: 額度解析、HTTP 錯誤、逾時、取消、非同步 UI、帳號對應與過期結果隔離；全程合成資料及模擬 HTTP。
[GuildDialog 全部測試通過]
--- 測試 1: 啟動 Web 儀表板伺服器 ---
--- 測試 2: 首頁 HTML 靜態路由 ---
--- 測試 3: 驗證碼防護 (PIN 鑑權) ---
--- 測試 4: 未授權存取受保護 API ---
--- 測試 5: 帳號清單與主機鎖定標記 ---
--- 測試 6: 防衝突鎖定攔截 (關鍵安全測試) ---
--- 測試 7: 非主機帳號安全派送流程 ---
PASS: 遠端 Web 儀表板、PIN 驗證、主機帳號鎖定防衝突、API 鑑權與安全推送測試全數通過！

[測試通過] 所有加密、識別、快照、還原與工作區保留測試皆符合預期！
```

### 3.2 發行建置與安全隔離審計驗證 (`build-installer.ps1`)
執行建置腳本確認打包完整性與 Zero-Credential 安全掃描：
```text
[Step 1/5] 執行白名單複製 (Whitelist Copy)...
  + 已加入白名單: WebDashboard.ps1
  + 已加入資源目錄: assets/
  + 已加入白名單: 使用說明.md (來源: README.md)
[Step 2/5] 執行機敏資料檢查閘門 (Security Gate)...
  [PASS] 檔名與副檔名黑名單檢查通過 (無 .bin, .log, auth.json 等憑證檔)
  [PASS] 內容敏感字串與個人憑證掃描通過 (無任何真實 Token、Session 特徵)
[Step 3/5] 封裝免安裝發行包 (Portable.zip)...
[Step 4/5] 編譯自包含單一安裝程式 (Setup-CodexAntigravitySwitcher.exe)...
[Step 5/5] 計算發行檔案 SHA-256 雜湊...
========================================================
 [成功] Codex 帳號切換工具封裝完成！發行檔案位於:
 1. dist\Setup-CodexAntigravitySwitcher.exe (自包含單檔安裝程式)
 2. dist\CodexAccountSwitcher-v1.1.0-Portable.zip (綠色免安裝/腳本發行包)
========================================================
```

---

## 4. 實機操作指南

1. **主機端操作**：
   - 啟動主工具，切換至「**遠端副機 (Web)**」分頁（或在 Codex 分頁點擊右上角「**🌐 遠端副機 / Web**」快速跳轉）。
   - 確認或修改監聽 Port（預設 `8998`），點擊「**▶ 啟動 Web 儀表板**」。
   - 主機會在視窗上顯示 6 碼動態 PIN（例如 `839201`）與連線網址（例如 `http://192.168.1.168:8998`）。
   - 可點擊「**⚡ 測試副機 SSH 連線**」確認與 CentOS 8 (192.168.1.195) 的連通狀態。
2. **副機端操作**：
   - 在 CentOS 8（或區網內的手機、平板、筆電）開啟瀏覽器，連線至 `http://192.168.1.168:8998`。
   - 輸入主機顯示的 6 碼 PIN 碼完成認證解鎖。
   - **檢視防衝突狀態**：主機正在使用的帳號會顯示 `🔒 主機使用中（鎖定保護）`，切換按鈕強制反灰禁止點擊。
   - 點擊其他備份帳號的「**🚀 切換至 CentOS 副機**」，主機即刻解密該帳號並經由 SSH 安全推送至副機的 `~/.codex/auth.json`。
   - **自動啟動副機桌面端**：切換成功後，主機除了原子替換 ~/.codex/auth.json，還會自動關閉副機舊的 Codex 程序，並自動偵測副機的 X11 圖形桌面環境（支援 XRDP Session :10 或本機 :0）背景喚起 Codex Desktop，副機桌面立即跳出已登入之新帳號！
