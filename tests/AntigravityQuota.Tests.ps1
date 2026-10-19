$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\AntigravityQuota.ps1')
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
    public int ModelsCode = 200;
    public int ModelsCalls;
    public int ModelsDelay;
    public bool CorrectRequests = true;
    public bool ProjectIncluded;
    public string ExpectedUserAgent;
    public string VersionedQuota;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
        CorrectRequests &= request.Method == HttpMethod.Post &&
            request.RequestUri.Host == "daily-cloudcode-pa.googleapis.com" &&
            request.Headers.Authorization != null && request.Headers.Authorization.Parameter == "synthetic" &&
            (ExpectedUserAgent == null || request.Headers.UserAgent.ToString() == ExpectedUserAgent);
        string route = request.RequestUri.AbsolutePath;
        string body = await request.Content.ReadAsStringAsync();
        if (route == "/v1internal:retrieveUserQuotaSummary")
            return new HttpResponseMessage(HttpStatusCode.OK) {
                Content = new StringContent(VersionedQuota != null && request.Headers.UserAgent.ToString() == ExpectedUserAgent ? VersionedQuota : Quota)
            };
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
$summary = @{ groups=@(@{ buckets=@(
    @{ bucketId='3p-5h'; remainingFraction=0.8; resetTime='2026-10-18T19:00:00Z' },
    @{ bucketId='3p-weekly'; remainingFraction=0.6; resetTime='2026-10-25T14:00:00Z' }
) }) }
$summaryJson = $summary | ConvertTo-Json -Depth 6 -Compress
$models = @{
    models=@{
        'gemini-flash'=@{ displayName='Gemini Flash'; quotaInfo=@{ remainingFraction=0.9; resetTime='2026-10-18T19:00:00Z' } }
        'gemini-tiered'=@{ quotaInfo=@{ remainingFraction=0.3; resetTime='2026-10-18T18:00:00Z' } }
        'gemini-image'=@{ displayName='Gemini Image'; quotaInfo=@{ remainingFraction=0.0 } }
        'claude-sonnet'=@{ displayName='Claude Sonnet'; quotaInfo=@{ remainingFraction=0.1 } }
    }
    tieredModelIds=@{ flashLite=@('gemini-flash'); flash=@('gemini-tiered'); pro=@('gemini-tiered') }
}
$modelsJson = $models | ConvertTo-Json -Depth 6 -Compress
$cancel = New-Object Threading.CancellationTokenSource
$versionSandbox = Join-Path ([IO.Path]::GetTempPath()) ('AGQuotaClientTest-' + [guid]::NewGuid().ToString('N'))
try {
    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $summaryJson; $handler.Models = $modelsJson
    $reply = Fetch-Test $handler $cancel
    $quota = ConvertFrom-AGQuotaReply $reply
    Check ($handler.ModelsCalls -eq 1 -and $handler.CorrectRequests -and $handler.ProjectIncluded) 'Gemini 缺漏時以相同帳號與官方專案查詢模型額度'
    Check ($quota.FiveHour -eq 'G* 30% / C 80%' -and $quota.FiveHourRemaining -eq 30) '模型額度採語言模型最低值且不混入圖片或第三方模型'
    Check ($quota.Weekly -eq 'G 未提供 / C 60%' -and $quota.WeeklyRemaining -eq 60) '不以模型額度推算 Gemini 每週額度'
    Check ($quota.Plan -eq 'Pro' -and $quota.Status -eq '已更新／部分額度') '方案與部分額度狀態'
    Check ($quota.Detail.Contains('回應未標示週期') -and $quota.Detail.Contains('Gemini Flash') -and $quota.Detail.Contains('gemini-tiered') -and $quota.Detail.Contains('2026-10-18')) '保留模型與重置明細並標示週期邊界'

    $models.models.'gemini-tiered'.quotaInfo.remainingFraction = 0.0
    $quota = ConvertFrom-AGQuotaReply (New-TestReply $summaryJson ($models | ConvertTo-Json -Depth 6 -Compress))
    Check ($quota.FiveHour -eq 'G* 0% / C 80%' -and $quota.FiveHourRemaining -eq 0) '明確回傳零額度不可被當成缺漏'

    $models.models.'gemini-tiered'.quotaInfo.Remove('remainingFraction')
    $models.models.'gemini-flash'.quotaInfo.remainingFraction = 1.5
    $quota = ConvertFrom-AGQuotaReply (New-TestReply $summaryJson ($models | ConvertTo-Json -Depth 6 -Compress))
    Check ($quota.FiveHour -eq 'G 未知 / C 80%') '缺少比例或比例超出範圍時不可補成 100%'

    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $summaryJson; $handler.ModelsCode = 429
    $reply = Fetch-Test $handler $cancel
    $quota = ConvertFrom-AGQuotaReply $reply
    Check ($quota.FiveHour -eq 'G 未知 / C 80%' -and $quota.Detail.Contains('HTTP 429')) '模型查詢失敗保留 Claude/GPT 額度與錯誤狀態'

    $quota = ConvertFrom-AGQuotaReply (New-TestReply $summaryJson '{invalid')
    Check ($quota.Status -eq '已更新／部分額度' -and $quota.Weekly -eq 'G 未提供 / C 60%') '模型回應損壞不影響原摘要'

    $full = @{ buckets=@(
        @{ bucketId='gemini-5h'; remainingFraction=0.5 },
        @{ bucketId='gemini-weekly'; remainingFraction=0.4 },
        @{ bucketId='3p-5h'; remainingFraction=0.8 },
        @{ bucketId='3p-weekly'; remainingFraction=0.6 }
    ) } | ConvertTo-Json -Depth 5 -Compress
    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $full
    $quota = ConvertFrom-AGQuotaReply (Fetch-Test $handler $cancel)
    Check ($handler.ModelsCalls -eq 0 -and $quota.FiveHour -eq 'G 50% / C 80%' -and $quota.Weekly -eq 'G 40% / C 60%' -and $quota.Status -eq '已更新') '完整舊摘要與頂層 buckets 相容且不多發模型請求'

    [IO.Directory]::CreateDirectory((Join-Path $versionSandbox 'resources\bin')) | Out-Null
    $fixtureApp = Join-Path $versionSandbox 'Antigravity.exe'
    Add-Type -TypeDefinition '[assembly: System.Reflection.AssemblyFileVersion("9.8.7.6")] public sealed class AGQuotaVersionFixture { public static void Main() {} }' -OutputAssembly $fixtureApp -OutputType ConsoleApplication
    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $summaryJson; $handler.VersionedQuota = $full
    $handler.ExpectedUserAgent = 'antigravity/9.8.7.6'
    $quota = ConvertFrom-AGQuotaReply (Fetch-Test $handler $cancel (Join-Path $versionSandbox 'resources\bin\language_server.exe'))
    Check ($handler.CorrectRequests -and $handler.ModelsCalls -eq 0) '從已安裝程式讀取版本，所有額度與方案請求都包含正確 User-Agent'
    Check ($quota.FiveHour -eq 'G 50% / C 80%' -and $quota.Weekly -eq 'G 40% / C 60%' -and $quota.Status -eq '已更新') '版本標頭使服務提供 Gemini 每週額度，無需模型替代資料'

    $disabled = @{ groups=@(@{ buckets=@(
        @{ bucketId='gemini-5h'; remainingFraction=1; disabled=$true },
        @{ bucketId='3p-5h'; remainingFraction=0.8 },
        @{ bucketId='3p-weekly'; remainingFraction=0.6 }
    ) }) } | ConvertTo-Json -Depth 6 -Compress
    $handler = New-Object AGQuotaTestHandler
    $handler.Quota = $disabled; $handler.Models = $modelsJson
    $quota = ConvertFrom-AGQuotaReply (Fetch-Test $handler $cancel)
    Check ($handler.ModelsCalls -eq 1 -and $quota.FiveHour -eq 'G* 30% / C 80%') '停用的 Gemini 摘要不可當成滿額'

    $cancelModel = New-Object Threading.CancellationTokenSource
    try {
        $handler = New-Object AGQuotaTestHandler
        $handler.Quota = $summaryJson; $handler.ModelsDelay = 1000
        $cancelModel.CancelAfter(50)
        $reply = Fetch-Test $handler $cancelModel
        Check ($reply.Status -eq 'OK' -and $reply.ModelsStatus -eq 'Canceled') '模型查詢取消保留已取得的原摘要'
    } finally { $cancelModel.Dispose() }

    $quota = ConvertFrom-AGQuotaReply (New-TestReply '{}' '{}')
    Check ($quota.Status -eq '格式不支援' -and $null -eq $quota.FiveHourRemaining) '完全無額度時維持未知狀態'
    Invoke-AGQuotaSelfTest
    'PASS: Antigravity 新舊摘要、Gemini 模型額度、來源標示、零額度、缺漏、取消與查詢失敗隔離。全程合成資料與模擬 HTTP。'
} finally {
    $cancel.Dispose()
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ((Test-Path -LiteralPath $versionSandbox) -and [IO.Path]::GetFullPath($versionSandbox).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $versionSandbox -Leaf) -like 'AGQuotaClientTest-*') {
        Remove-Item -LiteralPath $versionSandbox -Recurse -Force
    }
}
