# Codex 帳號切換工具 - 帳號額度（5h / 每週）查詢與顯示計畫 (Implementation Plan)

為滿足使用者在開啟應用時一併掌握各帳號剩餘額度（5 小時滾動上限與每週配額）的需求，本計畫規劃串接 OpenAI Codex 底層之配額查詢端點，並於切換器主畫面以直觀的剩餘百分比與重置倒數進行呈現。

---

## [需要架構決策]

串接 OpenAI 未公開之內部使用量 API (`https://chatgpt.com/backend-api/wham/usage`) 涉及外部網路連線與 Token 生命週期管理，提供以下兩種方案評估：

| 評估維度 | 方案 A：非同步背景查詢 + 自動 Token 換發（推薦） | 方案 B：啟動時輕量同步查詢 |
| :--- | :--- | :--- |
| **介面流暢度** | **極佳**：視窗立即秒開，額度欄位先顯示「查詢中…」，查詢完畢即時非同步填入。 | **一般**：若有 2~3 個帳號且網路延遲，開啟時可能停頓 0.5~1.5 秒。 |
| **Token 逾期容錯** | **具自我修復能力**：遇 401 逾期時，自動透過 `refresh_token` 換發新 `access_token` 並更新加密備份。 | **僅顯示逾期**：遇 401 標記「憑證逾期」，需待使用者切換或重新授權。 |
| **離線與超時防護** | **強**：背景逾時 3 秒自動結束，完全不影響離線時的切換作業。 | **普通**：若完全無網路，需等待各帳號逾時才會顯示視窗。 |
| **架構複雜度** | 需加入 PowerShell Background Runspace 或非同步定時調度。 | 程式碼異動範圍極小，循序呼叫。 |

> [!IMPORTANT]
> **架構建議**：採 **方案 A**。因多帳號切換器的核心職責是「迅速、可靠地切換程序」，額度查詢屬輔助感知資訊，絕不可因外部 API 延遲阻礙主視窗開啟或導致介面凍結；同時具備自動 Token 展期才能確保長期放置的備份帳號能持續成功讀取額度。

---

## User Review Required

> [!NOTE]
> **API 端點規格已實測驗證通過**：
> 經本地實測發送 Bearer Token 至 `https://chatgpt.com/backend-api/wham/usage`：
> * **5 小時窗口 (`primary_window`)**：包含 `used_percent`（使用百分比）與 `reset_after_seconds`（重置秒數）。
> * **每週窗口 (`secondary_window`)**：包含 `used_percent` 與 `reset_after_seconds`。
> * **方案別 (`plan_type`)**：可直接識別出 `team`、`plus`、`pro`。

---

## Proposed Changes

### 1. 核心查詢與 Token 自動展期模組 (Query & Refresh Logic)

#### [MODIFY] `outputs/CodexAccountSwitcher/CodexAccountSwitcher.ps1`
* **新增 `Get-AccountQuota` 函式**：
  * 傳入已解密之 `auth.json` 資料。
  * 呼叫 `GET https://chatgpt.com/backend-api/wham/usage`。
  * 若回傳 401，自動使用 `refresh_token` 呼叫 `POST https://auth.openai.com/oauth/token`（Client ID: `app_EMoamEEZ73f0CkXaXp7hrann`）換發新 Token，自動回寫更新 `.bin` 加密備份，並重試查詢。
  * 回傳物件：`@{ Plan; PrimaryUsed; PrimaryRemaining; PrimaryResetSec; SecondaryUsed; SecondaryRemaining; SecondaryResetSec; Status }`。
* **調整清單控制項 (ListView Layout)**：
  * 視窗寬度適度微調（由 740 擴展至 860，提供充裕顯示空間）。
  * 清單欄位調整為：
    1. 名稱 (110 px)
    2. 帳號 (180 px)
    3. 方案 (60 px，例如 team/plus)
    4. 5h 剩餘 (140 px，例如 `78% (3h8m)`)
    5. 每週剩餘 (140 px，例如 `84% (6.8d)`)
    6. 狀態 (65 px，目前/空白)
    7. 備份時間 (140 px)
* **開啟與重新整理觸發 (Trigger on Launch)**：
  * 開啟視窗時在背景（或首輪）啟動查詢一次。
  * 點擊「重新整理」按鈕時亦同步重整最新額度。

---

### 2. 封裝與安裝發行檔同步

#### [MODIFY] `work/build-installer.ps1`
* 執行自動化建置，同步更新：
  * `dist/Setup-CodexAccountSwitcher.exe`
  * `dist/CodexAccountSwitcher-v1.0.0-Portable.zip`
  * `dist/SHA256SUMS.txt`

#### [MODIFY] `outputs/CodexAccountSwitcher/使用說明.md`
* 增加「額度查詢與重置倒數說明」章節。

---

## Verification Plan

### 1. 額度查詢與解析測試
* 針對現有的已儲存帳號（例如：`account-a@example.com` 與 `account-b@example.com`）執行配額查詢：
  * 驗證 5h 剩餘與重置時間格式化（例如：`0% (2h 19m)`、`78% (3h 8m)`）。
  * 驗證每週剩餘與重置時間格式化（例如：`84% (6.8d)`、`0% (2.1d)`）。

### 2. 介面視覺與流暢度驗證
* 啟動 GUI 介面，確認清單欄位對齊正確、文字無截斷、視窗開啟不卡死。
* 執行 `-SelfTest` 確認所有回歸測試與安全邊界無虞。

### 3. 安裝包重構與純淨度審計
* 重新建置發行包，確認新版 `Setup.exe` 與 `Portable.zip` 正常產出且 0 憑證洩漏。
