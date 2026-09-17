# Codex 帳號切換工具 - Git 版控與機敏隔離審計結果 (Walkthrough)

本專案已完成 Git 版本控制初始化、嚴格的零機敏資料（Zero-Credential）審計，並完成首次標準乾淨提交（Commit `45d97f3`）。

---

## 一、機敏資料隔離審計結果

在提交前已執行多層深度掃描與去機敏化處理：
1. **黑名單副檔名排查**：已透過 `.gitignore` 嚴格排除 `auth.json`、`*.bin` (DPAPI 密文)、`*.rollback`、`*.log`、`work/` (反編譯代碼及快取) 與 `dist/` (發行二進位檔)。
2. **正則特徵掃描**：對所有即將納入版本庫之文檔與代碼進行深度掃描，確認無任何真實 Token (`Bearer `, `sess-`, `sk-`)、個人電子郵件或本機帳號標籤（掃描結果：**0 筆違規**）。
3. **歷史文檔示範化**：已將 `docs/` 內的真實測試信箱全數置換為示範佔位符（`account-a@example.com` / `account-b@example.com`）。

---

## 二、首版提交清單（Commit: `45d97f3`）

已納入版本控制之結構完整符合企業標準規範（含 `README.md`, `docker-compose.yml`, `.env.example`, `src/`, `tests/`, `docs/`）：

| 路徑 | 類型 | 說明 |
| :--- | :--- | :--- |
| `src/CodexAccountSwitcher.ps1` | 原始碼 | 核心帳號切換邏輯與 WinForms 介面 |
| `src/Launcher.cs` | 原始碼 | 靜默 C# 啟動器源代碼 |
| `src/Installer.cs` | 原始碼 | 自包含單檔 GUI 安裝精靈源代碼 |
| `src/Install.bat` | 腳本 | 免安裝版一鍵安裝腳本 |
| `src/Uninstall.bat` | 腳本 | 乾淨解除安裝腳本 |
| `scripts/build-installer.ps1` | 建置 | 自動化封裝與安全閘門檢查腳本 |
| `tests/Run-SelfTest.ps1` | 測試 | 自動化自我驗證測試套件 |
| `docs/spec/architecture.md` | 文檔 | 系統架構與安全邊界規格 |
| `docs/implementation_plan/*` | 文檔 | 歷史架構規劃紀錄 |
| `docs/walkthrough/*` | 文檔 | 故障排查與驗證歷程紀錄 |
| `.gitignore` | 設定 | 嚴格憑證與暫存防護規則 |
| `.env.example` | 設定 | 環境變數設定範本 |
| `docker-compose.yml` | 設定 | 審計與容器化測試配置 |
| `README.md` | 文檔 | 完整繁體中文專案說明與操作手冊 |

---

## 三、推送到 GitHub 步驟

本機 Git 儲存庫與 `main` 分支已完全就緒。請提供您的 GitHub 儲存庫 URL，或直接執行以下指令完成推送：

```powershell
# 1. 關聯您的遠端 GitHub 儲存庫
git remote add origin https://github.com/<您的使用者名稱或組織>/<儲存庫名稱>.git

# 2. 推送至 main 分支
git push -u origin main
```
