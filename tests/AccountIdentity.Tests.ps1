$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Security
$sourceRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'CodexAccountSwitcher.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '主程式語法錯誤' }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
$script:Utf8 = New-Object Text.UTF8Encoding($true)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('AccountIdentityTest-' + [guid]::NewGuid().ToString('N'))
$script:StorePath = Join-Path $sandbox 'backups'
$script:CodexPath = Join-Path $sandbox 'codex'
$script:AuthPath = Join-Path $script:CodexPath 'auth.json'
$script:LogPath = Join-Path $script:StorePath 'switcher.log'
. (Join-Path $sourceRoot 'AntigravityCredential.ps1')
. (Join-Path $sourceRoot 'CodexBilling.ps1')
Initialize-AGCredential

function Check([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw ('測試失敗：' + $Message) }
}
function New-TestAuth([string]$Subject, [string]$Email, [string]$Workspace, [string]$Token, [switch]$Antigravity) {
    $claims = @{ sub=$Subject; email=$Email } | ConvertTo-Json -Compress
    $jwt = 'test.' + [Convert]::ToBase64String($script:Utf8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.test'
    if ($Antigravity) {
        $auth = @{ id_token=$jwt; auth_method='oauth'; token=@{ access_token=$Token; refresh_token=('refresh-' + $Token) } }
    } else {
        $auth = @{ auth_mode='chatgpt'; tokens=@{ id_token=$jwt; account_id=$Workspace; access_token=$Token; refresh_token=('refresh-' + $Token) } }
    }
    return ,$script:Utf8.GetBytes(($auth | ConvertTo-Json -Depth 4 -Compress))
}
function Write-TestBackup([byte[]]$Bytes, [string]$Name, [string]$Saved, [switch]$Antigravity, [switch]$Canonical) {
    $identity = if ($Antigravity) { Get-AGIdentity $Bytes } else { Get-Identity $Bytes }
    $key = if ($Canonical) { $identity.Key } else { $identity.LegacyKey }
    $record = @{ Name=$Name; Key=$key; Saved=$Saved }
    $store = if ($Antigravity) { $script:AGStorePath } else { $script:StorePath }
    if ($Antigravity) {
        $record.Blob = [Convert]::ToBase64String($Bytes)
        $record.UserName = 'antigravity'; $record.Persist = 2
    } else { $record.Auth = [Convert]::ToBase64String($Bytes) }
    $path = Join-Path $store ($key + '.bin')
    $cipher = [Security.Cryptography.ProtectedData]::Protect($script:Utf8.GetBytes(($record | ConvertTo-Json -Compress)), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-Atomic $path $cipher
    return $path
}
function Stop-QuotaQueries {}
function Stop-AGQuotaQueries {}
$realStartQuotaQuery = ${function:Start-QuotaQuery}
function Start-QuotaQuery([byte[]]$Bytes, [string]$Key) {
    $script:CodexRequests += [pscustomobject]@{ Bytes=$Bytes; Key=$Key }
}
function Start-AGQuotaQuery([byte[]]$Bytes, [string]$Key) {
    $script:AGRequests += [pscustomobject]@{ Bytes=$Bytes; Key=$Key }
}
function Update-WebDashboardState([string]$HostActiveKey, [string]$RemoteHost, [string]$RemoteUser, [object[]]$AccountsList) {
    $script:WebSnapshot = [pscustomobject]@{ HostKey=$HostActiveKey; Accounts=$AccountsList }
}

$list = New-Object Windows.Forms.ListView
$apiList = New-Object Windows.Forms.ListView
$agList = New-Object Windows.Forms.ListView
$currentLabel = New-Object Windows.Forms.Label
$agCurrentLabel = New-Object Windows.Forms.Label
$nameBox = New-Object Windows.Forms.TextBox
$agNameBox = New-Object Windows.Forms.TextBox
$lastQueryLabel = New-Object Windows.Forms.Label
$agLastQueryLabel = New-Object Windows.Forms.Label
$status = New-Object Windows.Forms.Label
$agStatus = New-Object Windows.Forms.Label
$script:WebDashboardInstance = [pscustomobject]@{ IsRunning=$true }
$script:QuotaJobs = @(); $script:AGQuotaJobs = @()

try {
    $old = New-TestAuth 'session-old' 'Member@example.invalid' 'team-shared' 'old-token'
    $latest = New-TestAuth 'session-new' ' member@EXAMPLE.invalid ' 'team-shared' 'latest-token'
    $other = New-TestAuth 'session-other' 'other@example.invalid' 'team-shared' 'other-token'
    $current = New-TestAuth 'session-current' 'member@example.invalid' 'team-shared' 'current-token'
    Check ((Get-Identity $old).Key -eq (Get-Identity $latest).Key) '同帳號重新登入、大小寫及前後空白使用相同識別'
    Check ((Get-Identity $old).Key -ne (Get-Identity $other).Key) '同工作區的不同電子郵件保持獨立'
    $otherWorkspace = New-TestAuth 'session-current' 'member@example.invalid' 'another-team' 'workspace-token'
    Check ((Get-Identity $current).Key -eq (Get-Identity $otherWorkspace).Key) '同帳號切換工作區不新增資料列'
    $unknownA = New-TestAuth 'unknown-A' '' 'team-shared' 'unknown-A'
    $unknownB = New-TestAuth 'unknown-B' '' 'team-shared' 'unknown-B'
    Check ((Get-Identity $unknownA).Key -ne (Get-Identity $unknownB).Key) '缺少電子郵件的身分不互相合併'

    $oldPath = Write-TestBackup $old '原本名稱' '2026-01-01 10:00:00'
    $latestPath = Write-TestBackup $latest '最新名稱' '2026-01-02 10:00:00'
    Check ((Read-Backup $oldPath).StoredKey -eq (Get-Identity $old).LegacyKey) '舊版加密備份仍驗證原識別'
    Write-Atomic (Join-Path $script:StorePath 'broken.bin') $script:Utf8.GetBytes('invalid')
    $bad = 0
    $records = @(Get-AccountBackups -BadCount ([ref]$bad))
    Check ($records.Count -eq 1 -and $records[0].Name -eq '最新名稱' -and $bad -eq 1) '既有重複資料取最後儲存且保留損壞檔計數'
    Check ((Test-Path -LiteralPath $oldPath) -and (Test-Path -LiteralPath $latestPath)) '去重不刪除舊備份原檔'

    $script:CodexRequests = @()
    Write-Atomic $script:AuthPath $current
    Refresh-Accounts
    Check ($list.Items.Count -eq 1 -and $script:CodexRequests.Count -eq 1) '傳統清單與額度每個帳號只有一筆'
    Check ($list.Items[0].Text -eq (Get-Identity $current).Email -and $list.Items[0].SubItems.Count -eq 7) 'Codex 清單只顯示帳號，不重複顯示備份名稱'
    Check ($list.Items[0].SubItems[4].Text -eq '目前') '登入身分改變仍正確標記目前帳號'
    Check ([Convert]::ToBase64String($script:CodexRequests[0].Bytes) -eq [Convert]::ToBase64String($current)) '目前帳號查詢使用即時登入憑證'
    Check ($script:WebSnapshot.Accounts.Count -eq 1 -and $script:WebSnapshot.Accounts[0].Key -eq $script:WebSnapshot.HostKey) 'Web 清單與主機鎖定共用唯一識別'
    $list.Items.Clear()
    Sync-WebDashboardAccounts
    Check ($script:WebSnapshot.Accounts.Count -eq 1 -and $script:WebSnapshot.Accounts[0].Name -eq (Get-Identity $current).Email) 'Web 無 UI 清單時仍取得唯一且最新帳號'

    Backup-Current (Read-Current) ''
    $canonicalPath = Join-Path $script:StorePath ((Get-Identity $current).Key + '.bin')
    Check ((Read-Backup $canonicalPath).Name -eq '最新名稱') '自動備份保留舊版帳號的自訂名稱'
    $canonicalBefore = @(Get-ChildItem -LiteralPath $script:StorePath -Filter '*.bin' -File).Count
    Save-Backup $latest '重新登入後更新' ''
    Check (@(Get-ChildItem -LiteralPath $script:StorePath -Filter '*.bin' -File).Count -eq $canonicalBefore) '重新登入只更新相同備份路徑'
    Check ((@(Get-AccountBackups)).Count -eq 1 -and (Get-AccountBackups).Name -eq '重新登入後更新') '儲存後仍只有一筆帳號資料'
    $tiePath = Write-TestBackup $old '舊版同秒備份' (Read-Backup $canonicalPath).Saved
    Check ((Get-AccountBackups).Path -eq $canonicalPath) '同秒儲存優先使用新版正式備份'

    $legacyStore = Join-Path $sandbox 'legacy'
    $activeStore = $script:StorePath
    $script:StorePath = $legacyStore
    $null = Write-TestBackup $old '舊版舊資料' '2026-01-01 10:00:00'
    $null = Write-TestBackup $latest '舊版新資料' '2026-01-02 10:00:00'
    $script:StorePath = $activeStore
    Check ((Import-LegacyCodexBackups $legacyStore) -eq 0) '舊版不同檔名的同帳號不再次匯入'
    $script:StorePath = Join-Path $sandbox 'fresh-import'
    Check ((Import-LegacyCodexBackups $legacyStore) -eq 1 -and (Get-AccountBackups).Name -eq '舊版新資料') '首次匯入只保留同帳號最新一筆'
    $script:StorePath = $activeStore

    $agOld = New-TestAuth 'google-old' 'Member@example.invalid' '' 'ag-old' -Antigravity
    $agLatest = New-TestAuth 'google-new' ' member@EXAMPLE.invalid ' '' 'ag-latest' -Antigravity
    Check ((Get-AGIdentity $agOld).Key -eq (Get-AGIdentity $agLatest).Key) 'Antigravity 使用相同的電子郵件唯一規則'
    $null = Write-TestBackup $agOld 'AG 舊資料' '2026-01-01 10:00:00' -Antigravity
    $null = Write-TestBackup $agLatest 'AG 最新資料' '2026-01-02 10:00:00' -Antigravity
    $agRecords = @(Get-AccountBackups -Antigravity)
    Check ($agRecords.Count -eq 1 -and $agRecords[0].Name -eq 'AG 最新資料') 'Antigravity 舊版重複備份彙整'
    $agEntry = New-Object AntigravitySwitcher.CredentialEntry
    $agEntry.Blob = $agLatest; $agEntry.UserName = 'antigravity'; $agEntry.Persist = 2
    $script:FakeAGCurrent = [pscustomobject]@{ Entry=$agEntry; Identity=(Get-AGIdentity $agLatest) }
    function Read-AGCurrent { return $script:FakeAGCurrent }
    $script:AGRequests = @()
    Refresh-AGAccounts
    Check ($agList.Items[0].Text -eq (Get-AGIdentity $agLatest).Email -and $agList.Items[0].SubItems.Count -eq 7) 'Antigravity 清單只顯示帳號，不重複顯示備份名稱'
    Check ($agList.Items.Count -eq 1 -and $script:AGRequests.Count -eq 1 -and $agList.Items[0].SubItems[4].Text -eq '目前') 'Antigravity 清單、額度與目前帳號一致'
    Backup-AGCurrent $script:FakeAGCurrent ''
    Save-AGBackup $script:FakeAGCurrent 'AG 更新' ''
    Check ((@(Get-AccountBackups -Antigravity)).Count -eq 1 -and (Get-AccountBackups -Antigravity).Name -eq 'AG 更新') 'Antigravity 儲存只更新唯一帳號'
    Check ((@(Get-AccountBackups)).Count -eq 1) '兩個產品的帳號資料互相隔離'

    $validRecord = $script:Utf8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($canonicalPath), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)) | ConvertFrom-Json
    $validRecord.Key = (Get-Identity $other).Key
    $cipher = [Security.Cryptography.ProtectedData]::Protect($script:Utf8.GetBytes(($validRecord | ConvertTo-Json -Compress)), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $tamperedPath = Join-Path $sandbox 'tampered.bin'
    Write-Atomic $tamperedPath $cipher
    $rejected = $false
    try { Read-Backup $tamperedPath | Out-Null } catch { $rejected = $true }
    Check $rejected '不同帳號的錯誤備份識別仍被拒絕'
    $apiSecret = 'synthetic-api-account-A'
    $apiBytes = $script:Utf8.GetBytes((@{ auth_mode='apikey'; OPENAI_API_KEY=$apiSecret } | ConvertTo-Json -Compress))
    $apiIdentity = Get-Identity $apiBytes
    $legacyApi = $script:Utf8.GetBytes((@{ OPENAI_API_KEY=$apiSecret } | ConvertTo-Json -Compress))
    Check ($apiIdentity.AuthMode -eq 'apikey' -and $apiIdentity.Key -eq (Get-Identity $legacyApi).Key) '支援目前及未標註模式的 API key 登入檔'
    Check (!$apiIdentity.Email.Contains($apiSecret) -and $apiIdentity.Key -ne (Get-Identity $current).Key) 'API key 遮蔽顯示並與訂閱帳號隔離'
    foreach ($badAuth in @(
        @{ auth_mode='apikey'; OPENAI_API_KEY='' },
        @{ auth_mode='apikey'; OPENAI_API_KEY='   ' },
        @{ auth_mode='apikey'; OPENAI_API_KEY=123 },
        @{ auth_mode='apikey'; OPENAI_API_KEY='invalid key' },
        @{ auth_mode='chatgpt'; OPENAI_API_KEY=$apiSecret },
        @{ auth_mode='other'; OPENAI_API_KEY=$apiSecret },
        @{ auth_mode='apikey'; OPENAI_API_KEY=$apiSecret; tokens=@{ access_token='mixed' } }
    )) {
        $rejected = $false
        try { Get-Identity $script:Utf8.GetBytes(($badAuth | ConvertTo-Json -Compress)) | Out-Null }
        catch { $rejected = $true; Check (!$_.Exception.Message.Contains($apiSecret)) '格式錯誤不洩漏 API key' }
        Check $rejected '拒絕不完整或混用的 API key 認證'
    }
    $beforeAuth = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath))
    Save-CodexApiKey ('  ' + $apiSecret + '  ') '測試 API'
    $apiPath = Join-Path $script:StorePath ($apiIdentity.Key + '.bin')
    Check ((Read-Backup $apiPath).AuthMode -eq 'apikey' -and (Read-Backup $apiPath).Name -eq '測試 API') '直接新增 API key 並讀回 DPAPI 備份'
    Check (![IO.File]::ReadAllText($apiPath).Contains($apiSecret) -and ![IO.File]::ReadAllText($script:LogPath).Contains($apiSecret)) 'API key 不以明文寫入備份或日誌'
    Check ($beforeAuth -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath))) '新增 API key 不變更目前登入'
    Save-CodexApiKey $apiSecret 'API 更新名稱'
    Check (@(Get-AccountBackups | Where-Object { $_.AuthMode -eq 'apikey' }).Count -eq 1) '相同 API key 重複儲存只更新同一筆'
    Save-CodexApiKey 'synthetic-api-account-B' '第二把 API key'
    Check (@(Get-AccountBackups | Where-Object { $_.AuthMode -eq 'apikey' }).Count -eq 2) '不同 API key 分別保存'
    $script:CodexRequests = @()
    Refresh-Accounts
    Check ($list.Items.Count -eq 1 -and $apiList.Items.Count -eq 2 -and $script:CodexRequests.Count -eq 1) '訂閱與 API key 分別列入獨立表格，只有訂閱帳號查詢訂閱額度'
    Check ($apiList.Items[$apiIdentity.Key].SubItems[1].Text -eq 'API key' -and $apiList.Items[$apiIdentity.Key].SubItems[2].Text -eq '未設定' -and $apiList.Items[$apiIdentity.Key].SubItems[5].Text -eq 'API 計費') 'API key 未設定預算時明示未設定'
    Check ($apiList.Items[$apiIdentity.Key].Text.Contains('API 更新名稱') -and !$apiList.Items[$apiIdentity.Key].Text.Contains($apiSecret)) 'API key 表格使用名稱與雜湊摘要，不顯示金鑰'
    Check ($script:WebSnapshot.Accounts.Count -eq 3) 'Web 同步合併兩張表格的帳號，沒有遺漏 API key'
    & $realStartQuotaQuery $apiBytes $apiIdentity.Key
    Check (!$script:QuotaJobs.Count) '額度入口直接拒絕向訂閱用量端點傳送 API key'
    Install-Auth (Read-Backup $apiPath).Bytes
    Check ((Read-Current).Identity.Key -eq $apiIdentity.Key) '訂閱帳號可切換至 API key'
    $script:CodexRequests = @()
    Refresh-Accounts
    Check ($apiList.Items[$apiIdentity.Key].SubItems[4].Text -eq '目前' -and $script:WebSnapshot.HostKey -eq $apiIdentity.Key) '獨立 API key 表格的目前帳號與 Web 鎖定一致'
    $apiRollback = Join-Path $script:StorePath 'last-switch.rollback'
    Install-Auth (Read-Backup $apiRollback).Bytes
    Check ((Read-Current).Identity.Key -eq (Get-Identity $current).Key) 'API key 可還原至訂閱帳號'

    # 刪除涵蓋同帳號的所有舊檔，且不復活於舊版匯入與切換自動備份。
    $currentKey = (Get-Identity $current).Key
    Save-Backup $current '相符還原點' $apiRollback
    $beforeAuth = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath))
    Remove-AccountBackup $canonicalPath
    Check (!(Test-Path -LiteralPath $oldPath) -and !(Test-Path -LiteralPath $latestPath) -and !(Test-Path -LiteralPath $canonicalPath) -and !(Test-Path -LiteralPath $apiRollback)) 'Codex 刪除所有同帳號重複備份及相符還原點'
    Check ((Import-LegacyCodexBackups $legacyStore) -eq 0) '重新啟動的舊版匯入不會復活已刪帳號'
    Check (@(Get-ChildItem -LiteralPath $legacyStore -Filter '*.bin' -File).Count -eq 2) '刪除不變更舊版原件'
    Backup-Current (Read-Current) ''
    Check (!(Test-Path -LiteralPath $canonicalPath)) '刪除目前帳號後自動備份不會重新加入'
    Check ($beforeAuth -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath))) '刪除目前帳號不會登出或覆寫登入檔'
    Check ((Test-Path -LiteralPath $apiPath) -and (Test-Path -LiteralPath (Join-Path $script:StorePath 'broken.bin'))) '其他帳號與無法識別的損壞檔保留'
    Check (@(Get-AccountBackups -Antigravity).Count -eq 1) 'Codex 刪除不影響 Antigravity'
    Backup-Current (Read-Current) '明確重新儲存'
    Check ((Test-Path -LiteralPath $canonicalPath) -and !(Test-Path -LiteralPath (Join-Path $script:StorePath ($currentKey + '.deleted')))) '明確儲存可重新加入已刪帳號'
    Save-Backup $current '其他帳號還原點' $apiRollback
    Remove-AccountBackup $apiPath
    Check (!(Test-Path -LiteralPath $apiPath) -and (Test-Path -LiteralPath $apiRollback)) 'API key 可刪除且保留其他帳號還原點'
    $script:CodexRequests = @()
    Refresh-Accounts
    Check (!$apiList.Items.ContainsKey($apiIdentity.Key) -and @($script:WebSnapshot.Accounts | Where-Object { $_.Key -eq $apiIdentity.Key }).Count -eq 0) '刪除後 API key 表格與 Web 同步移除帳號'
    Save-CodexApiKey $apiSecret '重新新增 API'
    Check ((Test-Path -LiteralPath $apiPath) -and !(Test-Path -LiteralPath (Join-Path $script:StorePath ($apiIdentity.Key + '.deleted')))) 'API key 刪除後可明確重新新增'

    $agPath = (Get-AccountBackups -Antigravity).Path
    $agRollback = Join-Path $script:AGStorePath 'last-switch.rollback'
    Save-AGBackup $script:FakeAGCurrent '相符 AG 還原點' $agRollback
    $agBefore = [Convert]::ToBase64String($script:FakeAGCurrent.Entry.Blob)
    foreach ($wrongPath in @($canonicalPath,$tamperedPath,$agRollback)) {
        $rejected = $false
        try { Remove-AccountBackup $wrongPath -Antigravity } catch { $rejected = $true }
        Check ($rejected -and (Test-Path -LiteralPath $wrongPath)) '拒絕跨產品、目錄外或還原點作為刪除入口'
    }
    Remove-AccountBackup $agPath -Antigravity
    Check (@(Get-ChildItem -LiteralPath $script:AGStorePath -Filter '*.bin' -File).Count -eq 0 -and !(Test-Path -LiteralPath $agRollback)) 'Antigravity 刪除全部舊版、正式備份及相符還原點'
    Backup-AGCurrent $script:FakeAGCurrent ''
    Check (@(Get-AccountBackups -Antigravity).Count -eq 0 -and (Test-Path -LiteralPath $canonicalPath)) 'Antigravity 自動備份不復活且不影響 Codex'
    Check ([Convert]::ToBase64String($script:FakeAGCurrent.Entry.Blob) -eq $agBefore) 'Antigravity 刪除不變更目前登入認證'
    Refresh-AGAccounts
    Check ($agList.Items.Count -eq 0) '刪除最後一筆 Antigravity 帳號後清單為空'
    Save-AGBackup $script:FakeAGCurrent '明確重新儲存 AG' ''
    Check (@(Get-AccountBackups -Antigravity).Count -eq 1) 'Antigravity 刪除後可明確重新儲存'
    'PASS: 帳號唯一識別、API key 加密儲存與雙向切換、額度隔離、Codex／Antigravity 刪除、重複備份清除、刪除防復活及 Web 同步。未讀寫真實憑證。'
} finally {
    foreach ($control in @($list,$apiList,$agList,$currentLabel,$agCurrentLabel,$nameBox,$agNameBox,$lastQueryLabel,$agLastQueryLabel,$status,$agStatus)) { $control.Dispose() }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($sandbox).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $sandbox -Leaf) -like 'AccountIdentityTest-*') {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
