$ErrorActionPreference = 'Stop'
$script:StorePath = 'C:\AGProcessTest\backups'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\AntigravityCredential.ps1')

function Check([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw ('Antigravity 程序測試失敗：' + $Message) }
}
function New-TestProcess([int]$Id, [int]$Parent, [string]$Path, [datetime]$Created = [datetime]'2026-10-19T10:00:00') {
    [pscustomobject]@{ ProcessId=$Id; ParentProcessId=$Parent; ExecutablePath=$Path; Name=[IO.Path]::GetFileName($Path); CreationDate=$Created }
}
function Reset-TestState([object[]]$Processes) {
    $script:Processes = @($Processes)
    $script:Stopped = @(); $script:Closed = @()
    $script:Graceful = @(10); $script:Blocked = @()
    $script:Clock = [datetime]'2026-10-19T11:00:00'
    $script:Snapshots = 0; $script:OnSnapshot = $null
}
function Get-CimInstance([string]$ClassName) {
    if ($ClassName -ne 'Win32_Process') { throw '非預期的程序查詢' }
    $script:Snapshots++
    if ($script:OnSnapshot) { & $script:OnSnapshot }
    $script:Processes
}
function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    if (!($script:Processes | Where-Object { $_.ProcessId -eq $Id })) { return }
    $process = [pscustomobject]@{ Id=$Id; HasExited=$false; MainWindowHandle=[IntPtr]1 }
    $process | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value {
        $script:Closed += $this.Id
        if ($script:Graceful -contains $this.Id) {
            $script:Processes = @($script:Processes | Where-Object { $_.ProcessId -ne $this.Id })
        }
        return $true
    }
    $process
}
function Stop-Process {
    [CmdletBinding()]
    param([int]$Id, [switch]$Force)
    if (!$Force) { throw '殘留程序必須使用強制關閉' }
    $script:Stopped += $Id
    if ($script:Blocked -notcontains $Id) {
        $script:Processes = @($script:Processes | Where-Object { $_.ProcessId -ne $Id })
    }
}
function Get-Date { $script:Clock }
function Start-Sleep([int]$Milliseconds) { $script:Clock = $script:Clock.AddMilliseconds($Milliseconds) }

$app = [pscustomobject]@{ Exe='C:\AGProcessTest\Antigravity.exe' }
$helper = 'C:\AGProcessTest\resources\bin\language_server.exe'
$unrelated = 'C:\OtherApp\language_server.exe'

Reset-TestState @(
    (New-TestProcess 10 1 $app.Exe),
    (New-TestProcess 11 10 $helper),
    (New-TestProcess 12 11 'C:\Task\worker.exe'),
    (New-TestProcess 20 999 $helper),
    (New-TestProcess 21 20 'C:\Task\orphan-worker.exe'),
    (New-TestProcess 30 1 $unrelated),
    (New-TestProcess 31 10 'C:\OtherApp\stale-parent.exe' ([datetime]'2026-10-19T09:00:00'))
)
Stop-AGDesktop $app
Check (($script:Closed -join ',') -eq '10') '先要求桌面版正常關閉'
Check ((($script:Stopped | Sort-Object) -join ',') -eq '11,12,20,21') '自動結束殘留、孤兒語言服務及其子程序'
Check ((($script:Processes.ProcessId | Sort-Object) -join ',') -eq '30,31') '其他安裝目錄的同名服務與父 PID 重用前的舊程序保持執行'

Reset-TestState @((New-TestProcess 10 1 $app.Exe), (New-TestProcess 11 10 $helper))
$script:Graceful = @()
Stop-AGDesktop $app
Check ((($script:Stopped | Sort-Object) -join ',') -eq '10,11') '桌面版未正常退出時自動強制關閉'

Reset-TestState @((New-TestProcess 20 999 $helper))
Stop-AGDesktop $app
Check (($script:Stopped -join ',') -eq '20') '桌面版已關閉時仍清理舊語言服務'

Reset-TestState @((New-TestProcess 10 1 $app.Exe))
$script:OnSnapshot = {
    if ($script:Snapshots -eq 3) {
        $script:Processes += (New-TestProcess 22 999 $helper), (New-TestProcess 23 22 'C:\Task\late-worker.exe')
    }
}
Stop-AGDesktop $app
Check ((($script:Stopped | Sort-Object) -join ',') -eq '22,23') '納入正常關閉期間才出現的語言服務及子程序'

Reset-TestState @((New-TestProcess 10 1 $app.Exe), (New-TestProcess 11 10 $helper), (New-TestProcess 12 11 'C:\Task\worker.exe'))
$script:OnSnapshot = {
    if ($script:Snapshots -eq 3) {
        $script:Processes = @((New-TestProcess 12 1 'C:\OtherApp\reused.exe' ([datetime]'2026-10-19T10:30:00')))
    }
}
Stop-AGDesktop $app
Check ($script:Stopped.Count -eq 0 -and $script:Processes[0].ProcessId -eq 12) 'PID 重複使用且建立時間不同時不終止新程序'

Reset-TestState @((New-TestProcess 10 1 $app.Exe), (New-TestProcess 11 10 $helper))
$script:Blocked = @(11)
$rejected = $false
try { Stop-AGDesktop $app } catch { $rejected = $_.Exception.Message -like '*認證尚未替換*' }
Check ($rejected -and $script:Processes[0].ProcessId -eq 11) '實際無法終止背景服務時阻止後續認證切換'

foreach ($client in @('agy.exe','Antigravity IDE.exe')) {
    Reset-TestState @((New-TestProcess 10 1 $app.Exe), (New-TestProcess 40 1 ('C:\OtherClient\' + $client)))
    $rejected = $false
    try { Stop-AGDesktop $app } catch { $rejected = $_.Exception.Message -like '*其他用戶端*' }
    Check ($rejected -and !$script:Stopped.Count -and !$script:Closed.Count) '其他 CLI 或 IDE 執行時保留原有阻擋'
}

'PASS: Antigravity 正常關閉、強制結束、孤兒服務、子程序、新增服務、PID 重用與失敗阻擋。全程模擬程序，未終止真實程序或讀寫認證。'
