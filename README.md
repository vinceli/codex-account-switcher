# Codex 帳號切換工具 (CodexAccountSwitcher)

適用於 Windows 環境的 OpenAI Codex Desktop 多帳號無痛切換工具。基於 Windows PowerShell 5.1 與 WinForms 原生開發，無需安裝額外執行環境，徹底解決多帳號切換時憑證遭 OpenAI 雲端連鎖撤銷（401 Unauthorized / token_revoked）的核心痛點。

---

## 🌟 核心特色

1. **防連鎖撤銷（Anti-Revocation Architecture）**：
   - 內建【裝置代碼安全授權模式 (`--device-auth`)】，自動於 Chrome / Edge 獨立無痕視窗中完成身分授權。
   - 完全不碰觸主瀏覽器既有工作階段（Session），舊帳號的 Refresh Token 絕不被雲端註銷，實現雙帳號永久並存。
2. **工作區與歷史零破壞（Non-Destructive Guarantee）**：
   - 僅執行 `auth.json` 憑證替換與程序優雅重啟。
   - 絕不刪除、搬移或重設使用者既有之專案目錄、Git worktrees、本機歷史對話或 `config.toml`。
3. **本機高強度安全加密（Windows DPAPI）**：
   - 所有已儲存帳號憑證皆以 Windows `ProtectedData` (DPAPI CurrentUser) 加密封裝。
   - 僅限原登入 Windows 使用者有權解密，即使備份檔被複製到其他電腦亦無法解密還原。
4. **安全隔離檢查閘門（Zero-Credential Security Gate）**：
   - 建置腳本內建嚴格白名單與正則掃描檢查，徹底杜絕任何真實 Token、金鑰或個人信箱被包入發行檔或提交至版本控制。
5. **多種安裝與部署模式**：
   - 提供單一自包含 GUI 安裝程式（`Setup-CodexAccountSwitcher.exe`，免 Admin/UAC 權限）。
   - 提供綠色免安裝發行包（`Portable.zip`，內建一鍵捷徑建立與標準解除安裝腳本）。

---

## 📂 專案結構

```text
├── docs/                        # 架構規格、實作計畫與變更歷程
│   ├── implementation_plan/     # 功能與架構實作計畫
│   ├── spec/                    # 規格設計與 API 端點文檔
│   └── walkthrough/             # 歷次功能驗證與問題排除歷程
├── scripts/                     # 自動化建置與發行封裝腳本
│   └── build-installer.ps1      # 零機敏安全檢查閥門與單檔安裝器編譯腳本
├── src/                         # 應用程式核心原始碼
│   ├── CodexAccountSwitcher.ps1 # 主介面與帳號切換核心邏輯
│   ├── Launcher.cs              # 靜默無命令提示字元視窗之 C# 啟動器
│   ├── Installer.cs             # 自包含 GUI 安裝精靈原始碼
│   ├── Install.bat              # 免安裝版一鍵安裝捷徑腳本
│   └── Uninstall.bat            # 乾淨解除安裝腳本
├── tests/                       # 自動化測試套件
│   └── Run-SelfTest.ps1         # 核心邏輯自我驗證執行腳本
├── .env.example                 # 環境變數設定範本
├── .gitignore                   # 嚴格機敏資料過濾防護
├── docker-compose.yml           # 容器化審計與測試環境設定
└── README.md                    # 專案詳細說明
```

---

## 🚀 快速開始

### 方式一：使用 GUI 安裝程式（推薦）
1. 執行發行包中的 `Setup-CodexAccountSwitcher.exe`。
2. 預設安裝至 `%LOCALAPPDATA%\Programs\CodexAccountSwitcher`（不需系統管理員權限）。
3. 安裝完成後將自動在**桌面**與**開始功能表**建立「Codex 帳號切換」捷徑。

### 方式二：綠色免安裝版
1. 解壓縮 `CodexAccountSwitcher-v1.0.0-Portable.zip` 至任意資料夾。
2. 點擊 `Install.bat` 即可一鍵建立桌面捷徑；亦可直接點擊 `CodexAccountSwitcher.exe` 立即啟動。

---

## 📖 操作指引

### 1. 儲存目前第一個帳號
1. 確認 OpenAI Codex Desktop 已正常登入帳號 A。
2. 開啟「Codex 帳號切換」工具，輸入自訂名稱（例如：`工作帳號`），點擊「**儲存目前帳號**」。

### 2. 新增或授權第二個帳號（關鍵步驟）
1. 直接在工具內點擊「**引導登入新帳號**」。
2. 彈出對話框時點選「**是 (Y)**」選擇【裝置代碼安全模式 (`--device-auth`)】。
3. 工具會自動暫存目前環境並**自動開啟 Edge/Chrome 獨立無痕視窗**，同時在終端機顯示一次性 8 碼驗證代碼。
4. 於無痕視窗輸入該 8 碼代碼，登入帳號 B 並完成授權確認。
5. 授權完成後終端機自動關閉，工具捕獲新憑證並加密儲存。

### 3. 日常切換
1. 在清單中點選目標帳號。
2. 點擊「**切換並重新啟動**」，工具會自動關閉既有 Desktop、保存最新 Token、置換憑證並重啟應用。

---

## 🧪 自我驗證與測試

執行測試腳本可驗證加密、備份、Token 更新、原子置換與工作區保護（全數採合成資料測試，不讀寫真實憑證）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-SelfTest.ps1
```

---

## 🔒 資安宣告（Security Policy）

* 本專案遵循 **Zero-Credential Policy**，原始碼與版本控制歷史中**絕不包含**任何真實使用者權杖 (`auth.json`)、DPAPI 加密金鑰檔 (`*.bin`)、個人電子郵件或操作日誌 (`*.log`)。
* 本工具僅在使用者本機進行原子檔案置換，不架設中繼伺服器，不向任何第三方轉發未經授權的憑證。

---

## 📄 授權條款

MIT License.
