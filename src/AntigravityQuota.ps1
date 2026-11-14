function Initialize-AGQuotaClient {
    if ('AntigravitySwitcher.QuotaClient' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Net.Http,System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace AntigravitySwitcher {
    public sealed class QuotaReply {
        public string Status;
        public string Json;
        public string PlanJson;
        public string ModelsJson;
        public string ModelsStatus;
        public DateTimeOffset ReceivedAt;
    }

    public static class QuotaClient {
        private const string QuotaUrl = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary";
        private const string PlanUrl = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
        private const string ModelsUrl = "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels";
        private const string TokenUrl = "https://oauth2.googleapis.com/token";
        private const string ClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";

        private static HttpRequestMessage Request(string url, string token, string body, string userAgent) {
            var request = new HttpRequestMessage(HttpMethod.Post, url);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.TryAddWithoutValidation("User-Agent", userAgent);
            request.Content = new StringContent(body, Encoding.UTF8, "application/json");
            return request;
        }

        private static string InstalledUserAgent(string binaryPath) {
            string architecture = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") == "ARM64" ? "arm64" :
                (Environment.Is64BitOperatingSystem ? "amd64" : "386");
            string platform = " windows/" + architecture;
            const string product = "antigravity/hub";
            try {
                if (string.IsNullOrEmpty(binaryPath)) return product + platform;
                string appPath = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(binaryPath), "..", "..", "Antigravity.exe"));
                if (File.Exists(appPath)) {
                    var version = Regex.Match(FileVersionInfo.GetVersionInfo(appPath).FileVersion ?? "", @"^\s*(\d+\.\d+\.\d+(?:\.\d+)?)");
                    if (version.Success) return product + "/" + version.Groups[1].Value + platform;
                }
            } catch (IOException) { }
              catch (ArgumentException) { }
              catch (UnauthorizedAccessException) { }
            return product + platform;
        }

        private static string InstalledClientSecret(string binaryPath) {
            if (!File.Exists(binaryPath)) return null;
            string found = null;
            var buffer = new byte[65536 + 34];
            int carry = 0;
            using (var stream = File.OpenRead(binaryPath)) {
                int read;
                while ((read = stream.Read(buffer, carry, 65536)) > 0) {
                    int length = carry + read;
                    foreach (Match match in Regex.Matches(Encoding.ASCII.GetString(buffer, 0, length), @"GOCSPX-[A-Za-z0-9]{28}")) {
                        if (found != null) return null;
                        found = match.Value;
                    }
                    carry = Math.Min(34, length);
                    Buffer.BlockCopy(buffer, length - carry, buffer, 0, carry);
                }
            }
            return found;
        }

        public static async Task<QuotaReply> Fetch(string accessToken, string refreshToken,
            string binaryPath, CancellationToken cancellation, HttpMessageHandler handler) {
            try {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                using (var client = new HttpClient(handler ?? new HttpClientHandler {
                    AllowAutoRedirect = false, UseCookies = false
                })) {
                    client.Timeout = TimeSpan.FromSeconds(12);
                    client.MaxResponseContentBufferSize = 256 * 1024;
                    string token = accessToken;
                    string userAgent = InstalledUserAgent(binaryPath);
                    for (int attempt = 0; attempt < 2; attempt++) {
                        using (var request = Request(QuotaUrl, token, "{}", userAgent))
                        using (var response = await client.SendAsync(request, cancellation).ConfigureAwait(false)) {
                            int code = (int)response.StatusCode;
                            if (code == 200) {
                                var result = new QuotaReply {
                                    Status = "OK", ReceivedAt = DateTimeOffset.UtcNow,
                                    Json = await response.Content.ReadAsStringAsync().ConfigureAwait(false)
                                };
                                try {
                                    using (var planRequest = Request(PlanUrl, token, "{\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}", userAgent))
                                    using (var planResponse = await client.SendAsync(planRequest, cancellation).ConfigureAwait(false)) {
                                        if (planResponse.IsSuccessStatusCode)
                                            result.PlanJson = await planResponse.Content.ReadAsStringAsync().ConfigureAwait(false);
                                    }
                                } catch (HttpRequestException) { }
                                  catch (OperationCanceledException) { }
                                try {
                                    var body = "{}";
                                    if (!string.IsNullOrEmpty(result.PlanJson)) {
                                        try {
                                            var plan = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(result.PlanJson);
                                            object project;
                                            if (plan.TryGetValue("cloudaicompanionProject", out project) && project is string && !string.IsNullOrEmpty((string)project))
                                                body = new JavaScriptSerializer().Serialize(new { project = (string)project });
                                        } catch { }
                                    }
                                    using (var modelRequest = Request(ModelsUrl, token, body, userAgent))
                                    using (var modelResponse = await client.SendAsync(modelRequest, cancellation).ConfigureAwait(false)) {
                                        result.ModelsStatus = "HTTP " + (int)modelResponse.StatusCode;
                                        if (modelResponse.IsSuccessStatusCode)
                                            result.ModelsJson = await modelResponse.Content.ReadAsStringAsync().ConfigureAwait(false);
                                    }
                                } catch (HttpRequestException) { result.ModelsStatus = "NetworkError"; }
                                  catch (OperationCanceledException) { result.ModelsStatus = cancellation.IsCancellationRequested ? "Canceled" : "Timeout"; }
                                return result;
                            }
                            if (code != 401 || attempt > 0) return new QuotaReply { Status = "HTTP " + code };
                        }
                        if (string.IsNullOrEmpty(refreshToken)) return new QuotaReply { Status = "HTTP 401" };
                        string secret = InstalledClientSecret(binaryPath);
                        if (string.IsNullOrEmpty(secret)) return new QuotaReply { Status = "ClientUnavailable" };
                        var form = new Dictionary<string, string> {
                            { "client_id", ClientId }, { "client_secret", secret },
                            { "refresh_token", refreshToken }, { "grant_type", "refresh_token" }
                        };
                        using (var refresh = new HttpRequestMessage(HttpMethod.Post, TokenUrl)) {
                            refresh.Content = new FormUrlEncodedContent(form);
                            using (var response = await client.SendAsync(refresh, cancellation).ConfigureAwait(false)) {
                                if (!response.IsSuccessStatusCode)
                                    return new QuotaReply { Status = "Refresh HTTP " + (int)response.StatusCode };
                                var values = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(
                                    await response.Content.ReadAsStringAsync().ConfigureAwait(false));
                                object refreshed;
                                if (!values.TryGetValue("access_token", out refreshed) || !(refreshed is string) || string.IsNullOrEmpty((string)refreshed))
                                    return new QuotaReply { Status = "RefreshFormat" };
                                token = (string)refreshed;
                            }
                        }
                    }
                    return new QuotaReply { Status = "HTTP 401" };
                }
            } catch (OperationCanceledException) {
                return new QuotaReply { Status = cancellation.IsCancellationRequested ? "Canceled" : "Timeout" };
            } catch (HttpRequestException) {
                return new QuotaReply { Status = "NetworkError" };
            } catch {
                return new QuotaReply { Status = "ClientUnavailable" };
            }
        }
    }
}
'@
}

function ConvertFrom-AGQuotaReply($Reply) {
    $result = [pscustomobject]@{ Plan='—'; FiveHour='未知'; Weekly='未知'; FiveHourRemaining=$null; WeeklyRemaining=$null; Status='查詢失敗'; Detail='' }
    if ($Reply.Status -ne 'OK') {
        $result.Status = switch ($Reply.Status) {
            { $_ -in @('HTTP 401','Refresh HTTP 400','Refresh HTTP 401') } { '需重新授權'; break }
            'HTTP 403' { '存取受限' }
            'HTTP 429' { '稍後重試' }
            'Timeout' { '查詢逾時' }
            'Canceled' { '已取消' }
            'NetworkError' { '連線失敗' }
            'ClientUnavailable' { '查詢設定不可用' }
            default { '服務無法使用' }
        }
        $result.Detail = $result.Status
        return $result
    }
    try {
        $data = $Reply.Json | ConvertFrom-Json
        $buckets = @{}
        foreach ($bucket in (@($data.buckets) + @(foreach ($group in @($data.groups)) { $group.buckets }))) {
            $bucketId = if ($bucket.bucketId -eq 'gemini-argon-wtu-weekly') { 'argon-weekly' } else { [string]$bucket.bucketId }
            $fraction = 0.0
            if ($bucketId -in @('gemini-5h','gemini-weekly','3p-5h','3p-weekly','argon-5h','argon-weekly') -and !$bucket.disabled -and
                $null -ne $bucket.remainingFraction -and
                [double]::TryParse([string]$bucket.remainingFraction, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$fraction) -and
                ![double]::IsNaN($fraction) -and $fraction -ge 0 -and $fraction -le 1) {
                $buckets[$bucketId] = [pscustomobject]@{ Fraction=$fraction; Reset=[string]$bucket.resetTime }
            }
        }
        $modelQuotas = @{ G=@(); C=@(); A=@() }
        if ($Reply.ModelsJson) {
            try {
                $models = $Reply.ModelsJson | ConvertFrom-Json
                $modelIds = @($models.tieredModelIds.flashLite) + @($models.tieredModelIds.flash) + @($models.tieredModelIds.pro)
                $modelIds = @($modelIds | Where-Object { $_ } | Select-Object -Unique)
                foreach ($property in $models.models.PSObject.Properties) {
                    if ($property.Value.disabled -or $property.Name -match '[-_]disabled$') { continue }
                    $code = if ($property.Name -match '(^|-)argon($|-)' -or $property.Value.displayName -match '\bArgon\b') { 'A' }
                            elseif ($property.Name -match '^gemini-' -and $property.Name -notmatch 'image' -and
                                (($modelIds.Count -and $property.Name -in $modelIds) -or (!$modelIds.Count -and $property.Value.displayName))) { 'G' }
                            elseif ($property.Name -match '^(claude-|gpt-)') { 'C' }
                            else { continue }
                    $info = $property.Value.quotaInfo
                    $fraction = 0.0
                    if ($null -eq $info.remainingFraction -or
                        ![double]::TryParse([string]$info.remainingFraction, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$fraction) -or
                        [double]::IsNaN($fraction) -or $fraction -lt 0 -or $fraction -gt 1) { continue }
                    $modelQuotas[$code] += [pscustomobject]@{
                        Name=$(if ($property.Value.displayName) { $property.Value.displayName } else { $property.Name })
                        Fraction=$fraction; Reset=[string]$info.resetTime
                    }
                }
            } catch { $modelQuotas = @{ G=@(); C=@(); A=@() } }
        }
        if (!$buckets.Count -and !($modelQuotas.G.Count + $modelQuotas.C.Count + $modelQuotas.A.Count)) { throw 'schema' }
        $lines = @('查詢時間：' + $Reply.ReceivedAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        $primaryTexts = @(); $weeklyTexts = @(); $primaryRemaining = @(); $weeklyRemaining = @()
        foreach ($spec in @(@('G','Gemini','gemini'),@('C','Claude/GPT','3p'),@('A','Argon','argon'))) {
            $code = $spec[0]; $label = $spec[1]; $prefix = $spec[2]
            $primaryQuota = $buckets[$prefix + '-5h']
            $weeklyQuota = $buckets[$prefix + '-weekly']
            $weeklyOnly = $code -eq 'A' -and $weeklyQuota -and !$primaryQuota
            $fromModel = !$primaryQuota -and !$weeklyOnly -and $modelQuotas[$code].Count -gt 0
            if ($fromModel) {
                $primaryQuota = $modelQuotas[$code] | Sort-Object Fraction, @{ Expression='Reset'; Descending=$true } | Select-Object -First 1
                $lines += "${code}*：${label} 模型額度，回應未標示週期；採最低剩餘比例，重置時間對應該模型。"
            }
            $formatted = @()
            foreach ($isWeekly in @($false,$true)) {
                $quota = if ($isWeekly) { $weeklyQuota } else { $primaryQuota }
                $window = $null
                if ($null -ne $quota) {
                    $window = [pscustomobject]@{
                        used_percent=(100 - $quota.Fraction * 100)
                        limit_window_seconds=$(if ($isWeekly) { 604800 } elseif ($fromModel) { $null } else { 18000 })
                        reset_at=$null
                    }
                    $reset = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse($quota.Reset, [ref]$reset)) { $window.reset_at = $reset.ToUnixTimeSeconds() }
                }
                $display = Format-QuotaWindow $window $Reply.ReceivedAt -IsPrimary:(!$isWeekly)
                $formatted += $display
                $period = if ($isWeekly) { '每週' } elseif ($fromModel) { '模型額度' } else { '五小時' }
                $lines += "${label} ${period}：$($display.Detail)"
            }
            if (!$weeklyOnly -and $weeklyQuota -and $weeklyQuota.Fraction -le 0) {
                $formatted[0].Remaining = 0
                $formatted[0].Text = '0% (週額度耗盡)'
            }
            $primaryTexts += if ($weeklyOnly) { $code + ' 僅每週' } else { $code + $(if ($fromModel) { '* ' } else { ' ' }) + $formatted[0].Text }
            $weeklyTexts += $code + ' ' + $formatted[1].Text
            if ($null -ne $formatted[0].Remaining) { $primaryRemaining += $formatted[0].Remaining }
            if ($null -ne $formatted[1].Remaining) { $weeklyRemaining += $formatted[1].Remaining }
            foreach ($model in @($modelQuotas[$code] | Sort-Object Name)) {
                $reset = [DateTimeOffset]::MinValue
                $resetText = if ([DateTimeOffset]::TryParse($model.Reset, [ref]$reset)) { $reset.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') } else { '未提供' }
                $lines += $model.Name + '：' + [Math]::Round($model.Fraction * 100, 1).ToString() + '% / 重置 ' + $resetText
            }
        }
        if ($Reply.ModelsStatus -and $Reply.ModelsStatus -ne 'HTTP 200') { $lines += '模型額度查詢：' + $Reply.ModelsStatus }
        $result.FiveHour = $primaryTexts -join ' / '
        $result.Weekly = $weeklyTexts -join ' / '
        if ($primaryRemaining.Count) { $result.FiveHourRemaining = ($primaryRemaining | Measure-Object -Minimum).Minimum }
        if ($weeklyRemaining.Count) { $result.WeeklyRemaining = ($weeklyRemaining | Measure-Object -Minimum).Minimum }
        if ($Reply.PlanJson) {
            try {
                $plan = $Reply.PlanJson | ConvertFrom-Json
                $tier = if ($plan.paidTier.id) { [string]$plan.paidTier.id } else { [string]$plan.currentTier.id }
                $result.Plan = switch -Regex ($tier) {
                    'ultra' { 'Ultra'; break }
                    'pro' { 'Pro'; break }
                    'plus' { 'Plus'; break }
                    'free' { 'Free'; break }
                    default { '—' }
                }
            } catch { }
        }
        $complete = @('gemini-5h','gemini-weekly','3p-5h','3p-weekly','argon-weekly' | Where-Object { !$buckets.ContainsKey($_) }).Count -eq 0
        $result.Status = if ($complete) { '已更新' } else { '已更新／部分額度' }
        $result.Detail = $lines -join "`r`n"
    } catch { $result.Status='格式不支援'; $result.Detail='服務回傳格式無法辨識。' }
    return $result
}

$script:AGQuotaJobs = @()
$script:AGQuotaGeneration = 0
$script:AGQuotaQueryStarted = $false

function Stop-AGQuotaQueries {
    $script:AGQuotaGeneration++
    $script:AGQuotaQueryStarted = $false
    foreach ($job in $script:AGQuotaJobs) { $job.Cancellation.Cancel(); $job.Cancellation.Dispose() }
    $script:AGQuotaJobs = @()
}

function Start-AGQuotaQuery([byte[]]$Bytes, [string]$Key) {
    $auth = $script:Utf8.GetString($Bytes) | ConvertFrom-Json
    $binary = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\resources\bin\language_server.exe'
    $cancel = New-Object Threading.CancellationTokenSource
    $task = [AntigravitySwitcher.QuotaClient]::Fetch([string]$auth.token.access_token, [string]$auth.token.refresh_token, $binary, $cancel.Token, $null)
    $script:AGQuotaJobs += [pscustomobject]@{ Key=$Key; Generation=$script:AGQuotaGeneration; Cancellation=$cancel; Task=$task }
    $script:AGQuotaQueryStarted = $true
}

function Update-AGQuotaResults {
    if ($form.IsDisposed -or $form.Disposing) { Stop-AGQuotaQueries; return }
    $hasUpdates = $false
    foreach ($job in @($script:AGQuotaJobs)) {
        if (!$job.Task.IsCompleted) { continue }
        try {
            if ($job.Generation -ne $script:AGQuotaGeneration -or !$agList.Items.ContainsKey($job.Key)) { continue }
            $quota = ConvertFrom-AGQuotaReply ($job.Task.GetAwaiter().GetResult())
            $item = $agList.Items[$job.Key]
            $item.SubItems[1].Text = $quota.Plan
            $item.SubItems[2].Text = $quota.FiveHour
            $item.SubItems[3].Text = $quota.Weekly
            $item.UseItemStyleForSubItems = $false
            $item.SubItems[2].ForeColor = Get-QuotaColor $quota.FiveHourRemaining
            $item.SubItems[3].ForeColor = Get-QuotaColor $quota.WeeklyRemaining
            $item.SubItems[5].Text = $quota.Status
            $item.ToolTipText = $quota.Detail
            $hasUpdates = $true
        } catch {
            if ($agList.Items.ContainsKey($job.Key)) { $agList.Items[$job.Key].SubItems[5].Text = '查詢失敗' }
            $hasUpdates = $true
        } finally {
            $job.Cancellation.Dispose()
            $script:AGQuotaJobs = @($script:AGQuotaJobs | Where-Object { $_ -ne $job })
        }
    }
    if ($script:AGQuotaQueryStarted -and !$script:AGQuotaJobs.Count) {
        $agLastQueryLabel.Text = '最後查詢：' + (Get-Date).ToString('HH:mm:ss')
        $script:AGQuotaQueryStarted = $false
    }
    if ($hasUpdates -and (Get-Command 'Update-GuildView' -ErrorAction SilentlyContinue)) { Update-GuildView }
}

function Invoke-AGQuotaSelfTest {
    function Check-Quota([bool]$Condition, [string]$Message) { if (!$Condition) { throw ('Antigravity 額度測試失敗：' + $Message) } }
    $groups = @{ groups=@(
        @{ buckets=@(
            @{ bucketId='gemini-5h'; remainingFraction=0.8642442; resetTime='2026-09-24T15:00:00Z' },
            @{ bucketId='gemini-weekly'; remainingFraction=0.4825072; resetTime='2026-09-30T15:00:00Z' }
        ) },
        @{ buckets=@(
            @{ bucketId='3p-5h'; remainingFraction=1.0; resetTime='2026-09-24T15:00:00Z' },
            @{ bucketId='3p-weekly'; remainingFraction=0.0134956; resetTime='2026-09-30T15:00:00Z' }
        ) }
    ) } | ConvertTo-Json -Depth 6 -Compress
    $reply = [pscustomobject]@{ Status='OK'; Json=$groups; PlanJson='{"paidTier":{"id":"g1-pro-tier"}}'; ReceivedAt=[DateTimeOffset]::UtcNow }
    $quota = ConvertFrom-AGQuotaReply $reply
    Check-Quota ($quota.Plan -eq 'Pro' -and $quota.FiveHour -match '^G 86.4% \(' -and $quota.FiveHour -match ' / C 100% \(' -and $quota.FiveHour -match ' / A 未提供$' -and $quota.Weekly -match '^G 48.3% \(' -and $quota.Weekly -match ' / C 1.3% \(' -and $quota.Status -eq '已更新／部分額度') '三模型組顯示、缺漏 Argon 及雙視窗重置資訊'
    Check-Quota ($quota.Detail -match 'Gemini 五小時' -and $quota.Detail -match 'Claude/GPT 每週') '重置資訊提示'
    Check-Quota ((ConvertFrom-AGQuotaReply ([pscustomobject]@{ Status='Refresh HTTP 400' })).Status -eq '需重新授權') '過期憑證狀態'
    Check-Quota ((ConvertFrom-AGQuotaReply ([pscustomobject]@{ Status='OK'; Json='{}'; ReceivedAt=[DateTimeOffset]::UtcNow })).Status -eq '格式不支援') '拒絕缺少額度的回應'
    'PASS: Antigravity 雙模型組五小時與每週額度、方案、重置資訊及錯誤狀態。'
}
