@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title Codex 帳號切換工具 - 解除安裝精靈

echo ========================================================
echo   Codex 帳號切換工具 - 解除安裝精靈
echo ========================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& {
    $dest = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\CodexAntigravitySwitcher'
    $store = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexAntigravitySwitcher'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    
    # 移除捷徑
    $scDesk = Join-Path $desktop 'Codex 與 Antigravity 帳號切換.lnk'
    if (Test-Path -LiteralPath $scDesk) {
        Remove-Item -LiteralPath $scDesk -Force -ErrorAction SilentlyContinue
        Write-Host '[已移除] 桌面捷徑' -ForegroundColor Yellow
    }
    
    $scStart = Join-Path $startMenu 'Codex 與 Antigravity 帳號切換.lnk'
    if (Test-Path -LiteralPath $scStart) {
        Remove-Item -LiteralPath $scStart -Force -ErrorAction SilentlyContinue
        Write-Host '[已移除] 開始功能表捷徑' -ForegroundColor Yellow
    }
    
    # 移除註冊表
    try {
        $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexAntigravitySwitcher'
        if (Test-Path $regKey) {
            Remove-Item -Path $regKey -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host '[已移除] 系統應用程式註冊資訊' -ForegroundColor Yellow
        }
    } catch { }

    # 詢問是否清除儲存的本機帳號快照
    Write-Host ''
    $ans = Read-Host '是否一併清除本機已儲存的帳號加密快照目錄 ($store)？(Y/N，預設 N)'
    if ($ans -eq 'Y' -or $ans -eq 'y') {
        if (Test-Path -LiteralPath $store) {
            Remove-Item -LiteralPath $store -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host '[已清除] 本機帳號加密快照目錄' -ForegroundColor Yellow
        }
    }
    
    # 延遲移除安裝目錄
    if (Test-Path -LiteralPath $dest) {
        Start-Process cmd.exe -ArgumentList ('/c timeout /t 1 >nul & rmdir /s /q \"' + $dest + '\"') -WindowStyle Hidden
        Write-Host '[已排程移除] 主程式目錄: ' $dest -ForegroundColor Yellow
    }
    
    Write-Host ''
    Write-Host '[完成] Codex 帳號切換工具已順利解除安裝。' -ForegroundColor Green
}"

pause
