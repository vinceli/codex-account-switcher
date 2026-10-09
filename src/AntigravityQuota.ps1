function Initialize-AGQuotaClient {
    if ('AntigravitySwitcher.QuotaClient' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Net.Http,System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
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
        public DateTimeOffset ReceivedAt;
    }

    public static class QuotaClient {
        private const string QuotaUrl = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary";
        private const string PlanUrl = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
        private const string TokenUrl = "https://oauth2.googleapis.com/token";
        private const string ClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";

        private static HttpRequestMessage Request(string url, string token, string body) {
            var request = new HttpRequestMessage(HttpMethod.Post, url);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.UserAgent.ParseAdd("antigravity");
            request.Content = new StringContent(body, Encoding.UTF8, "application/json");
            return request;
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
                    for (int attempt = 0; attempt < 2; attempt++) {
                        using (var request = Request(QuotaUrl, token, "{}"))
                        using (var response = await client.SendAsync(request, cancellation).ConfigureAwait(false)) {
                            int code = (int)response.StatusCode;
                            if (code == 200) {
                                var result = new QuotaReply {
                                    Status = "OK", ReceivedAt = DateTimeOffset.UtcNow,
                                    Json = await response.Content.ReadAsStringAsync().ConfigureAwait(false)
                                };
                                try {
                                    using (var planRequest = Request(PlanUrl, token, "{\"metadata\":{\"ideType\":\"ANTIGRAVITY\"}}"))
                                    using (var planResponse = await client.SendAsync(planRequest, cancellation).ConfigureAwait(false)) {
                                        if (planResponse.IsSuccessStatusCode)
                                            result.PlanJson = await planResponse.Content.ReadAsStringAsync().ConfigureAwait(false);
                                    }
                                } catch (HttpRequestException) { }
                                  catch (OperationCanceledException) { }
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
        foreach ($group in @($data.groups)) {
            foreach ($bucket in @($group.buckets)) {
                if ($bucket.bucketId -in @('gemini-5h','gemini-weekly','3p-5h','3p-weekly') -and
                    $null -ne $bucket.remainingFraction -and [double]$bucket.remainingFraction -ge 0 -and [double]$bucket.remainingFraction -le 1) {
                    $buckets[[string]$bucket.bucketId] = $bucket
                }
            }
        }
        if (!$buckets.Count) { throw 'schema' }
        $lines = @('查詢時間：' + $Reply.ReceivedAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
        foreach ($spec in @(@('gemini-5h','Gemini 五小時'),@('gemini-weekly','Gemini 每週'),@('3p-5h','Claude/GPT 五小時'),@('3p-weekly','Claude/GPT 每週'))) {
            $bucket = $buckets[$spec[0]]
            if (!$bucket) { $lines += $spec[1] + '：未知'; continue }
            $percent = [Math]::Round([double]$bucket.remainingFraction * 100, 1)
            $reset = '重置時間未知'
            if ($bucket.resetTime) {
                $when = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$bucket.resetTime, [ref]$when)) { $reset = '重置 ' + $when.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') }
            }
            $lines += $spec[1] + "：$percent% / $reset"
        }
        $g5 = $buckets['gemini-5h']; $c5 = $buckets['3p-5h']
        $gw = $buckets['gemini-weekly']; $cw = $buckets['3p-weekly']
        $gEffective = if ($g5) { if ($gw -and [double]$gw.remainingFraction -le 0) { 0 } else { [double]$g5.remainingFraction * 100 } } else { $null }
        $cEffective = if ($c5) { if ($cw -and [double]$cw.remainingFraction -le 0) { 0 } else { [double]$c5.remainingFraction * 100 } } else { $null }
        $result.FiveHour = 'G ' + $(if ($null -ne $gEffective) { [Math]::Round($gEffective, 1).ToString() + '%' } else { '未知' }) + ' / C ' + $(if ($null -ne $cEffective) { [Math]::Round($cEffective, 1).ToString() + '%' } else { '未知' })
        $result.Weekly = 'G ' + $(if ($gw) { [Math]::Round([double]$gw.remainingFraction * 100, 1).ToString() + '%' } else { '未知' }) + ' / C ' + $(if ($cw) { [Math]::Round([double]$cw.remainingFraction * 100, 1).ToString() + '%' } else { '未知' })
        if ($null -ne $gEffective -or $null -ne $cEffective) { $result.FiveHourRemaining = [Math]::Min($(if ($null -ne $gEffective) { $gEffective } else { 100 }), $(if ($null -ne $cEffective) { $cEffective } else { 100 })) }
        if ($gw -or $cw) { $result.WeeklyRemaining = [Math]::Min($(if ($gw) { [double]$gw.remainingFraction * 100 } else { 100 }), $(if ($cw) { [double]$cw.remainingFraction * 100 } else { 100 })) }
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
        $result.Status = '已更新'
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
            $item.SubItems[2].Text = $quota.Plan
            $item.SubItems[3].Text = $quota.FiveHour
            $item.SubItems[4].Text = $quota.Weekly
            $item.UseItemStyleForSubItems = $false
            $item.SubItems[3].ForeColor = Get-QuotaColor $quota.FiveHourRemaining
            $item.SubItems[4].ForeColor = Get-QuotaColor $quota.WeeklyRemaining
            $item.SubItems[6].Text = $quota.Status
            $item.ToolTipText = $quota.Detail
            $hasUpdates = $true
        } catch {
            if ($agList.Items.ContainsKey($job.Key)) { $agList.Items[$job.Key].SubItems[6].Text = '查詢失敗' }
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
    Check-Quota ($quota.Plan -eq 'Pro' -and $quota.FiveHour -eq 'G 86.4% / C 100%' -and $quota.Weekly -eq 'G 48.3% / C 1.3%' -and $quota.Status -eq '已更新') '雙模型組與雙視窗解析'
    Check-Quota ($quota.Detail -match 'Gemini 五小時' -and $quota.Detail -match 'Claude/GPT 每週') '重置資訊提示'
    Check-Quota ((ConvertFrom-AGQuotaReply ([pscustomobject]@{ Status='Refresh HTTP 400' })).Status -eq '需重新授權') '過期憑證狀態'
    Check-Quota ((ConvertFrom-AGQuotaReply ([pscustomobject]@{ Status='OK'; Json='{}'; ReceivedAt=[DateTimeOffset]::UtcNow })).Status -eq '格式不支援') '拒絕缺少額度的回應'
    'PASS: Antigravity 雙模型組五小時與每週額度、方案、重置資訊及錯誤狀態。'
}
