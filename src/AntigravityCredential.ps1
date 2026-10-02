$script:AGStorePath = Join-Path $script:StorePath 'antigravity'
$script:AGCredentialTarget = 'gemini:antigravity'

function Initialize-AGCredential {
    if ('AntigravitySwitcher.Credentials' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AntigravitySwitcher {
    public sealed class CredentialEntry {
        public byte[] Blob;
        public string UserName;
        public string Comment;
        public string TargetAlias;
        public int Persist;
        public int Flags;
    }

    public static class Credentials {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct NativeCredential {
            public int Flags;
            public int Type;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
            public long LastWritten;
            public int BlobSize;
            public IntPtr Blob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref NativeCredential credential, int flags);
        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int flags);
        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        private static extern void CredFree(IntPtr credential);

        public static CredentialEntry Read(string target) {
            IntPtr pointer;
            if (!CredRead(target, 1, 0, out pointer)) {
                if (Marshal.GetLastWin32Error() == 1168) return null;
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                var native = (NativeCredential)Marshal.PtrToStructure(pointer, typeof(NativeCredential));
                if (native.Type != 1 || native.AttributeCount != 0 || native.BlobSize <= 0)
                    throw new InvalidOperationException("Unsupported credential format.");
                var blob = new byte[native.BlobSize];
                Marshal.Copy(native.Blob, blob, 0, blob.Length);
                return new CredentialEntry {
                    Blob = blob, UserName = native.UserName, Comment = native.Comment,
                    TargetAlias = native.TargetAlias, Persist = native.Persist, Flags = native.Flags
                };
            } finally { CredFree(pointer); }
        }

        public static void Write(string target, CredentialEntry entry) {
            if (entry == null || entry.Blob == null || entry.Blob.Length == 0 || entry.Persist < 1 || entry.Persist > 3)
                throw new ArgumentException("Invalid credential.");
            IntPtr blob = Marshal.AllocHGlobal(entry.Blob.Length);
            try {
                Marshal.Copy(entry.Blob, 0, blob, entry.Blob.Length);
                var native = new NativeCredential {
                    Flags = entry.Flags, Type = 1, TargetName = target, Comment = entry.Comment,
                    BlobSize = entry.Blob.Length, Blob = blob, Persist = entry.Persist,
                    TargetAlias = entry.TargetAlias, UserName = entry.UserName
                };
                if (!CredWrite(ref native, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally {
                for (int i = 0; i < entry.Blob.Length; i++) Marshal.WriteByte(blob, i, 0);
                Marshal.FreeHGlobal(blob);
            }
        }

        public static void DeleteForRollback(string target) {
            if (target != "gemini:antigravity" && !target.StartsWith("CodexSwitcherTest-", StringComparison.Ordinal))
                throw new InvalidOperationException("Unsupported credential target.");
            if (!CredDelete(target, 1, 0) && Marshal.GetLastWin32Error() != 1168)
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}

function Get-AGIdentity([byte[]]$Bytes) {
    try {
        $auth = $script:Utf8.GetString($Bytes) | ConvertFrom-Json
        if (!$auth.token -or !$auth.id_token -or !$auth.auth_method) { throw 'fields' }
        $parts = ([string]$auth.id_token).Split('.')
        if ($parts.Count -ne 3) { throw 'jwt' }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = $script:Utf8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if (!$claims.sub -or !$claims.email) { throw 'identity' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $key = ([BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes([string]$claims.sub)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        [pscustomobject]@{ Key=$key; Email=[string]$claims.email }
    } catch { throw 'Antigravity 登入資料格式不支援或已損壞，沒有修改認證。' }
}

function Get-AGCurrentOrNull {
    Initialize-AGCredential
    $entry = [AntigravitySwitcher.Credentials]::Read($script:AGCredentialTarget)
    if (!$entry) { return $null }
    [pscustomobject]@{ Entry=$entry; Identity=(Get-AGIdentity $entry.Blob) }
}

function Read-AGCurrent {
    $current = Get-AGCurrentOrNull
    if (!$current) { throw '找不到 Antigravity 登入資料。請先在桌面版登入。' }
    return $current
}

function Read-AGBackup([string]$Path) {
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $record = $script:Utf8.GetString($plain) | ConvertFrom-Json
        $entry = New-Object AntigravitySwitcher.CredentialEntry
        $entry.Blob = [Convert]::FromBase64String($record.Blob)
        $entry.UserName = [string]$record.UserName
        $entry.Comment = [string]$record.Comment
        $entry.TargetAlias = [string]$record.TargetAlias
        $entry.Persist = [int]$record.Persist
        $entry.Flags = [int]$record.Flags
        $identity = Get-AGIdentity $entry.Blob
        if ($record.Key -ne $identity.Key -or $entry.Persist -lt 1 -or $entry.Persist -gt 3) { throw 'identity' }
        [pscustomobject]@{ Name=[string]$record.Name; Key=$identity.Key; Email=$identity.Email; Saved=[string]$record.Saved; Entry=$entry; Path=$Path }
    } catch { throw '無法解密或驗證 Antigravity 備份；原始備份已保留。' }
}

function Save-AGBackup([object]$Current, [string]$Name, [string]$Path) {
    $identity = Get-AGIdentity $Current.Entry.Blob
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80) { throw '請輸入 1 至 80 字的帳號名稱。' }
    if (!$Path) { $Path = Join-Path $script:AGStorePath ($identity.Key + '.bin') }
    $record = @{
        Name=$Name.Trim(); Key=$identity.Key; Saved=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Blob=[Convert]::ToBase64String($Current.Entry.Blob)
        UserName=$Current.Entry.UserName; Comment=$Current.Entry.Comment
        TargetAlias=$Current.Entry.TargetAlias; Persist=$Current.Entry.Persist; Flags=$Current.Entry.Flags
    }
    $json = $record | ConvertTo-Json -Compress
    $cipher = [Security.Cryptography.ProtectedData]::Protect($script:Utf8.GetBytes($json), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-Atomic $Path $cipher
    $verified = Read-AGBackup $Path
    if ([Convert]::ToBase64String($Current.Entry.Blob) -ne [Convert]::ToBase64String($verified.Entry.Blob)) { throw 'Antigravity 備份驗證失敗。' }
    Write-SwitcherLog 'INFO' '儲存 Antigravity 備份' "Key=$($identity.Key), Path=$Path"
}

function Backup-AGCurrent([object]$Current, [string]$Name) {
    $path = Join-Path $script:AGStorePath ($Current.Identity.Key + '.bin')
    if (!$Name) { $Name = if (Test-Path -LiteralPath $path) { (Read-AGBackup $path).Name } else { '自動備份 ' + $Current.Identity.Email } }
    Save-AGBackup $Current $Name $path
}

function Install-AGCredential([object]$Target) {
    $targetIdentity = Get-AGIdentity $Target.Blob
    $current = Get-AGCurrentOrNull
    if ($current) {
        Backup-AGCurrent $current ''
        Save-AGBackup $current '切換前還原點' (Join-Path $script:AGStorePath 'last-switch.rollback')
    }
    try {
        [AntigravitySwitcher.Credentials]::Write($script:AGCredentialTarget, $Target)
        $check = Read-AGCurrent
        if ($check.Identity.Key -ne $targetIdentity.Key -or [Convert]::ToBase64String($check.Entry.Blob) -ne [Convert]::ToBase64String($Target.Blob)) { throw 'verify' }
    } catch {
        try {
            if ($current) {
                [AntigravitySwitcher.Credentials]::Write($script:AGCredentialTarget, $current.Entry)
                $restored = Read-AGCurrent
                if ([Convert]::ToBase64String($restored.Entry.Blob) -ne [Convert]::ToBase64String($current.Entry.Blob)) { throw 'rollback' }
            } else {
                [AntigravitySwitcher.Credentials]::DeleteForRollback($script:AGCredentialTarget)
                if (Get-AGCurrentOrNull) { throw 'rollback' }
            }
        } catch { throw 'Antigravity 憑證切換與自動還原均失敗；請使用官方登入流程恢復。' }
        throw 'Antigravity 憑證切換失敗，已恢復原始認證。'
    }
}

function Get-AGDesktopApp {
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw '找不到 Antigravity 2.0 桌面版執行檔。' }
    [pscustomobject]@{ Exe=[IO.Path]::GetFullPath($exe) }
}

function Get-AGDesktopProcesses([object]$App) {
    @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($App.Exe, [StringComparison]::OrdinalIgnoreCase) })
}

function Stop-AGDesktop([object]$App) {
    $all = @(Get-CimInstance Win32_Process)
    $other = @($all | Where-Object { $_.Name -in @('agy.exe','Antigravity IDE.exe') })
    if ($other.Count) { throw '偵測到 Antigravity CLI 或 IDE。請先關閉其他用戶端，再切換桌面版帳號。' }
    $desktop = @($all | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($App.Exe, [StringComparison]::OrdinalIgnoreCase) })
    $owned = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($item in $desktop) { [void]$owned.Add([int]$item.ProcessId) }
    do {
        $changed = $false
        foreach ($item in $all) { if ($owned.Contains([int]$item.ParentProcessId) -and $owned.Add([int]$item.ProcessId)) { $changed = $true } }
    } while ($changed)
    $helpers = @($all | Where-Object { $owned.Contains([int]$_.ProcessId) -and $_.Name -eq 'language_server.exe' })
    foreach ($item in $desktop) {
        $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if (!$process) { continue }
        try {
            if (!$process.HasExited -and $process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
        } catch [InvalidOperationException] { }
    }
    $deadline = (Get-Date).AddSeconds(10)
    while (@(Get-AGDesktopProcesses $App).Count -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (@(Get-AGDesktopProcesses $App).Count) { throw 'Antigravity 尚未完全關閉；請手動關閉後重試，認證尚未替換。' }
    $now = @(Get-CimInstance Win32_Process)
    if (@($helpers | Where-Object { $helper = $_; $now | Where-Object { $_.ProcessId -eq $helper.ProcessId -and $_.CreationDate -eq $helper.CreationDate } }).Count) {
        throw 'Antigravity 語言服務仍在執行；請手動關閉後重試，認證尚未替換。'
    }
}

function Start-AGDesktop([object]$App) {
    Start-Process -FilePath $App.Exe | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (@(Get-AGDesktopProcesses $App).Count) { return }
    }
    throw '認證已替換，但未偵測到 Antigravity 啟動；請從開始功能表開啟，必要時使用還原上次切換。'
}

function Switch-AGAccount([string]$Path) {
    $target = Read-AGBackup $Path
    $current = Get-AGCurrentOrNull
    if ($current -and $target.Key -eq $current.Identity.Key -and $Path -notlike '*.rollback') { throw '目前已是這個帳號；請使用「儲存目前帳號」更新備份。' }
    $app = Get-AGDesktopApp
    $answer = [Windows.Forms.MessageBox]::Show("即將切換至「$($target.Name)」。`r`n`r`n請先完成執行中的任務。工具會關閉 Antigravity，只替換 Windows 認證管理員中的登入資料，再重新啟動；不移動工作區或對話。`r`n`r`n備份若因登出而失效，仍須重新登入。是否繼續？", '切換 Antigravity 帳號', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    Write-SwitcherLog 'INFO' '開始切換 Antigravity 帳號' "TargetKey=$($target.Key)"
    Stop-AGDesktop $app
    Install-AGCredential $target.Entry
    Start-AGDesktop $app
    Write-SwitcherLog 'INFO' 'Antigravity 帳號切換完成' "TargetKey=$($target.Key)"
    Set-Status 'Antigravity 已重新啟動；請在 Account 頁確認實際登入帳號。'
}

function Start-AGGuidedLogin {
    $current = Read-AGCurrent
    $app = Get-AGDesktopApp
    $answer = [Windows.Forms.MessageBox]::Show("工具會先加密備份目前帳號，關閉 Antigravity，再清除本機登入項目並啟動官方登入畫面。`r`n`r`n請在瀏覽器登入另一個 Google 帳號；不要在 Antigravity 按 Sign Out。登入完成後返回此工具確認，工具會自動儲存新帳號。`r`n`r`n執行中的任務會中斷。是否繼續？", '引導登入 Antigravity 新帳號', 'YesNo', 'Information')
    if ($answer -ne 'Yes') { return }

    Write-SwitcherLog 'INFO' '開始引導登入 Antigravity 新帳號'
    Backup-AGCurrent $current ''
    Save-AGBackup $current '新增帳號前還原點' (Join-Path $script:AGStorePath 'last-switch.rollback')
    $cleared = $false
    try {
        Set-Status '正在關閉 Antigravity，準備登入新帳號…'
        Stop-AGDesktop $app
        [AntigravitySwitcher.Credentials]::DeleteForRollback($script:AGCredentialTarget)
        $cleared = $true
        if (Get-AGCurrentOrNull) { throw '本機登入項目未清除。' }
        Start-AGDesktop $app
        $done = [Windows.Forms.MessageBox]::Show("請在 Antigravity 完成新帳號的瀏覽器登入。`r`n`r`n確認 Account 頁顯示新帳號後，按「確定」讓工具儲存；若要取消，按「取消」，工具會恢復原帳號。", '等待 Antigravity 新帳號登入', 'OKCancel', 'Information')
        if ($done -ne 'OK') { throw '已取消新增帳號。' }
        $newCurrent = Read-AGCurrent
        if ($newCurrent.Identity.Key -eq $current.Identity.Key) { throw '登入帳號未變更，已取消新增。' }
        $name = Prompt-AccountName $newCurrent.Identity.Email $newCurrent.Identity.Email
        if (!$name) { $name = $newCurrent.Identity.Email }
        Save-AGBackup $newCurrent $name ''
        Write-SwitcherLog 'INFO' 'Antigravity 新帳號已儲存' "Key=$($newCurrent.Identity.Key)"
        Set-Status '新帳號已加密儲存；請在 Antigravity Account 頁確認登入狀態。'
    } catch {
        $failure = $_
        if ($cleared) {
            try {
                Stop-AGDesktop $app
                [AntigravitySwitcher.Credentials]::Write($script:AGCredentialTarget, $current.Entry)
                $restored = Read-AGCurrent
                if ([Convert]::ToBase64String($restored.Entry.Blob) -ne [Convert]::ToBase64String($current.Entry.Blob)) { throw '還原驗證失敗。' }
                Start-AGDesktop $app
            } catch {
                throw '新增帳號未完成，且自動還原失敗。加密還原點仍在，請從工具執行「還原上次切換」。'
            }
        }
        throw $failure
    }
}

function Invoke-AGSelfTest {
    $originalStore = $script:StorePath
    $originalAGStore = $script:AGStorePath
    $originalTarget = $script:AGCredentialTarget
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('AGSwitcherTest-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($sandbox) | Out-Null
    $script:StorePath = Join-Path $sandbox 'backups'
    $script:AGStorePath = Join-Path $script:StorePath 'antigravity'
    $script:AGCredentialTarget = 'CodexSwitcherTest-' + [guid]::NewGuid().ToString('N')
    try {
        Initialize-AGCredential
        function Check-AG([bool]$Condition, [string]$Message) { if (!$Condition) { throw ('Antigravity 測試失敗：' + $Message) } }
        function Fake-AG([string]$Id, [string]$Token) {
            $claims = @{ sub=$Id; email=($Id + '@example.invalid') } | ConvertTo-Json -Compress
            $jwt = 'test.' + [Convert]::ToBase64String($script:Utf8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.test'
            $entry = New-Object AntigravitySwitcher.CredentialEntry
            $entry.Blob = $script:Utf8.GetBytes((@{ token=@{ access_token=$Token; refresh_token=('refresh-' + $Token) }; auth_method='oauth'; id_token=$jwt } | ConvertTo-Json -Depth 4 -Compress))
            $entry.UserName = 'antigravity'
            $entry.Persist = 2
            return $entry
        }
        $preserved = @{}
        foreach ($relative in @('app_storage.json','workspaceStorage\existing','brain\existing')) {
            $path = Join-Path $sandbox $relative
            $value = 'existing-' + $relative
            Write-Atomic $path $script:Utf8.GetBytes($value)
            $preserved[$path] = $value
        }
        $a = Fake-AG 'A' 'old-A'
        $updated = Fake-AG 'A' 'new-A'
        $b = Fake-AG 'B' 'token-B'
        [AntigravitySwitcher.Credentials]::Write($script:AGCredentialTarget, $a)
        $current = Read-AGCurrent
        Check-AG ($current.Identity.Email -eq 'A@example.invalid') '讀取 Windows 認證管理員與 ID Token 身分'
        Save-AGBackup $current '帳號 A' ''
        $aPath = Join-Path $script:AGStorePath ($current.Identity.Key + '.bin')
        Check-AG ((Read-AGBackup $aPath).Name -eq '帳號 A') 'DPAPI 備份往返'
        Check-AG (![IO.File]::ReadAllText($aPath).Contains('old-A')) '備份不是明文'
        [AntigravitySwitcher.Credentials]::Write($script:AGCredentialTarget, $updated)
        Install-AGCredential $b
        Check-AG ((Read-AGCurrent).Identity.Email -eq 'B@example.invalid') '切換目標帳號'
        Check-AG ([Convert]::ToBase64String((Read-AGBackup $aPath).Entry.Blob) -eq [Convert]::ToBase64String($updated.Blob)) '切換前保存最新 Token'
        $rollback = Read-AGBackup (Join-Path $script:AGStorePath 'last-switch.rollback')
        Install-AGCredential $rollback.Entry
        Check-AG ((Read-AGCurrent).Identity.Email -eq 'A@example.invalid') '還原原帳號'
        $before = [Convert]::ToBase64String((Read-AGCurrent).Entry.Blob)
        $bad = New-Object AntigravitySwitcher.CredentialEntry
        $bad.Blob = $script:Utf8.GetBytes('{}')
        $bad.UserName = 'antigravity'; $bad.Persist = 2
        $rejected = $false
        try { Install-AGCredential $bad | Out-Null } catch { $rejected = $true }
        Check-AG ($rejected -and $before -eq [Convert]::ToBase64String((Read-AGCurrent).Entry.Blob)) '無效目標不修改認證'
        [AntigravitySwitcher.Credentials]::DeleteForRollback($script:AGCredentialTarget)
        Check-AG ($null -eq (Get-AGCurrentOrNull)) '測試認證清除'
        $savedA = Read-AGBackup $aPath
        Install-AGCredential $savedA.Entry
        Check-AG ((Read-AGCurrent).Identity.Email -eq 'A@example.invalid') '未登入狀態可恢復備份'
        foreach ($path in $preserved.Keys) {
            Check-AG ([IO.File]::Exists($path) -and [IO.File]::ReadAllText($path) -ceq $preserved[$path]) '工作區及對話資料保持原文'
        }
        'PASS: Antigravity 合成憑證讀寫、身分解析、DPAPI 備份、切換與還原。未讀寫真實憑證。'
    } finally {
        if ('AntigravitySwitcher.Credentials' -as [type]) { [AntigravitySwitcher.Credentials]::DeleteForRollback($script:AGCredentialTarget) }
        $script:StorePath = $originalStore
        $script:AGStorePath = $originalAGStore
        $script:AGCredentialTarget = $originalTarget
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ([IO.Path]::GetFullPath($sandbox).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $sandbox -Leaf) -like 'AGSwitcherTest-*') { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    }
}
