# ==============================================================================
# Codex 帳號切換工具 - 自動化自我測試 (SelfTest Runner)
# ==============================================================================
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSScriptRoot
$switcherScript = Join-Path $scriptDir 'src\CodexAccountSwitcher.ps1'

if (!(Test-Path -LiteralPath $switcherScript)) {
    throw "[錯誤] 找不到測試目標: $switcherScript"
}

Write-Host "=== 執行 CodexAccountSwitcher 核心邏輯自我驗證 ===" -ForegroundColor Cyan
$result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $switcherScript -SelfTest
Write-Host $result

if ($LASTEXITCODE -eq 0 -and $result -match '^PASS') {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Quota.Tests.ps1')
    if ($LASTEXITCODE -ne 0) { exit 1 }
    Write-Host "`n[測試通過] 所有加密、識別、快照、還原與工作區保留測試皆符合預期！" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n[測試失敗] 自我測試未回傳 PASS！" -ForegroundColor Red
    exit 1
}
