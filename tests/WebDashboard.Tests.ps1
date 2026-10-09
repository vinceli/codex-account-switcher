# WebDashboard.Tests.ps1 - 遠端 Web 儀表板與安全鎖定單元測試
$ErrorActionPreference = 'Stop'
$webScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\WebDashboard.ps1'

if (!(Test-Path -LiteralPath $webScript)) {
    throw "找不到 WebDashboard.ps1: $webScript"
}

. $webScript

function Check([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "測試失敗：$Message" }
}

$testPort = 18998
$testPin = '654321'
$hostKey = 'HOST_CURRENT_ACTIVE_KEY'

Write-Host "--- 測試 1: 啟動 Web 儀表板伺服器 ---" -ForegroundColor Cyan
$info = Start-WebDashboard -Port $testPort -Pin $testPin -HostActiveKey $hostKey
Check ($null -ne $info -and $info.Port -eq $testPort) "回傳伺服器資訊物件"
Check ($info.Pin -eq $testPin) "驗證碼設定正確"
Check ($script:WebDashboardInstance.IsRunning) "伺服器運行中"

try {
    Write-Host "--- 測試 2: 首頁 HTML 靜態路由 ---" -ForegroundColor Cyan
    $homePage = Invoke-WebRequest -Uri "http://127.0.0.1:$testPort/" -UseBasicParsing
    Check ($homePage.StatusCode -eq 200) "首頁 HTTP 200"
    Check ($homePage.Content.Contains('Codex')) "首頁包含 Codex 戰情室內容"

    Write-Host "--- 測試 3: 驗證碼防護 (PIN 鑑權) ---" -ForegroundColor Cyan
    $wrongFailed = $false
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/verify" -Method Post -Body (@{pin='000000'} | ConvertTo-Json) -ContentType 'application/json'
    } catch {
        $wrongFailed = ($_.Exception.Response.StatusCode.value__ -eq 401)
    }
    Check $wrongFailed "錯誤 PIN 被拒絕 (401 Unauthorized)"

    $auth = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/verify" -Method Post -Body (@{pin=$testPin} | ConvertTo-Json) -ContentType 'application/json'
    Check ($auth.success -and !([string]::IsNullOrEmpty($auth.token))) "正確 PIN 通過並核發 Token"
    $token = $auth.token

    Write-Host "--- 測試 4: 未授權存取受保護 API ---" -ForegroundColor Cyan
    $unauthBlocked = $false
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/status" -Method Get
    } catch {
        $unauthBlocked = ($_.Exception.Response.StatusCode.value__ -eq 401)
    }
    Check $unauthBlocked "未帶 Token 請求受保護端點被拒絕 (401)"

    $status = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/status" -Method Get -Headers @{'X-Session-Token'=$token}
    Check ($status.running -and $status.port -eq $testPort) "帶 Token 存取狀態成功"

    Write-Host "--- 測試 5: 帳號清單與主機鎖定標記 ---" -ForegroundColor Cyan
    $mockList = @(
        [pscustomobject]@{
            Key = $hostKey
            Name = '主機執勤中帳號'
            Email = 'active@host.invalid'
            Plan = 'Team'
            Primary = '85% (14:00)'
            Secondary = '90% (6.5d)'
            PrimaryRemaining = 85
            SecondaryRemaining = 90
            Saved = '2026-10-05 10:00'
            Bytes = [Text.Encoding]::UTF8.GetBytes('{"tokens":{"access_token":"token_active"}}')
        },
        [pscustomobject]@{
            Key = 'SECONDARY_STANDBY_KEY'
            Name = '副機備份帳號 B'
            Email = 'standby@host.invalid'
            Plan = 'Plus'
            Primary = '60% (15:00)'
            Secondary = '75% (5.0d)'
            PrimaryRemaining = 60
            SecondaryRemaining = 75
            Saved = '2026-10-05 09:00'
            Bytes = [Text.Encoding]::UTF8.GetBytes('{"tokens":{"access_token":"token_standby"}}')
        }
    )
    Update-WebDashboardState -HostActiveKey $hostKey -AccountsList $mockList

    $accounts = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/accounts" -Headers @{'X-Session-Token'=$token}
    Check ($accounts.Count -eq 2) "帳號數量正確 (2 個)"

    $accActive = $accounts | Where-Object { $_.key -eq $hostKey }
    $accStandby = $accounts | Where-Object { $_.key -eq 'SECONDARY_STANDBY_KEY' }

    Check ($accActive.is_host_active -eq $true) "主機執勤帳號標記 is_host_active = true"
    Check ($accActive.locked -eq $true) "主機執勤帳號標記 locked = true"
    Check (![string]::IsNullOrEmpty($accActive.lock_reason)) "主機執勤帳號包含鎖定原因"
    Check ($accStandby.is_host_active -eq $false -and $accStandby.locked -eq $false) "非主機帳號 locked = false"

    Write-Host "--- 測試 6: 防衝突鎖定攔截 (關鍵安全測試) ---" -ForegroundColor Cyan
    $collisionBlocked = $false
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/switch-remote" -Method Post -Headers @{'X-Session-Token'=$token} -Body (@{target_key=$hostKey} | ConvertTo-Json) -ContentType 'application/json'
    } catch {
        $collisionBlocked = ($_.Exception.Response.StatusCode.value__ -eq 403)
    }
    Check $collisionBlocked "副機試圖切換主機使用中帳號被強制攔截 (403 Forbidden)"

    Write-Host "--- 測試 7: 非主機帳號安全派送流程 ---" -ForegroundColor Cyan
    [CodexSwitcher.Web.DashboardServer]::MockPushForTesting = $true
    [CodexSwitcher.Web.DashboardServer]::LastPushedBytes = $null

    $pushRes = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/switch-remote" -Method Post -Headers @{'X-Session-Token'=$token} -Body (@{target_key='SECONDARY_STANDBY_KEY'; remote_host='192.168.1.195'; remote_user='vince'} | ConvertTo-Json) -ContentType 'application/json'
    Check ($pushRes.success -eq $true) "副機切換未鎖定帳號放行成功 (200 OK)"
    Check ($null -ne [CodexSwitcher.Web.DashboardServer]::LastPushedBytes) "成功交付憑證位元組"
    $deliveredStr = [Text.Encoding]::UTF8.GetString([CodexSwitcher.Web.DashboardServer]::LastPushedBytes)
    Check ($deliveredStr.Contains('token_standby')) "交付正確的目標帳號憑證"
    Check ([CodexSwitcher.Web.DashboardServer]::LastPushedHost -eq '192.168.1.195') "目標副機 IP 正確"
    Check ([CodexSwitcher.Web.DashboardServer]::LastPushedUser -eq 'vince') "目標副機使用者名稱正確"

    Write-Host "PASS: 遠端 Web 儀表板、PIN 驗證、主機帳號鎖定防衝突、API 鑑權與安全推送測試全數通過！" -ForegroundColor Green
} finally {
    Stop-WebDashboard
    [CodexSwitcher.Web.DashboardServer]::MockPushForTesting = $false
}
