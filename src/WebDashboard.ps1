# WebDashboard.ps1 - Codex 遠端 Web 儀表板與副機安全派送模組
$ErrorActionPreference = 'Stop'

if (-not ('CodexSwitcher.Web.DashboardServer' -as [type])) {
    Add-Type -ReferencedAssemblies System, System.Core -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Collections.Generic;

namespace CodexSwitcher.Web {
    public class DashboardServer {
        private TcpListener _listener;
        private Thread _worker;
        private volatile bool _running;

        public int Port { get; private set; }
        public string Pin { get; set; }
        public string HostActiveKey { get; set; }
        public string RemoteHost { get; set; }
        public string RemoteUser { get; set; }
        public int RemotePort { get; set; }
        public string HtmlContent { get; set; }
        public string AccountsJson { get; set; }
        public string Url { get; set; }
        public string HostIp { get; set; }

        public string GenerateNewPin() {
            var rnd = new Random();
            Pin = rnd.Next(100000, 999999).ToString();
            return Pin;
        }

        public readonly Dictionary<string, byte[]> AccountCredentials = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);

        public static bool MockPushForTesting = false;
        public static byte[] LastPushedBytes;
        public static string LastPushedHost;
        public static string LastPushedUser;
        public static int LastPushedPort;

        private readonly HashSet<string> _tokens = new HashSet<string>(StringComparer.Ordinal);
        private readonly object _lock = new object();

        public bool IsRunning { get { return _running; } }

        public DashboardServer() {
            RemotePort = 22;
            RemoteHost = "192.168.1.195";
            RemoteUser = "vince";
            AccountsJson = "[]";
        }

        public void Start(int port, string pin) {
            if (_running) Stop();
            Port = port;
            Pin = pin;
            _listener = new TcpListener(IPAddress.Any, port);
            _listener.Start();
            _running = true;
            _worker = new Thread(ListenLoop) { IsBackground = true };
            _worker.Start();
        }

        public void Stop() {
            _running = false;
            try {
                if (_listener != null) _listener.Stop();
            } catch { }
            if (_worker != null) {
                try { _worker.Join(500); } catch { }
                _worker = null;
            }
        }

        private void ListenLoop() {
            while (_running) {
                try {
                    var client = _listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(_ => ProcessClient(client));
                } catch {
                    if (!_running) break;
                }
            }
        }

        private void ProcessClient(TcpClient client) {
            using (client)
            using (var stream = client.GetStream()) {
                stream.ReadTimeout = 8000;
                stream.WriteTimeout = 8000;

                string requestHeader = "";
                var headerBuffer = new byte[4096];
                int totalRead = 0;
                while (totalRead < headerBuffer.Length) {
                    int r = stream.Read(headerBuffer, totalRead, 1);
                    if (r <= 0) break;
                    totalRead += r;
                    if (totalRead >= 4 &&
                        headerBuffer[totalRead - 4] == '\r' && headerBuffer[totalRead - 3] == '\n' &&
                        headerBuffer[totalRead - 2] == '\r' && headerBuffer[totalRead - 1] == '\n') {
                        requestHeader = Encoding.UTF8.GetString(headerBuffer, 0, totalRead);
                        break;
                    }
                }

                if (string.IsNullOrEmpty(requestHeader)) return;

                var lines = requestHeader.Split(new[] { "\r\n" }, StringSplitOptions.None);
                if (lines.Length == 0) return;

                var reqParts = lines[0].Split(' ');
                if (reqParts.Length < 2) return;
                string method = reqParts[0].ToUpperInvariant();
                string path = reqParts[1].Split('?')[0];

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 1; i < lines.Length; i++) {
                    int colon = lines[i].IndexOf(':');
                    if (colon > 0) {
                        string k = lines[i].Substring(0, colon).Trim();
                        string v = lines[i].Substring(colon + 1).Trim();
                        headers[k] = v;
                    }
                }

                int contentLength = 0;
                if (headers.ContainsKey("Content-Length")) {
                    int.TryParse(headers["Content-Length"], out contentLength);
                }

                string body = "";
                if (contentLength > 0 && contentLength < 1024 * 1024) {
                    var bodyBytes = new byte[contentLength];
                    int bodyRead = 0;
                    while (bodyRead < contentLength) {
                        int r = stream.Read(bodyBytes, bodyRead, contentLength - bodyRead);
                        if (r <= 0) break;
                        bodyRead += r;
                    }
                    body = Encoding.UTF8.GetString(bodyBytes, 0, bodyRead);
                }

                HandleRequest(stream, method, path, headers, body);
            }
        }

        private bool IsAuthorized(Dictionary<string, string> headers) {
            string token = "";
            if (headers.ContainsKey("X-Session-Token")) {
                token = headers["X-Session-Token"];
            } else if (headers.ContainsKey("Cookie")) {
                var m = Regex.Match(headers["Cookie"], @"session_token=([a-fA-F0-9]+)");
                if (m.Success) token = m.Groups[1].Value;
            } else if (headers.ContainsKey("X-Pin") && headers["X-Pin"] == Pin) {
                return true;
            }

            if (!string.IsNullOrEmpty(token)) {
                lock (_lock) {
                    if (_tokens.Contains(token)) return true;
                }
            }
            return false;
        }

        private void HandleRequest(NetworkStream stream, string method, string path, Dictionary<string, string> headers, string body) {
            if (method == "GET" && (path == "/" || path == "/index.html")) {
                byte[] htmlBytes = Encoding.UTF8.GetBytes(HtmlContent ?? "<h1>Codex Dashboard</h1>");
                SendResponse(stream, 200, "OK", "text/html; charset=utf-8", htmlBytes, null);
                return;
            }

            if (method == "POST" && path == "/api/verify") {
                var match = Regex.Match(body, @"(?:""pin""|pin)\s*:\s*""?(\d{6})""?", RegexOptions.IgnoreCase);
                string inputPin = match.Success ? match.Groups[1].Value : "";
                if (inputPin == Pin) {
                    string newToken = Guid.NewGuid().ToString("N");
                    lock (_lock) { _tokens.Add(newToken); }
                    string resp = "{\"success\":true,\"token\":\"" + newToken + "\"}";
                    string cookie = "session_token=" + newToken + "; Path=/; HttpOnly";
                    SendResponse(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), cookie);
                } else {
                    string resp = "{\"success\":false,\"error\":\"\\u9a57\\u8b49\\u78bc\\u932f\\u8aa4\\uff0c\\u8acb\\u78ba\\u8a8d\\u4e3b\\u6a5f\\u756b\\u9762\\u3002\"}";
                    SendResponse(stream, 401, "Unauthorized", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), null);
                }
                return;
            }

            // All subsequent /api endpoints require authorization
            if (!IsAuthorized(headers)) {
                string resp = "{\"success\":false,\"error\":\"\\u672a\\u7d93\\u6388\\u6b0a\\uff0c\\u8acb\\u5148\\u8f38\\u5165\\u0020\\u0036\\u0020\\u78bc\\u9a57\\u8b49\\u78bc\\u3002\"}";
                SendResponse(stream, 401, "Unauthorized", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), null);
                return;
            }

            if (method == "GET" && path == "/api/status") {
                string json = string.Format(
                    "{{\"running\":true,\"port\":{0},\"remote_host\":\"{1}\",\"remote_user\":\"{2}\",\"host_active_key\":\"{3}\"}}",
                    Port, RemoteHost ?? "", RemoteUser ?? "", HostActiveKey ?? ""
                );
                SendResponse(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json), null);
                return;
            }

            if (method == "GET" && path == "/api/accounts") {
                string json = AccountsJson ?? "[]";
                SendResponse(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json), null);
                return;
            }

            if (method == "POST" && path == "/api/switch-remote") {
                var mKey = Regex.Match(body, @"(?:""target_key""|target_key)\s*:\s*""([^""]+)""", RegexOptions.IgnoreCase);
                var mHost = Regex.Match(body, @"(?:""remote_host""|remote_host)\s*:\s*""([^""]+)""", RegexOptions.IgnoreCase);
                var mUser = Regex.Match(body, @"(?:""remote_user""|remote_user)\s*:\s*""([^""]+)""", RegexOptions.IgnoreCase);

                string targetKey = mKey.Success ? mKey.Groups[1].Value : "";
                string host = mHost.Success ? mHost.Groups[1].Value : (RemoteHost ?? "192.168.1.195");
                string user = mUser.Success ? mUser.Groups[1].Value : (RemoteUser ?? "vince");

                if (string.IsNullOrEmpty(targetKey)) {
                    string resp = "{\"success\":false,\"error\":\"\\u7f3a\\u5c11\\u0020\\u0074\\u0061\\u0072\\u0067\\u0065\\u0074\\u005f\\u006b\\u0065\\u0079\\u0020\\u53c3\\u6578\"}";
                    SendResponse(stream, 400, "Bad Request", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), null);
                    return;
                }

                // Collision Lock: Reject if target is host active account
                if (!string.IsNullOrEmpty(HostActiveKey) && string.Equals(targetKey, HostActiveKey, StringComparison.OrdinalIgnoreCase)) {
                    string resp = "{\"success\":false,\"error\":\"\\u6b64\\u5e33\\u865f\\u76ee\\u524d\\u6b63\\u7531\\u4e3b\\u6a5f\\u57f7\\u52e4\\u4e2d\\uff0c\\u5df2\\u9396\\u5b9a\\u7981\\u6b62\\u526f\\u6a5f\\u5207\\u63db\\uff0c\\u4ee5\\u907f\\u514d\\u0020\\u0054\\u006f\\u006b\\u0065\\u006e\\u0020\\u7af6\\u614b\\u885d\\u7a81\\u3002\"}";
                    SendResponse(stream, 403, "Forbidden", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), null);
                    return;
                }

                byte[] credBytes = null;
                lock (_lock) {
                    if (AccountCredentials.ContainsKey(targetKey)) {
                        credBytes = AccountCredentials[targetKey];
                    }
                }

                if (credBytes == null || credBytes.Length == 0) {
                    string resp = "{\"success\":false,\"error\":\"\\u627e\\u4e0d\\u5230\\u8a72\\u5e33\\u865f\\u4e4b\\u6191\\u8b49\\u8cc7\\u6599\\uff0c\\u8acb\\u5148\\u65bc\\u4e3b\\u6a5f\\u7aef\\u91cd\\u65b0\\u6574\\u7406\\u3002\"}";
                    SendResponse(stream, 404, "Not Found", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), null);
                    return;
                }

                try {
                    if (MockPushForTesting) {
                        LastPushedBytes = credBytes;
                        LastPushedHost = host;
                        LastPushedUser = user;
                        LastPushedPort = RemotePort;
                    } else {
                        PushAuthToRemote(credBytes, host, user, RemotePort);
                    }
                    string resp = "{\"success\":true,\"message\":\"\\u5df2\\u6210\\u529f\\u5c07\\u76ee\\u6a19\\u5e33\\u865f\\u63a8\\u9001\\u81f3\\u526f\\u6a5f (" + host + ":~/.codex/auth.json) \\u4e26\\u91cd\\u65b0\\u555f\\u52d5 Codex Desktop\\uff01\"}";
                    SendResponse(stream, 200, "OK", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), null);
                } catch (Exception ex) {
                    string resp = "{\"success\":false,\"error\":\"" + EscapeJson(ex.Message) + "\"}";
                    SendResponse(stream, 500, "Internal Server Error", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(resp), null);
                }
                return;
            }

            // 404
            string notFound = "{\"error\":\"Not Found\"}";
            SendResponse(stream, 404, "Not Found", "application/json; charset=utf-8", Encoding.UTF8.GetBytes(notFound), null);
        }

        private static void ExecuteCommand(string exe, string args) {
            var psi = new System.Diagnostics.ProcessStartInfo {
                FileName = exe,
                Arguments = args,
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardError = true,
                RedirectStandardOutput = true
            };
            using (var p = System.Diagnostics.Process.Start(psi)) {
                string err = p.StandardError.ReadToEnd();
                if (!p.WaitForExit(8000)) {
                    try { p.Kill(); } catch { }
                    throw new TimeoutException("遠端連線或傳輸逾時。");
                }
                if (p.ExitCode != 0) {
                    throw new InvalidOperationException("遠端操作失敗 (" + exe + " Code " + p.ExitCode + "): " + err);
                }
            }
        }

        public static void PushAuthToRemote(byte[] authBytes, string host, string user, int port) {
            string tempFile = Path.GetTempFileName();
            try {
                File.WriteAllBytes(tempFile, authBytes);
                string sshOpts = string.Format("-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p {0}", port);
                string scpOpts = string.Format("-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -P {0}", port);

                // 1. 關閉副機既有 Codex Desktop 程序避免舊 Token 競爭
                try {
                    ExecuteCommand("ssh.exe", sshOpts + " " + user + "@" + host + " \"pkill -f chatgpt || true\"");
                } catch { }

                // 2. mkdir ~/.codex & chmod 700
                ExecuteCommand("ssh.exe", sshOpts + " " + user + "@" + host + " \"mkdir -p ~/.codex && chmod 700 ~/.codex\"");

                // 3. scp to tmp
                string remoteTemp = "~/.codex/auth.json.tmp." + Guid.NewGuid().ToString("N");
                ExecuteCommand("scp.exe", scpOpts + " \"" + tempFile + "\" " + user + "@" + host + ":" + remoteTemp);

                // 4. atomic mv & chmod 600
                ExecuteCommand("ssh.exe", sshOpts + " " + user + "@" + host + " \"mv -f " + remoteTemp + " ~/.codex/auth.json && chmod 600 ~/.codex/auth.json\"");

                // 5. 自動偵測副機 X11 DISPLAY 並以背景喚起 Codex Desktop
                try {
                    string launchCmd = "DISP=\\$(ls -t /tmp/.X11-unix/ 2>/dev/null | grep -E '^X[0-9]+' | grep -v '^X0\\$' | head -n 1 | sed 's/^X/:/'); if [ -z \\\"\\$DISP\\\" ]; then DISP=\\\":0\\\"; fi; env DISPLAY=\\$DISP XDG_RUNTIME_DIR=/run/user/\\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\\$(id -u)/bus nohup /usr/bin/chatgpt </dev/null >/dev/null 2>&1 &";
                    ExecuteCommand("ssh.exe", sshOpts + " " + user + "@" + host + " \"" + launchCmd + "\"");
                } catch { }
            } finally {
                if (File.Exists(tempFile)) {
                    try {
                        File.WriteAllBytes(tempFile, new byte[64]);
                        File.Delete(tempFile);
                    } catch { }
                }
            }
        }

        private static string EscapeJson(string s) {
            if (s == null) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", " ");
        }

        private void SendResponse(NetworkStream stream, int statusCode, string statusDesc, string contentType, byte[] content, string setCookie) {
            var sb = new StringBuilder();
            sb.AppendFormat("HTTP/1.1 {0} {1}\r\n", statusCode, statusDesc);
            sb.AppendFormat("Content-Type: {0}\r\n", contentType);
            sb.AppendFormat("Content-Length: {0}\r\n", content.Length);
            sb.Append("Connection: close\r\n");
            if (!string.IsNullOrEmpty(setCookie)) {
                sb.AppendFormat("Set-Cookie: {0}\r\n", setCookie);
            }
            sb.Append("\r\n");

            byte[] headerBytes = Encoding.UTF8.GetBytes(sb.ToString());
            stream.Write(headerBytes, 0, headerBytes.Length);
            if (content.Length > 0) {
                stream.Write(content, 0, content.Length);
            }
            stream.Flush();
        }
    }
}
'@
}

$script:WebDashboardInstance = $null

function New-RandomPin {
    return ('{0:D6}' -f (Get-Random -Minimum 100000 -Maximum 999999))
}

function Get-HostIpAddress {
    try {
        $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object {
            $_.AddressFamily -eq 'InterNetwork' -and !$_.IPAddressToString.StartsWith('127.')
        }
        $primary = $ips | Where-Object { $_.IPAddressToString -like '192.168.*' } | Select-Object -First 1
        if ($primary) { return $primary.IPAddressToString }
        if ($ips.Count -gt 0) { return $ips[0].IPAddressToString }
    } catch { }
    return '127.0.0.1'
}

function Start-WebDashboard {
    param(
        [int]$Port = 8998,
        [string]$Pin,
        [string]$HostActiveKey,
        [string]$RemoteHost = '192.168.1.195',
        [string]$RemoteUser = 'vince',
        [int]$RemotePort = 22
    )

    if ($script:WebDashboardInstance -and $script:WebDashboardInstance.IsRunning) {
        $script:WebDashboardInstance.Stop()
    }

    if (!$Pin) { $Pin = New-RandomPin }

    $htmlPath = Join-Path $PSScriptRoot 'assets\web\index.html'
    $htmlContent = if (Test-Path -LiteralPath $htmlPath) {
        [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
    } else {
        '<!DOCTYPE html><html><body><h1>Codex Web Dashboard</h1></body></html>'
    }

    $server = New-Object CodexSwitcher.Web.DashboardServer
    $server.HostActiveKey = $HostActiveKey
    $server.RemoteHost = $RemoteHost
    $server.RemoteUser = $RemoteUser
    $server.RemotePort = $RemotePort
    $server.HtmlContent = $htmlContent

    $server.Start($Port, $Pin)
    $hostIp = Get-HostIpAddress
    $server.HostIp = $hostIp
    $server.Url = "http://$($hostIp):$Port"
    $script:WebDashboardInstance = $server
    return $server
}

function Stop-WebDashboard {
    if ($script:WebDashboardInstance) {
        $script:WebDashboardInstance.Stop()
        $script:WebDashboardInstance = $null
    }
}

function Update-WebDashboardState {
    param(
        [string]$HostActiveKey,
        [string]$RemoteHost,
        [string]$RemoteUser,
        [object[]]$AccountsList
    )
    if ($script:WebDashboardInstance -and $script:WebDashboardInstance.IsRunning) {
        if ($HostActiveKey) { $script:WebDashboardInstance.HostActiveKey = $HostActiveKey }
        if ($RemoteHost) { $script:WebDashboardInstance.RemoteHost = $RemoteHost }
        if ($RemoteUser) { $script:WebDashboardInstance.RemoteUser = $RemoteUser }

        if ($AccountsList) {
            $script:WebDashboardInstance.AccountCredentials.Clear()
            $dtos = @()
            foreach ($acc in $AccountsList) {
                if ($acc.Key -and $acc.Bytes) {
                    $script:WebDashboardInstance.AccountCredentials[$acc.Key] = $acc.Bytes
                }
                $isHostActive = ($acc.Key -and $acc.Key -eq $script:WebDashboardInstance.HostActiveKey)
                $dtos += [pscustomobject]@{
                    key = $acc.Key
                    name = $acc.Name
                    email = $acc.Email
                    plan = $acc.Plan
                    primary = $acc.Primary
                    secondary = $acc.Secondary
                    primary_remaining = $acc.PrimaryRemaining
                    secondary_remaining = $acc.SecondaryRemaining
                    saved = $acc.Saved
                    is_host_active = $isHostActive
                    locked = $isHostActive
                    lock_reason = if ($isHostActive) { '此帳號目前正由主機執勤中，已鎖定禁止副機切換。' } else { '' }
                }
            }
            $script:WebDashboardInstance.AccountsJson = ($dtos | ConvertTo-Json -Depth 5 -Compress)
        }
    }
}
