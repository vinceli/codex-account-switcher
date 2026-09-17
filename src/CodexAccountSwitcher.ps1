param([switch]$SelfTest, [string]$PreviewPath, [switch]$CheckEnvironment)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Security
$script:StorePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexAccountSwitcher'
$script:CodexPath = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { Join-Path $env:USERPROFILE '.codex' }
$script:AuthPath = Join-Path $script:CodexPath 'auth.json'
$script:Utf8 = New-Object Text.UTF8Encoding($true)
$script:LogPath = Join-Path $script:StorePath 'switcher.log'

function Write-SwitcherLog([string]$Level, [string]$Message, [string]$Detail = '') {
    try {
        if (!(Test-Path -LiteralPath $script:StorePath)) {
            [IO.Directory]::CreateDirectory($script:StorePath) | Out-Null
        }
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $line = "[$timestamp] [$Level] $Message"
        if ($Detail) { $line += " | Detail: $Detail" }
        [IO.File]::AppendAllText($script:LogPath, "$line`r`n", $script:Utf8)
    } catch { }
}

function Write-Atomic([string]$Path, [byte[]]$Bytes) {
    $directory = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temp = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Get-Identity([byte[]]$Bytes) {
    try {
        $auth = $script:Utf8.GetString($Bytes) | ConvertFrom-Json
        if ($auth.auth_mode -and $auth.auth_mode -ne 'chatgpt') { throw 'mode' }
        if (!$auth.tokens.access_token -or !$auth.tokens.refresh_token -or !$auth.tokens.id_token -or !$auth.tokens.account_id) { throw 'tokens' }
        $payload = ([string]$auth.tokens.id_token).Split('.')[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = $script:Utf8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if (!$claims.sub) { throw 'subject' }
        $identity = [string]$claims.sub + '|' + [string]$auth.tokens.account_id
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $key = ([BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes($identity)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $email = if ($claims.email) { [string]$claims.email } else { '未提供電子郵件' }
        [pscustomobject]@{ Key = $key; Email = $email; Account = [string]$auth.tokens.account_id }
    } catch { throw '登入檔格式不支援或已損壞。請先在 Codex 使用 ChatGPT 帳號登入；本工具不支援 API Key。' }
}

function Assert-FileStorage {
    $config = Join-Path $script:CodexPath 'config.toml'
    if (Test-Path -LiteralPath $config) {
        # ponytail: 僅接受可確認的全域設定；不猜測 TOML 的多行或特殊寫法。
        foreach ($line in [IO.File]::ReadAllLines($config)) {
            if ($line -match '^\s*\[') { break }
            if ($line -match '^\s*cli_auth_credentials_store\s*=') {
                if ($line -notmatch '^\s*cli_auth_credentials_store\s*=\s*["'']file["'']\s*(#.*)?$') {
                    throw '設定不是 file 憑證儲存模式，已停止操作。請先確認 Codex 使用 auth.json。'
                }
            }
        }
    }
    if (!(Test-Path -LiteralPath $script:AuthPath -PathType Leaf)) { throw '找不到 auth.json。請先在 Codex 登入，並確認使用檔案儲存憑證。' }
}

function Read-Current {
    Assert-FileStorage
    $bytes = [IO.File]::ReadAllBytes($script:AuthPath)
    $identity = Get-Identity $bytes
    [pscustomobject]@{ Bytes = $bytes; Identity = $identity }
}

function Read-Backup([string]$Path) {
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $record = $script:Utf8.GetString($plain) | ConvertFrom-Json
        $bytes = [Convert]::FromBase64String($record.Auth)
        $identity = Get-Identity $bytes
        if ($record.Key -ne $identity.Key) { throw 'identity' }
        [pscustomobject]@{ Name = [string]$record.Name; Key = $identity.Key; Email = $identity.Email; Saved = [string]$record.Saved; Bytes = $bytes; Path = $Path }
    } catch { throw '無法解密或驗證備份。備份只能由原本的 Windows 使用者開啟。' }
}

function Save-Backup([byte[]]$Bytes, [string]$Name, [string]$Path) {
    $identity = Get-Identity $Bytes
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80) { throw '請輸入 1 至 80 字的帳號名稱。' }
    if (!$Path) { $Path = Join-Path $script:StorePath ($identity.Key + '.bin') }
    $json = @{ Name = $Name.Trim(); Key = $identity.Key; Saved = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Auth = [Convert]::ToBase64String($Bytes) } | ConvertTo-Json -Compress
    $cipher = [Security.Cryptography.ProtectedData]::Protect($script:Utf8.GetBytes($json), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-Atomic $Path $cipher
    $verified = Read-Backup $Path
    if ([Convert]::ToBase64String($verified.Bytes) -ne [Convert]::ToBase64String($Bytes)) { throw '備份驗證失敗，已停止操作。' }
    Write-SwitcherLog 'INFO' '儲存帳號備份' "Name=$Name, Email=$($identity.Email), Key=$($identity.Key), Path=$Path"
}

function Backup-Current([object]$Current, [string]$Name) {
    $path = Join-Path $script:StorePath ($Current.Identity.Key + '.bin')
    if (!$Name) {
        $Name = if (Test-Path -LiteralPath $path) { (Read-Backup $path).Name } else { '自動備份 ' + $Current.Identity.Email }
    }
    Save-Backup $Current.Bytes $Name $path
}

function Get-CodexCliPath {
    $binDir = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binDir) {
        $candidate = Get-ChildItem -LiteralPath $binDir -Filter 'codex.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object { (Get-Item $_.FullName).LastWriteTime } -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    $cmd = Get-Command 'codex.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw '找不到 codex.exe 命令列工具，無法執行登入流程。'
}

function Get-DesktopApp {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' | Select-Object -First 1
    if (!$package) { throw '找不到 OpenAI.Codex Windows 安裝套件。此版本工具支援目前電腦的 Microsoft Store 安裝方式。' }
    $manifest = $package | Get-AppxPackageManifest
    $application = @($manifest.Package.Applications.Application) | Where-Object { $_.Executable -match '(ChatGPT|Codex)\.exe$' } | Select-Object -First 1
    if (!$application) { throw '無法辨識 Codex 啟動入口。' }
    [pscustomobject]@{ Root = $package.InstallLocation.TrimEnd('\') + '\'; Id = $package.PackageFamilyName + '!' + $application.Id }
}

function Get-DesktopProcesses([object]$App) {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($App.Root, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Assert-NoOtherClients([object]$App, [object[]]$Processes) {
    $owned = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($item in $Processes) {
        if ($item.ExecutablePath -and $item.ExecutablePath.StartsWith($App.Root, [StringComparison]::OrdinalIgnoreCase)) { [void]$owned.Add([int]$item.ProcessId) }
    }
    do {
        $changed = $false
        foreach ($item in $Processes) {
            if ($owned.Contains([int]$item.ParentProcessId) -and $owned.Add([int]$item.ProcessId)) { $changed = $true }
        }
    } while ($changed)
    $others = @($Processes | Where-Object { $_.Name -ieq 'codex.exe' -and !$owned.Contains([int]$_.ProcessId) })
    if ($others.Count) { throw '另有 Codex CLI、IDE 或獨立背景服務正在執行。請先關閉這些用戶端，再切換帳號。' }
    return ,$owned
}

function Stop-Desktop([object]$App) {
    $all = @(Get-CimInstance Win32_Process)
    $owned = Assert-NoOtherClients $App $all
    $tracked = @($all | Where-Object { $owned.Contains([int]$_.ProcessId) })
    foreach ($item in $tracked) {
        if ($item.ExecutablePath -and $item.ExecutablePath.StartsWith($App.Root, [StringComparison]::OrdinalIgnoreCase)) {
            $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
            if ($process -and $process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
        }
    }
    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-DesktopProcesses $App)
    } while ($remaining.Count -and (Get-Date) -lt $deadline)
    # 使用 PID 加建立時間，避免關閉到重複使用相同 PID 的其他程式。
    $now = @(Get-CimInstance Win32_Process)
    foreach ($item in $tracked) {
        $live = $now | Where-Object { $_.ProcessId -eq $item.ProcessId -and $_.CreationDate -eq $item.CreationDate }
        if ($live) { Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 500
    if (@(Get-DesktopProcesses $App).Count -or @(Get-Process -Name codex -ErrorAction SilentlyContinue).Count) {
        throw 'Codex 程序尚未完全結束，沒有替換 auth.json。請關閉剩餘程序後重試。'
    }
}

function Start-Desktop([object]$App) {
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('shell:AppsFolder\' + $App.Id) -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 500
        if (@(Get-DesktopProcesses $App).Count) { return }
    } while ((Get-Date) -lt $deadline)
    throw '憑證已替換，但未偵測到 Codex 啟動。請從開始功能表開啟 Codex；需要還原時使用「還原上次切換」。'
}

function Install-Auth([byte[]]$Target) {
    $null = Get-Identity $Target
    $current = Read-Current
    Backup-Current $current ''
    Save-Backup $current.Bytes '切換前還原點' (Join-Path $script:StorePath 'last-switch.rollback')
    try {
        Write-Atomic $script:AuthPath $Target
        $check = Read-Current
        if ([Convert]::ToBase64String($check.Bytes) -ne [Convert]::ToBase64String($Target)) { throw '驗證失敗' }
    } catch {
        Write-Atomic $script:AuthPath $current.Bytes
        throw '替換憑證失敗，已恢復原始 auth.json。'
    }
}

function Switch-Account([string]$Path) {
    $target = Read-Backup $Path
    $current = Read-Current
    if ($target.Key -eq $current.Identity.Key -and $Path -notlike '*.rollback') { throw '目前已是這個帳號；請使用「儲存目前帳號」更新備份。' }
    $app = Get-DesktopApp
    $null = Assert-NoOtherClients $app @(Get-CimInstance Win32_Process)
    $answer = [Windows.Forms.MessageBox]::Show("即將切換至「$($target.Name)」。`r`n`r`n只替換 auth.json 並關閉、重開 Codex，不執行登出。`r`n執行中的任務會中斷，請先完成或停止任務。`r`n若這份備份曾被登出撤銷，必須重新登入並儲存。`r`n是否繼續？", '切換帳號', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    Write-SwitcherLog 'INFO' '執行切換帳號' "From=$($current.Identity.Email) ($($current.Identity.Key)) -> To=$($target.Name) ($($target.Email), $($target.Key))"
    Set-Status '正在關閉 Codex、更新備份並切換…'
    Stop-Desktop $app
    Write-SwitcherLog 'INFO' 'Codex Desktop 程序已終止'
    try {
        Install-Auth $target.Bytes
        Write-SwitcherLog 'INFO' 'auth.json 替換驗證成功' "TargetKey=$($target.Key)"
    }
    catch {
        $failure = $_
        Write-SwitcherLog 'ERROR' 'auth.json 替換失敗' "$($failure.Exception.Message)"
        try { Start-Desktop $app } catch { }
        throw $failure
    }
    Start-Desktop $app
    Write-SwitcherLog 'INFO' 'Codex Desktop 已重新啟動' "AppId=$($app.Id)"
    Set-Status '已替換憑證並啟動 Codex。請在 Codex 帳號選單確認實際登入狀態。'
}

function Prompt-AccountName([string]$DefaultName, [string]$Email) {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = '儲存登入帳號'
    $dialog.ClientSize = New-Object Drawing.Size(420, 160)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10)
    $dialog.BackColor = [Drawing.Color]::FromArgb(247,248,250)

    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = "已完成授權：$Email`r`n請輸入此帳號在工具中的自訂名稱："
    $lbl.SetBounds(20, 15, 380, 40)
    $dialog.Controls.Add($lbl)

    $txt = New-Object Windows.Forms.TextBox
    $txt.Text = $DefaultName
    $txt.SetBounds(20, 60, 380, 28)
    $txt.MaxLength = 80
    $dialog.Controls.Add($txt)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = '確定儲存'
    $btnOk.DialogResult = [Windows.Forms.DialogResult]::OK
    $btnOk.SetBounds(210, 105, 95, 32)
    $dialog.Controls.Add($btnOk)
    $dialog.AcceptButton = $btnOk

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = '略過'
    $btnCancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $btnCancel.SetBounds(315, 105, 85, 32)
    $dialog.Controls.Add($btnCancel)
    $dialog.CancelButton = $btnCancel

    $result = $dialog.ShowDialog($form)
    $name = $txt.Text.Trim()
    $dialog.Dispose()

    if ($result -ne [Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($name)) {
        return $null
    }
    return $name
}

function Start-GuidedLogin {
    $cliPath = Get-CodexCliPath
    $app = Get-DesktopApp
    $null = Assert-NoOtherClients $app @(Get-CimInstance Win32_Process)

    try {
        $current = Read-Current
        Backup-Current $current ''
    } catch { }

    $msg = "即將啟動瀏覽器授權登入流程。`r`n`r`n" +
           "【★ 雙帳號共存防失效須知 ★】`r`n" +
           "Team/Enterprise 工作空間不支援裝置代碼，請走瀏覽器授權：`r`n`r`n" +
           "1. 視窗開啟授權頁面後，【絕對不要點選網頁上的登出 (Log out)】！`r`n" +
           "2. 請直接「複製網址列的完整網址」，按 Ctrl+Shift+N 開啟「無痕視窗」貼上前往。`r`n" +
           "3. 於無痕視窗登入您的新帳號，授權完成後直接關閉無痕視窗即可。`r`n`r`n" +
           "如此一來，既有帳號的 Refresh Token 便能完整保留，不再被雲端註銷！`r`n`r`n" +
           "是否立即開始？"
    $confirm = [Windows.Forms.MessageBox]::Show($msg, '引導登入新帳號', 'YesNo', 'Information')
    if ($confirm -ne 'Yes') { return }

    Write-SwitcherLog 'INFO' '發起引導登入新帳號流程' "CLI=$cliPath, Mode=StandardBrowser"
    Set-Status '正在關閉 Codex Desktop 並準備登入…'
    Stop-Desktop $app

    Set-Status '請複製授權網址至無痕視窗完成登入…'
    $authBefore = if (Test-Path -LiteralPath $script:AuthPath) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath)) } else { '' }

    $loginCmd = "`$host.UI.RawUI.WindowTitle = 'Codex 登入授權精靈'; " +
                "Write-Host '================================================================' -ForegroundColor Cyan; " +
                "Write-Host '【雙帳號共存重要指引】請勿在預設瀏覽器中按「登出」！' -ForegroundColor Red; " +
                "Write-Host '1. 系統已自動開啟預設瀏覽器。' -ForegroundColor Gray; " +
                "Write-Host '2. 請直接複製網址列的完整網址 (Ctrl+L -> Ctrl+C)。' -ForegroundColor Yellow; " +
                "Write-Host '3. 按 Ctrl+Shift+N 開啟「無痕視窗」，貼上網址前往並登入！' -ForegroundColor Green; " +
                "Write-Host '4. 在無痕視窗完成登入後，此視窗將自動關閉，切換器自動完成儲存。' -ForegroundColor Cyan; " +
                "Write-Host '================================================================' -ForegroundColor Cyan; " +
                "& '$cliPath' login; " +
                "if (`$LASTEXITCODE -ne 0) { Write-Host '登入未完成或發生錯誤。' -ForegroundColor Red; Start-Sleep -Seconds 3 }"

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', $loginCmd) -PassThru -Wait
    Write-SwitcherLog 'INFO' '登入終端已結束' "ExitCode=$($proc.ExitCode)"

    try {
        $newCurrent = Read-Current
    } catch {
        Write-SwitcherLog 'WARN' '引導登入後無法讀取有效憑證' "$($_.Exception.Message)"
        throw '未偵測到有效的登入憑證或登入流程已取消。'
    }

    $authAfter = [Convert]::ToBase64String($newCurrent.Bytes)
    if ($authBefore -and $authBefore -eq $authAfter) {
        Write-SwitcherLog 'WARN' '登入憑證未變更'
        Set-Status '登入憑證未變更（登入被取消或未更新）。'
        return
    }

    $defaultName = $newCurrent.Identity.Email
    $customName = Prompt-AccountName $defaultName $newCurrent.Identity.Email
    if (!$customName) { $customName = $defaultName }

    Backup-Current $newCurrent $customName
    Write-SwitcherLog 'INFO' '引導登入帳號儲存完成' "Name=$customName, Email=$($newCurrent.Identity.Email), Key=$($newCurrent.Identity.Key)"
    Refresh-Accounts

    $reopen = [Windows.Forms.MessageBox]::Show("帳號「$customName」已成功登入並加密儲存！`r`n`r`n是否立即啟動 Codex Desktop？", '登入成功', 'YesNo', 'Information')
    if ($reopen -eq 'Yes') {
        Start-Desktop $app
        Write-SwitcherLog 'INFO' '引導登入後啟動 Codex Desktop'
        Set-Status "已啟動 Codex Desktop（目前使用：$($newCurrent.Identity.Email)）。"
    } else {
        Set-Status "帳號「$customName」已完成儲存。隨時可點選「切換並重新啟動」。"
    }
}

function Invoke-SelfTest {
    $originalStore = $script:StorePath
    $originalCodex = $script:CodexPath
    $originalAuth = $script:AuthPath
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('CodexSwitcherTest-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($sandbox) | Out-Null
    try {
        $script:StorePath = Join-Path $sandbox 'backups'
        $script:CodexPath = $sandbox
        $script:AuthPath = Join-Path $sandbox 'auth.json'
        $preservedPaths = @('config.toml', '.codex-global-state.json', 'state_5.sqlite', 'sessions\existing.jsonl', 'worktrees\existing\source.txt', 'projects\existing\source.txt')
        $preserved = @{}
        foreach ($relative in $preservedPaths) {
            $path = Join-Path $sandbox $relative
            $content = if ($relative -eq 'config.toml') { 'cli_auth_credentials_store = "file"' } else { 'existing-content-' + $relative }
            Write-Atomic $path $script:Utf8.GetBytes($content)
            $preserved[$path] = $content
        }
        function Fake-Auth([string]$Id, [string]$Token) {
            $claims = @{ sub = $Id; email = ($Id + '@example.invalid') } | ConvertTo-Json -Compress
            $jwt = 'test.' + [Convert]::ToBase64String($script:Utf8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.test'
            return ,$script:Utf8.GetBytes((@{ auth_mode='chatgpt'; tokens=@{ id_token=$jwt; account_id=('workspace-' + $Id); access_token=$Token; refresh_token=('refresh-' + $Token) } } | ConvertTo-Json -Depth 4))
        }
        function Check([bool]$Condition, [string]$Message) { if (!$Condition) { throw ('測試失敗：' + $Message) } }
        $a = Fake-Auth 'A' 'old-A'
        $updated = Fake-Auth 'A' 'new-A'
        $b = Fake-Auth 'B' 'token-B'
        Write-Atomic $script:AuthPath $a
        Backup-Current (Read-Current) '帳號 A'
        Save-Backup $b '帳號 B' ''
        $aPath = Join-Path $script:StorePath ((Get-Identity $a).Key + '.bin')
        Check ((Read-Backup $aPath).Name -eq '帳號 A') '加密備份往返'
        Check (![IO.File]::ReadAllText($aPath).Contains('old-A')) '備份不是明文'
        Write-Atomic $script:AuthPath $updated
        Install-Auth $b
        Check ((Read-Current).Identity.Key -eq (Get-Identity $b).Key) '切換目標帳號'
        Check ([Convert]::ToBase64String((Read-Backup $aPath).Bytes) -eq [Convert]::ToBase64String($updated)) '保留更新後 token'
        $rollback = Read-Backup (Join-Path $script:StorePath 'last-switch.rollback')
        Install-Auth $rollback.Bytes
        Check ((Read-Current).Identity.Key -eq (Get-Identity $a).Key) '還原原帳號'
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath))
        $rejected = $false
        try { Install-Auth $script:Utf8.GetBytes('{}') } catch { $rejected = $true }
        Check ($rejected -and $before -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath))) '無效目標不修改現有憑證'
        $originalRead = ${function:Read-Current}
        $script:testReadCount = 0
        function Read-Current {
            $script:testReadCount++
            if ($script:testReadCount -eq 2) { throw '模擬替換後讀回失敗' }
            & $originalRead
        }
        $rejected = $false
        try { Install-Auth $b } catch { $rejected = $true }
        Check ($rejected -and $before -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AuthPath))) '讀回失敗自動恢復'
        Remove-Item Function:\Read-Current
        foreach ($path in $preserved.Keys) {
            Check ([IO.File]::Exists($path) -and [IO.File]::ReadAllText($path) -ceq $preserved[$path]) '切換、還原及失敗恢復均保留工作區與設定原文'
        }
        $rejected = $false
        try { Get-Identity $script:Utf8.GetBytes('{"OPENAI_API_KEY":"fake"}') | Out-Null } catch { $rejected = $true }
        Check $rejected '拒絕不支援的登入檔'
        Write-Atomic (Join-Path $sandbox 'config.toml') $script:Utf8.GetBytes('cli_auth_credentials_store = "keyring"')
        $rejected = $false
        try { Read-Current | Out-Null } catch { $rejected = $true }
        Check $rejected '拒絕 keyring'
        Write-Atomic (Join-Path $sandbox 'config.toml') $script:Utf8.GetBytes('cli_auth_credentials_store = "file"')
        $app = [pscustomobject]@{ Root='C:\App\' }
        $processes = @([pscustomobject]@{ ProcessId=10; ParentProcessId=1; Name='ChatGPT.exe'; ExecutablePath='C:\App\ChatGPT.exe' }, [pscustomobject]@{ ProcessId=11; ParentProcessId=10; Name='codex.exe'; ExecutablePath='C:\CLI\codex.exe' })
        $owned = Assert-NoOtherClients $app $processes
        Check ($owned.Contains(11)) '辨識 Desktop 後端'
        $rejected = $false
        try { $null = Assert-NoOtherClients $app ($processes + [pscustomobject]@{ ProcessId=12; ParentProcessId=1; Name='codex.exe'; ExecutablePath='C:\CLI\codex.exe' }) } catch { $rejected=$true }
        Check $rejected '阻擋其他用戶端'
        Write-Atomic $aPath ([byte[]](1,2,3))
        $rejected=$false
        try { Read-Backup $aPath | Out-Null } catch { $rejected=$true }
        $cliCandidate = Get-CodexCliPath
        Check (![string]::IsNullOrWhiteSpace($cliCandidate)) '探測 codex.exe CLI 路徑'
        'PASS: 加密儲存、帳號識別、token 更新、切換、還原、工作區及設定保留、格式檢查、儲存模式、程序辨識、CLI 探測。未讀取真實憑證或重啟 Codex。'
    } finally {
        $script:StorePath=$originalStore; $script:CodexPath=$originalCodex; $script:AuthPath=$originalAuth
        if ([IO.Path]::GetFullPath($sandbox).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $sandbox -Leaf) -like 'CodexSwitcherTest-*') { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    }
}

if ($SelfTest) { Invoke-SelfTest; exit }
if ($CheckEnvironment) {
    Assert-FileStorage
    $app = Get-DesktopApp
    $owned = Assert-NoOtherClients $app @(Get-CimInstance Win32_Process)
    [pscustomobject]@{ Application = $app.Id; DesktopProcesses = @(Get-DesktopProcesses $app).Count; RelatedProcesses = $owned.Count; AuthFileExists = $true; CredentialsRead = $false } | ConvertTo-Json
    exit
}

[Windows.Forms.Application]::EnableVisualStyles()
$mutex = New-Object Threading.Mutex($false, 'Local\CodexAccountSwitcher')
$acquired = $false
try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
if (!$acquired -and !$PreviewPath) { [Windows.Forms.MessageBox]::Show('帳號切換工具已開啟。') | Out-Null; $mutex.Dispose(); exit }

$form = New-Object Windows.Forms.Form
$form.Text = 'Codex 帳號切換工具'
$form.ClientSize = New-Object Drawing.Size(740, 510)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(247,248,250)
$form.AutoScaleMode = 'Dpi'

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $control = New-Object Windows.Forms.Label
    $control.Text=$Text; $control.SetBounds($X,$Y,$Width,$Height)
    $form.Controls.Add($control)
    return $control
}
function New-Button([string]$Text, [int]$X, [int]$Y, [int]$Width, [scriptblock]$Action) {
    $control = New-Object Windows.Forms.Button
    $control.Text=$Text; $control.SetBounds($X,$Y,$Width,36)
    $control.Add_Click($Action)
    $form.Controls.Add($control)
    return $control
}
function Set-Status([string]$Message) { $status.Text = $Message; $status.Refresh() }
function Invoke-Action([scriptblock]$Action) {
    $form.UseWaitCursor=$true
    foreach ($button in $script:Buttons) { $button.Enabled=$false }
    try { & $Action }
    catch {
        Write-SwitcherLog 'ERROR' '操作未完成或發生異常' "$($_.Exception.Message)"
        Set-Status $_.Exception.Message
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '未完成操作', 'OK', 'Warning') | Out-Null
    }
    finally { $form.UseWaitCursor=$false; foreach ($button in $script:Buttons) { $button.Enabled=$true } }
}
function Refresh-Accounts {
    $list.Items.Clear()
    $currentKey = ''
    try {
        $current = Read-Current
        $currentKey = $current.Identity.Key
        $currentLabel.Text = '登入檔帳號：' + $current.Identity.Email
        $nameBox.Text = $current.Identity.Email
    } catch { $currentLabel.Text = '登入檔狀態：' + $_.Exception.Message }
    $bad=0
    foreach ($file in @(Get-ChildItem -LiteralPath $script:StorePath -Filter '*.bin' -ErrorAction SilentlyContinue)) {
        try {
            $record = Read-Backup $file.FullName
            $item = New-Object Windows.Forms.ListViewItem($record.Name)
            [void]$item.SubItems.Add($record.Email)
            [void]$item.SubItems.Add($record.Saved)
            [void]$item.SubItems.Add($(if ($record.Key -eq $currentKey) { '目前' } else { '' }))
            $item.Tag=$record.Path
            [void]$list.Items.Add($item)
        } catch { $bad++ }
    }
    Write-SwitcherLog 'DEBUG' '刷新清單完成' "CurrentKey=$currentKey, Backups=$($list.Items.Count), Corrupted=$bad"
    if ($bad) { Set-Status "有 $bad 個備份無法解密，未列入清單；原檔已保留。" }
}

$title=New-Label 'Codex 帳號切換' 24 18 520 34
$title.Font=New-Object Drawing.Font('Microsoft JhengHei UI', 17, [Drawing.FontStyle]::Bold)
$viewLog=New-Button '查看日誌 (Log)' 554 16 158 {
    if (!(Test-Path -LiteralPath $script:LogPath)) {
        Write-SwitcherLog 'INFO' '切換工具日誌初始化'
    }
    Start-Process notepad.exe -ArgumentList "`"$script:LogPath`""
}
$currentLabel=New-Label '正在讀取登入檔…' 26 62 686 44
$null=New-Label '帳號名稱' 26 112 90 28
$nameBox=New-Object Windows.Forms.TextBox
$nameBox.SetBounds(120,109,390,30); $nameBox.MaxLength=80; $form.Controls.Add($nameBox)
$save=New-Button '儲存目前帳號' 528 106 184 {
    Invoke-Action {
        $current=Read-Current
        Backup-Current $current $nameBox.Text
        Refresh-Accounts
        Set-Status '已加密儲存目前帳號。之後使用本工具切換，不要先在 Codex 按登出。'
    }
}
$list=New-Object Windows.Forms.ListView
$list.SetBounds(26,158,686,206); $list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$false; $list.HideSelection=$false
foreach ($column in @(@('名稱',155),@('帳號',260),@('備份時間',185),@('狀態',65))) { [void]$list.Columns.Add($column[0],$column[1]) }
$form.Controls.Add($list)
$switch=New-Button '切換並重新啟動' 26 380 160 {
    Invoke-Action {
        if (!$list.SelectedItems.Count) { throw '請先選擇要切換的帳號。' }
        Switch-Account ([string]$list.SelectedItems[0].Tag)
        Refresh-Accounts
    }
}
$login=New-Button '引導登入新帳號' 196 380 160 {
    Invoke-Action {
        Start-GuidedLogin
    }
}
$restore=New-Button '還原上次切換' 366 380 150 {
    Invoke-Action {
        $path=Join-Path $script:StorePath 'last-switch.rollback'
        if (!(Test-Path -LiteralPath $path)) { throw '目前沒有切換還原點。' }
        Switch-Account $path
        Refresh-Accounts
    }
}
$refresh=New-Button '重新整理' 526 380 186 { Invoke-Action { Refresh-Accounts } }
$status=New-Label '只換 auth，不執行登出；保留現有工作區。已被登出撤銷的備份需重新登入並儲存。' 26 430 686 50
$status.ForeColor=[Drawing.Color]::FromArgb(45,75,90)
$note=New-Label '備份以 Windows 使用者加密保存在 LocalAppData；僅支援 auth.json。' 26 484 686 22
$note.Font=New-Object Drawing.Font('Microsoft JhengHei UI', 8)
$script:Buttons=@($save,$switch,$login,$restore,$refresh,$viewLog)
try {
    if ($PreviewPath) {
        $currentLabel.Text='登入檔帳號：account-a@example.invalid'
        $nameBox.Text='工作帳號'
        $item=New-Object Windows.Forms.ListViewItem('工作帳號')
        foreach ($value in @('account-a@example.invalid','2026-09-17 12:00:00','目前')) { [void]$item.SubItems.Add($value) }
        [void]$list.Items.Add($item)
        $form.Show(); $form.Refresh()
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try { $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
        $form.Close()
    } else {
        Write-SwitcherLog 'INFO' '切換工具視窗已開啟' "PID=$PID"
        Refresh-Accounts
        [void]$form.ShowDialog()
    }
} finally {
    Write-SwitcherLog 'INFO' '切換工具視窗已結束'
    $form.Dispose()
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
