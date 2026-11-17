param(
    [switch]$RunOnce,
    [switch]$ConnectPersonal,
    [switch]$ConnectCompany,
    [string]$Proxy = $env:HTTPS_PROXY,
    [string]$PersonalHome = $env:CODEX_QUOTA_PERSONAL_HOME,
    [string]$CompanyHome = $env:CODEX_QUOTA_COMPANY_HOME,
    [string]$StateDirectory
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security
if (-not ('QuotaTransport' -as [type])) {
    Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

public static class TrayNativeMethods {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}

public sealed class QuotaReply {
    public string Status;
    public string Body;
    public QuotaReply(string status, string body) { Status = status; Body = body; }
}

public static class QuotaTransport {
    // Own the request and response, including cancellation and shutdown paths.
    // Buffer and decode the bounded response away from the WinForms thread.
    public static async Task<QuotaReply> FetchAsync(HttpClient client,
        HttpRequestMessage request, CancellationToken cancellation) {
        using (request) {
            try {
                using (var response = await client.SendAsync(request,
                    HttpCompletionOption.ResponseContentRead, cancellation).ConfigureAwait(false)) {
                    int code = (int)response.StatusCode;
                    if (code == 401 || code == 403)
                        return new QuotaReply("unauthorized", null);
                    if (!response.IsSuccessStatusCode)
                        return new QuotaReply("http-" + code, null);
                    string body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    return new QuotaReply("ok", body);
                }
            }
            catch (OperationCanceledException) { return new QuotaReply("timeout", null); }
            catch (HttpRequestException) { return new QuotaReply("offline", null); }
            catch (ObjectDisposedException) { return new QuotaReply("cancelled", null); }
            catch (Exception) { return new QuotaReply("request-failed", null); }
        }
    }
}
public static class QuotaOAuth {
    public static async System.Threading.Tasks.Task<QuotaReply> PostAsync(
        System.Net.Http.HttpClient client, string json) {
        using (var request = new System.Net.Http.HttpRequestMessage(
            System.Net.Http.HttpMethod.Post, "https://auth.openai.com/oauth/token")) {
            request.Content = new System.Net.Http.StringContent(json,
                System.Text.Encoding.UTF8, "application/json");
            try {
                using (var response = await client.SendAsync(request).ConfigureAwait(false)) {
                    int code = (int)response.StatusCode;
                    if (code == 400 || code == 401 || code == 403)
                        return new QuotaReply("login-needed", null);
                    if (!response.IsSuccessStatusCode)
                        return new QuotaReply("http-" + code, null);
                    return new QuotaReply("ok", await response.Content.ReadAsStringAsync().ConfigureAwait(false));
                }
            }
            catch (System.OperationCanceledException) { return new QuotaReply("timeout", null); }
            catch (System.Exception) { return new QuotaReply("offline", null); }
        }
    }
}

// A separate OAuth grant owns its refresh token. No Codex auth file is changed.
public sealed class QuotaLoginSession : System.IDisposable {
    private System.Net.Sockets.TcpListener listener;
    private volatile bool disposed;
    public string State { get; private set; }
    public string Verifier { get; private set; }
    public string Challenge { get; private set; }
    public string RedirectUri { get; private set; }
    public System.Threading.Tasks.Task<string> Code { get; private set; }

    private static string Base64Url(byte[] value) {
        return System.Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
    public QuotaLoginSession() {
        byte[] random = new byte[32];
        using (var rng = System.Security.Cryptography.RandomNumberGenerator.Create()) {
            rng.GetBytes(random); State = Base64Url(random);
            rng.GetBytes(random); Verifier = Base64Url(random);
        }
        using (var sha = System.Security.Cryptography.SHA256.Create())
            Challenge = Base64Url(sha.ComputeHash(System.Text.Encoding.ASCII.GetBytes(Verifier)));
        foreach (int port in new int[] {1455, 1457}) {
            var candidate = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
            try { candidate.Start(); listener = candidate; break; }
            catch (System.Net.Sockets.SocketException) { candidate.Stop(); }
        }
        if (listener == null) throw new System.InvalidOperationException("Login callback port unavailable.");
        RedirectUri = "http://127.0.0.1:" + ((System.Net.IPEndPoint)listener.LocalEndpoint).Port + "/auth/callback";
        Code = ReceiveAsync();
    }
    public static string ValidateCallback(string target, string state) {
        if (target == null || !target.StartsWith("/auth/callback?", System.StringComparison.Ordinal)) return null;
        var values = new System.Collections.Generic.Dictionary<string, string>();
        foreach (string item in target.Substring(target.IndexOf('?') + 1).Split('&')) {
            int split = item.IndexOf('=');
            string key = System.Uri.UnescapeDataString(split < 0 ? item : item.Substring(0, split));
            string value = split < 0 ? "" : System.Uri.UnescapeDataString(item.Substring(split + 1).Replace('+', ' '));
            if (values.ContainsKey(key)) return null;
            values.Add(key, value);
        }
        string actual, code;
        if (!values.TryGetValue("state", out actual) || actual.Length != state.Length) return null;
        int different = 0;
        for (int i = 0; i < state.Length; i++) different |= actual[i] ^ state[i];
        if (different != 0 || values.ContainsKey("error") || !values.TryGetValue("code", out code) ||
            code.Length == 0 || code.Length > 8192) return null;
        return code;
    }
    private async System.Threading.Tasks.Task<string> ReceiveAsync() {
        while (!disposed) {
            System.Net.Sockets.TcpClient client;
            try { client = await listener.AcceptTcpClientAsync().ConfigureAwait(false); }
            catch (System.Exception) { if (disposed) return null; throw; }
            using (client) {
                try {
                    var stream = client.GetStream();
                    byte[] buffer = new byte[16384];
                    int length = 0;
                    string headers = "";
                    while (length < buffer.Length && headers.IndexOf("\r\n\r\n", System.StringComparison.Ordinal) < 0) {
                        var read = stream.ReadAsync(buffer, length, buffer.Length - length);
                        if (await System.Threading.Tasks.Task.WhenAny(read,
                            System.Threading.Tasks.Task.Delay(5000)).ConfigureAwait(false) != read) break;
                        int count = await read.ConfigureAwait(false);
                        if (count == 0) break;
                        length += count;
                        headers = System.Text.Encoding.ASCII.GetString(buffer, 0, length);
                    }
                    string[] first = headers.Split(new string[] {"\r\n"}, System.StringSplitOptions.None)[0].Split(' ');
                    string code = first.Length == 3 && first[0] == "GET" ? ValidateCallback(first[1], State) : null;
                    string body = code == null ? "Invalid callback. Return to the authorization page." :
                        "Authorization received. You can close this tab and return to the quota indicator.";
                    string response = "HTTP/1.1 " + (code == null ? "400 Bad Request" : "200 OK") +
                        "\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n" +
                        "Referrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n\r\n" + body;
                    byte[] bytes = System.Text.Encoding.UTF8.GetBytes(response);
                    await stream.WriteAsync(bytes, 0, bytes.Length).ConfigureAwait(false);
                    if (code != null) return code;
                }
                catch (System.Exception) { if (disposed) return null; }
            }
        }
        return null;
    }
    public void Dispose() { disposed = true; if (listener != null) listener.Stop(); }
}

'@
}

$script:entryPath = $PSCommandPath
# Each row owns its independent grant and authorization menu.

$usageUrl = 'https://chatgpt.com/backend-api/wham/usage'
$script:notify = $null
$script:menu = $null
$script:timer = $null
$script:completionTimer = $null
$script:generatedIcon = $null
$script:iconKey = ''
$script:singleInstanceMutex = $null
$script:ownsMutex = $false
$script:lastDesktopState = 'Unknown'
$script:paused = $false
$script:profiles = @()
$script:invariant = [Globalization.CultureInfo]::InvariantCulture

function New-EmptyWindow([string]$State = 'missing') {
    return [pscustomobject]@{
        Remaining = $null; ResetAtUtc = $null; CapturedUtc = $null; State = $State
    }
}

function New-QuotaProfile([string]$Name, [string]$Label, [string]$Directory, [string]$DefaultDirectory) {
    $pathError = $false
    $authPath = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = $DefaultDirectory }
        $Directory = [IO.Path]::GetFullPath($Directory)
        $authPath = Join-Path $Directory 'auth.json'
    }
    catch { $pathError = $true }
    return [pscustomobject]@{
        Name = $Name; Label = $Label; AuthPath = $authPath; PathError = $pathError
        Status = 'unread'; Five = (New-EmptyWindow); Week = (New-EmptyWindow)
        LastAttemptUtc = $null; UpdatedUtc = $null; Client = $null
        Pending = $null; Cancellation = $null; StartedUtc = $null; TimedOut = $false
        Credential = $null; Identity = ''; Generation = 0; RequestGeneration = -1
        LastSavedToken = $null; RequestWasCached = $false
        QuotaSession = $null; RequestSession = $null; UnsavedSession = $null
        PendingKind = 'usage'; RefreshLock = $null; RenewAfterUtc = $null
        ForceRenewal = $false; UsageRetryUsed = $false
        MenuFive = $null; MenuWeek = $null; MenuStatus = $null; AuthMenu = $null
    }
}

function Get-WorkspaceRole([string]$Plan) {
    switch ($Plan) {
        { $_ -in @('free', 'go', 'plus', 'pro', 'prolite', 'promax') } { return 'personal' }
        { $_ -in @('team', 'business', 'enterprise', 'edu') } { return 'company' }
    }
    return $null
}

function Get-WorkspaceCredential([string]$Token, [string]$ExpectedAccount) {
    if ($Token.Length -gt 32768 -or $Token -cnotmatch '^[A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+\z') { return $null }
    try {
        # The first-party API authenticates the token. Decode claims here only to route it.
        $part = $Matches[1].Replace('-', '+').Replace('_', '/')
        $part += '=' * ((4 - ($part.Length % 4)) % 4)
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        $claims = $payload.'https://api.openai.com/auth'
        $role = Get-WorkspaceRole $claims.chatgpt_plan_type
        $account = [string]$claims.chatgpt_account_id
        $user = [string]$claims.chatgpt_user_id
        if (-not $user) { $user = [string]$claims.user_id }
        if (-not $role -or $account -cnotmatch '^[A-Za-z0-9_-]{1,128}\z' -or
            $user -cnotmatch '^[A-Za-z0-9_-]{1,128}\z' -or
            ($ExpectedAccount -and $ExpectedAccount -cne $account)) { return $null }
        $expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$payload.exp).UtcDateTime
        return [pscustomobject]@{ Role = $role; Account = $account; User = $user; Expires = $expires; Token = $Token; Cached = $false }
    }
    catch { return $null }
}

function Read-WorkspaceAuth($Profile) {
    try {
        if ($Profile.PathError) { return @{ Status = 'path-config'; Credential = $null } }
        if (-not (Test-Path -LiteralPath $Profile.AuthPath -PathType Leaf)) {
            return @{ Status = 'missing-auth'; Credential = $null }
        }
        if ((Get-Item -LiteralPath $Profile.AuthPath -Force).Length -gt 131072) { throw 'Invalid auth file size.' }
        $auth = Get-Content -Raw -LiteralPath $Profile.AuthPath -Encoding UTF8 | ConvertFrom-Json
        $credential = Get-WorkspaceCredential $auth.tokens.access_token $auth.tokens.account_id
        if ($null -eq $credential) { return @{ Status = 'invalid-auth'; Credential = $null } }
        return @{ Status = 'ok'; Credential = $credential }
    }
    catch { return @{ Status = 'invalid-auth'; Credential = $null } }
}

function Get-PersonalCachePath($Profile) {
    $directory = $StateDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexQuotaIndicator'
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Profile.AuthPath.ToUpperInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    return Join-Path ([IO.Path]::GetFullPath($directory)) ('personal-' + $key + '.dpapi')
}

function Read-PersonalCache($Profile) {
    $plain = $null
    try {
        $path = Get-PersonalCachePath $Profile
        if (-not [IO.File]::Exists($path) -or [IO.FileInfo]::new($path).Length -gt 65536) { return $null }
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $null, 'CurrentUser')
        $credential = Get-WorkspaceCredential ([Text.Encoding]::UTF8.GetString($plain)) ''
        if ($null -ne $credential -and $credential.Role -eq 'personal') {
            $credential.Cached = $true
            return $credential
        }
    }
    catch { }
    finally { if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) } }
    return $null
}

function Save-PersonalCache($Profile, $Credential) {
    if ($Credential.Token -ceq $Profile.LastSavedToken) { return }
    $plain = $null
    $temporary = $null
    try {
        $path = Get-PersonalCachePath $Profile
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        $plain = [Text.Encoding]::UTF8.GetBytes($Credential.Token)
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain, $null, 'CurrentUser')
        [IO.File]::WriteAllBytes($temporary, $encrypted)
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
        $Profile.LastSavedToken = $Credential.Token
    }
    catch { }
    finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($temporary) { try { [IO.File]::Delete($temporary) } catch { } }
    }
}

function Clear-QuotaWindows($Profile) {
    $Profile.Five = New-EmptyWindow
    $Profile.Week = New-EmptyWindow
    $Profile.UpdatedUtc = $null
}

function Sync-QuotaCredentials {
    $validThrough = [DateTime]::UtcNow.AddSeconds(30)
    foreach ($profile in $script:profiles) {
        if ($profile.Status -eq 'profile-conflict') { continue }
        $auth = Read-WorkspaceAuth $profile
        $candidate = $auth.Credential
        $status = $auth.Status
        if ($null -ne $candidate) {
            if ($candidate.Role -ne $profile.Name) {
                $workspaceUser = $candidate.User
                $candidate = $null
                $status = 'workspace-login-needed'
                # A desktop workspace switch keeps the same user but changes the token's account.
                if ($profile.Name -eq 'personal') {
                    $cached = Read-PersonalCache $profile
                    if ($null -ne $cached -and $cached.User -ceq $workspaceUser -and $cached.Expires -gt $validThrough) {
                        $candidate = $cached
                    }
                }
            }
            elseif ($candidate.Expires -le $validThrough) {
                $candidate = $null
                $status = 'workspace-login-needed'
            }
            elseif ($profile.Name -eq 'personal') { Save-PersonalCache $profile $candidate }
        }

        $profile.QuotaSession = $null
        if ($null -ne $auth.Credential) {
            if ($null -ne $profile.UnsavedSession) {
                $lock = Lock-QuotaSession $profile
                if ($null -ne $lock) {
                    try {
                        if (Save-QuotaSession $profile $profile.UnsavedSession) { $profile.UnsavedSession = $null }
                    }
                    finally { $lock.Dispose() }
                }
            }
            $session = if ($null -ne $profile.UnsavedSession) { $profile.UnsavedSession } else { Read-QuotaSession $profile }
            # The row is pinned to its authorized account, independent of the selected workspace.
            # A different signed-in user must never inherit this user's saved quota.
            if ($null -ne $session -and $session.Credential.User -ceq $auth.Credential.User) {
                $profile.QuotaSession = $session
                if ($session.Disabled) { $candidate = $null; $status = 'login-needed' }
                else { $candidate = $session.Credential }
            }
            elseif ($null -ne $session) {
                $candidate = $null
                $status = 'workspace-login-needed'
            }
        }

        $identity = if ($null -ne $candidate) { $candidate.Account + '/' + $candidate.User } else { '' }
        if ($profile.Identity -cne $identity) {
            Clear-QuotaWindows $profile
            $profile.Identity = $identity
            $profile.Generation++
            $profile.LastAttemptUtc = $null
            $profile.Status = 'unread'
            $profile.RenewAfterUtc = $null
            $profile.ForceRenewal = $false
            $profile.UsageRetryUsed = $false
            if ($null -ne $profile.Cancellation) { $profile.Cancellation.Cancel() }
        }
        elseif ($null -ne $candidate -and $candidate.Token -cne $profile.Credential.Token -and
            $profile.Status -in @('unauthorized', 'workspace-login-needed')) {
            $profile.LastAttemptUtc = $null
            $profile.Status = 'unread'
        }
        $profile.Credential = $candidate
        if ($null -eq $candidate) { $profile.Status = $status }
    }
}


function Get-QuotaSessionPath($Profile) {
    $cache = Get-PersonalCachePath $Profile
    return Join-Path ([IO.Path]::GetDirectoryName($cache)) ([IO.Path]::GetFileName($cache).Replace('personal-', ($Profile.Name + '-session-')))
}

function ConvertTo-QuotaSession($Value, [string]$Role = 'personal') {
    if ($Value.version -ne 1 -or [string]::IsNullOrWhiteSpace($Value.refresh_token) -or
        $Value.refresh_token.Length -gt 16384 -or $Value.refresh_token -match '[\x00-\x20\x7f]') { return $null }
    $credential = Get-WorkspaceCredential $Value.access_token $Value.account
    if ($null -eq $credential -or $credential.Role -ne $Role -or $credential.User -cne $Value.user) { return $null }
    $credential | Add-Member -NotePropertyName Dedicated -NotePropertyValue $true
    return [pscustomobject]@{ Credential=$credential; RefreshToken=[string]$Value.refresh_token; Disabled=($Value.disabled -eq $true) }
}

function Read-QuotaSession($Profile) {
    $plain = $null
    try {
        $path = Get-QuotaSessionPath $Profile
        if (-not [IO.File]::Exists($path) -or [IO.FileInfo]::new($path).Length -gt 131072) { return $null }
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $null, 'CurrentUser')
        return ConvertTo-QuotaSession ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json) $Profile.Name
    }
    catch { return $null }
    finally { if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) } }
}

function Save-QuotaSession($Profile, $Session) {
    $plain = $null; $temporary = $null
    try {
        $path = Get-QuotaSessionPath $Profile
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        $data = @{ version=1; access_token=$Session.Credential.Token; refresh_token=$Session.RefreshToken
            account=$Session.Credential.Account; user=$Session.Credential.User; disabled=[bool]$Session.Disabled }
        $plain = [Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Compress))
        $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllBytes($temporary, [Security.Cryptography.ProtectedData]::Protect($plain, $null, 'CurrentUser'))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
        return $true
    }
    catch { return $false }
    finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($temporary) { try { [IO.File]::Delete($temporary) } catch { } }
    }
}

function Lock-QuotaSession($Profile) {
    try {
        $path = Get-QuotaSessionPath $Profile
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        return [IO.File]::Open(($path + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    }
    catch { return $null }
}

function Send-QuotaTokenRequest($Client, $Body) {
    # Fixed first-party authority; the existing explicit proxy/no-redirect policy applies.
    return ,([QuotaOAuth]::PostAsync($Client, ($Body | ConvertTo-Json -Compress)))
}

function Start-QuotaRenewal($Profile) {
    $lock = Lock-QuotaSession $Profile
    if ($null -eq $lock) {
        $Profile.Status = 'refresh-busy'
        $Profile.LastAttemptUtc = $null
        return $true
    }
    try {
        $session = Read-QuotaSession $Profile
        if ($null -eq $session -or $session.Disabled -or $session.Credential.Account -cne $Profile.Credential.Account -or
            $session.Credential.User -cne $Profile.Credential.User) {
            $Profile.Status = 'login-needed'
            return $true
        }
        # A second process may have renewed while this process was waiting for the lock.
        if ($session.Credential.Token -cne $Profile.Credential.Token -and
            $session.Credential.Expires -gt [DateTime]::UtcNow.AddMinutes(5)) {
            $Profile.Credential = $session.Credential
            $Profile.QuotaSession = $session
            $Profile.ForceRenewal = $false
            return $false
        }
        # Verify that encrypted storage is writable before consuming a rotating token.
        if (-not (Save-QuotaSession $Profile $session)) { $Profile.Status = 'auth-storage'; return $true }
        $Profile.RequestSession = $session
        $Profile.PendingKind = 'usage'
        $Profile.RequestGeneration = $Profile.Generation
        $Profile.RequestWasCached = $true
        $Profile.StartedUtc = [DateTime]::UtcNow
        $Profile.TimedOut = $false
        $Profile.PendingKind = 'renewal'
        $Profile.Pending = Send-QuotaTokenRequest $Profile.Client @{
            grant_type='refresh_token'; refresh_token=$session.RefreshToken; client_id='app_EMoamEEZ73f0CkXaXp7hrann'
        }
        $Profile.RefreshLock = $lock
        $lock = $null
        $Profile.Status = 'loading'
        if ($null -ne $script:completionTimer) { $script:completionTimer.Start() }
        return $true
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Complete-QuotaRenewal($Profile, $Reply) {
    if ($Reply.Status -ne 'ok') {
        if ($Reply.Status -eq 'login-needed') {
            $Profile.RequestSession.Disabled = $true
            if (-not (Save-QuotaSession $Profile $Profile.RequestSession)) { $Profile.UnsavedSession = $Profile.RequestSession }
            Clear-QuotaWindows $Profile
        }
        else { $Profile.RenewAfterUtc = [DateTime]::UtcNow.AddMinutes(2) }
        $Profile.Status = $Reply.Status
        # While its old access token is valid, an offline renewal need not hide the quota.
        return $Reply.Status -ne 'login-needed' -and $Profile.Credential.Expires -gt [DateTime]::UtcNow.AddSeconds(30)
    }
    try {
        $tokens = $Reply.Body | ConvertFrom-Json
        $credential = Get-WorkspaceCredential $tokens.access_token $Profile.RequestSession.Credential.Account
        if ($null -eq $credential -or $credential.Role -ne $Profile.Name -or
            $credential.User -cne $Profile.RequestSession.Credential.User -or
            $credential.Expires -le [DateTime]::UtcNow.AddSeconds(30)) { throw 'Invalid renewed identity.' }
        $refresh = if ([string]::IsNullOrWhiteSpace($tokens.refresh_token)) { $Profile.RequestSession.RefreshToken } else { [string]$tokens.refresh_token }
        $session = ConvertTo-QuotaSession @{version=1;access_token=$credential.Token;refresh_token=$refresh;account=$credential.Account;user=$credential.User;disabled=$false} $Profile.Name
        if ($null -eq $session) { throw 'Invalid renewed session.' }
        $current = Read-QuotaSession $Profile
        if ($null -eq $current -or $current.RefreshToken -cne $Profile.RequestSession.RefreshToken) {
            $Profile.Status = 'refresh-busy'; $Profile.LastAttemptUtc = $null; return $false
        }
        if (-not (Save-QuotaSession $Profile $session)) {
            $Profile.UnsavedSession = $session
            $Profile.Status = 'auth-storage'
            return $false
        }
        $Profile.QuotaSession = $session
        $Profile.Credential = $session.Credential
        $Profile.ForceRenewal = $false
        $Profile.RenewAfterUtc = $null
        $Profile.Status = 'unread'
        return $true
    }
    catch {
        # A consumed refresh with an invalid response must never be retried in a loop.
        $Profile.RequestSession.Disabled = $true
        if (-not (Save-QuotaSession $Profile $Profile.RequestSession)) { $Profile.UnsavedSession = $Profile.RequestSession }
        Clear-QuotaWindows $Profile
        $Profile.Status = 'login-needed'
        return $false
    }
}

function Get-QuotaAuthorizationUrl($Login, [string]$Account) {
    $parameters = [ordered]@{ response_type='code'; client_id='app_EMoamEEZ73f0CkXaXp7hrann'
        redirect_uri=$Login.RedirectUri; scope='openid profile email offline_access'
        code_challenge=$Login.Challenge; code_challenge_method='S256'; state=$Login.State
        id_token_add_organizations='true'; codex_cli_simplified_flow='true'; originator='codex_cli_rs' }
    if ($Account) { $parameters.allowed_workspace_id = $Account }
    $query = @($parameters.GetEnumerator() | ForEach-Object { [Uri]::EscapeDataString($_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
    return 'https://auth.openai.com/oauth/authorize?' + $query
}

function Connect-QuotaAccount($Profile) {
    $lock = Lock-QuotaSession $Profile
    if ($null -eq $lock) { return 'refresh-busy' }
    $login = $null; $client = $null
    try {
        $expected = if ($Profile.Name -eq 'personal') { Read-PersonalCache $Profile } else { $null }
        $existing = Read-QuotaSession $Profile
        if ($null -ne $existing) { $expected = $existing.Credential }
        $source = Read-WorkspaceAuth $Profile
        if ($null -eq $existing -and $null -ne $source.Credential -and $source.Credential.Role -eq $Profile.Name) { $expected = $source.Credential }
        $login = [QuotaLoginSession]::new()
        $client = New-QuotaClient
        Start-Process (Get-QuotaAuthorizationUrl $login $expected.Account)
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        while (-not $login.Code.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if (-not $login.Code.IsCompleted) { return 'timeout' }
        $code = $login.Code.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($code)) { return 'login-needed' }
        $task = Send-QuotaTokenRequest $client @{
            grant_type='authorization_code'; client_id='app_EMoamEEZ73f0CkXaXp7hrann'
            code=$code; redirect_uri=$login.RedirectUri; code_verifier=$login.Verifier
        }
        $reply = $task.GetAwaiter().GetResult()
        $task.Dispose()
        if ($reply.Status -ne 'ok') { return $reply.Status }
        $tokens = $reply.Body | ConvertFrom-Json
        $credential = Get-WorkspaceCredential $tokens.access_token $expected.Account
        if ($null -eq $credential -or $credential.Role -ne $Profile.Name -or
            ($expected.User -and $credential.User -cne $expected.User) -or
            ($source.Credential.User -and $credential.User -cne $source.Credential.User) -or
            $credential.Expires -le [DateTime]::UtcNow.AddSeconds(30)) { return 'workspace-mismatch' }
        # Accept only a new grant, never a copied refresh token already owned by Codex.
        foreach ($other in $script:profiles) {
            try {
                $auth = Get-Content -Raw -LiteralPath $other.AuthPath -Encoding UTF8 | ConvertFrom-Json
                if ($auth.tokens.refresh_token -and $auth.tokens.refresh_token -ceq $tokens.refresh_token) { return 'login-needed' }
            }
            catch { }
        }
        $session = ConvertTo-QuotaSession @{version=1;access_token=$credential.Token;refresh_token=$tokens.refresh_token;account=$credential.Account;user=$credential.User;disabled=$false} $Profile.Name
        if ($null -eq $session) { return 'login-needed' }
        if (-not (Save-QuotaSession $Profile $session)) { return 'auth-storage' }
        return 'ok'
    }
    catch { return 'login-needed' }
    finally {
        if ($null -ne $login) { $login.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        $lock.Dispose()
    }
}

function Start-QuotaAuthorization([string]$Role) {
    $values = [ordered]@{ PersonalHome=[IO.Path]::GetDirectoryName($script:profiles[0].AuthPath)
        CompanyHome=[IO.Path]::GetDirectoryName($script:profiles[1].AuthPath)
        StateDirectory=[IO.Path]::GetDirectoryName((Get-QuotaSessionPath $script:profiles[0])) }
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) { $values.Proxy=$Proxy }
    $command = '& ' + "'" + $script:entryPath.Replace("'", "''") + "' -Connect" + (Get-Culture).TextInfo.ToTitleCase($Role)
    foreach ($item in $values.GetEnumerator()) { $command += ' -' + $item.Key + " '" + $item.Value.Replace("'", "''") + "'" }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-EncodedCommand',$encoded) -WindowStyle Hidden
}


function Format-Percent($Remaining) {
    if ($null -eq $Remaining) { return '-' }
    return ([decimal]$Remaining).ToString('0.############################', $script:invariant) + '%'
}

function Format-Duration([double]$Seconds) {
    if ($Seconds -le 0) { return 'due' }
    if ($Seconds -lt 3600) { return '{0}m' -f [int][Math]::Ceiling($Seconds / 60) }
    if ($Seconds -lt 86400) { return '{0}h' -f [int][Math]::Ceiling($Seconds / 3600) }
    $days = [Math]::Ceiling($Seconds / 86400)
    if ($days -gt 99) { return '99d+' }
    return '{0}d' -f [int]$days
}

function Get-WindowDisplay($Window) {
    $result = New-EmptyWindow
    if ($null -eq $Window) { return $result }
    [decimal]$used = 0
    $usedText = [Convert]::ToString($Window.used_percent, $script:invariant)
    if ($null -eq $Window.used_percent -or
        -not [decimal]::TryParse($usedText, [Globalization.NumberStyles]::Float, $script:invariant, [ref]$used) -or
        $used -lt 0 -or $used -gt 100) {
        $result.State = 'invalid'
        return $result
    }
    $result.Remaining = [decimal]100 - $used
    $result.CapturedUtc = [DateTime]::UtcNow
    $result.State = 'ok'
    [double]$seconds = 0
    try {
        $resetText = [Convert]::ToString($Window.reset_after_seconds, $script:invariant)
        if ($null -ne $Window.reset_after_seconds -and
            [double]::TryParse($resetText, [Globalization.NumberStyles]::Float, $script:invariant, [ref]$seconds) -and
            -not [double]::IsNaN($seconds) -and $seconds -ge 0 -and $seconds -le 315360000) {
            $result.ResetAtUtc = $result.CapturedUtc.AddSeconds($seconds)
        }
        elseif ($null -ne $Window.reset_at) {
            [double]$epoch = 0
            $epochText = [Convert]::ToString($Window.reset_at, $script:invariant)
            if ([double]::TryParse($epochText, [Globalization.NumberStyles]::Float, $script:invariant, [ref]$epoch) -and
                -not [double]::IsNaN($epoch) -and $epoch -ge 0 -and $epoch -le 253402300799) {
                $result.ResetAtUtc = ([datetime]'1970-01-01T00:00:00Z').ToUniversalTime().AddSeconds($epoch)
            }
        }
    }
    catch { $result.ResetAtUtc = $null }
    return $result
}

function Merge-Window($Previous, $Current) {
    if ($null -eq $Current.Remaining -and $null -ne $Previous.Remaining) {
        $Previous.State = 'stale'
        return $Previous
    }
    return $Current
}

function Get-LiveWindowDisplay($Profile, $Snapshot) {
    $seconds = $null
    $elapsed = $false
    if ($null -ne $Snapshot.ResetAtUtc) {
        $seconds = ([datetime]$Snapshot.ResetAtUtc - [DateTime]::UtcNow).TotalSeconds
        $elapsed = $seconds -le 0
        $seconds = [Math]::Max(0, $seconds)
    }
    $stale = $false
    if ($null -ne $Snapshot.Remaining) {
        $stale = $Snapshot.State -eq 'stale' -or $Profile.Status -notin @('ok', 'loading') -or $elapsed
        if ($null -ne $Snapshot.CapturedUtc -and
            ([DateTime]::UtcNow - $Snapshot.CapturedUtc).TotalMinutes -ge 20) { $stale = $true }
    }
    $reset = if ($elapsed) { 'due' } elseif ($null -eq $seconds) { '?' } else { Format-Duration $seconds }
    return [pscustomobject]@{
        Remaining = $Snapshot.Remaining; ResetAfterSeconds = $seconds
        ResetAtUtc = $Snapshot.ResetAtUtc; ResetElapsed = $elapsed; ResetText = $reset; Stale = $stale
    }
}

function Get-StatusText([string]$Status) {
    switch ($Status) {
        'unread' { return '尚未读取' }
        'loading' { return '读取中' }
        'ok' { return '正常' }
        'partial' { return '部分窗口缺失或无效' }
        'missing-auth' { return '缺少登录文件' }
        'workspace-login-needed' { return '请切到对应空间后立即刷新' }
        'workspace-mismatch' { return '额度响应的空间类型不符' }
        'login-needed' { return '请在右键菜单连接对应空间的自动续期' }
        'refresh-busy' { return '授权正在更新，稍后自动重试' }
        'auth-storage' { return '无法保存授权，请检查缓存目录权限' }
        'invalid-auth' { return '登录文件无效或无法读取' }
        'unauthorized' { return '登录已失效' }
        'offline' { return '网络或代理连接失败' }
        'timeout' { return '请求超时' }
        'proxy-config' { return '代理配置无效' }
        'path-config' { return '配置目录无效' }
        'profile-conflict' { return '两个配置目录不能相同' }
        'invalid-data' { return '额度响应无效' }
        'cancelled' { return '请求已取消' }
        default {
            if ($Status -like 'http-*') { return '服务返回 HTTP ' + $Status.Substring(5) }
            return '读取失败'
        }
    }
}

function Get-ProfileMark($Profile, $Five, $Week) {
    $mark = if ($Five.Stale -or $Week.Stale) { '~' } else { '' }
    switch ($Profile.Status) {
        'ok' { if ($script:paused) { return $mark + '停' }; return $mark }
        'loading' { return $mark + '读' }
        'unread' { if ($script:paused) { return '停' }; return '未' }
        'missing-auth' { return $mark + '缺' }
        'workspace-login-needed' { return $mark + '登' }
        'workspace-mismatch' { return $mark + '错' }
        'login-needed' { return $mark + '登' }
        'refresh-busy' { return $mark + '读' }
        'invalid-auth' { return $mark + '登' }
        'unauthorized' { return $mark + '登' }
        'offline' { return $mark + '网' }
        'timeout' { return $mark + '超' }
        'partial' { return $mark + '部' }
        default { return $mark + '错' }
    }
}

function Get-TooltipText {
    $rows = @()
    foreach ($profile in $script:profiles) {
        $five = Get-LiveWindowDisplay $profile $profile.Five
        $week = Get-LiveWindowDisplay $profile $profile.Week
        $rows += [pscustomobject]@{
            Label = $profile.Label + (Get-ProfileMark $profile $five $week)
            P = (Format-Percent $five.Remaining); W = (Format-Percent $week.Remaining)
            R = $five.ResetText; S = $week.ResetText
        }
    }
    $text = ($rows | ForEach-Object { '{0} 5h:{1}/{2} 7d:{3}/{4}' -f $_.Label, $_.P, $_.R, $_.W, $_.S }) -join "`n"
    if ($text.Length -le 63) { return $text }
    # Compact form keeps the documented left=5h, right=7d ordering.
    $text = ($rows | ForEach-Object { '{0} {1}/{2} {3}/{4}' -f $_.Label, $_.P, $_.R, $_.W, $_.S }) -join "`n"
    if ($text.Length -le 63) { return $text }
    # Arbitrarily long decimal percentages cannot all fit in 63 characters.
    # Preserve both profiles and all resets; '~' explicitly marks shortened values.
    $overhead = (($rows | ForEach-Object { '{0} /{1} /{2}' -f $_.Label, $_.R, $_.S }) -join "`n").Length
    $budget = [int][Math]::Floor((63 - $overhead) / 4)
    foreach ($row in $rows) {
        foreach ($field in @('P', 'W')) {
            $value = [string]$row.$field
            if ($value.Length -gt $budget) {
                $row.$field = $value.Substring(0, [Math]::Max(1, $budget - 2)) + '~%'
            }
        }
    }
    return (($rows | ForEach-Object { '{0} {1}/{2} {3}/{4}' -f $_.Label, $_.P, $_.R, $_.W, $_.S }) -join "`n")
}

# Pixel fonts: 5x7 at native 20px; a separate 3x5 font keeps 16px legible.
$script:glyphs = @{
    '0' = @('01110','10001','10011','10101','11001','10001','01110')
    '1' = @('00100','01100','00100','00100','00100','00100','01110')
    '2' = @('01110','10001','00001','00010','00100','01000','11111')
    '3' = @('11110','00001','00001','01110','00001','00001','11110')
    '4' = @('00010','00110','01010','10010','11111','00010','00010')
    '5' = @('11111','10000','10000','11110','00001','00001','11110')
    '6' = @('01110','10000','10000','11110','10001','10001','01110')
    '7' = @('11111','00001','00010','00100','01000','01000','01000')
    '8' = @('01110','10001','10001','01110','10001','10001','01110')
    '9' = @('01110','10001','10001','01111','00001','00001','01110')
    'F' = @('11111','10000','10000','11110','10000','10000','10000')
    '-' = @('00000','00000','00000','11111','00000','00000','00000')
}
$script:smallGlyphs = @{
    '0' = @('111','101','101','101','111'); '1' = @('010','110','010','010','111')
    '2' = @('110','001','010','100','111'); '3' = @('110','001','010','001','110')
    '4' = @('101','101','111','001','001'); '5' = @('111','100','110','001','110')
    '6' = @('011','100','111','101','111'); '7' = @('111','001','010','010','010')
    '8' = @('111','101','111','101','111'); '9' = @('111','101','111','001','110')
    'F' = @('111','100','110','100','100'); '-' = @('000','000','111','000','000')
}

function Get-IndicatorState($Remaining) {
    if ($null -eq $Remaining) { return '-' }
    if ([decimal]$Remaining -eq 100) { return 'F' }
    return ([int][Math]::Floor([decimal]$Remaining / [decimal]10)).ToString($script:invariant)
}

function Set-IndicatorIcon {
    if ($null -eq $script:notify) { return }
    $width = [Math]::Max(16, [Math]::Min(64, [TrayNativeMethods]::GetSystemMetrics(49)))
    $height = [Math]::Max(16, [Math]::Min(64, [TrayNativeMethods]::GetSystemMetrics(50)))
    $characters = @(
        (Get-IndicatorState $script:profiles[0].Five.Remaining),
        (Get-IndicatorState $script:profiles[0].Week.Remaining),
        (Get-IndicatorState $script:profiles[1].Five.Remaining),
        (Get-IndicatorState $script:profiles[1].Week.Remaining)
    )
    $key = "$width,$height," + ($characters -join '')
    if ($key -eq $script:iconKey) { return }
    $small = [Math]::Min($width, $height) -lt 20
    $baseSize = if ($small) { 16 } else { 20 }
    $font = if ($small) { $script:smallGlyphs } else { $script:glyphs }
    $positions = if ($small) { @(@(2,2), @(11,2), @(2,9), @(11,9)) } else { @(@(2,2), @(13,2), @(2,11), @(13,11)) }
    $base = $null; $bitmap = $null; $wrapper = $null; $replacement = $null
    $handle = [IntPtr]::Zero
    try {
        $base = [Drawing.Bitmap]::new($baseSize, $baseSize)
        for ($i = 0; $i -lt 4; $i++) {
            $glyph = $font[$characters[$i]]
            for ($y = 0; $y -lt $glyph.Count; $y++) {
                for ($x = 0; $x -lt $glyph[$y].Length; $x++) {
                    if ($glyph[$y][$x] -eq '1') {
                        $base.SetPixel($positions[$i][0] + $x, $positions[$i][1] + $y, [Drawing.Color]::White)
                    }
                }
            }
        }
        if ($small) {
            $base.SetPixel(7, 4, [Drawing.Color]::White)
            $base.SetPixel(7, 11, [Drawing.Color]::White)
        }
        else {
            foreach ($dotY in @(5, 14)) {
                for ($dy = 0; $dy -lt 2; $dy++) {
                    for ($dx = 0; $dx -lt 2; $dx++) { $base.SetPixel(9 + $dx, $dotY + $dy, [Drawing.Color]::White) }
                }
            }
        }
        $bitmap = [Drawing.Bitmap]::new($width, $height)
        # Explicit nearest-neighbor sampling: no font rasterization or antialiasing.
        for ($y = 0; $y -lt $height; $y++) {
            for ($x = 0; $x -lt $width; $x++) {
                $sx = [int][Math]::Floor($x * $baseSize / $width)
                $sy = [int][Math]::Floor($y * $baseSize / $height)
                $bitmap.SetPixel($x, $y, $base.GetPixel($sx, $sy))
            }
        }
        $handle = $bitmap.GetHicon()
        $wrapper = [Drawing.Icon]::FromHandle($handle)
        $replacement = [Drawing.Icon]$wrapper.Clone()
        $script:notify.Icon = $replacement
        $old = $script:generatedIcon
        $script:generatedIcon = $replacement
        $replacement = $null
        $script:iconKey = $key
        if ($null -ne $old) { $old.Dispose() }
    }
    finally {
        if ($null -ne $replacement) { $replacement.Dispose() }
        if ($null -ne $wrapper) { $wrapper.Dispose() }
        if ($handle -ne [IntPtr]::Zero) { [void][TrayNativeMethods]::DestroyIcon($handle) }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Update-LocalQuotaDisplay {
    if ($null -eq $script:notify) { return }
    foreach ($profile in $script:profiles) {
        $windows = @((Get-LiveWindowDisplay $profile $profile.Five), (Get-LiveWindowDisplay $profile $profile.Week))
        $items = @($profile.MenuFive, $profile.MenuWeek)
        $labels = @('5 小时', '7 天')
        for ($i = 0; $i -lt 2; $i++) {
            $window = $windows[$i]
            $value = Format-Percent $window.Remaining
            $reset = if ($window.ResetElapsed) { '已到重置时间，等待刷新' } elseif ($null -eq $window.ResetAtUtc) { '重置时间未知' } else {
                '{0} 后重置（{1}）' -f $window.ResetText, $window.ResetAtUtc.ToLocalTime().ToString('MM-dd HH:mm:ss')
            }
            $stale = if ($window.Stale) { ' [旧值]' } else { '' }
            $items[$i].Text = '{0} {1}：{2}；{3}{4}' -f $profile.Label, $labels[$i], $value, $reset, $stale
        }
        $updated = if ($null -eq $profile.UpdatedUtc) { '尚无成功响应' } else { '上次响应 ' + $profile.UpdatedUtc.ToLocalTime().ToString('HH:mm:ss') }
        $pause = if ($script:paused) { '；自动刷新暂停' } else { '' }
        $profile.MenuStatus.Text = '{0}：{1}；{2}{3}' -f $profile.Label, (Get-StatusText $profile.Status), $updated, $pause
    }
    foreach ($profile in $script:profiles) {
        if ($null -eq $profile.AuthMenu) { continue }
        $connected = Read-QuotaSession $profile
        $profile.AuthMenu.Text = if ($null -ne $connected -and -not $connected.Disabled) {
            $profile.Label + '自动续期：已连接（重新授权）'
        } else { '连接' + $profile.Label + '自动续期…' }
    }
    $script:notify.Text = Get-TooltipText
    Set-IndicatorIcon
}

function New-QuotaClient {
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
            $webProxy = [Net.WebProxy]::new($script:proxyUri)
            $webProxy.BypassProxyOnLocal = $false
            $webProxy.BypassList = [string[]]@()
            $handler.UseProxy = $true
            $handler.Proxy = $webProxy
        }
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler, $true)
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.MaxResponseContentBufferSize = 262144
        return $client
    }
    catch {
        if ($null -ne $client) { $client.Dispose() } else { $handler.Dispose() }
        throw
    }
}

function Update-Quota($Profile) {
    if ($null -ne $Profile.Pending) { return }
    $Profile.LastAttemptUtc = [DateTime]::UtcNow
    if ($Profile.PathError) { $Profile.Status = 'path-config'; return }
    if ($Profile.Status -eq 'profile-conflict') { return }
    if ($script:proxyInvalid) { $Profile.Status = 'proxy-config'; return }
    if ($null -eq $Profile.Client) { $Profile.Status = 'request-failed'; return }
    $credential = $Profile.Credential
    if ($null -eq $credential) { return }
    if ($null -ne $Profile.UnsavedSession) { $Profile.Status = 'auth-storage'; return }
    if ($credential.Dedicated -and ($Profile.ForceRenewal -or $credential.Expires -le [DateTime]::UtcNow.AddMinutes(5))) {
        if ($null -eq $Profile.RenewAfterUtc -or $Profile.RenewAfterUtc -le [DateTime]::UtcNow) {
            if (Start-QuotaRenewal $Profile) { return }
            $credential = $Profile.Credential
        }
    }
    if ($credential.Expires -le [DateTime]::UtcNow.AddSeconds(30)) {
        $Profile.LastAttemptUtc = $null
        return
    }
    $request = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $usageUrl)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $credential.Token)
        [void]$request.Headers.TryAddWithoutValidation('OpenAI-Beta', 'codex-1')
        [void]$request.Headers.TryAddWithoutValidation('originator', 'Codex Desktop')
        [void]$request.Headers.TryAddWithoutValidation('ChatGPT-Account-ID', $credential.Account)
        $Profile.PendingKind = 'usage'
        $Profile.RequestGeneration = $Profile.Generation
        $Profile.RequestWasCached = $credential.Cached
        $Profile.Cancellation = [Threading.CancellationTokenSource]::new()
        $Profile.Cancellation.CancelAfter(20000)
        $Profile.StartedUtc = [DateTime]::UtcNow
        $Profile.TimedOut = $false
        $Profile.Pending = [QuotaTransport]::FetchAsync($Profile.Client, $request, $Profile.Cancellation.Token)
        $request = $null  # Ownership transferred to QuotaTransport.
        $Profile.Status = 'loading'
        if ($null -ne $script:completionTimer) { $script:completionTimer.Start() }
    }
    catch {
        $Profile.Status = 'invalid-auth'
        if ($null -ne $Profile.Cancellation) { $Profile.Cancellation.Dispose(); $Profile.Cancellation = $null }
    }
    finally {
        if ($null -ne $request) { $request.Dispose() }
        $credential = $null
    }
}

function Complete-QuotaRefresh {
    $changed = $false
    foreach ($profile in $script:profiles) {
        if ($null -eq $profile.Pending) { continue }
        if (-not $profile.Pending.IsCompleted) {
            if ($profile.RequestGeneration -eq $profile.Generation -and -not $profile.TimedOut -and
                ([DateTime]::UtcNow - $profile.StartedUtc).TotalSeconds -ge 25) {
                $profile.TimedOut = $true
                $profile.Status = 'timeout'
                if ($null -ne $profile.Cancellation) { $profile.Cancellation.Cancel() }
                else { $profile.Client.CancelPendingRequests() }
                $changed = $true
            }
            continue
        }
        $changed = $true
        $restart = $false
        try {
            $stale = $profile.RequestGeneration -ne $profile.Generation
            if ($stale -and $profile.PendingKind -ne 'renewal') { continue }
            $reply = $profile.Pending.GetAwaiter().GetResult()
            if ($profile.PendingKind -eq 'renewal') {
                # A successful rotation must be saved even if the user switched during the request.
                # A detached copy keeps that response out of the newly selected user's display.
                $target = if ($stale) { $profile.PSObject.Copy() } else { $profile }
                $restart = Complete-QuotaRenewal $target $reply
                if ($stale) { $profile.UnsavedSession = $target.UnsavedSession; $restart = $false }
            }
            else {
                if ($profile.TimedOut) { $profile.Status = 'timeout'; continue }
                if ($reply.Status -ne 'ok') {
                    if ($reply.Status -eq 'unauthorized' -and $profile.Credential.Dedicated -and -not $profile.UsageRetryUsed) {
                        $profile.ForceRenewal = $true
                        $profile.UsageRetryUsed = $true
                        $restart = $true
                    }
                    elseif ($reply.Status -eq 'unauthorized' -and $profile.Credential.Dedicated) {
                        $lock = Lock-QuotaSession $profile
                        try {
                            $session = if ($null -ne $lock) { Read-QuotaSession $profile } else { $null }
                            if ($null -ne $session -and $session.Credential.Token -ceq $profile.Credential.Token) {
                                $session.Disabled = $true
                                if (-not (Save-QuotaSession $profile $session)) { $profile.UnsavedSession = $session }
                                Clear-QuotaWindows $profile
                                $profile.Status = 'login-needed'
                            }
                            else { $profile.Status = 'refresh-busy'; $profile.LastAttemptUtc = $null }
                        }
                        finally { if ($null -ne $lock) { $lock.Dispose() } }
                    }
                    else {
                        $profile.Status = if ($reply.Status -eq 'unauthorized' -and $profile.RequestWasCached) {
                            'workspace-login-needed'
                        } else { $reply.Status }
                    }
                }
                else {
                    $profile.Status = 'invalid-data'
                    $usage = $reply.Body | ConvertFrom-Json -ErrorAction Stop
                    if ((Get-WorkspaceRole $usage.plan_type) -ne $profile.Name) {
                        Clear-QuotaWindows $profile
                        $profile.Status = 'workspace-mismatch'
                        continue
                    }
                    if ($null -eq $usage.rate_limit) { continue }
                    $five = Get-WindowDisplay $usage.rate_limit.primary_window
                    $week = Get-WindowDisplay $usage.rate_limit.secondary_window
                    $profile.Five = Merge-Window $profile.Five $five
                    $profile.Week = Merge-Window $profile.Week $week
                    $profile.UpdatedUtc = [DateTime]::UtcNow
                    $profile.UsageRetryUsed = $false
                    $profile.Status = if ($null -ne $five.Remaining -and $null -ne $week.Remaining) { 'ok' } else { 'partial' }
                }
            }
        }
        catch { $profile.Status = 'invalid-data' }
        finally {
            $reply = $null; $usage = $null
            $profile.Pending.Dispose()
            $profile.Pending = $null
            if ($null -ne $profile.Cancellation) { $profile.Cancellation.Dispose(); $profile.Cancellation = $null }
            if ($null -ne $profile.RefreshLock) { $profile.RefreshLock.Dispose(); $profile.RefreshLock = $null }
            $profile.RequestSession = $null
        }
        if ($restart) { Update-Quota $profile }
    }
    if ($changed) { Update-LocalQuotaDisplay }
    if ($null -ne $script:completionTimer -and @($script:profiles | Where-Object { $null -ne $_.Pending }).Count -eq 0) {
        $script:completionTimer.Stop()
    }
}

function Get-CodexDesktopState {
    $processIds = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -like '*\OpenAI.Codex_*\app\ChatGPT.exe' } |
        Select-Object -ExpandProperty ProcessId)
    if ($processIds.Count -eq 0) { return 'Stopped' }
    $window = [TrayNativeMethods]::GetForegroundWindow()
    if ($window -ne [IntPtr]::Zero) {
        [uint32]$foregroundId = 0
        [void][TrayNativeMethods]::GetWindowThreadProcessId($window, [ref]$foregroundId)
        if ($processIds -contains [int]$foregroundId) { return 'Foreground' }
    }
    return 'Background'
}

function Get-RefreshDecision([string]$DesktopState, [string]$PreviousDesktopState, $LastQuotaAttempt, [datetime]$Now) {
    if ($DesktopState -eq 'Stopped') { return 'Pause' }
    if ($null -ne $LastQuotaAttempt -and ($Now - $LastQuotaAttempt).TotalMinutes -lt 5) { return 'Wait' }
    if ($PreviousDesktopState -in @('Unknown', 'Stopped')) { return 'Refresh' }
    if ($DesktopState -eq 'Foreground' -and $PreviousDesktopState -ne 'Foreground') { return 'Refresh' }
    $intervalMinutes = if ($DesktopState -eq 'Foreground') { 5 } else { 15 }
    if ($null -eq $LastQuotaAttempt -or ($Now - $LastQuotaAttempt).TotalMinutes -ge $intervalMinutes) { return 'Refresh' }
    return 'Wait'
}

function Invoke-QuotaRefresh {
    # Manual refresh and RunOnce explicitly bypass desktop detection and throttling.
    $script:paused = $false
    Sync-QuotaCredentials
    foreach ($profile in $script:profiles) { Update-Quota $profile }
    Update-LocalQuotaDisplay
}

function Update-RefreshSchedule {
    Sync-QuotaCredentials
    $desktopState = Get-CodexDesktopState
    $script:paused = $desktopState -eq 'Stopped'
    foreach ($profile in $script:profiles) {
        $decision = Get-RefreshDecision $desktopState $script:lastDesktopState $profile.LastAttemptUtc ([DateTime]::UtcNow)
        if ($decision -eq 'Refresh') { Update-Quota $profile }
    }
    $script:lastDesktopState = $desktopState
    Update-LocalQuotaDisplay
}

function Get-RunOnceWindow($Profile, $Snapshot) {
    $live = Get-LiveWindowDisplay $Profile $Snapshot
    return [ordered]@{
        remainingPercent = $live.Remaining
        resetAtUtc = $(if ($null -eq $live.ResetAtUtc) { $null } else { $live.ResetAtUtc.ToString('o') })
        resetAfterSeconds = $(if ($null -eq $live.ResetAfterSeconds) { $null } else { [long][Math]::Ceiling($live.ResetAfterSeconds) })
        resetElapsed = $live.ResetElapsed
        stale = $live.Stale
        state = $(if ($null -eq $live.Remaining) { $Snapshot.State } elseif ($live.Stale) { 'stale' } else { 'ok' })
    }
}

function Write-RunOnceResult {
    $results = @()
    foreach ($profile in $script:profiles) {
        $results += [ordered]@{
            profile = $profile.Name
            status = $profile.Status
            fiveHour = (Get-RunOnceWindow $profile $profile.Five)
            sevenDay = (Get-RunOnceWindow $profile $profile.Week)
        }
    }
    [ordered]@{ profiles = $results } | ConvertTo-Json -Depth 6
}

function Close-QuotaResources {
    foreach ($clock in @($script:timer, $script:completionTimer)) {
        if ($null -ne $clock) { $clock.Stop(); $clock.Dispose() }
    }
    if ($null -ne $script:notify) { $script:notify.Visible = $false; $script:notify.Dispose() }
    if ($null -ne $script:generatedIcon) { $script:generatedIcon.Dispose() }
    if ($null -ne $script:menu) { $script:menu.Dispose() }
    foreach ($profile in $script:profiles) {
        if ($null -ne $profile.Cancellation) { $profile.Cancellation.Cancel() }
        if ($null -ne $profile.Client) { $profile.Client.Dispose() }
    }
    # Bound shutdown waiting across both requests; the async helper owns disposal
    # of any request/response still unwinding after this deadline.
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    foreach ($profile in $script:profiles) {
        if ($null -ne $profile.Pending) {
            $milliseconds = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            try { [void]$profile.Pending.Wait($milliseconds) } catch { }
            if ($profile.Pending.IsCompleted) { $profile.Pending.Dispose() }
        }
        if ($null -ne $profile.Cancellation) { $profile.Cancellation.Dispose() }
        if ($null -ne $profile.RefreshLock) { $profile.RefreshLock.Dispose() }
    }
    if ($null -ne $script:singleInstanceMutex) {
        if ($script:ownsMutex) { try { $script:singleInstanceMutex.ReleaseMutex() } catch { } }
        $script:singleInstanceMutex.Dispose()
    }
}

$exitCode = 0
try {
    # Intentionally never consult CODEX_HOME: the two defaults must stay distinct.
    $personalDefault = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    $companyDefault = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI\Codex-Company'
    $script:profiles = @(
        (New-QuotaProfile 'personal' '个人' $PersonalHome $personalDefault),
        (New-QuotaProfile 'company' '公司' $CompanyHome $companyDefault)
    )
    if (-not $script:profiles[0].PathError -and -not $script:profiles[1].PathError -and
        [string]::Equals($script:profiles[0].AuthPath, $script:profiles[1].AuthPath, [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($profile in $script:profiles) { $profile.Status = 'profile-conflict' }
    }
    $script:proxyUri = $null
    $script:proxyInvalid = $PSBoundParameters.ContainsKey('Proxy') -and [string]::IsNullOrWhiteSpace($Proxy)
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $script:proxyInvalid = -not [Uri]::TryCreate($Proxy, [UriKind]::Absolute, [ref]$script:proxyUri)
        if (-not $script:proxyInvalid) {
            $script:proxyInvalid = $script:proxyUri.Scheme -notin @('http', 'https') -or
                [string]::IsNullOrWhiteSpace($script:proxyUri.Host) -or
                -not [string]::IsNullOrEmpty($script:proxyUri.UserInfo) -or
                $script:proxyUri.AbsolutePath -ne '/' -or
                -not [string]::IsNullOrEmpty($script:proxyUri.Query) -or
                -not [string]::IsNullOrEmpty($script:proxyUri.Fragment)
        }
    }
    if ($ConnectPersonal -or $ConnectCompany) {
        if ($ConnectPersonal -and $ConnectCompany) { throw 'Connect one workspace at a time.' }
        $target = if ($ConnectCompany) { $script:profiles[1] } else { $script:profiles[0] }
        $status = if ($script:proxyInvalid) { 'proxy-config' } else { Connect-QuotaAccount $target }
        if ($status -eq 'ok') {
            [void][Windows.Forms.MessageBox]::Show(($target.Label + '自动续期已连接。以后无需切换 Codex 空间；指示器将在一分钟内自动读取新授权。'), '额度指示器')
        }
        else {
            [void][Windows.Forms.MessageBox]::Show(($target.Label + '授权未完成：' + (Get-StatusText $status) + '。可在指示器右键菜单重新连接。'), '额度指示器')
        }
        exit $(if ($status -eq 'ok') { 0 } else { 1 })
    }
    if (-not $RunOnce) {
        [void][TrayNativeMethods]::SetProcessDPIAware()
        [Windows.Forms.Application]::EnableVisualStyles()
        [bool]$createdNew = $false
        $script:singleInstanceMutex = [Threading.Mutex]::new($true, 'Local\CodexQuotaIndicator', [ref]$createdNew)
        if (-not $createdNew) { exit 0 }
        $script:ownsMutex = $true
    }
    foreach ($profile in $script:profiles) {
        if ($profile.PathError) { $profile.Status = 'path-config'; continue }
        if ($profile.Status -eq 'profile-conflict') { continue }
        if ($script:proxyInvalid) { $profile.Status = 'proxy-config'; continue }
        try { $profile.Client = New-QuotaClient } catch { $profile.Status = 'request-failed' }
    }
    if ($RunOnce) {
        Invoke-QuotaRefresh
        $deadline = [DateTime]::UtcNow.AddSeconds(55)
        while (@($script:profiles | Where-Object { $null -ne $_.Pending }).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Complete-QuotaRefresh
            Start-Sleep -Milliseconds 20
        }
        Complete-QuotaRefresh
        foreach ($profile in $script:profiles) {
            if ($null -ne $profile.Pending) {
                $profile.Status = 'timeout'
                if ($null -ne $profile.Cancellation) { $profile.Cancellation.Cancel() }
                elseif ($null -ne $profile.Client) { $profile.Client.CancelPendingRequests() }
            }
            if ($profile.Status -ne 'ok') { $exitCode = 1 }
        }
        Write-RunOnceResult
    }
    else {
        $script:menu = [Windows.Forms.ContextMenuStrip]::new()
        foreach ($profile in $script:profiles) {
            $profile.MenuFive = [Windows.Forms.ToolStripMenuItem]::new()
            $profile.MenuWeek = [Windows.Forms.ToolStripMenuItem]::new()
            $profile.MenuStatus = [Windows.Forms.ToolStripMenuItem]::new()
            foreach ($item in @($profile.MenuFive, $profile.MenuWeek, $profile.MenuStatus)) {
                $item.Enabled = $false
                [void]$script:menu.Items.Add($item)
            }
            [void]$script:menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
        }
        foreach ($profile in $script:profiles) {
            $profile.AuthMenu = [Windows.Forms.ToolStripMenuItem]::new('连接' + $profile.Label + '自动续期…')
            $profile.AuthMenu.Tag = $profile.Name
            $profile.AuthMenu.Add_Click({ param($sender, $eventArgs) Start-QuotaAuthorization ([string]$sender.Tag) })
            [void]$script:menu.Items.Add($profile.AuthMenu)
        }
        $refreshItem = [Windows.Forms.ToolStripMenuItem]::new('立即刷新')
        $refreshItem.Add_Click({ Invoke-QuotaRefresh })
        $openItem = [Windows.Forms.ToolStripMenuItem]::new('打开 Codex 用量页面')
        $openItem.Add_Click({ Start-Process 'https://chatgpt.com/codex/settings/usage' })
        $exitItem = [Windows.Forms.ToolStripMenuItem]::new('退出')
        $exitItem.Add_Click({ [Windows.Forms.Application]::Exit() })
        [void]$script:menu.Items.Add($refreshItem)
        [void]$script:menu.Items.Add($openItem)
        [void]$script:menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
        [void]$script:menu.Items.Add($exitItem)
        $script:notify = [Windows.Forms.NotifyIcon]::new()
        $script:notify.ContextMenuStrip = $script:menu
        $script:timer = [Windows.Forms.Timer]::new()
        $script:timer.Interval = 60000
        $script:timer.Add_Tick({ Update-RefreshSchedule })
        $script:completionTimer = [Windows.Forms.Timer]::new()
        $script:completionTimer.Interval = 200
        $script:completionTimer.Add_Tick({ Complete-QuotaRefresh })
        Update-LocalQuotaDisplay
        $script:notify.Visible = $true
        Update-RefreshSchedule
        $script:timer.Start()
        [Windows.Forms.Application]::Run()
    }
}
catch {
    # Never expose exception messages, authentication objects, paths or response bodies.
    $exitCode = 1
    if ($RunOnce) {
        foreach ($profile in $script:profiles) {
            if ($profile.Status -in @('unread', 'loading')) { $profile.Status = 'internal-error' }
        }
        Write-RunOnceResult
    }
    else { Write-Error 'Codex quota indicator could not continue.' -ErrorAction Continue }
}
finally { Close-QuotaResources }
exit $exitCode
