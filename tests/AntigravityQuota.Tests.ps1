$ErrorActionPreference = 'Stop'
$sourceRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'CodexAccountSwitcher.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '主程式語法錯誤' }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst] -and $statement.Name -in @('Format-QuotaWindow','Get-QuotaColor')) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
. (Join-Path $sourceRoot 'AntigravityQuota.ps1')
Initialize-AGQuotaClient
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class AGQuotaTestHandler : HttpMessageHandler {
    public string Quota = "{}";
    public string Plan = "{\"paidTier\":{\"id\":\"g1-pro-tier\"},\"cloudaicompanionProject\":\"synthetic-project\"}";
    public string Models = "{}";
    public string HubQuota;
    public int ModelsCode = 200;
    public int ModelsCalls;
    public int ModelsDelay;
    public bool CorrectRequests = true;
    public bool ProjectIncluded;
    public string ExpectedUserAgent;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
        string userAgent = string.Join(" ", request.Headers.GetValues("User-Agent"));
        bool hub = userAgent.StartsWith("antigravity/hub", StringComparison.Ordinal);
        CorrectRequests &= hub && request.Method == HttpMethod.Post &&
            request.RequestUri.Host == "daily-cloudcode-pa.googleapis.com" &&
            request.Headers.Authorization != null && request.Headers.Authorization.Parameter == "synthetic" &&
            (ExpectedUserAgent == null || userAgent == ExpectedUserAgent);
        string route = request.RequestUri.AbsolutePath;
        string body = await request.Content.ReadAsStringAsync().ConfigureAwait(false);
        if (route == "/v1internal:retrieveUserQuotaSummary")
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(hub && HubQuota != null ? HubQuota : Quota) };
        if (route == "/v1internal:loadCodeAssist")
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Plan) };
        if (route == "/v1internal:fetchAvailableModels") {
            ModelsCalls++;
            ProjectIncluded = body.Contains("\"project\":\"synthetic-project\"");
            if (ModelsDelay > 0) await Task.Delay(ModelsDelay, cancellation).ConfigureAwait(false);
            return new HttpResponseMessage((HttpStatusCode)ModelsCode) { Content = new StringContent(Models) };
        }
        throw new HttpRequestException("unexpected synthetic route");
    }
}
'@
function Check([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw ('Antigravity 額度測試失敗：' + $Message) }
}
function New-TestReply([string]$Summary, [string]$Models = '', [string]$ModelsStatus = '') {
    [pscustomobject]@{
        Status='OK'; Json=$Summary; ModelsJson=$Models; ModelsStatus=$ModelsStatus
        PlanJson='{"paidTier":{"id":"g1-pro-tier"}}'; ReceivedAt=[DateTimeOffset]::UtcNow
    }
}
function Fetch-Test($Handler, $Cancel, [string]$BinaryPath = '') {
    [AntigravitySwitcher.QuotaClient]::Fetch('synthetic', '', $BinaryPath, $Cancel.Token, $Handler).GetAwaiter().GetResult()
}
$now = [DateTimeOffset]::UtcNow
$soon = $now.AddHours(2).ToString('o')
$later = $now.AddHours(4).ToString('o')
$weekly = $now.AddDays(3).ToString('o')
$summary = @{ groups=@(@{ buckets=@(
    @{ bucketId='3p-5h'; remainingFraction=0.8; resetTime=$soon },
    @{ bucketId='3p-weekly'; remainingFraction=0.6; resetTime=$weekly }
) }) }
$summaryJson = $summary | ConvertTo-Json -Depth 6 -Compress
$models = @{
    models=@{
        'gemini-flash'=@{ displayName='Gemini Flash'; quotaInfo=@{ remainingFraction=0.9; resetTime=$soon } }
        'gemini-tiered'=@{ quotaInfo=@{ remainingFraction=0.3; resetTime=$later } }
        'gemini-image'=@{ displayName='Gemini Image'; quotaInfo=@{ remainingFraction=0.0 } }
        'gemini-4-argon-low'=@{ displayName='Gemini 4 Argon (Low)'; quotaInfo=@{ remainingFraction=0.2; resetTime=$later } }
        'gemini-4-argon-high'=@{ displayName='Gemini 4 Argon (High)'; quotaInfo=@{ remainingFraction=0.7; resetTime=$soon } }
        'claude-sonnet'=@{ displayName='Claude Sonnet'; quotaInfo=@{ remainingFraction=0.1; resetTime=$later } }
    }
    tieredModelIds=@{ flashLite=@('gemini-flash'); flash=@('gemini-tiered'); pro=@('gemini-tiered','gemini-4-argon-low') }
}
$modelsJson = $models | ConvertTo-Json -Depth 6 -Compress
$cancel = New-Object Threading.CancellationTokenSource
$versionSandbox = Join-Path ([IO.Path]::GetTempPath()) ('AGQuotaClientTest-' + [guid]::NewGuid().ToString('N'))
$form = New-Object Windows.Forms.Form
$agList = New-Object Windows.Forms.ListView
$agLastQueryLabel = New-Object Windows.Forms.Label
try {
    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $summaryJson; $handler.Models = $modelsJson
    $reply = Fetch-Test $handler $cancel
    $quota = ConvertFrom-AGQuotaReply $reply
    $laterText = ([DateTimeOffset]::Parse($later)).ToLocalTime().ToString('HH:mm')
    $soonText = ([DateTimeOffset]::Parse($soon)).ToLocalTime().ToString('HH:mm')
    Check ($handler.ModelsCalls -eq 1 -and $handler.CorrectRequests -and $handler.ProjectIncluded) '以相同帳號與官方專案查詢三種模型額度'
    Check ($quota.FiveHour -match '^G\* 30% \(' -and $quota.FiveHour -match ' / C 80% \(' -and $quota.FiveHour -match ' / A\* 20% \(' -and $quota.FiveHourRemaining -eq 20) 'Argon 與一般 Gemini 獨立分組，摘要優先於 Claude 模型替代值'
    Check ($quota.FiveHour.Contains('A* 20% (' + $laterText + ')') -and $quota.FiveHour.Contains('C 80% (' + $soonText + ')')) '每種額度的重置時間對應自己的來源，採最低額度模型的時間'
    Check ($quota.Weekly -like 'G 未提供 / C 60% (*) / A 未提供' -and $quota.WeeklyRemaining -eq 60) '模型額度不推算每週額度'
    Check ($quota.Plan -eq 'Pro' -and $quota.Status -eq '已更新／部分額度') '方案與部分額度狀態'
    Check ($quota.Detail.Contains('回應未標示週期') -and $quota.Detail.Contains('Gemini Flash') -and $quota.Detail.Contains('gemini-tiered') -and $quota.Detail.Contains('Gemini 4 Argon')) '保留三種模型的比例、來源與重置明細'

    $models.models.'gemini-tiered'.quotaInfo.remainingFraction = 0.0
    $quota = ConvertFrom-AGQuotaReply (New-TestReply $summaryJson ($models | ConvertTo-Json -Depth 6 -Compress))
    Check ($quota.FiveHour -match '^G\* 0%' -and $quota.FiveHourRemaining -eq 0) '明確回傳零額度不可被當成缺漏'
    $models.models.'gemini-tiered'.quotaInfo.Remove('remainingFraction')
    $models.models.'gemini-flash'.quotaInfo.remainingFraction = 1.5
    $quota = ConvertFrom-AGQuotaReply (New-TestReply $summaryJson ($models | ConvertTo-Json -Depth 6 -Compress))
    Check ($quota.FiveHour -like 'G 未提供 / C 80%* / A*' -and $quota.FiveHour -notmatch 'G\*') '無效 Gemini 比例不以 Argon 額度補值'

    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $summaryJson; $handler.ModelsCode = 429
    $quota = ConvertFrom-AGQuotaReply (Fetch-Test $handler $cancel)
    Check ($quota.FiveHour -like 'G 未提供 / C 80%* / A 未提供' -and $quota.Detail.Contains('HTTP 429')) '模型查詢失敗保留原摘要，缺少 Argon 不補成 100%'
    $quota = ConvertFrom-AGQuotaReply (New-TestReply $summaryJson '{invalid')
    Check ($quota.Status -eq '已更新／部分額度' -and $quota.Weekly -like 'G 未提供 / C 60%* / A 未提供') '模型回應損壞不影響原摘要'

    $fullBuckets = @(
        @{ bucketId='gemini-5h'; remainingFraction=0.5; resetTime=$soon },
        @{ bucketId='gemini-weekly'; remainingFraction=0.4; resetTime=$weekly },
        @{ bucketId='3p-5h'; remainingFraction=0.8; resetTime=$soon },
        @{ bucketId='3p-weekly'; remainingFraction=0.6; resetTime=$weekly }
    )
    $full = @{ buckets=$fullBuckets } | ConvertTo-Json -Depth 5 -Compress
    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $full; $handler.Models = $modelsJson
    $quota = ConvertFrom-AGQuotaReply (Fetch-Test $handler $cancel)
    Check ($handler.ModelsCalls -eq 1 -and $quota.FiveHour -match '^G 50%.* / C 80%.* / A\* 20%' -and $quota.Weekly -match '^G 40%.* / C 60%.* / A 未提供$') '完整舊摘要仍查詢 Argon，保留 Gemini 與 Claude 摘要值'

    [IO.Directory]::CreateDirectory((Join-Path $versionSandbox 'resources\bin')) | Out-Null
    $fixtureApp = Join-Path $versionSandbox 'Antigravity.exe'
    Add-Type -TypeDefinition '[assembly: System.Reflection.AssemblyFileVersion("9.8.7.6")] public sealed class AGQuotaVersionFixture { public static void Main() {} }' -OutputAssembly $fixtureApp -OutputType ConsoleApplication
    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $full; $handler.Models = $modelsJson
    $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
    $handler.ExpectedUserAgent = 'antigravity/hub/9.8.7.6 windows/' + $architecture
    $handler.HubQuota = @{ buckets=$fullBuckets + @(@{ bucketId='gemini-argon-wtu-weekly'; window='weekly'; remainingFraction=0.95; resetTime=$weekly }) } | ConvertTo-Json -Depth 5 -Compress
    $quota = ConvertFrom-AGQuotaReply (Fetch-Test $handler $cancel (Join-Path $versionSandbox 'resources\bin\language_server.exe'))
    Check ($handler.CorrectRequests -and $handler.ModelsCalls -eq 1) '摘要、方案與模型請求皆使用 hub 識別、已安裝版本及 Windows 平台'
    Check ($quota.Status -eq '已更新' -and $quota.FiveHour -match 'A 僅每週$' -and $quota.Weekly -match 'A 95% \(' -and $quota.Detail.Contains('Argon 每週')) 'hub 才提供的真實 Argon bucket 可解析，週額度優先於模型值且不冒充五小時額度'

    $six = @{ buckets=$fullBuckets + @(
        @{ bucketId='argon-5h'; remainingFraction=0.9; resetTime=$later },
        @{ bucketId='argon-weekly'; remainingFraction=0.0; resetTime=$weekly }
    ) } | ConvertTo-Json -Depth 5 -Compress
    $quota = ConvertFrom-AGQuotaReply (New-TestReply $six $modelsJson)
    Check ($quota.Status -eq '已更新' -and $quota.FiveHour -match 'A 0% \(週額度耗盡\)' -and $quota.Weekly -match 'A 0% \(' -and $quota.FiveHourRemaining -eq 0) '合成三組摘要支援各自窗口與每週歸零保護'

    $weeklyOnly = '{"buckets":[{"bucketId":"gemini-argon-wtu-weekly","remainingFraction":0,"resetTime":"' + $weekly + '"}]}'
    $quota = ConvertFrom-AGQuotaReply (New-TestReply $weeklyOnly $modelsJson)
    Check ($quota.FiveHour -eq 'G* 30% (' + $laterText + ') / C* 10% (' + $laterText + ') / A 僅每週' -and $quota.Weekly -match 'A 0% \(' -and $quota.FiveHourRemaining -eq 10 -and $quota.WeeklyRemaining -eq 0) 'Argon 每週用盡不改寫 Gemini／Claude 五小時額度'
    foreach ($disabledModel in @(
        '{"models":{"gemini-4-argon-disabled":{"quotaInfo":{"remainingFraction":1}}}}',
        '{"models":{"gemini-4-argon":{"disabled":true,"quotaInfo":{"remainingFraction":1}}}}'
    )) {
        $quota = ConvertFrom-AGQuotaReply (New-TestReply $full $disabledModel)
        Check ($quota.FiveHour -match 'A 未提供$' -and $quota.Weekly -match 'A 未提供$') '停用的 Argon 占位模型不得顯示為滿額'
    }

    $argonOnly = '{"models":{"gemini-4-argon":{"displayName":"Gemini 4 Argon","quotaInfo":{"remainingFraction":0}}}}'
    $quota = ConvertFrom-AGQuotaReply (New-TestReply '{}' $argonOnly)
    Check ($quota.FiveHour -eq 'G 未提供 / C 未提供 / A* 0% (重置未知)' -and $quota.FiveHourRemaining -eq 0 -and $quota.WeeklyRemaining -eq $null) '只有 Argon 模型時保持獨立，缺少時間與週額度明示未知'

    foreach ($invalid in @('null','"NaN"','"Infinity"','1.5','-0.1')) {
        $json = '{"models":{"gemini-4-argon":{"quotaInfo":{"remainingFraction":' + $invalid + '}}}}'
        $quota = ConvertFrom-AGQuotaReply (New-TestReply $full $json)
        Check ($quota.FiveHour -match 'A 未提供$') '無效 Argon 比例不可顯示為有效額度'
    }
    $badReset = '{"models":{"gemini-4-argon":{"quotaInfo":{"remainingFraction":0.2,"resetTime":"invalid"}}}}'
    Check ((ConvertFrom-AGQuotaReply (New-TestReply '{}' $badReset)).FiveHour -match 'A\* 20% \(重置未知\)') 'Argon 時間損壞保留有效比例，不推算重置時間'

    $cancelModel = New-Object Threading.CancellationTokenSource
    try {
        $handler = New-Object AGQuotaTestHandler
        $handler.Quota = $full; $handler.ModelsDelay = 1000
        $cancelModel.CancelAfter(50)
        $reply = Fetch-Test $handler $cancelModel
        Check ($reply.Status -eq 'OK' -and $reply.ModelsStatus -eq 'Canceled') 'Argon 模型查詢取消保留已取得摘要'
    } finally { $cancelModel.Dispose() }

    foreach ($key in @('B','A')) {
        $item = New-Object Windows.Forms.ListViewItem($key); $item.Name = $key
        1..6 | ForEach-Object { [void]$item.SubItems.Add('waiting') }
        [void]$agList.Items.Add($item)
    }
    $handler = New-Object AGQuotaTestHandler; $handler.Quota = $full; $handler.Models = $modelsJson
    $jobCancel = New-Object Threading.CancellationTokenSource
    $task = [AntigravitySwitcher.QuotaClient]::Fetch('synthetic','', '', $jobCancel.Token, $handler)
    $null = $task.GetAwaiter().GetResult()
    $script:AGQuotaJobs = @([pscustomobject]@{ Key='A'; Generation=0; Cancellation=$jobCancel; Task=$task })
    Update-AGQuotaResults
    Check ($agList.Items['A'].SubItems[1].Text -eq 'Pro' -and $agList.Items['A'].SubItems[2].Text -match 'A\* 20%' -and $agList.Items['A'].SubItems[5].Text -eq '已更新／部分額度' -and $agList.Items['B'].SubItems[1].Text -eq 'waiting') '移除名稱欄後仍依帳號 Key 更新正確的方案、三種額度及狀態欄'
    $staleCancel = New-Object Threading.CancellationTokenSource
    $script:AGQuotaJobs = @([pscustomobject]@{ Key='B'; Generation=-1; Cancellation=$staleCancel; Task=$task })
    Update-AGQuotaResults
    Check ($agList.Items['B'].SubItems[1].Text -eq 'waiting') '忽略上一輪過期查詢結果'

    $quota = ConvertFrom-AGQuotaReply (New-TestReply '{}' '{}')
    Check ($quota.Status -eq '格式不支援' -and $null -eq $quota.FiveHourRemaining) '完全無額度時維持未知狀態'
    Invoke-AGQuotaSelfTest
    'PASS: Antigravity 三種額度分組、Argon 偵測、重置時間、來源隔離、缺漏與零額度、非同步欄位更新及取消。全程合成資料與模擬 HTTP。'
} finally {
    $cancel.Dispose()
    $form.Dispose(); $agList.Dispose(); $agLastQueryLabel.Dispose()
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ((Test-Path -LiteralPath $versionSandbox) -and [IO.Path]::GetFullPath($versionSandbox).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $versionSandbox -Leaf) -like 'AGQuotaClientTest-*') {
        Remove-Item -LiteralPath $versionSandbox -Recurse -Force
    }
}
