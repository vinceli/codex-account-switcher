# 變更記錄：視窗圖示與工作列圖示一致性修正

## 1. 變更背景與目標
先前工具在桌面捷徑使用 Windows 系統金鑰匙圖示（`shell32.dll, 44`），但程式執行時視窗左上角及 Windows 工作列顯示為預設白底藍窗圖示或通用終端機圖示。
本次變更讓：
- **程式視窗左上角圖示**
- **Windows 工作列圖示**
- **Alt-Tab 切換圖示**
- **所有子對話框**
- **可執行檔與安裝檔實體**
全面與桌面快捷圖示（金鑰匙）保持一致。

---

## 2. 異動內容摘要

### 2.1 原生圖示資產 (`src/app.ico`)
- 從 Windows 系統 `shell32.dll, 44` 提取 16x16, 20x20, 24x24, 32x32, 40x40, 48x48, 64x64, 96x96, 128x128, 256x256 全尺寸圖標，建構為標準多解析度 `src/app.ico` 納入版控。

### 2.2 表單與工作列圖示綁定 (`src/CodexAccountSwitcher.ps1`)
- **AppUserModelID 註冊**：新增 `[NativeGuiHelper]::SetCurrentProcessExplicitAppUserModelID('CodexTools.CodexAntigravitySwitcher')`，讓 Windows 11 工作列將工具辨識為獨立應用，並顯示視窗自訂圖標而非 PowerShell 圖標。
- **雙重載入機制**：實作 `Get-ApplicationIcon`，優先讀取本機 `app.ico`，缺失時自動備援回退至 `shell32.dll, 44` 原生提取，確保任何啟動模式皆有圖示。
- **視窗與訊息綁定**：主視窗設定 `$form.Icon`，並在 HandleCreated 時發送 Win32 `WM_SETICON`（大圖示與小圖示），確保留存最高清晰度。
- **對話框繼承**：`Prompt-AccountName` 對話框同步繼承主視窗圖示。

### 2.3 啟動器與建置腳本 (`src/Launcher.cs`, `scripts/build-installer.ps1`, `src/Installer.cs`, `src/Install.bat`)
- `scripts/build-installer.ps1`：編譯 `CodexAccountSwitcher.exe` 與自包含安裝程式時內嵌 `/win32icon:"src\app.ico"`，並將 `app.ico` 納入打包白名單。
- `src/Install.bat` 與 `src/Installer.cs`：檔案複製清單納入 `app.ico`，捷徑圖示優先使用安裝目錄下的 `app.ico`。
- 本機環境部署：已同步更新 `C:\Users\vince\AppData\Local\Programs\CodexAntigravitySwitcher` 檔案與桌面捷徑。

---

## 3. 驗證結果

1. **圖示完整性與多尺寸檢查**：
   - `src/app.ico` 包含 16px 至 256px 共 10 個 frame，於各 DPI 縮放下均能清晰呈現。
2. **核心自我測試 (`tests/Run-SelfTest.ps1`)**：
   - 包含圖示解析檢查在內之所有密碼學儲存、還原、額度快照測試 100% 通過。
3. **介面渲染測試**：
   - 產出實體視窗截圖，視窗標題列左上角清楚呈現金鑰匙圖示。
4. **本機啟動器驗證**：
   - `CodexAccountSwitcher.exe` 本體與安裝檔均已成功內嵌金鑰匙圖示。
