param(
    [switch]$RunOnce,
    [string]$Proxy = $env:HTTPS_PROXY,
    [string]$PersonalHome = $env:CODEX_QUOTA_PERSONAL_HOME,
    [string]$CompanyHome = $env:CODEX_QUOTA_COMPANY_HOME
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
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
'@
}

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
        MenuFive = $null; MenuWeek = $null; MenuStatus = $null
    }
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
    $request = $null; $auth = $null; $token = $null
    try {
        if (-not (Test-Path -LiteralPath $Profile.AuthPath -PathType Leaf -ErrorAction Stop)) {
            $Profile.Status = 'missing-auth'
            return
        }
        $auth = Get-Content -Raw -LiteralPath $Profile.AuthPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $token = [string]$auth.tokens.access_token
        if ([string]::IsNullOrWhiteSpace($token)) { $Profile.Status = 'invalid-auth'; return }
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $usageUrl)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        [void]$request.Headers.TryAddWithoutValidation('OpenAI-Beta', 'codex-1')
        [void]$request.Headers.TryAddWithoutValidation('originator', 'Codex Desktop')
        if (-not [string]::IsNullOrWhiteSpace([string]$auth.tokens.account_id)) {
            [void]$request.Headers.TryAddWithoutValidation('ChatGPT-Account-ID', [string]$auth.tokens.account_id)
        }
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
        $auth = $null; $token = $null
    }
}

function Complete-QuotaRefresh {
    $changed = $false
    foreach ($profile in $script:profiles) {
        if ($null -eq $profile.Pending) { continue }
        if (-not $profile.Pending.IsCompleted) {
            if (-not $profile.TimedOut -and ([DateTime]::UtcNow - $profile.StartedUtc).TotalSeconds -ge 25) {
                $profile.TimedOut = $true
                $profile.Status = 'timeout'
                $profile.Cancellation.Cancel()
                $changed = $true
            }
            continue
        }
        $changed = $true
        try {
            $reply = $profile.Pending.GetAwaiter().GetResult()
            if ($profile.TimedOut) { $profile.Status = 'timeout'; continue }
            if ($reply.Status -ne 'ok') { $profile.Status = $reply.Status; continue }
            $profile.Status = 'invalid-data'
            $usage = $reply.Body | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $usage.rate_limit) { continue }
            $five = Get-WindowDisplay $usage.rate_limit.primary_window
            $week = Get-WindowDisplay $usage.rate_limit.secondary_window
            $profile.Five = Merge-Window $profile.Five $five
            $profile.Week = Merge-Window $profile.Week $week
            $profile.UpdatedUtc = [DateTime]::UtcNow
            $profile.Status = if ($null -ne $five.Remaining -and $null -ne $week.Remaining) { 'ok' } else { 'partial' }
        }
        catch { $profile.Status = 'invalid-data' }
        finally {
            $reply = $null; $usage = $null
            $profile.Pending.Dispose()
            $profile.Pending = $null
            if ($null -ne $profile.Cancellation) { $profile.Cancellation.Dispose(); $profile.Cancellation = $null }
        }
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
    foreach ($profile in $script:profiles) { Update-Quota $profile }
    Update-LocalQuotaDisplay
}

function Update-RefreshSchedule {
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
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (@($script:profiles | Where-Object { $null -ne $_.Pending }).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Complete-QuotaRefresh
            Start-Sleep -Milliseconds 20
        }
        Complete-QuotaRefresh
        foreach ($profile in $script:profiles) {
            if ($null -ne $profile.Pending) {
                $profile.Status = 'timeout'
                $profile.Cancellation.Cancel()
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
