function Get-CodexBillingPath([string]$Key) {
    if ($Key -cnotmatch '^[a-f0-9]{64}$') { throw '帳號識別無效。' }
    Join-Path (Join-Path $script:StorePath 'billing') ($Key + '.bin')
}

function Assert-CodexBillingSettings($Settings) {
    if ($Settings.AdminKey -isnot [string] -or [string]::IsNullOrWhiteSpace($Settings.AdminKey) -or $Settings.AdminKey -match '\s' -or
        $Settings.Budget -le 0 -or $Settings.Budget -gt 1000000000 -or
        $Settings.ResetDay -lt 1 -or $Settings.ResetDay -gt 31 -or
        $Settings.ResetHour -lt 0 -or $Settings.ResetHour -gt 23 -or
        $Settings.ResetMinute -lt 0 -or $Settings.ResetMinute -gt 59 -or
        $Settings.Scope -notin @('key','organization')) { throw '請填寫 Admin API key、有效的每月 USD 預算與重置日期時間。' }
    if ($Settings.Scope -eq 'key' -and $Settings.ApiKeyId -cnotmatch '^key_[A-Za-z0-9_-]+$') { throw '指定金鑰查詢須填寫 API key ID（key_ 開頭的識別碼，不是 sk- 金鑰）。' }
    $null = [TimeZoneInfo]::FindSystemTimeZoneById($Settings.TimeZoneId)
}

function Read-CodexBillingSettings([string]$Key) {
    $path = Get-CodexBillingPath $Key
    if (!(Test-Path -LiteralPath $path)) { return $null }
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $settings = $script:Utf8.GetString($plain) | ConvertFrom-Json
        if ($settings.Key -cne $Key) { throw 'identity' }
        Assert-CodexBillingSettings $settings
        return $settings
    } catch { throw '無法解密或驗證 API 預算設定，請重新設定。' }
}

function Save-CodexBillingSettings([string]$Key, [string]$AdminKey, [decimal]$Budget, [int]$ResetDay,
    [int]$ResetHour, [int]$ResetMinute, [string]$TimeZoneId, [string]$Scope, [string]$ApiKeyId) {
    $record = Get-AccountBackups | Where-Object { $_.Key -eq $Key }
    if (!$record -or $record.AuthMode -ne 'apikey') { throw '請先選取已儲存的 API key 帳號。' }
    $settings = [pscustomobject]@{ Key=$Key; AdminKey=$AdminKey.Trim(); Budget=$Budget; ResetDay=$ResetDay
        ResetHour=$ResetHour; ResetMinute=$ResetMinute; TimeZoneId=$TimeZoneId; Scope=$Scope; ApiKeyId=$ApiKeyId.Trim() }
    Assert-CodexBillingSettings $settings
    $json = $settings | ConvertTo-Json -Compress
    $cipher = [Security.Cryptography.ProtectedData]::Protect($script:Utf8.GetBytes($json), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-Atomic (Get-CodexBillingPath $Key) $cipher
    $null = Read-CodexBillingSettings $Key
    Write-SwitcherLog 'INFO' '已儲存 API 預算設定' "Key=$Key"
}

function Get-CodexBillingPeriod($Settings, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow) {
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById($Settings.TimeZoneId)
    $localNow = [TimeZoneInfo]::ConvertTime($Now, $zone)
    $month = [datetime]::new($localNow.Year, $localNow.Month, 1)
    function Get-Boundary([datetime]$Month) {
        $day = [Math]::Min([int]$Settings.ResetDay, [datetime]::DaysInMonth($Month.Year, $Month.Month))
        $local = [datetime]::new($Month.Year, $Month.Month, $day, [int]$Settings.ResetHour, [int]$Settings.ResetMinute, 0, [DateTimeKind]::Unspecified)
        while ($zone.IsInvalidTime($local)) { $local = $local.AddMinutes(1) }
        return [DateTimeOffset][TimeZoneInfo]::ConvertTimeToUtc($local, $zone)
    }
    $start = Get-Boundary $month
    if ($Now -lt $start) { $month=$month.AddMonths(-1); $start=Get-Boundary $month }
    [pscustomobject]@{ Start=$start; End=(Get-Boundary $month.AddMonths(1)); Zone=$zone }
}

function Get-CodexBillingQueryEnd([DateTimeOffset]$AsOf) {
    return [DateTimeOffset]$AsOf.UtcDateTime.Date.AddDays(1)
}

function Initialize-CodexBillingClient {
    if ('CodexSwitcher.BillingClient' -as [type]) { return }
    Add-Type -AssemblyName System.Net.Http
    Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;
namespace CodexSwitcher {
    public sealed class BillingReply {
        public string Status;
        public string Json;
        public DateTimeOffset ReceivedAt;
    }
    public static class BillingClient {
        public static async Task<BillingReply> Fetch(string adminKey, long start, long end, string keyId,
            string page, CancellationToken cancellation, HttpMessageHandler handler) {
            try {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                string url = "https://api.openai.com/v1/organization/costs?bucket_width=1d&limit=180&start_time=" + start + "&end_time=" + end;
                if (!string.IsNullOrEmpty(keyId)) url += "&api_key_ids%5B%5D=" + Uri.EscapeDataString(keyId) + "&group_by%5B%5D=api_key_id";
                if (!string.IsNullOrEmpty(page)) url += "&page=" + Uri.EscapeDataString(page);
                using (var client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect=false, UseCookies=false }))
                using (var request = new HttpRequestMessage(HttpMethod.Get, url)) {
                    client.Timeout = TimeSpan.FromSeconds(5);
                    client.MaxResponseContentBufferSize = 1024 * 1024;
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", adminKey);
                    request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                    using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellation).ConfigureAwait(false)) {
                        if ((int)response.StatusCode != 200) return new BillingReply { Status="HTTP " + (int)response.StatusCode };
                        return new BillingReply { Status="OK", ReceivedAt=DateTimeOffset.UtcNow, Json=await response.Content.ReadAsStringAsync().ConfigureAwait(false) };
                    }
                }
            } catch (OperationCanceledException) {
                return new BillingReply { Status=cancellation.IsCancellationRequested ? "Canceled" : "Timeout" };
            } catch { return new BillingReply { Status="NetworkError" }; }
        }
    }
}
'@
}

function ConvertFrom-CodexCostPage($Reply, [string]$ApiKeyId, [long]$StartTime, [long]$EndTime) {
    $page = $Reply.Json | ConvertFrom-Json
    if ($page.object -ne 'page' -or $page.data -isnot [array] -or $page.has_more -isnot [bool]) { throw 'format' }
    $total = [decimal]0; $boundaryEstimated = $false
    foreach ($bucket in $page.data) {
        if ($null -eq $bucket.start_time -or $null -eq $bucket.end_time -or $bucket.end_time -le $bucket.start_time -or
            $bucket.results -isnot [array]) { throw 'bucket' }
        if ($bucket.end_time -le $StartTime -or $bucket.start_time -ge $EndTime) { throw 'range' }
        if ($bucket.start_time -lt $StartTime) { $boundaryEstimated=$true }
        foreach ($result in $bucket.results) {
            if ($result.object -ne 'organization.costs.result' -or $result.amount.currency -ine 'usd' -or
                $null -eq $result.amount.value -or $result.amount.value -is [bool] -or
                ($ApiKeyId -and $result.api_key_id -cne $ApiKeyId)) { throw 'amount' }
            $amount = [decimal]0
            if (![decimal]::TryParse([string]$result.amount.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$amount)) { throw 'amount' }
            $total += $amount
        }
    }
    if ($page.has_more -and ($page.next_page -isnot [string] -or [string]::IsNullOrWhiteSpace($page.next_page))) { throw 'cursor' }
    [pscustomobject]@{ Amount=$total; HasMore=$page.has_more; NextPage=[string]$page.next_page; BoundaryEstimated=$boundaryEstimated }
}

function Format-CodexBillingResult($Job, [string]$Status = '已更新（估算）') {
    $detail = 'API 費用查詢未完成；不將未知用量視為零。'
    $primary='未知'; $secondary='未知'; $remaining=$null
    if ($Status -eq '已更新（估算）') {
        $used = [decimal]$Job.Total
        $balance = [decimal]$Job.Billing.Budget - $used
        $remaining = [double][Math]::Max([decimal]0, [Math]::Min([decimal]100, $balance / [decimal]$Job.Billing.Budget * 100))
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $primary = 'USD ' + $used.ToString('0.00', $culture)
        if ($Job.BoundaryEstimated) { $primary='約 ' + $primary }
        $secondary = '估 USD ' + $balance.ToString('0.00', $culture) + ' (' + $remaining.ToString('0.#', $culture) + '%)'
        if ($balance -lt 0) { $Status='預算超支（估）' }
        $scope = if ($Job.Billing.Scope -eq 'key') { '指定 API key：' + $Job.Billing.ApiKeyId } else { '整個組織（含其他 API key；各列不可重複加總）' }
        $start = [TimeZoneInfo]::ConvertTime($Job.Period.Start, $Job.Period.Zone).ToString('yyyy/MM/dd HH:mm')
        $end = [TimeZoneInfo]::ConvertTime($Job.Period.End, $Job.Period.Zone).ToString('yyyy/MM/dd HH:mm')
        $detail = "範圍：$scope`r`n本期：$start ～ $end（$($Job.Billing.TimeZoneId)）`r`n每月預算：USD $($Job.Billing.Budget)`r`n查詢時間：$($Job.QueriedAt.ToLocalTime().ToString('yyyy/MM/dd HH:mm:ss'))`r`n剩餘估算＝預算－本期已用；不是 OpenAI 儲值餘額，也不會強制停止 API 使用。費用按日彙總且可能延遲，重置時刻跨日彙總邊界時可能包含跨期費用。"
        if ($Job.BoundaryEstimated) { $detail += "`r`n本次包含跨期日彙總，已用金額亦為估算。" }
        if ($Job.Billing.Scope -eq 'organization') { $Status='組織：' + $Status }
    }
    [pscustomobject]@{ Plan='API key'; Primary=$primary; Secondary=$secondary; PrimaryRemaining=$null; SecondaryRemaining=$remaining; Status=$Status; Detail=$detail }
}

function Start-CodexBillingPage($Job, [string]$Page) {
    $keyId = if ($Job.Billing.Scope -eq 'key') { $Job.Billing.ApiKeyId } else { '' }
    $queryEnd = Get-CodexBillingQueryEnd $Job.QueriedAt
    $Job.Task = [CodexSwitcher.BillingClient]::Fetch($Job.Billing.AdminKey, $Job.Period.Start.ToUnixTimeSeconds(), $queryEnd.ToUnixTimeSeconds(),
        $keyId, $Page, $Job.Cancellation.Token, $null)
}

function Complete-CodexBillingPage($Job) {
    $reply = $Job.Task.GetAwaiter().GetResult()
    if ($reply.Status -ne 'OK') {
        $status = switch ($reply.Status) {
            'HTTP 401' { 'Admin key 無效' }; 'HTTP 403' { 'Admin key 權限不足' }; 'HTTP 429' { '稍後重試' }
            'Timeout' { '費用查詢逾時' }; 'Canceled' { '查詢已取消' }; default { '費用查詢失敗' }
        }
        return Format-CodexBillingResult $Job $status
    }
    try {
        $keyId = if ($Job.Billing.Scope -eq 'key') { $Job.Billing.ApiKeyId } else { '' }
        $queryEnd = Get-CodexBillingQueryEnd $Job.QueriedAt
        $page = ConvertFrom-CodexCostPage $reply $keyId $Job.Period.Start.ToUnixTimeSeconds() $queryEnd.ToUnixTimeSeconds()
        $Job.Total += $page.Amount
        $Job.BoundaryEstimated = $Job.BoundaryEstimated -or $page.BoundaryEstimated
        $Job.PageCount++
        if ($page.HasMore) {
            if ($Job.PageCount -ge 10 -or $Job.Cursors.Contains($page.NextPage)) { throw 'pagination' }
            [void]$Job.Cursors.Add($page.NextPage)
            Start-CodexBillingPage $Job $page.NextPage
            return $null
        }
        return Format-CodexBillingResult $Job
    } catch { return Format-CodexBillingResult $Job '費用格式不支援' }
}

function Start-CodexBillingQuery([string]$Key, $Item) {
    try { $settings=Read-CodexBillingSettings $Key }
    catch { $Item.SubItems[5].Text='預算設定損壞'; $Item.ToolTipText=$_.Exception.Message; return }
    if (!$settings) { $Item.ToolTipText='請選取此帳號，點「API 預算設定」設定 Admin API key 與每月預算。'; return }
    $now = [DateTimeOffset]::UtcNow
    $period = Get-CodexBillingPeriod $settings $now
    if (!$script:NextBillingReset -or $period.End -lt $script:NextBillingReset) { $script:NextBillingReset=$period.End }
    if ($now.ToUnixTimeSeconds() -le $period.Start.ToUnixTimeSeconds()) {
        $Item.SubItems[2].Text='USD 0.00'; $Item.SubItems[3].Text='剛重置，待查詢'; $Item.SubItems[5].Text='已重置'
        $script:NextBillingReset=$now.AddSeconds(1)
        return
    }
    $Item.SubItems[2].Text='查詢中…'; $Item.SubItems[3].Text='查詢中…'; $Item.SubItems[5].Text='費用查詢中…'
    $job = [pscustomobject]@{ Kind='Billing'; Key=$Key; Generation=$script:QuotaGeneration; Billing=$settings; Period=$period; QueriedAt=$now
        Cancellation=(New-Object Threading.CancellationTokenSource); Task=$null; Total=[decimal]0; PageCount=0
        Cursors=(New-Object 'Collections.Generic.HashSet[string]'); BoundaryEstimated=$false }
    Start-CodexBillingPage $job ''
    $script:QuotaJobs += $job
    $script:QuotaQueryStarted = $true
}

function Update-CodexBillingCycles {
    if ($script:NextBillingReset -and [DateTimeOffset]::UtcNow -ge $script:NextBillingReset) { Refresh-Accounts }
}

function Show-CodexBillingDialog([string]$Path) {
    if ($IsolatedAntigravityTestPath) { throw '獨立測試模式不提供 Codex 預算設定。' }
    $record = Read-Backup $Path
    if ($record.AuthMode -ne 'apikey') { throw '請選取 API key 帳號；訂閱帳號不使用此設定。' }
    try { $settings = Read-CodexBillingSettings $record.Key }
    catch { $settings = $null }
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='API 預算設定'; $dialog.ClientSize=New-Object Drawing.Size(600, 490)
    $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $dialog.Font=New-Object Drawing.Font('Microsoft JhengHei UI', 9)
    $heading=New-Object Windows.Forms.Label
    $heading.Text=$record.Email; $heading.SetBounds(18, 14, 564, 30)
    $adminLabel=New-Object Windows.Forms.Label
    $adminLabel.Text='Admin API key'; $adminLabel.SetBounds(18, 57, 150, 24)
    $admin=New-Object Windows.Forms.TextBox
    $admin.Name='AdminKey'; $admin.SetBounds(175, 54, 405, 26); $admin.UseSystemPasswordChar=$true
    $keyHint=New-Object Windows.Forms.Label
    $keyHint.Text=if ($settings) { '已儲存加密金鑰；留空保留，輸入新金鑰則替換。' } else { '請使用組織 Admin API key，與 Codex 登入金鑰分開儲存。' }
    $keyHint.SetBounds(175, 85, 405, 38)
    $scopeLabel=New-Object Windows.Forms.Label
    $scopeLabel.Text='費用查詢範圍'; $scopeLabel.SetBounds(18, 131, 150, 24)
    $scope=New-Object Windows.Forms.ComboBox
    $scope.Name='Scope'; $scope.SetBounds(175, 128, 405, 26); $scope.DropDownStyle='DropDownList'
    [void]$scope.Items.Add('指定 API key'); [void]$scope.Items.Add('整個組織（含其他金鑰）')
    $scope.SelectedIndex=if ($settings -and $settings.Scope -eq 'organization') { 1 } else { 0 }
    $idLabel=New-Object Windows.Forms.Label
    $idLabel.Text='API key ID（key_…）'; $idLabel.SetBounds(18, 173, 155, 24)
    $keyId=New-Object Windows.Forms.TextBox
    $keyId.Name='ApiKeyId'; $keyId.SetBounds(175, 170, 405, 26); $keyId.Enabled=($scope.SelectedIndex -eq 0)
    if ($settings) { $keyId.Text=$settings.ApiKeyId }
    $scope.Add_SelectedIndexChanged({ $keyId.Enabled=($scope.SelectedIndex -eq 0) })
    $budgetLabel=New-Object Windows.Forms.Label
    $budgetLabel.Text='每月預算（USD）'; $budgetLabel.SetBounds(18, 215, 150, 24)
    $budget=New-Object Windows.Forms.NumericUpDown
    $budget.Name='Budget'; $budget.SetBounds(175, 212, 200, 26); $budget.DecimalPlaces=2; $budget.Minimum=0.01; $budget.Maximum=1000000000
    $budget.Value=if ($settings) { $settings.Budget } else { 100 }
    $dayLabel=New-Object Windows.Forms.Label
    $dayLabel.Text='每月重置日／時間'; $dayLabel.SetBounds(18, 257, 150, 24)
    $day=New-Object Windows.Forms.NumericUpDown
    $day.Name='ResetDay'; $day.SetBounds(175, 254, 90, 26); $day.Minimum=1; $day.Maximum=31
    $day.Value=if ($settings) { $settings.ResetDay } else { 1 }
    $time=New-Object Windows.Forms.DateTimePicker
    $time.Name='ResetTime'; $time.SetBounds(285, 254, 130, 26); $time.Format='Custom'; $time.CustomFormat='HH:mm'; $time.ShowUpDown=$true
    $time.Value=if ($settings) { [datetime]::Today.AddHours($settings.ResetHour).AddMinutes($settings.ResetMinute) } else { [datetime]::Today }
    $zoneId=if ($settings) { $settings.TimeZoneId } else { [TimeZoneInfo]::Local.Id }
    $hint=New-Object Windows.Forms.Label
    $hint.SetBounds(18, 300, 562, 95)
    $hint.Text="時區：$zoneId。29～31 日遇短月改為月底。`r`n依自訂重置日計算本期費用；剩餘估算＝預算－本期已用。`r`n費用按日彙總且可能延遲；此估算不是儲值餘額，不會限制 API 使用。"
    $ok=New-Object Windows.Forms.Button
    $ok.Text='儲存'; $ok.SetBounds(385, 438, 90, 32)
    $ok.Add_Click({
        try {
            $adminValue=if ([string]::IsNullOrWhiteSpace($admin.Text) -and $settings) { $settings.AdminKey } else { $admin.Text }
            $scopeValue=if ($scope.SelectedIndex -eq 0) { 'key' } else { 'organization' }
            Save-CodexBillingSettings $record.Key $adminValue $budget.Value ([int]$day.Value) $time.Value.Hour $time.Value.Minute $zoneId $scopeValue $keyId.Text
            $dialog.DialogResult='OK'
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '無法儲存', 'OK', 'Warning') | Out-Null }
    })
    $clear=New-Object Windows.Forms.Button
    $clear.Text='移除預算與 Admin key'; $clear.SetBounds(18, 438, 190, 32); $clear.Enabled=($null -ne $settings)
    $clear.Add_Click({ [IO.File]::Delete((Get-CodexBillingPath $record.Key)); $dialog.DialogResult='OK' })
    $cancel=New-Object Windows.Forms.Button
    $cancel.Text='取消'; $cancel.SetBounds(490, 438, 90, 32); $cancel.DialogResult='Cancel'
    $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    $dialog.Controls.AddRange(@($heading,$adminLabel,$admin,$keyHint,$scopeLabel,$scope,$idLabel,$keyId,$budgetLabel,$budget,$dayLabel,$day,$time,$hint,$ok,$clear,$cancel))
    try { if ($dialog.ShowDialog($form) -eq 'OK') { Set-Status '已更新 API 預算設定；重新整理取得當期費用。' } }
    finally { $admin.Clear(); $dialog.Dispose() }
}
