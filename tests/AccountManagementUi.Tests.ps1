$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Security
$PreviewDirectory=$env:CODEX_SWITCHER_TEST_PREVIEW
$sourceRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$source = [IO.File]::ReadAllText((Join-Path $sourceRoot 'CodexAccountSwitcher.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '主程式語法錯誤' }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('AccountManagementUiTest-' + [guid]::NewGuid().ToString('N'))
$script:Utf8 = New-Object Text.UTF8Encoding($true)
$script:StorePath = Join-Path $sandbox 'backups'
$script:CodexPath = Join-Path $sandbox 'codex'
$script:AuthPath = Join-Path $script:CodexPath 'auth.json'
$script:LogPath = Join-Path $script:StorePath 'switcher.log'
$script:QuotaJobs = @(); $script:AGQuotaJobs = @()
$script:QuotaGeneration = 0; $script:AGQuotaGeneration = 0
$PreviewPath = Join-Path $sandbox 'preview.png'
. (Join-Path $sourceRoot 'AntigravityCredential.ps1')
. (Join-Path $sourceRoot 'AntigravityQuota.ps1')
. (Join-Path $sourceRoot 'WebDashboard.ps1')
. (Join-Path $sourceRoot 'GuildView.ps1')
. (Join-Path $sourceRoot 'CodexBilling.ps1')
function Get-ApplicationIcon { return $null }
function Start-QuotaQuery([byte[]]$Bytes, [string]$Key) {
    $item=$list.Items[$Key]
    $item.SubItems[1].Text='plus'; $item.SubItems[2].Text='78% (15:08)'; $item.SubItems[3].Text='84% (6.8d)'; $item.SubItems[5].Text='已更新'
}
function Switch-Account([string]$Path) { $script:SwitchedPath=$Path }
function Confirm-AccountDeletion([string]$Path) { $script:DeletedPath=$Path }
function Start-CodexBillingPage($Job, [string]$Page) {
    $json=@{ object='page'; has_more=$false; data=@(@{ start_time=$Job.Period.Start.ToUnixTimeSeconds(); end_time=$Job.QueriedAt.ToUnixTimeSeconds()
        results=@(@{ object='organization.costs.result'; api_key_id='key_ui'; amount=@{ currency='usd'; value=7.25 } }) }) } | ConvertTo-Json -Depth 8 -Compress
    $Job.Task=[Threading.Tasks.Task]::FromResult([pscustomobject]@{ Status='OK'; Json=$json })
}
function Check([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw ('測試失敗：' + $Message) }
}
function Invoke-ApiDialog([bool]$Save) {
    $script:DialogError = $null
    $script:DialogSave = $Save
    $script:DialogSeen = $false
    $script:DialogTimer = New-Object Windows.Forms.Timer
    $script:DialogTimer.Interval = 100
    $script:DialogTimer.Add_Tick({
        $dialog = @([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq '新增 Codex API key' }) | Select-Object -First 1
        if (!$dialog) { return }
        $script:DialogTimer.Stop()
        try {
            $script:DialogSeen = $true
            $inputs = @($dialog.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] })
            $keyInput = $inputs | Where-Object { $_.UseSystemPasswordChar }
            $nameInput = $inputs | Where-Object { !$_.UseSystemPasswordChar }
            Check ($null -ne $keyInput -and $null -ne $nameInput) 'API key 使用密碼輸入欄位'
            $keyInput.Text = 'synthetic-ui-api-key'
            $nameInput.Text = '介面測試 API'
            if ($script:DialogSave) { $dialog.AcceptButton.PerformClick() }
            else { $dialog.CancelButton.PerformClick() }
        } catch {
            $script:DialogError = $_
            $dialog.DialogResult = 'Cancel'
        }
    })
    try {
        $script:DialogTimer.Start()
        $addApiKey.PerformClick()
        if ($script:DialogError) { throw $script:DialogError }
        Check $script:DialogSeen '新增按鈕開啟實際 API key 對話框'
    } finally { $script:DialogTimer.Stop(); $script:DialogTimer.Dispose() }
}
function Save-UiPreview($Control, [string]$Name) {
    if (!$PreviewDirectory) { return }
    [IO.Directory]::CreateDirectory($PreviewDirectory) | Out-Null
    $bitmap=New-Object Drawing.Bitmap($Control.Width,$Control.Height)
    try {
        $Control.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$Control.Width,$Control.Height)))
        $bitmap.Save((Join-Path $PreviewDirectory $Name),[Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
}
function Invoke-BudgetDialog([string]$Operation) {
    $apiList.Items[0].Selected=$true
    $script:BudgetOperation=$Operation; $script:BudgetSeen=$false; $script:BudgetError=$null
    $script:BudgetTimer=New-Object Windows.Forms.Timer; $script:BudgetTimer.Interval=100
    $script:BudgetTimer.Add_Tick({
        $dialog=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'API 預算設定' }) | Select-Object -First 1
        if (!$dialog) { return }
        $script:BudgetTimer.Stop()
        try {
            $script:BudgetSeen=$true
            $admin=$dialog.Controls.Find('AdminKey',$false)[0]
            Check ($admin.UseSystemPasswordChar -and !$admin.Text) 'Admin key 遮蔽且編輯時不回填明文'
            if ($script:BudgetOperation -eq 'clear') {
                ($dialog.Controls | Where-Object { $_.Text -eq '移除預算與 Admin key' }).PerformClick()
            } elseif ($script:BudgetOperation -eq 'cancel') { $dialog.CancelButton.PerformClick() }
            else {
                if ($script:BudgetOperation -eq 'save') { $admin.Text='synthetic-ui-admin' }
                $dialog.Controls.Find('ApiKeyId',$false)[0].Text='key_ui'
                $dialog.Controls.Find('Budget',$false)[0].Value=if ($script:BudgetOperation -eq 'save') { 50 } else { 60 }
                $dialog.Controls.Find('ResetDay',$false)[0].Value=18
                $dialog.Controls.Find('ResetTime',$false)[0].Value=[datetime]::Today.AddHours(9).AddMinutes(45)
                Save-UiPreview $dialog 'api-budget-settings.png'
                $dialog.AcceptButton.PerformClick()
            }
        } catch { $script:BudgetError=$_; $dialog.DialogResult='Cancel' }
    })
    try {
        $script:BudgetTimer.Start(); $billing.PerformClick()
        if ($script:BudgetError) { throw $script:BudgetError }
        Check $script:BudgetSeen '預算按鈕開啟實際設定視窗'
    } finally { $script:BudgetTimer.Stop(); $script:BudgetTimer.Dispose() }
}
try {
    # 僅執行實際 UI 建構段落，避開啟動時的真實帳號讀取、舊版匯入與服務啟動。
    $start = $source.IndexOf('$form = New-Object Windows.Forms.Form')
    $end = $source.IndexOf('$form.Add_FormClosing({ $quotaTimer.Stop();')
    Check ($start -ge 0 -and $end -gt $start) '取得 UI 建構入口'
    . ([scriptblock]::Create($source.Substring($start, $end - $start)))
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Check ($codexTab.Controls.Contains($addApiKey) -and $codexTab.Controls.Contains($delete) -and $agTab.Controls.Contains($agDelete)) '兩產品顯示管理按鈕'
    Check ($addApiKey.Right -le $delete.Left -and $delete.Right -le $refresh.Left) 'Codex 新增與刪除按鈕不重疊'
    Check ($list.Bottom -le $apiTitle.Top -and $apiList.Bottom -le $switch.Top) '兩個獨立表格及操作列不重疊'
    Check ($list.Columns[2].Text -eq '5 小時用量／重置' -and $list.Columns[3].Text -eq '週用量／重置') '訂閱表格保留五小時與週額度標題'
    Check ($apiList.Columns[2].Text -eq '本期已用金額' -and $apiList.Columns[3].Text -eq '預算剩餘估算') 'API key 表格使用獨立的金額欄位標題'
    Check ((@($apiList.Columns | ForEach-Object { $_.Text }) -join '|') -notmatch '5 小時|週用量') 'API key 表格不出現訂閱額度欄位'
    Invoke-ApiDialog $false
    Check (@(Get-AccountBackups).Count -eq 0) '取消新增不建立帳號備份'
    Invoke-ApiDialog $true
    $records = @(Get-AccountBackups)
    Check ($records.Count -eq 1 -and $records[0].Name -eq '介面測試 API') '透過實際新增視窗加密儲存 API key'
    Check ($apiList.Items.Count -eq 1 -and $apiList.Items[0].SubItems[5].Text -eq 'API 計費') '儲存後清單立即更新且不查詢訂閱額度'
    Check (!(Test-Path -LiteralPath $script:AuthPath)) '介面新增不建立或改寫目前登入檔'
    $claims=@{ sub='ui-subscription'; email='subscription@example.invalid' } | ConvertTo-Json -Compress
    $jwt='test.' + [Convert]::ToBase64String($script:Utf8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.test'
    $subscriptionBytes=$script:Utf8.GetBytes((@{ auth_mode='chatgpt'; tokens=@{ id_token=$jwt; account_id='ui-workspace'; access_token='ui-access'; refresh_token='ui-refresh' } } | ConvertTo-Json -Depth 4 -Compress))
    Save-Backup $subscriptionBytes '介面測試訂閱' ''
    Refresh-Accounts
    Check ($list.Items.Count -eq 1 -and $apiList.Items.Count -eq 1 -and @(Get-CodexAccountItems).Count -eq 2) '混合帳號分開顯示且共用讀取入口保留全部帳號'
    $subscriptionPath=[string]$list.Items[0].Tag
    $apiList.Items[0].Selected=$true
    $list.Items[0].Selected=$true
    Check ($apiList.SelectedItems.Count -eq 0 -and (Get-SelectedCodexAccount).Tag -eq $subscriptionPath) '選取訂閱帳號會清除 API key 選取'
    $switch.PerformClick()
    Check ($script:SwitchedPath -eq $subscriptionPath) '共用切換按鈕選取訂閱表格中的正確帳號'
    $apiList.Items[0].Selected=$true
    Check ($list.SelectedItems.Count -eq 0 -and (Get-SelectedCodexAccount).Tag -eq $records[0].Path) '選取 API key 會清除訂閱表格選取'
    $switch.PerformClick()
    Check ($script:SwitchedPath -eq $records[0].Path) '共用切換按鈕選取 API key 表格中的正確帳號'
    $list.Items[0].Selected=$true; $delete.PerformClick()
    Check ($script:DeletedPath -eq $subscriptionPath) '共用刪除按鈕處理訂閱表格選取'
    $apiList.Items[0].Selected=$true; $delete.PerformClick()
    Check ($script:DeletedPath -eq $records[0].Path) '共用刪除按鈕處理 API key 表格選取'
    $apiList.Items[0].Selected=$true
    Invoke-BudgetDialog 'cancel'
    Check ($null -eq (Read-CodexBillingSettings $records[0].Key)) '取消預算設定不寫入 Admin key'
    Invoke-BudgetDialog 'save'
    $settings=Read-CodexBillingSettings $records[0].Key
    Check ($settings.AdminKey -eq 'synthetic-ui-admin' -and $settings.Budget -eq 50 -and $settings.ResetDay -eq 18 -and $settings.ResetHour -eq 9 -and $settings.ResetMinute -eq 45) '介面儲存 Admin key、每月預算與重置日期時間'
    Update-QuotaResults
    Check ($apiList.Items[0].SubItems[2].Text -eq 'USD 7.25' -and $apiList.Items[0].SubItems[3].Text -eq '估 USD 42.75 (85.5%)') '非同步費用查詢立即顯示本期支出與預算剩餘'
    Save-UiPreview $form 'api-budget-list.png'
    $apiList.Items[0].Selected=$true
    Invoke-BudgetDialog 'retain'
    Check ((Read-CodexBillingSettings $records[0].Key).AdminKey -eq 'synthetic-ui-admin' -and (Read-CodexBillingSettings $records[0].Key).Budget -eq 60) '修改預算時留白保留原 Admin key'
    $apiList.Items[0].Selected=$true
    Invoke-BudgetDialog 'clear'
    Check ($null -eq (Read-CodexBillingSettings $records[0].Key) -and $apiList.Items[0].SubItems[2].Text -eq '未設定') '可移除 Admin key 與預算，帳號仍保留'
    Set-ViewMode 'Guild'
    $script:CurrentGuildProduct = 'Codex'
    Update-GuildView
    Check $script:BtnGuildApiKey.Visible 'Codex 公會視圖提供新增 API key'
    Check ($script:RosterCardControls.Count -eq 2) '公會視圖保留兩張表格的所有帳號'
    $secondClaims=@{ sub='ui-subscription-second'; email='subscription-second@example.invalid' } | ConvertTo-Json -Compress
    $secondJwt='test.' + [Convert]::ToBase64String($script:Utf8.GetBytes($secondClaims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.test'
    $secondBytes=$script:Utf8.GetBytes((@{ auth_mode='chatgpt'; tokens=@{ id_token=$secondJwt; account_id='ui-workspace'; access_token='ui-access-second'; refresh_token='ui-refresh-second' } } | ConvertTo-Json -Depth 4 -Compress))
    Save-Backup $secondBytes '第二個介面測試訂閱' ''
    Write-Atomic $script:AuthPath $subscriptionBytes
    Refresh-Accounts
    Update-GuildView
    Check ($list.Items.Count -eq 2 -and $apiList.Items.Count -eq 1 -and @(Get-CodexAccountItems).Count -eq 3) '兩個訂閱加一個 API key 的來源帳號完整'
    Check ($script:VanguardName.Text -eq (Get-Identity $subscriptionBytes).Email) '目前使用的訂閱帳號顯示於左側先鋒卡'
    $standbyPaths=@($script:RosterCardControls | ForEach-Object { [string]$_.Button.Tag })
    $secondPath=Join-Path $script:StorePath ((Get-Identity $secondBytes).Key + '.bin')
    Check ($standbyPaths.Count -eq 2 -and $standbyPaths -contains $secondPath -and $standbyPaths -contains $records[0].Path) '使用訂閱時，右側完整顯示另一個訂閱與 API key'
    Save-UiPreview $form 'guild-two-subscriptions-active-subscription.png'
    Write-Atomic $script:AuthPath $records[0].Bytes
    Refresh-Accounts
    Update-GuildView
    Check ($script:VanguardName.Text -eq (Read-Backup $records[0].Path).Email) '目前使用 API key 時顯示於左側先鋒卡'
    $standbyPaths=@($script:RosterCardControls | ForEach-Object { [string]$_.Button.Tag })
    Check ($standbyPaths.Count -eq 2 -and $standbyPaths -contains $subscriptionPath -and $standbyPaths -contains $secondPath) '使用 API key 時，右側完整顯示兩個訂閱帳號'
    Save-UiPreview $form 'guild-two-subscriptions-active-api.png'
    $script:CurrentGuildProduct = 'Antigravity'
    Update-GuildView
    Check (!$script:BtnGuildApiKey.Visible) 'Antigravity 公會視圖隱藏新增 API key'
    $manage = $script:RosterPanel.Controls | Where-Object { $_.Text -eq '管理／刪除帳號' }
    $manage.PerformClick()
    Check ($tabs.SelectedTab -eq $agTab -and $script:CurrentViewMode -eq 'Classic') '公會管理入口返回對應產品清單'
    'PASS: WinForms 獨立表格、預算與金額更新、公會兩個訂閱加一個 API key（訂閱或 API key 使用中）的全部帳號顯示；全程合成資料與模擬費用。'
} finally {
    if ($script:MotionTimer) { $script:MotionTimer.Stop(); $script:MotionTimer.Dispose() }
    if ($quotaTimer) { $quotaTimer.Stop(); $quotaTimer.Dispose() }
    Stop-QuotaQueries
    if ($form) { $form.Dispose() }
    if ($appIcon) { $appIcon.Dispose() }
    if ($script:AppIconBig) { $script:AppIconBig.Dispose() }
    foreach ($cachedImage in $script:GuildImageCache.Values) { $cachedImage.Dispose() }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ((Test-Path -LiteralPath $sandbox) -and [IO.Path]::GetFullPath($sandbox).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $sandbox -Leaf) -like 'AccountManagementUiTest-*') {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
