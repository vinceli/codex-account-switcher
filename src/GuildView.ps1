# ==============================================================================
# CodexAccountSwitcher - 冒險者公會風格戰情室 (Guild Cockpit View)
# ==============================================================================

$script:CurrentViewMode = 'Classic'
$script:CurrentGuildProduct = 'Codex'
$script:EnableSmartRotate = $true
$script:GuildImageCache = @{}
$script:CurrentVanguardPose = 'energetic'
$script:MotionFrame = 0
$script:LastGuildFingerprint = ''
$script:RosterCardControls = @()

function Enable-DoubleBuffering($Control) {
    try {
        $prop = $Control.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($prop) { $prop.SetValue($Control, $true, $null) }
    } catch { }
}


function Show-GuildInputDialog([string]$Prompt, [string]$Title, [string]$DefaultText = '') {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Size = New-Object Drawing.Size(460, 215)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = [Drawing.Color]::FromArgb(15, 23, 42) # #0F172A 深夜藍
    $dialog.ForeColor = [Drawing.Color]::White

    $lblPrompt = New-Object Windows.Forms.Label
    $lblPrompt.Text = $Prompt
    $lblPrompt.SetBounds(25, 20, 400, 36)
    $lblPrompt.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10, [Drawing.FontStyle]::Bold)
    $lblPrompt.ForeColor = [Drawing.Color]::FromArgb(243, 196, 91) # 公會金
    $dialog.Controls.Add($lblPrompt)

    $txtInput = New-Object Windows.Forms.TextBox
    $txtInput.Text = $DefaultText
    $txtInput.SetBounds(25, 62, 395, 30)
    $txtInput.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10)
    $txtInput.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $txtInput.ForeColor = [Drawing.Color]::White
    $txtInput.BorderStyle = 'FixedSingle'
    $dialog.Controls.Add($txtInput)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = '確定登記'
    $btnOk.SetBounds(210, 115, 100, 36)
    $btnOk.FlatStyle = 'Flat'
    $btnOk.BackColor = [Drawing.Color]::FromArgb(243, 196, 91)
    $btnOk.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
    $btnOk.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9.5, [Drawing.FontStyle]::Bold)
    $btnOk.Cursor = [Windows.Forms.Cursors]::Hand
    $btnOk.DialogResult = [Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnOk)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.SetBounds(320, 115, 100, 36)
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.BackColor = [Drawing.Color]::FromArgb(51, 65, 85)
    $btnCancel.ForeColor = [Drawing.Color]::White
    $btnCancel.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9.5)
    $btnCancel.Cursor = [Windows.Forms.Cursors]::Hand
    $btnCancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($btnCancel)

    $dialog.AcceptButton = $btnOk
    $dialog.CancelButton = $btnCancel

    $dialog.Add_Shown({
        $txtInput.Focus()
        $txtInput.SelectAll()
    })

    $parentForm = if ($script:GuildPanel) { $script:GuildPanel.FindForm() } else { $null }
    $result = if ($parentForm) { $dialog.ShowDialog($parentForm) } else { $dialog.ShowDialog() }

    $inputText = $null
    if ($result -eq [Windows.Forms.DialogResult]::OK -and !([string]::IsNullOrWhiteSpace($txtInput.Text))) {
        $inputText = $txtInput.Text.Trim()
    }
    $dialog.Dispose()
    return $inputText
}


function Get-UiPreference {
    $prefFile = Join-Path $script:StorePath 'ui-pref.json'
    $pref = [ordered]@{ ViewMode = 'Classic'; EnableSmartRotate = $true; GuildProduct = 'Codex' }
    if (Test-Path -LiteralPath $prefFile) {
        try {
            $json = [IO.File]::ReadAllText($prefFile, $script:Utf8) | ConvertFrom-Json
            if ($json.ViewMode -in @('Classic', 'Guild')) { $pref.ViewMode = $json.ViewMode }
            if ($null -ne $json.EnableSmartRotate) { $pref.EnableSmartRotate = [bool]$json.EnableSmartRotate }
            if ($json.GuildProduct -in @('Codex', 'Antigravity')) { $pref.GuildProduct = $json.GuildProduct }
        } catch { }
    }
    return $pref
}

function Set-UiPreference($Pref) {
    try {
        if (!(Test-Path -LiteralPath $script:StorePath)) { [IO.Directory]::CreateDirectory($script:StorePath) | Out-Null }
        $prefFile = Join-Path $script:StorePath 'ui-pref.json'
        $json = $Pref | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($prefFile, $json, $script:Utf8)
    } catch { }
}

function Get-GuildHeroFrame([string]$Product, [string]$Pose, [int]$Frame = 0) {
    $prefix = if ($Product -eq 'Antigravity') { 'antigravity-orbit-artificer' } else { 'codex-rune-knight' }
    
    $fileCandidate = if ($Frame -eq 1) {
        "$prefix-$Pose-motion-1.png"
    } else {
        if ($Pose -eq 'energetic') { "$prefix.png" } else { "$prefix-$Pose.png" }
    }
    
    $cacheKey = "$Product|$Pose|$Frame"
    if ($script:GuildImageCache.ContainsKey($cacheKey) -and $null -ne $script:GuildImageCache[$cacheKey]) {
        return $script:GuildImageCache[$cacheKey]
    }
    
    $searchPaths = @(
        (Join-Path $PSScriptRoot "assets\guild\$fileCandidate"),
        (Join-Path (Split-Path $PSScriptRoot -Parent) "srcssets\guild\$fileCandidate")
    )
    foreach ($p in $searchPaths) {
        if (Test-Path -LiteralPath $p) {
            try {
                $img = [Drawing.Image]::FromFile($p)
                $script:GuildImageCache[$cacheKey] = $img
                return $img
            } catch { }
        }
    }
    if ($Frame -ne 0) {
        return (Get-GuildHeroFrame $Product $Pose 0)
    }
    return $null
}

function Get-GuildHeroImage([string]$Product, [string]$Pose) {
    return (Get-GuildHeroFrame $Product $Pose 0)
}

function Get-HeroPose([object]$RemainingPercent, [string]$Status) {
    if ($Status -in @('需重新授權', '存取受限') -or ($null -ne $RemainingPercent -and $RemainingPercent -le 0)) {
        return 'exhausted'
    }
    if ($Status -in @('稍後重試', '受到限流') -or ($null -ne $RemainingPercent -and $RemainingPercent -le 20)) {
        return 'tired'
    }
    return 'energetic'
}

function Initialize-GuildView {
    $pref = Get-UiPreference
    $script:CurrentViewMode = if ($PreviewPath) { 'Classic' } else { $pref.ViewMode }
    $script:EnableSmartRotate = $pref.EnableSmartRotate
    $script:CurrentGuildProduct = $pref.GuildProduct

    # 1. 建立傳統清單視圖下的切換按鈕（置於兩個分頁右上角日誌按鈕左側）
    $btnToGuildCodex = New-Object Windows.Forms.Button
    $btnToGuildCodex.Text = '切換公會戰情室 (Guild)'
    $btnToGuildCodex.SetBounds(740, 16, 182, 36)
    $btnToGuildCodex.FlatStyle = 'Flat'
    $btnToGuildCodex.BackColor = [Drawing.Color]::FromArgb(235, 238, 242)
    $btnToGuildCodex.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $btnToGuildCodex.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9, [Drawing.FontStyle]::Bold)
    $btnToGuildCodex.Cursor = [Windows.Forms.Cursors]::Hand
    $btnToGuildCodex.Add_Click({
        $script:CurrentGuildProduct = 'Codex'
        Set-ViewMode 'Guild'
    })
    $codexTab.Controls.Add($btnToGuildCodex)

    $btnToGuildAG = New-Object Windows.Forms.Button
    $btnToGuildAG.Text = '切換公會戰情室 (Guild)'
    $btnToGuildAG.SetBounds(740, 16, 182, 36)
    $btnToGuildAG.FlatStyle = 'Flat'
    $btnToGuildAG.BackColor = [Drawing.Color]::FromArgb(235, 238, 242)
    $btnToGuildAG.ForeColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $btnToGuildAG.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9, [Drawing.FontStyle]::Bold)
    $btnToGuildAG.Cursor = [Windows.Forms.Cursors]::Hand
    $btnToGuildAG.Add_Click({
        $script:CurrentGuildProduct = 'Antigravity'
        Set-ViewMode 'Guild'
    })
    $agTab.Controls.Add($btnToGuildAG)

    # 2. 建立公會戰情室容器面板
    $script:GuildPanel = New-Object Windows.Forms.Panel
    $script:GuildPanel.SetBounds(5, 5, 1130, 565)
    $script:GuildPanel.BackColor = [Drawing.Color]::FromArgb(11, 17, 32) # 午夜藍 #0B1120
    Enable-DoubleBuffering $script:GuildPanel
    $form.Controls.Add($script:GuildPanel)

    # 頂部戰情導航列
    $titleLbl = New-Object Windows.Forms.Label
    $titleLbl.Text = 'CODE AGENT 冒險者公會戰情室'
    $titleLbl.SetBounds(15, 12, 330, 28)
    $titleLbl.ForeColor = [Drawing.Color]::FromArgb(243, 196, 91) # 公會金 #F3C45B
    $titleLbl.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 13, [Drawing.FontStyle]::Bold)
    $script:GuildPanel.Controls.Add($titleLbl)

    # 來源切換按鈕組 (Codex vs Antigravity)
    $script:BtnGuildCodex = New-Object Windows.Forms.Button
    $script:BtnGuildCodex.Text = 'Codex 符文工會'
    $script:BtnGuildCodex.SetBounds(355, 10, 140, 30)
    $script:BtnGuildCodex.FlatStyle = 'Flat'
    $script:BtnGuildCodex.Cursor = [Windows.Forms.Cursors]::Hand
    $script:BtnGuildCodex.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9.5, [Drawing.FontStyle]::Bold)
    $script:BtnGuildCodex.Add_Click({
        $script:CurrentGuildProduct = 'Codex'
        $script:LastGuildFingerprint = '' # 強制更新
        $pref = Get-UiPreference; $pref.GuildProduct = 'Codex'; if (!$PreviewPath) { Set-UiPreference $pref }
        Update-GuildView
    })
    $script:GuildPanel.Controls.Add($script:BtnGuildCodex)

    $script:BtnGuildAG = New-Object Windows.Forms.Button
    $script:BtnGuildAG.Text = 'Antigravity 術士星軌'
    $script:BtnGuildAG.SetBounds(505, 10, 165, 30)
    $script:BtnGuildAG.FlatStyle = 'Flat'
    $script:BtnGuildAG.Cursor = [Windows.Forms.Cursors]::Hand
    $script:BtnGuildAG.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9.5, [Drawing.FontStyle]::Bold)
    $script:BtnGuildAG.Add_Click({
        $script:CurrentGuildProduct = 'Antigravity'
        $script:LastGuildFingerprint = '' # 強制更新
        $pref = Get-UiPreference; $pref.GuildProduct = 'Antigravity'; if (!$PreviewPath) { Set-UiPreference $pref }
        Update-GuildView
    })
    $script:GuildPanel.Controls.Add($script:BtnGuildAG)

    # 智慧輪替開關 Checkbox
    $script:ChkSmartRotate = New-Object Windows.Forms.CheckBox
    $script:ChkSmartRotate.Text = '啟用智慧輪替'
    $script:ChkSmartRotate.SetBounds(685, 14, 140, 24)
    $script:ChkSmartRotate.ForeColor = [Drawing.Color]::FromArgb(148, 163, 184)
    $script:ChkSmartRotate.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9)
    $script:ChkSmartRotate.Checked = $script:EnableSmartRotate
    $script:ChkSmartRotate.Add_CheckedChanged({
        $script:EnableSmartRotate = $script:ChkSmartRotate.Checked
        $script:LastGuildFingerprint = '' # 立即更新輪替狀態
        $pref = Get-UiPreference; $pref.EnableSmartRotate = $script:EnableSmartRotate; if (!$PreviewPath) { Set-UiPreference $pref }
        Update-GuildView
    })
    $script:GuildPanel.Controls.Add($script:ChkSmartRotate)

    # 公會視圖內的「切換傳統清單」按鈕
    $btnReturnClassic = New-Object Windows.Forms.Button
    $btnReturnClassic.Text = '切換為傳統清單 (Classic)'
    $btnReturnClassic.SetBounds(935, 10, 180, 30)
    $btnReturnClassic.FlatStyle = 'Flat'
    $btnReturnClassic.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $btnReturnClassic.ForeColor = [Drawing.Color]::FromArgb(243, 196, 91)
    $btnReturnClassic.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9, [Drawing.FontStyle]::Bold)
    $btnReturnClassic.Cursor = [Windows.Forms.Cursors]::Hand
    $btnReturnClassic.Add_Click({ Set-ViewMode 'Classic' })
    $script:GuildPanel.Controls.Add($btnReturnClassic)

    # 3. 左側先鋒主將卡片 (Vanguard Panel)
    $script:VanguardPanel = New-Object Windows.Forms.Panel
    $script:VanguardPanel.SetBounds(15, 48, 435, 480)
    $script:VanguardPanel.BackColor = [Drawing.Color]::FromArgb(20, 33, 61) # #14213D
    Enable-DoubleBuffering $script:VanguardPanel
    $script:GuildPanel.Controls.Add($script:VanguardPanel)

    $vHeader = New-Object Windows.Forms.Label
    $vHeader.Text = '【當前出戰先鋒】(Active Champion)'
    $vHeader.SetBounds(15, 10, 400, 24)
    $vHeader.ForeColor = [Drawing.Color]::FromArgb(243, 196, 91)
    $vHeader.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10, [Drawing.FontStyle]::Bold)
    $script:VanguardPanel.Controls.Add($vHeader)

    $script:VanguardPic = New-Object Windows.Forms.PictureBox
    $script:VanguardPic.SetBounds(145, 38, 145, 145)
    $script:VanguardPic.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
    $script:VanguardPic.BackColor = [Drawing.Color]::FromArgb(20, 33, 61)
    $script:VanguardPanel.Controls.Add($script:VanguardPic)

    $script:VanguardName = New-Object Windows.Forms.Label
    $script:VanguardName.SetBounds(15, 190, 405, 26)
    $script:VanguardName.ForeColor = [Drawing.Color]::White
    $script:VanguardName.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 13, [Drawing.FontStyle]::Bold)
    $script:VanguardName.TextAlign = 'MiddleCenter'
    $script:VanguardPanel.Controls.Add($script:VanguardName)

    $script:VanguardMeta = New-Object Windows.Forms.Label
    $script:VanguardMeta.SetBounds(15, 218, 405, 20)
    $script:VanguardMeta.ForeColor = [Drawing.Color]::FromArgb(148, 163, 184)
    $script:VanguardMeta.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9)
    $script:VanguardMeta.TextAlign = 'MiddleCenter'
    $script:VanguardPanel.Controls.Add($script:VanguardMeta)

    $script:VanguardStatus = New-Object Windows.Forms.Label
    $script:VanguardStatus.SetBounds(15, 242, 405, 24)
    $script:VanguardStatus.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9.5, [Drawing.FontStyle]::Bold)
    $script:VanguardStatus.TextAlign = 'MiddleCenter'
    $script:VanguardPanel.Controls.Add($script:VanguardStatus)

    # 5 小時能量條
    $script:VanguardBar1Lbl = New-Object Windows.Forms.Label
    $script:VanguardBar1Lbl.SetBounds(25, 274, 385, 20)
    $script:VanguardBar1Lbl.ForeColor = [Drawing.Color]::FromArgb(226, 232, 240)
    $script:VanguardBar1Lbl.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9)
    $script:VanguardPanel.Controls.Add($script:VanguardBar1Lbl)

    $script:VanguardBar1 = New-Object Windows.Forms.ProgressBar
    $script:VanguardBar1.SetBounds(25, 296, 385, 16)
    $script:VanguardPanel.Controls.Add($script:VanguardBar1)

    # 每週戰力槽
    $script:VanguardBar2Lbl = New-Object Windows.Forms.Label
    $script:VanguardBar2Lbl.SetBounds(25, 320, 385, 20)
    $script:VanguardBar2Lbl.ForeColor = [Drawing.Color]::FromArgb(226, 232, 240)
    $script:VanguardBar2Lbl.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9)
    $script:VanguardPanel.Controls.Add($script:VanguardBar2Lbl)

    $script:VanguardBar2 = New-Object Windows.Forms.ProgressBar
    $script:VanguardBar2.SetBounds(25, 342, 385, 16)
    $script:VanguardPanel.Controls.Add($script:VanguardBar2)

    # 先鋒操作按鈕
    $btnRefresh = New-Object Windows.Forms.Button
    $btnRefresh.Text = '刷新額度'
    $btnRefresh.SetBounds(25, 375, 185, 34)
    $btnRefresh.FlatStyle = 'Flat'
    $btnRefresh.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $btnRefresh.ForeColor = [Drawing.Color]::White
    $btnRefresh.Cursor = [Windows.Forms.Cursors]::Hand
    $btnRefresh.Add_Click({
        if ($script:CurrentGuildProduct -eq 'Antigravity') { Invoke-Action { Refresh-AGAccounts } }
        else { Invoke-Action { Refresh-Accounts } }
    })
    $script:VanguardPanel.Controls.Add($btnRefresh)

    $btnLaunch = New-Object Windows.Forms.Button
    $btnLaunch.Text = '啟動客戶端'
    $btnLaunch.SetBounds(225, 375, 185, 34)
    $btnLaunch.FlatStyle = 'Flat'
    $btnLaunch.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $btnLaunch.ForeColor = [Drawing.Color]::White
    $btnLaunch.Cursor = [Windows.Forms.Cursors]::Hand
    $btnLaunch.Add_Click({
        if ($script:CurrentGuildProduct -eq 'Antigravity') { Start-AntigravityApp }
        else { Start-DesktopApp (Get-DesktopApp) }
    })
    $script:VanguardPanel.Controls.Add($btnLaunch)

    # 智慧輪替按鈕 (嚴格遵循使用者的三項規則)
    $script:BtnVanguardRotate = New-Object Windows.Forms.Button
    $script:BtnVanguardRotate.Text = '智慧輪替：換最高戰力出戰'
    $script:BtnVanguardRotate.SetBounds(25, 422, 385, 38)
    $script:BtnVanguardRotate.FlatStyle = 'Flat'
    $script:BtnVanguardRotate.BackColor = [Drawing.Color]::FromArgb(243, 196, 91)
    $script:BtnVanguardRotate.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
    $script:BtnVanguardRotate.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10, [Drawing.FontStyle]::Bold)
    $script:BtnVanguardRotate.Cursor = [Windows.Forms.Cursors]::Hand
    $script:BtnVanguardRotate.Add_Click({ Invoke-SmartRotation })
    $script:VanguardPanel.Controls.Add($script:BtnVanguardRotate)

    # 4. 右側後備營地面板 (Roster Panel)
    $script:RosterPanel = New-Object Windows.Forms.Panel
    $script:RosterPanel.SetBounds(460, 48, 655, 480)
    $script:RosterPanel.BackColor = [Drawing.Color]::FromArgb(15, 23, 42) # #0F172A
    Enable-DoubleBuffering $script:RosterPanel
    $script:GuildPanel.Controls.Add($script:RosterPanel)

    $script:RosterHeader = New-Object Windows.Forms.Label
    $script:RosterHeader.Text = '【後備英雄營地】(Standby Roster)'
    $script:RosterHeader.SetBounds(15, 10, 400, 24)
    $script:RosterHeader.ForeColor = [Drawing.Color]::FromArgb(243, 196, 91)
    $script:RosterHeader.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 10, [Drawing.FontStyle]::Bold)
    $script:RosterPanel.Controls.Add($script:RosterHeader)

    $script:RosterScroll = New-Object Windows.Forms.Panel
    $script:RosterScroll.SetBounds(15, 38, 625, 385)
    $script:RosterScroll.AutoScroll = $true
    Enable-DoubleBuffering $script:RosterScroll
    $script:RosterPanel.Controls.Add($script:RosterScroll)

    $script:BtnRosterBackup = New-Object Windows.Forms.Button
    $script:BtnRosterBackup.Text = '+ 登記新英雄 (備份目前新登入帳號)'
    $script:BtnRosterBackup.SetBounds(15, 432, 280, 36)
    $script:BtnRosterBackup.FlatStyle = 'Flat'
    $script:BtnRosterBackup.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $script:BtnRosterBackup.ForeColor = [Drawing.Color]::FromArgb(243, 196, 91)
    $script:BtnRosterBackup.Cursor = [Windows.Forms.Cursors]::Hand
    $script:BtnRosterBackup.Add_Click({
        if ($script:CurrentGuildProduct -eq 'Antigravity') {
            $defaultName = ''
            try {
                $cur = Read-AGCurrent
                if ($cur -and $cur.Identity -and $cur.Identity.Email) { $defaultName = $cur.Identity.Email }
            } catch { }
            $inputName = Show-GuildInputDialog '請輸入要備份的 Antigravity 英雄自訂名稱：' '登記新英雄' $defaultName
            if ($inputName) {
                Invoke-Action {
                    $cur = Read-AGCurrent
                    Save-AGBackup $cur $inputName ''
                    Set-Status '已加密儲存 Antigravity 認證。'
                } { Refresh-AGAccounts }
            }
        } else {
            $defaultName = ''
            try {
                $cur = Read-Current
                if ($cur -and $cur.Identity -and $cur.Identity.Email) { $defaultName = $cur.Identity.Email }
            } catch { }
            $inputName = Show-GuildInputDialog '請輸入要備份的 Codex 英雄自訂名稱：' '登記新英雄' $defaultName
            if ($inputName) {
                Invoke-Action {
                    $cur = Read-Current
                    Backup-Current $cur $inputName
                    Refresh-Accounts
                    Set-Status '已加密儲存目前 Codex 帳號。'
                }
            }
        }
    })
    $script:RosterPanel.Controls.Add($script:BtnRosterBackup)

    # 5. 底部戰情列
    $script:GuildStatusBar = New-Object Windows.Forms.Label
    $script:GuildStatusBar.SetBounds(15, 534, 1100, 24)
    $script:GuildStatusBar.ForeColor = [Drawing.Color]::FromArgb(148, 163, 184)
    $script:GuildStatusBar.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9)
    $script:GuildPanel.Controls.Add($script:GuildStatusBar)

    # 6. 動態英雄微動動畫計時器 (560ms，與原專案完全一致)
    $script:MotionTimer = New-Object Windows.Forms.Timer
    $script:MotionTimer.Interval = 560
    $script:MotionTimer.Add_Tick({
        if (!$script:GuildPanel -or !$script:GuildPanel.Visible) { return }
        $script:MotionFrame = ($script:MotionFrame + 1) % 2

        # 更新先鋒主將立繪影格
        if ($script:CurrentVanguardPose) {
            $vImg = Get-GuildHeroFrame $script:CurrentGuildProduct $script:CurrentVanguardPose $script:MotionFrame
            if ($vImg -and $script:VanguardPic -and !$script:VanguardPic.IsDisposed) {
                $script:VanguardPic.Image = $vImg
            }
        }

        # 更新後備名冊所有卡片的小頭像影格
        if ($script:RosterCardControls -and $script:RosterCardControls.Count) {
            foreach ($card in $script:RosterCardControls) {
                if ($card.Avatar -and !$card.Avatar.IsDisposed -and $card.Pose) {
                    $cardImg = Get-GuildHeroFrame $script:CurrentGuildProduct $card.Pose $script:MotionFrame
                    if ($cardImg) {
                        $card.Avatar.Image = $cardImg
                    }
                }
            }
        }
    })

    # 註冊關閉時清理
    $form.Add_FormClosing({
        if ($script:MotionTimer) { $script:MotionTimer.Stop(); $script:MotionTimer.Dispose() }
        foreach ($k in @($script:GuildImageCache.Keys)) {
            try { $script:GuildImageCache[$k].Dispose() } catch { }
        }
        $script:GuildImageCache.Clear()
    })

    # 初始套用模式
    Set-ViewMode $script:CurrentViewMode
}

function Set-ViewMode([string]$Mode) {
    $script:CurrentViewMode = $Mode
    $pref = Get-UiPreference
    $pref.ViewMode = $Mode
    if (!$PreviewPath) { Set-UiPreference $pref }

    if ($Mode -eq 'Guild') {
        $tabs.Visible = $false
        $script:GuildPanel.Visible = $true
        $script:GuildPanel.BringToFront()
        $form.BackColor = [Drawing.Color]::FromArgb(11, 17, 32)
        if ($script:MotionTimer) { $script:MotionTimer.Start() }
        $script:LastGuildFingerprint = '' # 強制觸發首次渲染
        Update-GuildView
    } else {
        if ($script:MotionTimer) { $script:MotionTimer.Stop() }
        $script:GuildPanel.Visible = $false
        $tabs.Visible = $true
        $tabs.BringToFront()
        $form.BackColor = [Drawing.Color]::FromArgb(247, 248, 250)
    }
}

function Parse-PercentFromText([string]$Text) {
    if ($Text -match '(\d+(?:\.\d+)?)%') {
        return [double]$matches[1]
    }
    return $null
}

function Invoke-SmartRotation {
    $isAg = ($script:CurrentGuildProduct -eq 'Antigravity')
    $sourceList = if ($isAg) { $agList } else { $list }
    $items = @($sourceList.Items)

    if ($items.Count -le 1) { return }

    $candidates = @($items | Where-Object { $_.SubItems[5].Text -ne '目前' })
    if (!$candidates.Count) { return }

    $best = $null
    $maxRemaining = -1
    foreach ($item in $candidates) {
        $rem = Parse-PercentFromText $item.SubItems[3].Text
        if ($null -ne $rem -and $rem -gt $maxRemaining) {
            $maxRemaining = $rem
            $best = $item
        }
    }

    if ($null -eq $best -or $maxRemaining -le 0) {
        [Windows.Forms.MessageBox]::Show('目前沒有健康且具有剩餘額度的後備英雄可供輪替。', '智慧輪替提示', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    Invoke-Action {
        if ($isAg) {
            Switch-AGAccount ([string]$best.Tag)
            Refresh-AGAccounts
        } else {
            Switch-Account ([string]$best.Tag)
            Refresh-Accounts
        }
    }
}

function Update-GuildView {
    if (!$script:GuildPanel -or !$script:GuildPanel.Visible) { return }

    $isAg = ($script:CurrentGuildProduct -eq 'Antigravity')
    $sourceList = if ($isAg) { $agList } else { $list }
    $items = @($sourceList.Items)

    # 計算資料指紋 (Dirty check) 防止非必要的頻繁重繪與閃爍
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$($script:CurrentGuildProduct)|$($items.Count)|$($script:EnableSmartRotate)")
    foreach ($it in $items) {
        [void]$sb.Append("||$($it.Text)|$($it.SubItems[1].Text)|$($it.SubItems[2].Text)|$($it.SubItems[3].Text)|$($it.SubItems[4].Text)|$($it.SubItems[5].Text)|$($it.SubItems[6].Text)")
    }
    $fingerprint = $sb.ToString()
    if ($fingerprint -eq $script:LastGuildFingerprint) {
        return # 資料完全未變動，直接略過，徹底消滅閃爍！
    }
    $script:LastGuildFingerprint = $fingerprint

    # 更新產品切換按鈕狀態外觀
    if ($isAg) {
        $script:BtnGuildCodex.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
        $script:BtnGuildCodex.ForeColor = [Drawing.Color]::FromArgb(148, 163, 184)
        $script:BtnGuildAG.BackColor = [Drawing.Color]::FromArgb(243, 196, 91)
        $script:BtnGuildAG.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
    } else {
        $script:BtnGuildCodex.BackColor = [Drawing.Color]::FromArgb(243, 196, 91)
        $script:BtnGuildCodex.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
        $script:BtnGuildAG.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
        $script:BtnGuildAG.ForeColor = [Drawing.Color]::FromArgb(148, 163, 184)
    }

    # 尋找當前出戰主將 (使用中 == '目前')
    $activeItem = $items | Where-Object { $_.SubItems[5].Text -eq '目前' } | Select-Object -First 1
    $standbyItems = @($items | Where-Object { $_.SubItems[5].Text -ne '目前' })

    # 更新主將卡片
    if ($activeItem) {
        $script:VanguardName.Text = $activeItem.Text
        $script:VanguardMeta.Text = "$($activeItem.SubItems[1].Text)  |  $($activeItem.SubItems[2].Text)"
        
        $p1 = Parse-PercentFromText $activeItem.SubItems[3].Text
        $p2 = Parse-PercentFromText $activeItem.SubItems[4].Text
        $statusText = $activeItem.SubItems[6].Text

        $pose = Get-HeroPose $p1 $statusText
        $script:CurrentVanguardPose = $pose
        $img = Get-GuildHeroFrame $script:CurrentGuildProduct $pose $script:MotionFrame
        if ($img -and $script:VanguardPic -and !$script:VanguardPic.IsDisposed) {
            $script:VanguardPic.Image = $img
        }

        # 狀態文字與顏色
        if ($pose -eq 'exhausted') {
            $script:VanguardStatus.Text = "● 額度耗盡 · 累癱待補給 ($statusText)"
            $script:VanguardStatus.ForeColor = [Drawing.Color]::FromArgb(239, 68, 68)
        } elseif ($pose -eq 'tired') {
            $script:VanguardStatus.Text = "▲ 補給不足 · 疲憊待命中 ($statusText)"
            $script:VanguardStatus.ForeColor = [Drawing.Color]::FromArgb(245, 158, 11)
        } else {
            $script:VanguardStatus.Text = "● 精神飽滿 · 隨時可出戰 ($statusText)"
            $script:VanguardStatus.ForeColor = [Drawing.Color]::FromArgb(74, 222, 128)
        }

        # 5 小時進度條
        $label1 = if ($isAg) { 'Gemini 5 小時用量' } else { '5 小時視窗用量' }
        $script:VanguardBar1Lbl.Text = "${label1}: $($activeItem.SubItems[3].Text)"
        $script:VanguardBar1.Value = if ($null -ne $p1) { [Math]::Max(0, [Math]::Min(100, [int]$p1)) } else { 0 }

        # 每週進度條
        $label2 = if ($isAg) { '每週額度' } else { '每週視窗用量' }
        $script:VanguardBar2Lbl.Text = "${label2}: $($activeItem.SubItems[4].Text)"
        $script:VanguardBar2.Value = if ($null -ne $p2) { [Math]::Max(0, [Math]::Min(100, [int]$p2)) } else { 0 }
    } else {
        $script:VanguardName.Text = '尚無出戰主將'
        $script:VanguardMeta.Text = '尚未登入或找不到生效中的認證'
        $script:VanguardStatus.Text = '○ 等待召喚英雄'
        $script:VanguardStatus.ForeColor = [Drawing.Color]::Gray
        $script:VanguardBar1Lbl.Text = '5 小時用量：—'
        $script:VanguardBar1.Value = 0
        $script:VanguardBar2Lbl.Text = '每週用量：—'
        $script:VanguardBar2.Value = 0
        $script:CurrentVanguardPose = 'energetic'
        $img = Get-GuildHeroFrame $script:CurrentGuildProduct 'energetic' $script:MotionFrame
        if ($img -and $script:VanguardPic -and !$script:VanguardPic.IsDisposed) {
            $script:VanguardPic.Image = $img
        }
    }

    # 智慧輪替按鈕顯示控制 (嚴格遵循使用者的三項規則)
    if (!$script:EnableSmartRotate -or $items.Count -le 1) {
        $script:BtnVanguardRotate.Visible = $false
    } else {
        $script:BtnVanguardRotate.Visible = $true
        $hasHealthyStandby = $false
        foreach ($sb in $standbyItems) {
            $rem = Parse-PercentFromText $sb.SubItems[3].Text
            if ($null -ne $rem -and $rem -gt 0) { $hasHealthyStandby = $true; break }
        }
        $script:BtnVanguardRotate.Enabled = $hasHealthyStandby
        if (!$hasHealthyStandby) {
            $script:BtnVanguardRotate.BackColor = [Drawing.Color]::FromArgb(75, 85, 99)
            $script:BtnVanguardRotate.ForeColor = [Drawing.Color]::FromArgb(156, 163, 175)
        } else {
            $script:BtnVanguardRotate.BackColor = [Drawing.Color]::FromArgb(243, 196, 91)
            $script:BtnVanguardRotate.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
        }
    }

    # 依 5 小時額度由高到低排序後備英雄
    $sortedStandby = @($standbyItems | Sort-Object {
        $p = Parse-PercentFromText $_.SubItems[3].Text
        if ($null -ne $p) { $p } else { -1 }
    } -Descending)

    $script:RosterHeader.Text = "【後備英雄營地】(Standby Roster) - 共 $($sortedStandby.Count) 位後備英雄"

    # 就地複用卡片 (In-place reuse)，避免 Controls.Clear() 造成的閃爍
    $reqCount = $sortedStandby.Count

    $script:RosterScroll.SuspendLayout()
    try {
        # 若現有卡片過多，移除多餘的
        while ($script:RosterCardControls.Count -gt $reqCount) {
            $lastIdx = $script:RosterCardControls.Count - 1
            $lastCard = $script:RosterCardControls[$lastIdx]
            $script:RosterScroll.Controls.Remove($lastCard.Panel)
            $lastCard.Panel.Dispose()
            if ($script:RosterCardControls.Count -le 1) {
                $script:RosterCardControls = @()
            } else {
                $script:RosterCardControls = @($script:RosterCardControls[0..($lastIdx - 1)])
            }
        }

        # 若現有卡片不足，建立新的補足
        while ($script:RosterCardControls.Count -lt $reqCount) {
            $idx = $script:RosterCardControls.Count
            $newCardPanel = New-Object Windows.Forms.Panel
            $newCardPanel.SetBounds(5, 5 + ($idx * 78), 595, 72)
            $newCardPanel.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
            Enable-DoubleBuffering $newCardPanel

            $cAvatar = New-Object Windows.Forms.PictureBox
            $cAvatar.SetBounds(10, 12, 48, 48)
            $cAvatar.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
            $cAvatar.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
            $newCardPanel.Controls.Add($cAvatar)

            $cName = New-Object Windows.Forms.Label
            $cName.SetBounds(68, 10, 360, 20)
            $cName.ForeColor = [Drawing.Color]::White
            $cName.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9.5, [Drawing.FontStyle]::Bold)
            $newCardPanel.Controls.Add($cName)

            $cMeta = New-Object Windows.Forms.Label
            $cMeta.SetBounds(68, 34, 380, 28)
            $cMeta.ForeColor = [Drawing.Color]::FromArgb(148, 163, 184)
            $cMeta.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 8.5)
            $newCardPanel.Controls.Add($cMeta)

            $btnSummon = New-Object Windows.Forms.Button
            $btnSummon.Text = '召喚出戰'
            $btnSummon.SetBounds(470, 18, 110, 36)
            $btnSummon.FlatStyle = 'Flat'
            $btnSummon.BackColor = [Drawing.Color]::FromArgb(243, 196, 91)
            $btnSummon.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
            $btnSummon.Font = New-Object Drawing.Font('Microsoft JhengHei UI', 9, [Drawing.FontStyle]::Bold)
            $btnSummon.Cursor = [Windows.Forms.Cursors]::Hand
            $btnSummon.Add_Click({
                $targetTag = [string]($this.Tag)
                Invoke-Action {
                    if ($script:CurrentGuildProduct -eq 'Antigravity') {
                        Switch-AGAccount $targetTag
                        Refresh-AGAccounts
                    } else {
                        Switch-Account $targetTag
                        Refresh-Accounts
                    }
                }
            })
            $newCardPanel.Controls.Add($btnSummon)

            $script:RosterScroll.Controls.Add($newCardPanel)

            $cardObj = [PSCustomObject]@{
                Panel = $newCardPanel
                Avatar = $cAvatar
                Name = $cName
                Meta = $cMeta
                Button = $btnSummon
                Pose = 'energetic'
            }
            $script:RosterCardControls += $cardObj
        }

        # 更新每一張卡片的資料
        for ($i = 0; $i -lt $reqCount; $i++) {
            $item = $sortedStandby[$i]
            $card = $script:RosterCardControls[$i]
            $card.Panel.Top = 5 + ($i * 78)

            $p1 = Parse-PercentFromText $item.SubItems[3].Text
            $statusText = $item.SubItems[6].Text
            $pose = Get-HeroPose $p1 $statusText
            $card.Pose = $pose

            $card.Name.Text = "$($item.Text)  ($($item.SubItems[2].Text))"
            $card.Meta.Text = "$($item.SubItems[1].Text)  |  5h: $($item.SubItems[3].Text)  |  週: $($item.SubItems[4].Text)"
            $card.Button.Tag = [string]$item.Tag

            $avatarImg = Get-GuildHeroFrame $script:CurrentGuildProduct $pose $script:MotionFrame
            if ($avatarImg -and $card.Avatar -and !$card.Avatar.IsDisposed) {
                $card.Avatar.Image = $avatarImg
            }
        }
    } finally {
        $script:RosterScroll.ResumeLayout()
    }

    # 更新底部戰情日誌
    $totalHeroes = $items.Count
    $readyHeroes = 0; $tiredHeroes = 0; $exhaustedHeroes = 0
    foreach ($it in $items) {
        $p = Parse-PercentFromText $it.SubItems[3].Text
        $st = $it.SubItems[6].Text
        $ps = Get-HeroPose $p $st
        if ($ps -eq 'energetic') { $readyHeroes++ }
        elseif ($ps -eq 'tired') { $tiredHeroes++ }
        else { $exhaustedHeroes++ }
    }
    $timeStr = (Get-Date).ToString('HH:mm:ss')
    $sourceStr = if ($isAg) { 'Antigravity' } else { 'Codex' }
    $script:GuildStatusBar.Text = "公會戰情報告：總計 $totalHeroes 位英雄 ($readyHeroes 位滿血待命、 $tiredHeroes 位補給中、 $exhaustedHeroes 位耗盡) | 來源：$sourceStr | 最近同步：$timeStr"
}
