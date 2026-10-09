# Codex 智慧啟動與介面排版修復記錄 (Walkthrough)

## 1. 任務背景與問題現象

使用者回報兩項核心問題與改善需求：
1. **按鈕排版異常與卡住**：
   - Codex 主分頁右上角按鈕重疊錯亂（`切換公會戰情室 (Guild)` 與 `遠端副機 / Web` 座標衝突重疊）。
   - WinForms GDI 在繁體中文環境（CP950）下無法渲染 SMP emoji（如 🌐），顯示為豆腐方框 `[]`。
   - 生成預覽截圖時因 `$PreviewPath` 條件式判斷缺陷，若僅指定 `-PreviewWebPath` 會落入 `ShowDialog()` 阻塞。
2. **Codex 尚未啟動時的操作體驗優化**：
   - 原先在 Codex 尚未啟動的狀態下，使用者點擊「切換並重新啟動」若選取當前 active 帳號，會被卡控阻擋並跳出「目前已是這個帳號；請使用『儲存目前帳號』更新備份」。
   - 使用者期望：若偵測到 Codex 尚未啟動，點擊切換並重新啟動時應直接以所選帳號權限啟動 Codex，不卡控是否為同一帳號，亦不跳出中斷任務之非必要警告。

---

## 2. 修改內容與實作方案

### 2.1 右上角按鈕衝突與字型渲染修復
- **移除重複快速按鈕**：頂部 TabControl 已具備「遠端副機 (Web)」分頁，移除右上角重複且座標碰撞的 `$webQuick` 按鈕。
- **文字全面標準化**：將按鈕與群組文字中的 SMP emoji 移除，改為標準繁體中文（如 `[鎖定保護]`、`在瀏覽器開啟`、`測試副機 SSH 連線`），確保在任何 Windows 系統下皆 100% 正常渲染無破字。
- **修正預覽模式條件式**：將預覽判定改為 `$isPreviewMode = [bool]($PreviewPath -or $PreviewAntigravityPath -or $PreviewGuildPath -or $PreviewGuildAGPath -or $PreviewWebPath)`，徹底解決單獨呼叫 `-PreviewWebPath` 時被 `ShowDialog()` 阻塞的問題。

### 2.2 Codex 尚未啟動之智慧直接啟動邏輯
修改 `src/CodexAccountSwitcher.ps1` 中的 `Switch-Account` 函式：
```powershell
$runningProcesses = @(Get-DesktopProcesses $app)
$codexExeProcesses = @(Get-Process -Name codex -ErrorAction SilentlyContinue)
$isDesktopRunning = ($runningProcesses.Count -gt 0) -or ($codexExeProcesses.Count -gt 0)
```
- **分支 A（Codex 執行中）**：
  - 若選擇同一帳號且非 rollback：卡控阻擋 `throw '目前已是這個帳號；請使用「儲存目前帳號」更新備份。'`。
  - 若切換帳號：跳出「執行中的任務會中斷」警告視窗，確認後終止 Codex、更新憑證、重啟 Codex。
- **分支 B（Codex 尚未啟動）**：
  - **解除同一帳號卡控**：即使目標帳號與目前 `auth.json` 相同，亦不拋出錯誤。
  - **直接啟動**：若帳號不同則原子套用選擇之憑證；若帳號相同則直接調用 `Start-Desktop $app`，不跳出任務中斷警告，流暢啟動 Codex。

---

## 3. 測試與驗證結果

1. **核心邏輯自我驗證（SelfTest）**：
   - 執行 `powershell -ExecutionPolicy Bypass -File tests\Run-SelfTest.ps1`
   - 全數通過：核心加解密、備份繼承、Antigravity Quota、公會戰情室對話方塊、Web 儀表板 7 項整合測試全數 `PASS`。
2. **介面預覽圖驗證**：
   - `preview_codex.png`：右上角按鈕整齊無重疊，經典佈局乾淨俐落。
   - `preview_web.png`：1 秒內生成完畢，無阻塞，控制項文字無豆腐塊缺字。
3. **打包發布檢查**：
   - 執行 `scripts\build-installer.ps1`，成功編譯最新 `CodexAccountSwitcher.exe` 並產出 `dist/` 免安裝 zip 與單檔安裝包。
