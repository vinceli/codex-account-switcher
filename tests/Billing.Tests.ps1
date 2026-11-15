$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Security
$sourceRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'CodexAccountSwitcher.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw '主程式語法錯誤' }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($statement.Extent.Text)) }
}
. (Join-Path $sourceRoot 'CodexBilling.ps1')
Initialize-QuotaClient
Initialize-CodexBillingClient
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class BillingTestHandler : HttpMessageHandler {
    public int Code=200;
    public int Delay;
    public bool TokenOk;
    public bool Disposed;
    public List<string> Requests=new List<string>();
    public string Body="{}";
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
        Requests.Add(request.RequestUri.AbsoluteUri);
        TokenOk=request.Method==HttpMethod.Get && request.Headers.Authorization.Scheme=="Bearer" && request.Headers.Authorization.Parameter=="synthetic-admin";
        if (Delay>0) await Task.Delay(Delay,cancellation).ConfigureAwait(false);
        return new HttpResponseMessage((HttpStatusCode)Code) { Content=new StringContent(Body) };
    }
    protected override void Dispose(bool disposing) { Disposed=true; base.Dispose(disposing); }
}
'@
function Check([bool]$Condition,[string]$Message) { if (!$Condition) { throw ('測試失敗：' + $Message) } }
function New-CostJson([decimal]$Amount,[bool]$More=$false,[string]$Cursor='') {
    @{ object='page'; has_more=$More; next_page=$Cursor; data=@(@{ object='bucket'; start_time=100; end_time=200
        results=@(@{ object='organization.costs.result'; api_key_id='key_target'; amount=@{value=$Amount; currency='usd'} }) }) } | ConvertTo-Json -Depth 8 -Compress
}
function New-TestJob($Settings) {
    [pscustomobject]@{ Kind='Billing'; Key=$script:Key; Generation=$script:QuotaGeneration; Billing=$Settings
        Period=[pscustomobject]@{ Start=[DateTimeOffset]::FromUnixTimeSeconds(100); End=[DateTimeOffset]::FromUnixTimeSeconds(1000); Zone=[TimeZoneInfo]::Utc }
        QueriedAt=[DateTimeOffset]::FromUnixTimeSeconds(250); Total=[decimal]0; PageCount=0; BoundaryEstimated=$false
        Cursors=(New-Object 'Collections.Generic.HashSet[string]'); Cancellation=(New-Object Threading.CancellationTokenSource); Task=$null }
}
function Set-JobReply($Job,[string]$Status,[string]$Json) {
    $reply=New-Object CodexSwitcher.BillingReply
    $reply.Status=$Status; $reply.Json=$Json; $reply.ReceivedAt=[DateTimeOffset]::UtcNow
    $Job.Task=[Threading.Tasks.Task]::FromResult($reply)
}
function Sync-WebDashboardAccounts { $script:SyncCount++ }
function Update-GuildView {}
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('CodexBillingTest-' + [guid]::NewGuid().ToString('N'))
$script:Utf8=New-Object Text.UTF8Encoding($true)
$script:StorePath=Join-Path $sandbox 'backups'
$script:CodexPath=Join-Path $sandbox 'codex'
$script:AuthPath=Join-Path $script:CodexPath 'auth.json'
$script:LogPath=Join-Path $script:StorePath 'switcher.log'
$script:QuotaJobs=@(); $script:QuotaGeneration=1; $script:SyncCount=0
$form=New-Object Windows.Forms.Form
$list=New-Object Windows.Forms.ListView
$form.Controls.Add($list)
$apiList=New-Object Windows.Forms.ListView
$form.Controls.Add($apiList)
$lastQueryLabel=New-Object Windows.Forms.Label
$cancel=New-Object Threading.CancellationTokenSource
try {
    Save-CodexApiKey 'synthetic-billing-key' '預算測試'
    $record=Get-AccountBackups
    $script:Key=$record.Key
    Save-CodexBillingSettings $script:Key 'synthetic-admin' 100 15 9 30 'Taipei Standard Time' 'key' 'key_target'
    $settings=Read-CodexBillingSettings $script:Key
    $path=Get-CodexBillingPath $script:Key
    Check ($settings.Budget -eq 100 -and $settings.AdminKey -eq 'synthetic-admin' -and $settings.ResetMinute -eq 30) 'DPAPI 設定儲存與解密往返'
    Check (![IO.File]::ReadAllText($path).Contains('synthetic-admin') -and ![IO.File]::ReadAllText($script:LogPath).Contains('synthetic-admin')) 'Admin key 不出現在明文設定或日誌'
    Check (($script:Utf8.GetString((Read-Backup $record.Path).Bytes) | ConvertFrom-Json).OPENAI_API_KEY -eq 'synthetic-billing-key') 'Admin 設定不覆寫一般 API key 認證'
    $before=Get-CodexBillingPeriod $settings ([DateTimeOffset]::Parse('2026-11-15T09:29:59+08:00'))
    $after=Get-CodexBillingPeriod $settings ([DateTimeOffset]::Parse('2026-11-15T09:30:00+08:00'))
    Check ($before.End -eq $after.Start -and $after.Start.ToUnixTimeSeconds() -eq ([DateTimeOffset]::Parse('2026-11-15T01:30:00Z')).ToUnixTimeSeconds()) '重置日時間及時區在邊界精確換期'
    $settings.ResetDay=31
    $feb=Get-CodexBillingPeriod $settings ([DateTimeOffset]::Parse('2026-02-28T10:00:00+08:00'))
    Check ($feb.Start.Day -eq 28 -and $feb.End.Day -eq 31 -and $feb.End.Month -eq 3) '短月採月底且下月回到原設定日期'
    $leap=Get-CodexBillingPeriod $settings ([DateTimeOffset]::Parse('2028-02-29T10:00:00+08:00'))
    Check ($leap.Start.Day -eq 29) '閏年二月月底'
    $settings.ResetDay=1
    $year=Get-CodexBillingPeriod $settings ([DateTimeOffset]::Parse('2027-01-01T09:29:59+08:00'))
    Check ($year.Start.Year -eq 2026 -and $year.End.Year -eq 2027) '跨年期間計算'
    $settings.ResetDay=15
    $queryEnd=Get-CodexBillingQueryEnd ([DateTimeOffset]::Parse('2026-11-15T20:00:00+08:00'))
    Check ($queryEnd -eq [DateTimeOffset]::Parse('2026-11-16T00:00:00Z')) 'Costs 查詢結束時間涵蓋完整當日 UTC bucket'
    Check ((Get-CodexBillingQueryEnd ([DateTimeOffset]::Parse('2026-11-15T00:00:00Z'))) -eq [DateTimeOffset]::Parse('2026-11-16T00:00:00Z')) 'UTC 零點查詢仍包含當日費用窗口'
    Check ((Get-CodexBillingQueryEnd ([DateTimeOffset]::Parse('2026-12-31T23:59:59Z'))) -eq [DateTimeOffset]::Parse('2027-01-01T00:00:00Z')) 'UTC 日窗口結束時間可跨年'
    $handler=New-Object BillingTestHandler; $handler.Body=New-CostJson 12.34
    $requestEnd=(Get-CodexBillingQueryEnd ([DateTimeOffset]::FromUnixTimeSeconds(250))).ToUnixTimeSeconds()
    $task=[CodexSwitcher.BillingClient]::Fetch('synthetic-admin',100,$requestEnd,'key_target','page +&',$cancel.Token,$handler)
    $reply=$task.GetAwaiter().GetResult()
    Check ($handler.TokenOk -and $handler.Disposed -and $handler.Requests[0].Contains('https://api.openai.com/v1/organization/costs?') -and $handler.Requests[0].Contains('start_time=100') -and $handler.Requests[0].Contains('end_time=86400') -and $handler.Requests[0].Contains('api_key_ids%5B%5D=key_target') -and $handler.Requests[0].Contains('page=page%20%2B%26')) '官方 Costs 請求含完整當日、Admin 認證、金鑰篩選及游標編碼'
    $page=ConvertFrom-CodexCostPage $reply 'key_target' 100 250
    Check ($page.Amount -eq 12.34 -and !$page.HasMore) '美元費用以 decimal 解析'
    $handler=New-Object BillingTestHandler; $handler.Body=New-CostJson 1
    $null=[CodexSwitcher.BillingClient]::Fetch('synthetic-admin',100,250,'','',$cancel.Token,$handler).GetAwaiter().GetResult()
    Check (!$handler.Requests[0].Contains('api_key_ids')) '組織模式不夾帶指定金鑰篩選'
    $job=New-TestJob $settings
    Set-JobReply $job 'OK' (New-CostJson 12.34)
    $result=Complete-CodexBillingPage $job
    Check ($result.Primary -eq 'USD 12.34' -and $result.Secondary -eq '估 USD 87.66 (87.7%)') '本期費用與預算剩餘公式'
    $job.Cancellation.Dispose()
    $job=New-TestJob $settings
    $job.QueriedAt=[DateTimeOffset]::FromUnixTimeSeconds(86400)
    Set-JobReply $job 'OK' ((New-CostJson 1.74).Replace('"start_time":100','"start_time":86400').Replace('"end_time":200','"end_time":172800'))
    Check ((Complete-CodexBillingPage $job).Primary -eq 'USD 1.74') '查詢當日 UTC 零點時，回傳的當日 bucket 不被誤判為超出範圍'
    $job.Cancellation.Dispose()
    $job=New-TestJob $settings
    Set-JobReply $job 'OK' (New-CostJson 125)
    $result=Complete-CodexBillingPage $job
    Check ($result.Status -eq '預算超支（估）' -and $result.Secondary.Contains('-25.00') -and $result.SecondaryRemaining -eq 0) '超支保留負數金額，百分比不低於零'
    $job.Cancellation.Dispose()
    $job=New-TestJob $settings
    Set-JobReply $job 'OK' '{"object":"page","data":[],"has_more":false}'
    Check ((Complete-CodexBillingPage $job).Primary -eq 'USD 0.00') '有效空資料才可視為零費用'
    $job.Cancellation.Dispose()
    foreach ($status in @('HTTP 401','HTTP 403','HTTP 429','Timeout','NetworkError')) {
        $job=New-TestJob $settings; Set-JobReply $job $status 'synthetic-admin-sensitive-error'
        $result=Complete-CodexBillingPage $job
        Check ($result.Primary -eq '未知' -and $result.Secondary -eq '未知' -and !$result.Detail.Contains('synthetic-admin')) '失敗與權限錯誤不顯示零費用或洩漏回應'
        $job.Cancellation.Dispose()
    }
    foreach ($body in @('{}','null','{"object":"page","data":[],"has_more":true}',(New-CostJson 1).Replace('key_target','key_wrong'),(New-CostJson 1).Replace('usd','eur'),(New-CostJson 1).Replace('"value":1','"value":null'))) {
        $job=New-TestJob $settings; Set-JobReply $job 'OK' $body
        Check ((Complete-CodexBillingPage $job).Status -eq '費用格式不支援') '拒絕缺漏、錯誤金鑰範圍、非美元及不完整分頁'
        $job.Cancellation.Dispose()
    }
    $job=New-TestJob $settings
    Set-JobReply $job 'OK' ((New-CostJson 2).Replace('"start_time":100','"start_time":90'))
    Check ((Complete-CodexBillingPage $job).Primary.StartsWith('約 USD')) '跨期日彙總明示費用估算'
    $job.Cancellation.Dispose()
    $originalPage=${function:Start-CodexBillingPage}
    function Start-CodexBillingPage($Job,[string]$Page) { Set-JobReply $Job 'OK' (New-CostJson 3) }
    $job=New-TestJob $settings
    Set-JobReply $job 'OK' (New-CostJson 2 $true 'next')
    Check ($null -eq (Complete-CodexBillingPage $job)) '尚有分頁時不提前顯示部分總額'
    Check ((Complete-CodexBillingPage $job).Primary -eq 'USD 5.00') '所有分頁加總後顯示總費用'
    $job.Cancellation.Dispose()
    function Start-CodexBillingPage($Job,[string]$Page) { Set-JobReply $Job 'OK' (New-CostJson 3 $true 'same') }
    $job=New-TestJob $settings
    Set-JobReply $job 'OK' (New-CostJson 2 $true 'same')
    $null=Complete-CodexBillingPage $job
    Check ((Complete-CodexBillingPage $job).Status -eq '費用格式不支援') '重複游標不無限查詢或顯示部分費用'
    $job.Cancellation.Dispose()
    $item=New-Object Windows.Forms.ListViewItem('API'); $item.Name=$script:Key
    1..6 | ForEach-Object { [void]$item.SubItems.Add('waiting') }; [void]$apiList.Items.Add($item)
    $subscription=New-Object Windows.Forms.ListViewItem('訂閱'); $subscription.Name=$script:Key
    1..6 | ForEach-Object { [void]$subscription.SubItems.Add('subscription') }; [void]$list.Items.Add($subscription)
    function Start-CodexBillingPage($Job,[string]$Page) { Set-JobReply $Job 'OK' (New-CostJson 6) }
    $job=New-TestJob $settings; Set-JobReply $job 'OK' (New-CostJson 4 $true 'next')
    $script:QuotaJobs=@($job)
    Update-QuotaResults
    Check ($script:QuotaJobs.Count -eq 1 -and $item.SubItems[2].Text -eq 'waiting') '非同步第一頁保留工作與 UI 原值'
    Update-QuotaResults
    Check (!$script:QuotaJobs.Count -and $item.SubItems[2].Text -eq 'USD 10.00' -and $script:SyncCount -eq 1) '末頁更新同帳號 UI 並同步 Web'
    Check ($subscription.SubItems[2].Text -eq 'subscription') '費用查詢只更新 API key 表格，不覆寫訂閱表格'
    $job=New-TestJob $settings; $job.Generation=-1; Set-JobReply $job 'OK' (New-CostJson 20)
    $script:QuotaJobs=@($job); Update-QuotaResults
    Check ($item.SubItems[2].Text -eq 'USD 10.00') '舊查詢世代不覆寫新費用'
    ${function:Start-CodexBillingPage}=$originalPage
    $handler=New-Object BillingTestHandler; $handler.Delay=10000
    $pendingCancel=New-Object Threading.CancellationTokenSource
    $pending=[CodexSwitcher.BillingClient]::Fetch('synthetic-admin',100,250,'','',$pendingCancel.Token,$handler)
    $pendingCancel.Cancel()
    Check ($pending.GetAwaiter().GetResult().Status -eq 'Canceled') '費用查詢可取消'
    $pendingCancel.Dispose()
    $script:ResetRefresh=0
    function Refresh-Accounts { $script:ResetRefresh++; $script:NextBillingReset=$null }
    $script:NextBillingReset=[DateTimeOffset]::UtcNow.AddSeconds(-1)
    Update-CodexBillingCycles; Update-CodexBillingCycles
    Check ($script:ResetRefresh -eq 1) '到重置時刻自動更新一次'
    Remove-AccountBackup $record.Path
    Check (!(Test-Path -LiteralPath $path)) '刪除帳號一併刪除 Admin key 與預算設定'
    'PASS: Admin key DPAPI 設定、每月時區與月底重置、Costs 篩選與分頁、預算估算、失敗保護、非同步取消及帳號刪除清理；全程合成資料與模擬 HTTP。'
} finally {
    Stop-QuotaQueries; $cancel.Dispose(); $form.Dispose(); $lastQueryLabel.Dispose()
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ((Test-Path -LiteralPath $sandbox) -and [IO.Path]::GetFullPath($sandbox).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $sandbox -Leaf) -like 'CodexBillingTest-*') { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
