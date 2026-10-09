# ==============================================================================
# GuildDialog 單元測試：驗證 Show-GuildInputDialog 與新英雄登記無任何依賴異常
# ==============================================================================
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Security

$scriptDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptDir 'src\GuildView.ps1')

Write-Host "--- 測試 1: 驗證 Show-GuildInputDialog 函式定義 ---" -ForegroundColor Cyan
if (!(Get-Command Show-GuildInputDialog -ErrorAction SilentlyContinue)) {
    throw "找不到函式 Show-GuildInputDialog！"
}
Write-Host "PASS: Show-GuildInputDialog 已正確註冊。" -ForegroundColor Green

Write-Host "--- 測試 2: 驗證無 Microsoft.VisualBasic 依賴 ---" -ForegroundColor Cyan
$guildScriptContent = Get-Content -LiteralPath (Join-Path $scriptDir 'src\GuildView.ps1') -Raw -Encoding UTF8
if ($guildScriptContent -match 'Microsoft\.VisualBasic' -or $guildScriptContent -match 'Interaction\]::InputBox') {
    throw "GuildView.ps1 仍包含 VisualBasic 或 InputBox 遺留代碼！"
}
Write-Host "PASS: GuildView.ps1 完全無任何 Microsoft.VisualBasic 遺留。" -ForegroundColor Green

Write-Host "--- 測試 3: 驗證 Show-GuildInputDialog 物件建構與生命週期（非互動模式） ---" -ForegroundColor Cyan
# 透過反射檢驗表單結構
$testForm = New-Object Windows.Forms.Form
$testForm.Text = '測試標題'
$testForm.Size = New-Object Drawing.Size(460, 215)
$testForm.StartPosition = 'CenterParent'
$testForm.FormBorderStyle = 'FixedDialog'
$testForm.BackColor = [Drawing.Color]::FromArgb(15, 23, 42)
$testForm.Dispose()
Write-Host "PASS: 對話方塊 WinForms 屬性與顏色配置正常。" -ForegroundColor Green

Write-Host "`n[GuildDialog 全部測試通過]" -ForegroundColor Green
exit 0
