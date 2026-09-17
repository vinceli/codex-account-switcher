$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\CodexAccountSwitcher.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '主程式語法錯誤' }
# 載入函式，不進入真實帳號讀取或 GUI 啟動入口。
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Initialize-QuotaClient
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class QuotaTestHandler : HttpMessageHandler {
    public int Code = 200;
    public string Body = "{}";
    public int Delay;
    public bool Offline;
    public bool Disposed;
    public int Calls;
    public bool CorrectRequest;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) {
        Calls++;
        CorrectRequest = r.Method == HttpMethod.Get &&
            r.RequestUri.AbsoluteUri == "https://chatgpt.com/backend-api/wham/usage" &&
            r.Headers.Authorization.Scheme == "Bearer" &&
            r.Headers.Authorization.Parameter == "synthetic" &&
            r.Headers.Contains("ChatGPT-Account-Id");
        if (Offline) throw new HttpRequestException("synthetic-sensitive-error-must-not-escape");
        if (Delay > 0) await Task.Delay(Delay, ct).ConfigureAwait(false);
        return new HttpResponseMessage((HttpStatusCode)Code) { Content = new StringContent(Body) };
    }
    protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}
'@
function Check([bool]$Condition, [string]$Message) { if (!$Condition) { throw "測試失敗：$Message" } }
function Fetch-Test($Handler, $Cancellation) {
    $task = [CodexSwitcher.QuotaClient]::Fetch('synthetic', 'synthetic-account', $Cancellation.Token, $Handler)
    $task.GetAwaiter().GetResult()
}
$now = [DateTimeOffset]::UtcNow
$reset = $now.AddHours(3).ToUnixTimeSeconds()
$json = @{
    plan_type='plus'
    rate_limit=@{
        primary_window=@{ used_percent=22; limit_window_seconds=18000; reset_at=$reset; reset_after_seconds=99999 }
        secondary_window=@{ used_percent=16; limit_window_seconds=604800; reset_after_seconds=587520 }
    }
    additional_rate_limits=@(@{ limit_name='Other'; rate_limit=@{ primary_window=@{ used_percent=10; limit_window_seconds=900 }; secondary_window=$null } })
} | ConvertTo-Json -Depth 8
$cancel = New-Object Threading.CancellationTokenSource
$form = New-Object Windows.Forms.Form
$list = New-Object Windows.Forms.ListView
$form.Controls.Add($list)
$script:QuotaJobs=@(); $script:QuotaGeneration=0
try {
    $handler=New-Object QuotaTestHandler; $handler.Body=$json
    $reply=Fetch-Test $handler $cancel
    $q=ConvertFrom-QuotaReply $reply
    Check ($q.Primary -like '5h 78%*' -and $q.Secondary -like '7d 84%*') '雙窗口百分比與實際週期'
    Check ($q.PrimaryRemaining -eq 78 -and $q.SecondaryRemaining -eq 84) '保留剩餘比例供介面著色'
    Check ((Get-QuotaColor 0).Name -eq 'Firebrick' -and (Get-QuotaColor 29.9).Name -eq 'DarkOrange' -and (Get-QuotaColor 69.9).Name -eq 'ForestGreen' -and (Get-QuotaColor 70).Name -eq 'RoyalBlue') '四色門檻'
    $weeklyEmpty = $json | ConvertFrom-Json
    $weeklyEmpty.rate_limit.secondary_window.used_percent = 100
    $q = ConvertFrom-QuotaReply ([pscustomobject]@{ Status='OK'; Json=($weeklyEmpty | ConvertTo-Json -Depth 8); ReceivedAt=$now })
    Check ($q.PrimaryRemaining -eq 0 -and $q.Primary -like '5h 0%*' -and $q.SecondaryRemaining -eq 0) '週額度歸零時五小時額度同步歸零'
    Check ($q.Detail.Contains('15m') -and $q.Status -eq '已更新／多額度') '其他額度保留在提示'
        Check ($q.Detail.Contains([DateTimeOffset]::FromUnixTimeSeconds($reset).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))) '絕對重置時間優先'
    # 5 小時額度顯示重置時間點，不顯示剩餘時間 (例如 3h00m)
    $expected5hResetTime = [DateTimeOffset]::FromUnixTimeSeconds($reset).ToLocalTime()
    $expected5hStr = if ($expected5hResetTime.Date -eq [DateTime]::Today) { $expected5hResetTime.ToString('HH:mm') } else { $expected5hResetTime.ToString('MM/dd HH:mm') }
    Check ($q.Primary.Contains($expected5hStr) -and !$q.Primary.Contains('3h00m')) '5小時用量改顯示重置時間且不顯示剩餘倒數'
    # 週用量小於 12 小時顯示重置時間
    $wUnder12 = @{ limit_window_seconds=604800; used_percent=20; reset_after_seconds=21600 }
    $under12Time = $now.AddSeconds(21600).ToLocalTime()
    $under12Str = if ($under12Time.Date -eq [DateTime]::Today) { $under12Time.ToString('HH:mm') } else { $under12Time.ToString('MM/dd HH:mm') }
    $qUnder12 = Format-QuotaWindow $wUnder12 $now
    Check ($qUnder12.Text.Contains($under12Str) -and !$qUnder12.Text.Contains('6h00m')) '週用量小於12小時改顯示重置時間'
    # 週用量大於 12 小時保持原樣 (12h~24h 顯示 XhYYm，>=24h 顯示 X.Xd)
    $w15h = @{ limit_window_seconds=604800; used_percent=50; reset_after_seconds=54000 }
    $q15h = Format-QuotaWindow $w15h $now
    Check ($q15h.Text.Contains('15h00m')) '週用量大於12小時且小於24小時保持原樣(小時倒數)'
    $w3d = @{ limit_window_seconds=604800; used_percent=50; reset_after_seconds=259200 }
    $q3d = Format-QuotaWindow $w3d $now
    Check ($q3d.Text.Contains('3d') -or $q3d.Text.Contains('3.0d')) '週用量大於24小時保持原樣(天數倒數)'
    Check ($handler.CorrectRequest -and $handler.Calls -eq 1 -and $handler.Disposed) '唯讀 GET、帳號標頭、無重試、釋放連線'
    foreach ($case in @(@(401,'需重新授權'),@(403,'存取受限'),@(429,'稍後重試'),@(500,'服務無法使用'),@(302,'服務無法使用'))) {
        $handler=New-Object QuotaTestHandler; $handler.Code=$case[0]; $handler.Body='sensitive-error-body'
        $reply=Fetch-Test $handler $cancel
        $q=ConvertFrom-QuotaReply $reply
        Check ($q.Status -eq $case[1] -and !$reply.Json -and $handler.Calls -eq 1) "HTTP $($case[0]) 不重試、不洩漏錯誤回應"
    }
    $handler=New-Object QuotaTestHandler; $handler.Offline=$true
    Check ((Fetch-Test $handler $cancel).Status -eq 'NetworkError') '離線錯誤不回傳例外內容'
    $handler=New-Object QuotaTestHandler; $handler.Delay=10000
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Check ((Fetch-Test $handler $cancel).Status -eq 'Timeout') '慢速服務逾時'
    Check ($watch.Elapsed.TotalSeconds -lt 5) '逾時有界'
    $handler=New-Object QuotaTestHandler; $handler.Delay=10000
    $otherCancel=New-Object Threading.CancellationTokenSource
    $task=[CodexSwitcher.QuotaClient]::Fetch('synthetic','synthetic-account',$otherCancel.Token,$handler)
    $otherCancel.Cancel()
    Check ($task.GetAwaiter().GetResult().Status -eq 'Canceled') '取消進行中的 HTTP'
    $otherCancel.Dispose()
    $q=ConvertFrom-QuotaReply ([pscustomobject]@{ Status='OK'; Json='{"plan_type":"plus","rate_limit":{"primary_window":{"limit_window_seconds":900}}}'; ReceivedAt=$now })
    Check ($q.Primary -like '15m 未知*' -and $q.Secondary -eq '未提供') '缺值不誤判為零或滿額'
    foreach ($case in @(@(125,'0%'),@(-5,'100%'))) {
        Check ((Format-QuotaWindow ([pscustomobject]@{ used_percent=$case[0] }) $now).Text.Contains($case[1])) '百分比上下限'
    }
    Check ((Format-QuotaWindow ([pscustomobject]@{ used_percent='NaN'; reset_at=1 }) $now).Text -like '*未知*待重新整理*') '無效數值及過期時間'
    foreach ($badJson in @('not-json','{}','[]','null')) {
        Check ((ConvertFrom-QuotaReply ([pscustomobject]@{ Status='OK'; Json=$badJson; ReceivedAt=$now })).Status -eq '格式不支援') '不支援的回應'
    }
    foreach ($key in @('B','A')) {
        $item=New-Object Windows.Forms.ListViewItem($key); $item.Name=$key
        1..7 | ForEach-Object { [void]$item.SubItems.Add('waiting') }
        [void]$list.Items.Add($item)
    }
    $handler=New-Object QuotaTestHandler; $handler.Body=$json; $handler.Delay=500
    $jobCancel=New-Object Threading.CancellationTokenSource
    $watch.Restart()
    $task=[CodexSwitcher.QuotaClient]::Fetch('synthetic','synthetic-account',$jobCancel.Token,$handler)
    Check ($watch.ElapsedMilliseconds -lt 300 -and !$task.IsCompleted) 'HTTP 不阻塞 UI 執行緒'
    $script:QuotaJobs=@([pscustomobject]@{ Key='A'; Generation=0; Cancellation=$jobCancel; Task=$task })
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=20; $script:Ticks=0
    $timer.Add_Tick({ $script:Ticks++ }); $timer.Start()
    while (!$task.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
    $timer.Stop(); $timer.Dispose()
    Update-QuotaResults
    Check ($script:Ticks -gt 3 -and $list.Items['A'].SubItems[2].Text -eq 'plus' -and $list.Items['B'].SubItems[2].Text -eq 'waiting') '查詢期間 UI 回應、依 Key 更新而非列索引'
    $staleCancel=New-Object Threading.CancellationTokenSource
    $script:QuotaJobs=@([pscustomobject]@{ Key='B'; Generation=-1; Cancellation=$staleCancel; Task=$task })
    Update-QuotaResults
    Check ($list.Items['B'].SubItems[2].Text -eq 'waiting') '忽略前一輪已完成結果'
    1..3 | ForEach-Object {
        $handler=New-Object QuotaTestHandler; $handler.Delay=10000
        $c=New-Object Threading.CancellationTokenSource
        $t=[CodexSwitcher.QuotaClient]::Fetch('synthetic','synthetic-account',$c.Token,$handler)
        $script:QuotaJobs=@([pscustomobject]@{ Key='B'; Generation=$script:QuotaGeneration; Cancellation=$c; Task=$t })
        Stop-QuotaQueries
        Check (!$script:QuotaJobs.Count -and $t.GetAwaiter().GetResult().Status -eq 'Canceled') '重新整理／切換取消前一輪'
    }
    $form.Dispose()
    Update-QuotaResults
    Check (!$script:QuotaJobs.Count) '視窗關閉後不更新控制項'
    'PASS: 額度解析、HTTP 錯誤、逾時、取消、非同步 UI、帳號對應與過期結果隔離；全程合成資料及模擬 HTTP。'
} finally { Stop-QuotaQueries; $cancel.Dispose(); $form.Dispose() }
