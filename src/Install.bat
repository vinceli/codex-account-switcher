@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title Codex 帳號切換工具 - 一鍵安裝精靈

echo ========================================================
echo   Codex 帳號切換工具 - 本機部署精靈
echo ========================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& {
    $src = $PSScriptRoot
    $dest = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\CodexAccountSwitcher'
    if (!(Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }
    
    $files = @('CodexAccountSwitcher.exe', 'CodexAccountSwitcher.ps1', '使用說明.md', 'Uninstall.bat')
    foreach ($f in $files) {
        $sf = Join-Path $src $f
        if (Test-Path -LiteralPath $sf) {
            Copy-Item -LiteralPath $sf -Destination (Join-Path $dest $f) -Force
        }
    }
    
    $wsh = New-Object -ComObject WScript.Shell
    $targetExe = Join-Path $dest 'CodexAccountSwitcher.exe'
    
    # 建立桌面捷徑
    $desktop = [Environment]::GetFolderPath('Desktop')
    $scDesk = $wsh.CreateShortcut((Join-Path $desktop 'Codex 帳號切換.lnk'))
    $scDesk.TargetPath = $targetExe
    $scDesk.WorkingDirectory = $dest
    $scDesk.Description = 'Codex 帳號切換工具'
    $scDesk.Save()
    
    # 建立開始功能表捷徑
    $startMenu = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    $scStart = $wsh.CreateShortcut((Join-Path $startMenu 'Codex 帳號切換.lnk'))
    $scStart.TargetPath = $targetExe
    $scStart.WorkingDirectory = $dest
    $scStart.Description = 'Codex 帳號切換工具'
    $scStart.Save()
    
    # 註冊 Windows 應用程式清單
    try {
        $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexAccountSwitcher'
        if (!(Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
        Set-ItemProperty -Path $regKey -Name 'DisplayName' -Value 'Codex 帳號切換工具'
        Set-ItemProperty -Path $regKey -Name 'DisplayVersion' -Value '1.0.0'
        Set-ItemProperty -Path $regKey -Name 'Publisher' -Value 'Codex Tools'
        Set-ItemProperty -Path $regKey -Name 'InstallLocation' -Value $dest
        Set-ItemProperty -Path $regKey -Name 'UninstallString' -Value ('\"' + (Join-Path $dest 'Uninstall.bat') + '\"')
        Set-ItemProperty -Path $regKey -Name 'DisplayIcon' -Value $targetExe
    } catch { }
    
    Write-Host '[成功] 已安裝至: ' $dest -ForegroundColor Green
    Write-Host '[成功] 已建立桌面捷徑與開始功能表捷徑！' -ForegroundColor Green
}"

echo.
echo 安裝完成！您可以直接從桌面捷徑開啟「Codex 帳號切換」。
pause
