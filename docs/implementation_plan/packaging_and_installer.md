# Codex 帳號切換工具 - 安裝檔封裝與機敏隔離計畫 (Implementation Plan)

為使「Codex 帳號切換工具」能跨電腦分發並安全部署至其他 Windows 電腦，本計畫規劃自動化建置流程，產出**單一自包含 GUI 安裝程式 (`Setup-CodexAccountSwitcher.exe`)** 與**純淨免安裝發行包 (`Portable.zip`)**，並建立**嚴格的白名單安全閘門（Zero-Credential Security Gate）**，徹底杜絕本地 Token、DPAPI 加密檔與個人憑證被打包外洩的風險。

---

## User Review Required

> [!IMPORTANT]
> **安裝路徑與權限策略**：
> 預設採用現代 Windows 推薦的 **Per-User 安裝目錄**：`%LOCALAPPDATA%\Programs\CodexAccountSwitcher`。
> * **優勢**：無需系統管理員權限 (No UAC / Admin required)，不會受公司群組原則或權限受限阻擋，且每個 Windows 使用者帳號彼此隔離。
> * **捷徑**：自動在「桌面」與「開始功能表」建立 `Codex 帳號切換` 捷徑。

> [!CAUTION]
> **機敏資料絕對隔離（Zero-Credential Policy）**：
> * 本工具本機儲存之 `*.bin` (DPAPI 加密憑證)、`auth.json` (OpenAI 存取權杖)、`last-switch.rollback` (還原點) 以及 `switcher.log` (操作日誌) **一律不得納入發行包**。
> * 建置腳本內建「安全掃描檢查閥門」，若發現任何憑證或機敏副檔名特徵，建置將強制中斷。

---

## Proposed Changes

### 1. 安全建置與封裝腳本 (Build & Security Gate)

#### [NEW] `work/build-installer.ps1`
* **功能職責**：
  1. **預檢與機敏隔離掃描**：強制採用嚴格白名單（僅納入 `CodexAccountSwitcher.exe`、`CodexAccountSwitcher.ps1`、`使用說明.md`、`Launcher.cs`），掃描檢查是否有任何 JSON/BIN/LOG/Token 殘留。
  2. **封裝 Portable 發行包**：壓縮產生 `dist/CodexAccountSwitcher-v1.0.0-Portable.zip`，內建一鍵捷徑安裝與移除腳本 (`Install.bat`, `Uninstall.bat`)。
  3. **編譯單一自包含安裝程式**：使用 Windows 內建 `csc.exe` 編譯 `Installer.cs`，將純淨 Payload 內嵌至 `dist/Setup-CodexAccountSwitcher.exe`。
  4. **雜湊與完整性驗證**：產出 `dist/SHA256SUMS.txt` 供核對。

---

### 2. 自包含 Windows GUI 安裝程式 (Installer Engine)

#### [NEW] `work/Installer.cs`
* **功能職責**：
  * 使用 .NET Framework 4.8 WinForms 原生開發（相容 Win10/Win11，無外部依賴）。
  * 介面提供安裝目錄選擇（預設 `%LOCALAPPDATA%\Programs\CodexAccountSwitcher`）、建立桌面捷徑核取方塊、開始功能表捷徑核取方塊。
  * 支援 Windows「新增或移除程式 (Apps & Features)」登錄註冊，提供標準乾淨卸載功能。
  * 安裝結束提供「立即啟動 Codex 帳號切換器」按鈕。

---

### 3. 一鍵安裝/解除安裝輔助腳本 (Portable Package Scripts)

#### [NEW] `outputs/CodexAccountSwitcher/Install.bat`
* 免 GUI 的命令列安裝腳本，複製檔案至使用者目錄並建立桌面與開始功能表捷徑。

#### [NEW] `outputs/CodexAccountSwitcher/Uninstall.bat`
* 乾淨解除安裝腳本，移除程式目錄與捷徑，並詢問是否一併清理本機快照目錄 (`%LOCALAPPDATA%\CodexAccountSwitcher`)。

---

### 4. 規格與使用文件

#### [NEW] `docs/spec/installer_and_distribution.md`
* 記錄安裝程式架構、部署路徑、登錄檔規格與安全隔離審計機制。

#### [MODIFY] `outputs/CodexAccountSwitcher/使用說明.md`
* 增加跨電腦安裝與部署章節，說明在全新電腦上的第一次初始化設定。

---

## Verification Plan

### 1. 機敏資料隔離審核（Automated Security Verification）
* 解開產出的 `dist/CodexAccountSwitcher-v1.0.0-Portable.zip` 與反編譯檢查 `Setup-CodexAccountSwitcher.exe` 內嵌資源：
  * 確認無任何 `auth.json`、`*.bin`、`*.rollback`、`switcher.log`。
  * 執行正規表達式掃描（確認無 `refresh_token`, `access_token`, `sess-`, `Bearer ` 等特徵字串）。

### 2. 安裝與執行端到端測試（E2E Install & SelfTest）
* 執行安裝程序至模擬目標路徑：
  * 確認捷徑正常生成且圖示/目標指令正確。
  * 啟動安裝後的 `CodexAccountSwitcher.exe -SelfTest`，確認自動化測試 100% 通過。
* 執行解除安裝：
  * 確認捷徑與安裝目錄乾淨移除。
