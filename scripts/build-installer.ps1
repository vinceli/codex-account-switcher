# ==============================================================================
# Codex 帳號切換工具 - 自動化封裝與安全隔離審計建置腳本
# ==============================================================================
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = "1.1.0",
    [ValidatePattern('^Setup-CodexAntigravitySwitcher(?:-[A-Za-z0-9.]+)?\.exe$')][string]$SetupFileName = 'Setup-CodexAntigravitySwitcher.exe'
)

$ErrorActionPreference = 'Stop'
$baseDir = Split-Path -Parent $PSScriptRoot
if (!$baseDir -or !(Test-Path (Join-Path $baseDir 'src'))) {
    $baseDir = (Get-Location).Path
}

$srcDir = Join-Path $baseDir 'src'
$distDir = Join-Path $baseDir 'dist'
$stagingDir = Join-Path $baseDir ('work\staging-' + [guid]::NewGuid().ToString('N'))
$installerDir = Join-Path $baseDir 'work\installer'
$payloadZip = Join-Path $installerDir 'payload.zip'
$cscExe = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " [Build] 開始封裝 Codex 帳號切換工具 v$Version" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# 1. 準備目錄；僅清理本次建立的 staging，不刪除整個 dist。
$rootPrefix = [IO.Path]::GetFullPath($baseDir).TrimEnd('\') + '\'
foreach ($directory in @($stagingDir, $distDir, $installerDir)) {
    $absolute = [IO.Path]::GetFullPath($directory)
    if (!$absolute.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '建置目錄超出專案範圍。' }
    $ancestor = $absolute
    while ($ancestor -and $ancestor.TrimEnd('\') -ne $rootPrefix.TrimEnd('\')) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '建置目錄不可使用連結或 junction。' }
        $ancestor = Split-Path -Parent $ancestor
    }
}
if (!(Test-Path $installerDir)) { New-Item -ItemType Directory -Path $installerDir -Force | Out-Null }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
New-Item -ItemType Directory -Path $distDir -Force | Out-Null

# 2. 編譯 Launcher (內嵌圖示)
$launcherExe = Join-Path $srcDir 'CodexAccountSwitcher.exe'
$launcherCs = Join-Path $srcDir 'Launcher.cs'
$appIco = Join-Path $srcDir 'app.ico'
$iconArg = if (Test-Path -LiteralPath $appIco) { "/win32icon:`"$appIco`"" } else { "" }
if (Test-Path $launcherCs) {
    Write-Host "編譯啟動器: $launcherExe..."
    & $cscExe /target:winexe $iconArg /out:"$launcherExe" "$launcherCs" | Out-Null
}

# 3. 嚴格白名單複製
$whitelist = @(
    'CodexAccountSwitcher.exe',
    'CodexAccountSwitcher.ps1',
    'AntigravityCredential.ps1',
    'AntigravityQuota.ps1',
    'GuildView.ps1',
    'WebDashboard.ps1',
    'Launcher.cs',
    'Install.bat',
    'Uninstall.bat',
    'app.ico'
)

Write-Host "`n[Step 1/5] 執行白名單複製 (Whitelist Copy)..." -ForegroundColor Yellow
foreach ($fileName in $whitelist) {
    $srcFile = Join-Path $srcDir $fileName
    if (!(Test-Path -LiteralPath $srcFile)) {
        throw "[錯誤] 缺少必要的發行檔案: $srcFile"
    }
    Copy-Item -LiteralPath $srcFile -Destination (Join-Path $stagingDir $fileName) -Force
    Write-Host "  + 已加入白名單: $fileName" -ForegroundColor Gray
}

# 加入素材資源目錄
$assetsSrc = Join-Path $srcDir 'assets'
if (Test-Path $assetsSrc) {
    Copy-Item -Path $assetsSrc -Destination $stagingDir -Recurse -Force
    Write-Host "  + 已加入資源目錄: assets/" -ForegroundColor Gray
}

# 加入說明檔
$readmeSrc = Join-Path $baseDir 'README.md'
if (Test-Path $readmeSrc) {
    Copy-Item -LiteralPath $readmeSrc -Destination (Join-Path $stagingDir '使用說明.md') -Force
    Write-Host "  + 已加入白名單: 使用說明.md (來源: README.md)" -ForegroundColor Gray
}

# 4. 機敏資料檢查閘門 (Zero-Credential Security Gate)
Write-Host "`n[Step 2/5] 執行機敏資料檢查閘門 (Security Gate)..." -ForegroundColor Yellow

# 4.1 檔名/副檔名黑名單檢查
$forbiddenPatterns = @('*.bin', '*.rollback', '*.log', 'auth.json', 'auth.*.json', '*.jwt', '*.key', '*.env', '.env*', '*.token')
foreach ($pattern in $forbiddenPatterns) {
    $leaks = Get-ChildItem -Path $stagingDir -Filter $pattern -Recurse -File
    if ($leaks.Count -gt 0) {
        throw "[重大安全威脅] 發現機敏或暫存檔案已被帶入打包清單: $($leaks[0].FullName)"
    }
}
Write-Host "  [PASS] 檔名與副檔名黑名單檢查通過 (無 .bin, .log, auth.json 等憑證檔)" -ForegroundColor Green

# 4.2 敏感字串/憑證特徵掃描 (僅掃描文字格式檔案)
$sensitivePatterns = @(
    'Bearer\s+[A-Za-z0-9\-_]{30,}',
    'sess-[A-Za-z0-9]{30,}',
    'sk-[A-Za-z0-9\-_]{30,}',
    'refresh-[a-zA-Z0-9\-_]{20,}'
)

$binaryExtensions = @('.png', '.ico', '.exe', '.dll', '.zip')
foreach ($file in Get-ChildItem -Path $stagingDir -Recurse -File) {
    if ($binaryExtensions -contains $file.Extension.ToLowerInvariant()) {
        continue
    }
    $content = [IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    foreach ($pat in $sensitivePatterns) {
        if ($content -match $pat) {
            throw "[重大安全威脅] 在檔案 $($file.Name) 中發現機敏字串匹配: $pat"
        }
    }
}
Write-Host "  [PASS] 內容敏感字串與個人憑證掃描通過 (無任何真實 Token、Session 特徵)" -ForegroundColor Green

# 5. 產生免安裝發行包 (Portable.zip)
Write-Host "`n[Step 3/5] 封裝免安裝發行包 (Portable.zip)..." -ForegroundColor Yellow
$portableZip = Join-Path $distDir "CodexAccountSwitcher-v$Version-Portable.zip"
if (Test-Path -LiteralPath $portableZip) { Remove-Item -LiteralPath $portableZip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $portableZip)
Write-Host "  [OK] 已產出: $portableZip ($( [Math]::Round((Get-Item $portableZip).Length / 1KB, 2) ) KB)" -ForegroundColor Green

# 6. 編譯自包含 GUI 安裝程式 (Setup-CodexAccountSwitcher.exe)
Write-Host "`n[Step 4/5] 編譯自包含單一安裝程式 (Setup-CodexAccountSwitcher.exe)..." -ForegroundColor Yellow
if (Test-Path $payloadZip) { Remove-Item -LiteralPath $payloadZip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $payloadZip)

$installerCs = Join-Path $srcDir 'Installer.cs'
$setupExe = Join-Path $distDir $SetupFileName

$compileArgs = @(
    "/target:winexe",
    "/out:`"$setupExe`"",
    "/resource:`"$payloadZip`",payload.zip"
)
if (Test-Path -LiteralPath $appIco) {
    $compileArgs += "/win32icon:`"$appIco`""
}
$compileArgs += @(
    "/r:System.dll",
    "/r:System.Windows.Forms.dll",
    "/r:System.Drawing.dll",
    "/r:System.IO.Compression.dll",
    "/r:System.IO.Compression.FileSystem.dll",
    "/r:Microsoft.CSharp.dll",
    "`"$installerCs`""
)

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $cscExe
$psi.Arguments = $compileArgs -join ' '
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$proc = [Diagnostics.Process]::Start($psi)
$out = $proc.StandardOutput.ReadToEnd()
$err = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

if ($proc.ExitCode -ne 0) {
    Write-Host $out
    Write-Host $err -ForegroundColor Red
    throw "[錯誤] csc.exe 編譯安裝程式失敗 (ExitCode: $($proc.ExitCode))"
}

Remove-Item -LiteralPath $payloadZip -Force -ErrorAction SilentlyContinue
Write-Host "  [OK] 已產出自包含單檔安裝程式: $setupExe ($( [Math]::Round((Get-Item $setupExe).Length / 1KB, 2) ) KB)" -ForegroundColor Green

# 7. 計算 SHA256 雜湊
Write-Host "`n[Step 5/5] 計算發行檔案 SHA-256 雜湊..." -ForegroundColor Yellow
$hashTxt = Join-Path $distDir 'SHA256SUMS.txt'
$hashes = @()
foreach ($distFile in Get-Item -LiteralPath $setupExe, $portableZip) {
    $h = (Get-FileHash -Path $distFile.FullName -Algorithm SHA256).Hash
    $hashes += "$h  $($distFile.Name)"
    Write-Host "  $($distFile.Name) : $h" -ForegroundColor Gray
}
[IO.File]::WriteAllLines($hashTxt, $hashes, (New-Object Text.UTF8Encoding($false)))

# 8. 清理臨時 staging
Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host " [成功] Codex 帳號切換工具封裝完成！發行檔案位於:" -ForegroundColor Green
Write-Host " 1. $setupExe (自包含單檔安裝程式)" -ForegroundColor White
Write-Host " 2. $portableZip (綠色免安裝/腳本發行包)" -ForegroundColor White
Write-Host " 3. $hashTxt (完整性校驗值)" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Cyan
