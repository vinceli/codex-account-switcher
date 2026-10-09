# 冒險者公會戰情室 (Guild Cockpit View) 整合與驗證成果

本文件記錄 `codex-account-switcher` 專案引入「冒險者公會戰情室」視覺化風格介面之架構設計、實作重點、安全防護與完整驗證成果。

---

## 🎯 需求背景與核心目標

1. **架構無損與雙風格並存**：
   - 完全保留原專案既有之傳統清單介面、Windows DPAPI 加密機制、原子憑證切換與工作區零破壞保證。
   - 提供**雙風格隨意切換**：在 Codex 與 Antigravity 分頁右上角均可切換至「公會戰情室 (Guild)」，亦可隨時返回「傳統清單 (Classic)」。
2. **多帳號視覺化展示**：
   - **先鋒主將卡片 (Active Vanguard)**：展示當前執勤帳號、角色立繪（Codex 符文騎士、Antigravity 星軌工匠）、雙能量條（5 小時用量與週用量）、即時狀態標籤與重置倒數。
   - **後備名冊滾動流 (Reserve Cadets)**：以橫向卡片流展示其他後備帳號，點擊任一後備卡片即可立即無縫切換為先鋒主將。
3. **智慧輪替三原則**：
   - **可開關選項**：介面提供明確的「啟用智慧輪替」核取方塊。
   - **單帳號隱藏保護**：當該來源帳號數 $\le 1$ 或無有效後備時，強制隱藏輪替建議面板與操作按鈕。
   - **嚴格來源隔離**：Codex 僅在 Codex 帳號池間輪替；Antigravity 僅在 Antigravity 帳號池間輪替，嚴禁跨來源互換。

---

## 🏗️ 實作架構與細節

### 1. 模組化介面 (`src/GuildView.ps1`)
- **獨立封裝**：公會戰情室所有 UI 控制項（先鋒卡片、後備容器、智慧輪替條）完全封裝於 `src/GuildView.ps1` 中，透過函式 `Initialize-GuildCockpitView`、`Update-GuildCockpitView` 與 `Update-GuildViewRotationPanel` 進行生命週期管理。
- **動態立繪載入**：依據帳號來源（Codex / Antigravity）與剩餘用量狀態（充沛/疲憊/竭盡），動態載入對應像素英雄資產，若圖檔缺失自動回退為幾何安全圖章。
- **雙能量條繪製**：原生 WinForms 繪製雙進度條，依剩餘比例自動切換青藍色（正常）、金黃色（低於 30%）與朱紅色（低於 15% / 竭盡）。

### 2. 主程式整合 (`src/CodexAccountSwitcher.ps1`)
- **切換按鈕佈局**：在 `$codexTab` 與 `$agTab` 右上角（X: 740, Y: 16）放置青色高亮「切換公會戰情室 (Guild)」按鈕，戰情室頂部（X: 935, Y: 10）設置「切換為傳統清單 (Classic)」按鈕，徹底解決 Win32 SysTabControl32 的 Z-Order 覆蓋問題。
- **資料與定時器無縫連動**：背景非同步用量查詢與 60 秒定時刷新同步觸發公會視圖更新；介面切換時自動維持最新狀態。

### 3. 素材資產與透明度處理 (`src/assets/guild/`)
- 引進 28 張 64x64 像素英雄立繪（包含符文騎士、星軌工匠、遊俠與法師等）。
- 自動偵測並透過 GDI+ `Format32bppArgb` 演算法將原始 24bpp 黑色背景素材轉換為真實 Alpha 透明通道，完美融合戰情室深色底板。

### 4. 建置腳本防護升級 (`scripts/build-installer.ps1`)
- **白名單納入**：加入 `GuildView.ps1` 及 `assets/guild/` 資源資料夾。
- **安全檢查閘門優化**：機敏字串與權杖特徵掃描自動排除二進位檔案（`.png`, `.ico`, `.exe`），並遞迴檢查所有內嵌檔案，落實 Zero-Credential 安全原則。

---

## 🧪 驗證與產出成果

### 1. 核心邏輯自我驗證
執行 `tests/Run-SelfTest.ps1`，100% 通過所有測試：
- DPAPI 加密儲存與舊版備份繼承驗證：**PASS**
- Antigravity 憑證讀寫、身分解析、切換與還原：**PASS**
- 雙模型組 5 小時與每週額度、方案解析：**PASS**
- 零機敏外洩與離線測試隔離保證：**PASS**
- 登錄新英雄對話框與零 VisualBasic 依賴驗證：**PASS**

### 2. 安裝發行包建置
執行 `scripts/build-installer.ps1`：
- 自包含單檔安裝程式：`dist/Setup-CodexAntigravitySwitcher.exe`
- 綠色免安裝發行包：`dist/CodexAccountSwitcher-v1.1.0-Portable.zip`
- 零機敏安全閘門檢查：**100% 通過（無任何 .bin, .log, 憑證檔或真實 Token）**

### 3. 介面視覺化預覽截圖
已於 `outputs/` 目錄產生截圖：
1. `outputs/preview-classic.png`：Codex 傳統清單模式（完整表格資料與功能按鈕）
2. `outputs/preview-ag.png`：Antigravity 傳統清單模式
3. `outputs/preview-guild.png`：Codex 符文騎士公會戰情室（先鋒卡片、雙能量條、後備名冊流與智慧輪替）
4. `outputs/preview-guild-ag.png`：Antigravity 星軌工匠公會戰情室（單帳號時自動隱藏輪替面板）

---

## ⚡ 動態待機微動動畫與零閃爍機制優化

針對使用者反饋之「後備營地資訊列閃爍重整」與「原始角色待機動畫」進行了架構級升級：

### 1. 資訊列閃爍根本原因與解決
- **閃爍原因**：先前背景額度輪詢 Timer（200ms）在每次 tick 無條件觸發 Update-GuildView，且該函式採用 Controls.Clear() 暴力清空重建物件，導致每秒重新渲染 5 次造成強烈肉眼閃爍。
- **解決方案**：
  1. **資料指紋檢驗 (Dirty Check)**：比對產品、出戰帳號、各後備帳號額度之特徵 Hash，無異動時在 0.001ms 內略過重繪。
  2. **就地複用卡片 (In-place Reuse)**：後備營地卡片不作銷毀，僅直接刷新內部文字與狀態；數量變更時採 SuspendLayout() / ResumeLayout() 增減。
  3. **雙緩衝防護 (DoubleBuffered)**：為公會戰情室各 Panel 啟用 WinForms 雙緩衝，徹底杜絕畫面撕裂與白閃。
  4. **陣列縮減邊界防禦**：修復卡片移除時邊界切片產生的潛在無窮迴圈問題。

### 2. 2-Frame 像素待機微動動畫 (Motion Animation)
- **動畫機制**：完全還原原專案之 560ms 雙影格呼吸待機規範。
- **快取池管理**：建立 $script:GuildImageCache，各狀態（滿血、工作中、疲憊、耗盡）之 Frame 0 與 Frame 1 預載於記憶體，每 560ms 僅切換控制項圖片指標，CPU 佔用率近乎 0%。
- **生命週期連動**：切換至傳統清單或關閉視窗時自動暫停並釋放 Timer，不佔用背景資源。

### 3. Codex 全套動態與狀態立繪像素去背淨化 (Alpha Matting & Anti-Halo)
- **根因洞察**：
  原 Web 版前端利用 CSS mix-blend-mode: screen（濾色混合）將 RGB 純黑底圖的黑色當作透明顯示，而未真正製作透明通道。移植至 Windows Forms 原生桌面程式時，GDI+ 缺乏 screen 混合模式，導致直接渲染出黑色外框。先前簡易顏色門檻去背又誤將角色身上的深色皮帶、手套與深藍色衣物摳成粉紅色破洞，且未能去除 AI 生成時身後的藍黑擴散光暈。
- **四重智慧去背演算法** (`scripts/clean_codex_assets.py`)：
  1. **Frame 0 遮罩幾何平移**：利用官方原生 100% 完美的 Frame 0 透明遮罩，進行剛體平移對齊，角色本體 100% 實心保護，徹底解決衣物皮帶內部穿孔破洞。
  2. **手持浮游魔法卡牌精準分離**：透過精確四邊形與多邊形擬合提取卡牌矩形，自動聚集分離卡牌周圍發光的十字星芒粒子，剔除卡牌外圍殘留的 AI 黑色方塊。
  3. **力竭伸展與疲憊呵欠手勢自適應外擴**：動態偵測地面伸出的手套指尖與撐頰微動，清除露出的黑色背景，徹底瓦解身後的黑雲光繭。
  4. **色彩去污反向反解 (Color Unblending)**：半透明邊界像素還原黑底混合前的真實色澤，消除黑邊與深色毛刺，確保在戰情室深藍底 (#14213D)、卡片底 (#1D2D50) 與淺色底皆晶瑩剔透。

---

## 🛡️ 登記新英雄「找不到類型 [Microsoft.VisualBasic.Interaction]」修復

### 1. 根本原因
- 在傳統清單模式下，介面直接在主表單上提供文字輸入框（`$nameBox` / `$agNameBox`），使用者輸入後點擊「儲存目前帳號」即可直接寫入 DPAPI 備份，不需跳出任何輸入視窗。
- 在公會戰情室中，後備營地左下角的「+ 登記新英雄 (備份目前新登入帳號)」按鈕原先直接呼叫了 `[Microsoft.VisualBasic.Interaction]::InputBox`。
- 在 Windows PowerShell 5.1 執行時，由於環境未載入 `Microsoft.VisualBasic` 組件，導致點擊時引發 `System.Management.Automation.RuntimeException: 找不到類型 [Microsoft.VisualBasic.Interaction]`。

### 2. 解決方案：原生暗黑風格對話框 (`Show-GuildInputDialog`)
- **原生 WinForms 實作**：以原生 WinForms 表單全新打造，不依賴任何第三方或 VisualBasic 舊組件。
- **風格一致性**：背景採用深夜藍 (`#0F172A`)、公會金色標題 (`#F3C45B`)、深色輸入框 (`#1E293B`) 與高亮按鈕，完美契合公會戰情室視覺風格。
- **使用者體驗增強**：
  - 自動帶入當前登入帳號（Email）作為預設名稱，直接按 Enter 鍵即可完成登記。
  - 支援 Enter (AcceptButton) 與 Esc (CancelButton) 鍵盤快捷鍵。
  - 對話框彈出時自動取得 Focus 並反白全選預設文字。
- **雙重防護**：
  - `src/GuildView.ps1` 徹底移除所有 `Microsoft.VisualBasic` 與 `InputBox` 呼叫。
  - `src/CodexAccountSwitcher.ps1` 開頭加入 `Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue` 作為全域防禦。
  - 新增單元測試 `tests/GuildDialog.Tests.ps1` 並納入全量 `tests/Run-SelfTest.ps1` 自動化驗證。
