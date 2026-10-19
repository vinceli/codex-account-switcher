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
    Check ($list.Items[0].SubItems[5].Text -eq '目前') '登入身分改變仍正確標記目前帳號'
    Check ([Convert]::ToBase64String($script:CodexRequests[0].Bytes) -eq [Convert]::ToBase64String($current)) '目前帳號查詢使用即時登入憑證'
    Check ($script:WebSnapshot.Accounts.Count -eq 1 -and $script:WebSnapshot.Accounts[0].Key -eq $script:WebSnapshot.HostKey) 'Web 清單與主機鎖定共用唯一識別'
    $list.Items.Clear()
    Sync-WebDashboardAccounts
    Check ($script:WebSnapshot.Accounts.Count -eq 1 -and $script:WebSnapshot.Accounts[0].Name -eq '最新名稱') 'Web 無 UI 清單時仍取得唯一且最新帳號'

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
    Check ($agList.Items.Count -eq 1 -and $script:AGRequests.Count -eq 1 -and $agList.Items[0].SubItems[5].Text -eq '目前') 'Antigravity 清單、額度與目前帳號一致'
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
    'PASS: 帳號唯一識別、舊備份去重、最新資料選取、重複儲存、舊版匯入、兩套清單與 Web 主機鎖定。未讀寫真實憑證。'
} finally {
    foreach ($control in @($list,$agList,$currentLabel,$agCurrentLabel,$nameBox,$agNameBox,$lastQueryLabel,$agLastQueryLabel,$status,$agStatus)) { $control.Dispose() }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($sandbox).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $sandbox -Leaf) -like 'AccountIdentityTest-*') {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
