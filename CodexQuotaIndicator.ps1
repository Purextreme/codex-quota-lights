param(
    [switch]$RunOnce
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TrayNativeMethods {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@

[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not $RunOnce) {
    [bool]$createdNew = $false
    $script:singleInstanceMutex = New-Object System.Threading.Mutex($true, 'Local\CodexQuotaIndicator', [ref]$createdNew)
    if (-not $createdNew) {
        $script:singleInstanceMutex.Dispose()
        exit 0
    }
}

$usageUrl = 'https://chatgpt.com/backend-api/wham/usage'
$fiveHourItem = New-Object System.Windows.Forms.ToolStripMenuItem('5 小时：读取中…')
$fiveHourItem.Enabled = $false
$weeklyItem = New-Object System.Windows.Forms.ToolStripMenuItem('周额度：读取中…')
$weeklyItem.Enabled = $false
$updatedItem = New-Object System.Windows.Forms.ToolStripMenuItem('上次更新：尚未更新')
$updatedItem.Enabled = $false
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add($fiveHourItem)
[void]$menu.Items.Add($weeklyItem)
[void]$menu.Items.Add($updatedItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.ContextMenuStrip = $menu
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Text = 'Codex 额度：读取中…'
$notify.Visible = $true
$script:generatedIcon = $null
$script:lastQuotaAttempt = $null
$script:lastDesktopState = 'Unknown'
$script:hasQuotaSnapshot = $false
$script:fiveHourSnapshot = $null
$script:weeklySnapshot = $null
$script:quotaRequestTask = $null
$script:quotaRequestMessage = $null
$script:runOnceError = $null
$script:httpClient = New-Object System.Net.Http.HttpClient
$script:httpClient.Timeout = [TimeSpan]::FromSeconds(20)

function Format-Duration([double]$Seconds) {
    $duration = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    if ($duration.TotalDays -ge 1) { return "{0}天{1}小时" -f [int]$duration.TotalDays, $duration.Hours }
    if ($duration.TotalHours -ge 1) { return "{0}小时{1}分" -f [int]$duration.TotalHours, $duration.Minutes }
    return "{0}分" -f [Math]::Max(1, $duration.Minutes)
}

function Get-WindowDisplay($Window, [string]$Label) {
    if ($null -eq $Window) {
        return [pscustomobject]@{ Label = $Label; Text = "$Label：当前套餐未提供此窗口"; Remaining = $null; ResetAfterSeconds = $null }
    }

    [double]$used = 0
    if ($null -eq $Window.used_percent -or -not [double]::TryParse([string]$Window.used_percent, [ref]$used)) {
        return [pscustomobject]@{ Label = $Label; Text = "$Label：额度数据不完整"; Remaining = $null; ResetAfterSeconds = $Window.reset_after_seconds }
    }
    $used = [Math]::Min(100, [Math]::Max(0, $used))
    $remaining = 100 - $used
    $resetText = if ($null -eq $Window.reset_after_seconds) { '重置时间未知' } else { "$(Format-Duration ([double]$Window.reset_after_seconds)) 后重置" }
    return [pscustomobject]@{ Label = $Label; Text = "$Label：剩余 $([Math]::Round($remaining))% · $resetText"; Remaining = $remaining; ResetAfterSeconds = $Window.reset_after_seconds }
}

function Get-TooltipText($FiveHour, $Weekly) {
    $shortFive = if ($null -eq $FiveHour.Remaining) { '—' } else { "剩 $([Math]::Round($FiveHour.Remaining))%" }
    $shortWeek = if ($null -eq $Weekly.Remaining) { '—' } else { "剩 $([Math]::Round($Weekly.Remaining))%" }
    $fiveReset = if ($FiveHour.ResetElapsed) { '等待刷新' } elseif ($null -eq $FiveHour.ResetAfterSeconds) { '重置未知' } else { "$(Format-Duration ([double]$FiveHour.ResetAfterSeconds))后重置" }
    $weekReset = if ($Weekly.ResetElapsed) { '等待刷新' } elseif ($null -eq $Weekly.ResetAfterSeconds) { '重置未知' } else { "$(Format-Duration ([double]$Weekly.ResetAfterSeconds))后重置" }
    return "Codex：5h $shortFive · $fiveReset | 周 $shortWeek · $weekReset"
}

function Set-ResetDeadline($Window) {
    $resetAtUtc = $null
    [double]$resetSeconds = 0
    if ($null -ne $Window.ResetAfterSeconds -and [double]::TryParse([string]$Window.ResetAfterSeconds, [ref]$resetSeconds) -and $resetSeconds -ge 0) {
        $resetAtUtc = [DateTime]::UtcNow.AddSeconds($resetSeconds)
    }
    $Window | Add-Member -NotePropertyName ResetAtUtc -NotePropertyValue $resetAtUtc -Force
    return $Window
}

function Get-LiveWindowDisplay($Snapshot) {
    $resetAfterSeconds = $null
    $resetElapsed = $false
    if ($null -ne $Snapshot.ResetAtUtc) {
        $resetAfterSeconds = ([datetime]$Snapshot.ResetAtUtc - [DateTime]::UtcNow).TotalSeconds
        if ($resetAfterSeconds -le 0) {
            $resetAfterSeconds = $null
            $resetElapsed = $true
        }
    }

    if ($null -eq $Snapshot.Remaining) {
        $text = $Snapshot.Text
    }
    else {
        $resetText = if ($resetElapsed) { '已到重置时间，等待刷新' } elseif ($null -eq $resetAfterSeconds) { '重置时间未知' } else { "$(Format-Duration $resetAfterSeconds) 后重置" }
        $text = "$($Snapshot.Label)：剩余 $([Math]::Round($Snapshot.Remaining))% · $resetText"
    }
    return [pscustomobject]@{ Text = $text; Remaining = $Snapshot.Remaining; ResetAfterSeconds = $resetAfterSeconds; ResetElapsed = $resetElapsed }
}

function Update-LocalQuotaDisplay {
    if (-not $script:hasQuotaSnapshot -or $null -eq $script:fiveHourSnapshot -or $null -eq $script:weeklySnapshot) { return }
    $fiveHour = Get-LiveWindowDisplay $script:fiveHourSnapshot
    $weekly = Get-LiveWindowDisplay $script:weeklySnapshot
    $fiveHourItem.Text = $fiveHour.Text
    $weeklyItem.Text = $weekly.Text
    $notify.Text = Get-TooltipText $fiveHour $weekly
    Set-IndicatorIcon (Get-IndicatorState $fiveHour.Remaining $weekly.Remaining $fiveHour.ResetAfterSeconds)
}

function Get-IndicatorState($FiveHourRemaining, $WeeklyRemaining, $ResetAfterSeconds) {
    $showPurple = $null -ne $ResetAfterSeconds -and [double]$ResetAfterSeconds -ge 0 -and [double]$ResetAfterSeconds -lt 1200
    if ($null -eq $FiveHourRemaining) {
        return [pscustomobject]@{ ActiveLights = 0; Color = [System.Drawing.Color]::DimGray; ShowPurple = $showPurple }
    }

    if ($null -ne $WeeklyRemaining -and $WeeklyRemaining -le 10 -and $FiveHourRemaining -le 25) {
        return [pscustomobject]@{ ActiveLights = 2; Color = [System.Drawing.Color]::Firebrick; ShowPurple = $showPurple }
    }

    if ($FiveHourRemaining -ge 100) {
        $activeLights = 4; $color = [System.Drawing.Color]::FromArgb(44, 154, 63)
    }
    elseif ($FiveHourRemaining -ge 75) {
        $activeLights = 3; $color = [System.Drawing.Color]::FromArgb(44, 154, 63)
    }
    elseif ($FiveHourRemaining -ge 50) {
        $activeLights = 2; $color = [System.Drawing.Color]::FromArgb(44, 154, 63)
    }
    elseif ($FiveHourRemaining -ge 25) {
        $activeLights = 1; $color = [System.Drawing.Color]::FromArgb(44, 154, 63)
    }
    elseif ($FiveHourRemaining -ge 10) {
        $activeLights = 1; $color = [System.Drawing.Color]::DarkOrange
    }
    else {
        $activeLights = 1; $color = [System.Drawing.Color]::Firebrick
    }

    return [pscustomobject]@{ ActiveLights = $activeLights; Color = $color; ShowPurple = $showPurple }
}

function Set-IndicatorIcon($State) {
    $bitmap = New-Object System.Drawing.Bitmap(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $offBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 70, 70))
    $onBrush = New-Object System.Drawing.SolidBrush($State.Color)
    $purpleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::MediumPurple)
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(30, 30, 30), 1)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $positions = @(@(3, 3), @(17, 3), @(3, 17), @(17, 17))
        for ($index = 0; $index -lt $positions.Count; $index++) {
            $position = $positions[$index]
            $brush = if ($index -lt $State.ActiveLights) { $onBrush } else { $offBrush }
            $graphics.FillEllipse($brush, $position[0], $position[1], 12, 12)
            $graphics.DrawEllipse($borderPen, $position[0], $position[1], 12, 12)
        }
        if ($State.ShowPurple) {
            $graphics.FillEllipse($purpleBrush, 13, 13, 6, 6)
        }
        $handle = $bitmap.GetHicon()
        $handleIcon = [System.Drawing.Icon]::FromHandle($handle)
        $replacement = $handleIcon.Clone()
        [void][TrayNativeMethods]::DestroyIcon($handle)
        if ($null -ne $script:generatedIcon) { $script:generatedIcon.Dispose() }
        $script:generatedIcon = $replacement
        $notify.Icon = $replacement
    }
    finally {
        $borderPen.Dispose(); $purpleBrush.Dispose(); $onBrush.Dispose(); $offBrush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    }
}

function Get-CodexDesktopState {
    $processIds = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -like '*\OpenAI.Codex_*\app\ChatGPT.exe' } |
        Select-Object -ExpandProperty ProcessId)
    if ($processIds.Count -eq 0) { return 'Stopped' }

    $foregroundWindow = [TrayNativeMethods]::GetForegroundWindow()
    if ($foregroundWindow -ne [IntPtr]::Zero) {
        [uint32]$foregroundProcessId = 0
        [void][TrayNativeMethods]::GetWindowThreadProcessId($foregroundWindow, [ref]$foregroundProcessId)
        if ($processIds -contains [int]$foregroundProcessId) { return 'Foreground' }
    }
    return 'Background'
}

function Get-RefreshDecision([string]$DesktopState, [string]$PreviousDesktopState, $LastQuotaAttempt, [datetime]$Now) {
    if ($DesktopState -eq 'Stopped') { return 'Pause' }
    if ($null -ne $LastQuotaAttempt -and ($Now - $LastQuotaAttempt).TotalMinutes -lt 5) { return 'Wait' }
    if ($PreviousDesktopState -eq 'Unknown' -or $PreviousDesktopState -eq 'Stopped') { return 'Refresh' }
    if ($DesktopState -eq 'Foreground' -and $PreviousDesktopState -ne 'Foreground') { return 'Refresh' }

    $intervalMinutes = if ($DesktopState -eq 'Foreground') { 5 } else { 15 }
    if ($null -eq $LastQuotaAttempt -or ($Now - $LastQuotaAttempt).TotalMinutes -ge $intervalMinutes) { return 'Refresh' }
    return 'Wait'
}

function Set-QuotaPausedDisplay {
    if (-not $script:hasQuotaSnapshot) {
        $fiveHourItem.Text = '5 小时：尚未读取'
        $weeklyItem.Text = '周额度：尚未读取'
        Set-IndicatorIcon (Get-IndicatorState $null $null $null)
    }
    $updatedItem.Text = 'Codex 未运行：已暂停刷新（保留上次额度）'
    $notify.Text = 'Codex 未运行：已暂停刷新'
}

function Set-QuotaFailureDisplay {
    $fiveHourItem.Text = '5 小时：无法读取'
    $weeklyItem.Text = '周额度：无法读取'
    $updatedItem.Text = '请确认 Codex 已登录，然后点击立即刷新'
    $notify.Text = 'Codex 额度：读取失败'
    Set-IndicatorIcon (Get-IndicatorState $null $null $null)
}

function Complete-QuotaRefresh {
    if ($null -eq $script:quotaRequestTask -or -not $script:quotaRequestTask.IsCompleted) { return }

    $response = $null
    try {
        $response = $script:quotaRequestTask.GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "用量服务返回 HTTP $([int]$response.StatusCode)；请重新登录 Codex 后重试。"
        }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $usage = $json | ConvertFrom-Json
        if ($null -eq $usage.rate_limit) { throw '用量服务未返回额度窗口。' }

        $fiveHour = Set-ResetDeadline (Get-WindowDisplay $usage.rate_limit.primary_window '5 小时')
        $weekly = Set-ResetDeadline (Get-WindowDisplay $usage.rate_limit.secondary_window '周额度')
        $script:fiveHourSnapshot = $fiveHour
        $script:weeklySnapshot = $weekly
        $script:hasQuotaSnapshot = $true
        $updatedItem.Text = "上次更新：$(Get-Date -Format 'HH:mm:ss')（前台 5 分钟 / 后台 15 分钟）"
        Update-LocalQuotaDisplay
        if ($RunOnce) { Write-Output "$($fiveHour.Text)`n$($weekly.Text)" }
    }
    catch {
        Set-QuotaFailureDisplay
        if ($RunOnce) { $script:runOnceError = $_ }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $script:quotaRequestMessage) { $script:quotaRequestMessage.Dispose() }
        $script:quotaRequestTask = $null
        $script:quotaRequestMessage = $null
        if ($null -ne $completionTimer) { $completionTimer.Stop() }
    }
}

function Update-Quota {
    if ($null -ne $script:quotaRequestTask) { return }
    try {
        $authPath = Join-Path $HOME '.codex\auth.json'
        if (-not (Test-Path -LiteralPath $authPath)) { throw '未找到 .codex\auth.json；请先在 Codex 登录。' }
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
        $token = $auth.tokens.access_token
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Codex 登录信息不完整；请重新登录。' }

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $usageUrl)
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        [void]$request.Headers.TryAddWithoutValidation('OpenAI-Beta', 'codex-1')
        [void]$request.Headers.TryAddWithoutValidation('originator', 'Codex Desktop')
        if (-not [string]::IsNullOrWhiteSpace($auth.tokens.account_id)) {
            [void]$request.Headers.TryAddWithoutValidation('ChatGPT-Account-ID', [string]$auth.tokens.account_id)
        }
        $script:quotaRequestMessage = $request
        $script:quotaRequestTask = $script:httpClient.SendAsync($request)
        $completionTimer.Start()
    }
    catch {
        if ($null -ne $script:quotaRequestMessage) { $script:quotaRequestMessage.Dispose() }
        $script:quotaRequestMessage = $null
        $script:quotaRequestTask = $null
        Set-QuotaFailureDisplay
        if ($RunOnce) { $script:runOnceError = $_ }
    }
}

function Invoke-QuotaRefresh([string]$DesktopState) {
    if ($DesktopState -eq 'Stopped') {
        Set-QuotaPausedDisplay
        return
    }
    if ($null -ne $script:quotaRequestTask) { return }
    $script:lastQuotaAttempt = Get-Date
    Update-Quota
}

function Update-RefreshSchedule {
    Update-LocalQuotaDisplay
    $desktopState = Get-CodexDesktopState
    $decision = Get-RefreshDecision $desktopState $script:lastDesktopState $script:lastQuotaAttempt (Get-Date)
    if ($decision -eq 'Pause') {
        Set-QuotaPausedDisplay
    }
    elseif ($decision -eq 'Refresh') {
        Invoke-QuotaRefresh $desktopState
    }
    $script:lastDesktopState = $desktopState
}

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem('立即刷新')
$refreshItem.Add_Click({
    $desktopState = Get-CodexDesktopState
    $script:lastDesktopState = $desktopState
    Invoke-QuotaRefresh $desktopState
})
$openItem = New-Object System.Windows.Forms.ToolStripMenuItem('打开 Codex 用量页面')
$openItem.Add_Click({ Start-Process 'https://chatgpt.com/codex/settings/usage' })
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
$exitItem.Add_Click({
    $timer.Stop()
    $completionTimer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    if ($null -ne $script:generatedIcon) { $script:generatedIcon.Dispose() }
    if ($null -ne $script:quotaRequestMessage) { $script:quotaRequestMessage.Dispose() }
    $script:httpClient.Dispose()
    if ($null -ne $script:singleInstanceMutex) { $script:singleInstanceMutex.Dispose() }
    [System.Windows.Forms.Application]::Exit()
})
[void]$menu.Items.Add($refreshItem)
[void]$menu.Items.Add($openItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($exitItem)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-RefreshSchedule })
$completionTimer = New-Object System.Windows.Forms.Timer
$completionTimer.Interval = 200
$completionTimer.Add_Tick({ Complete-QuotaRefresh })
Update-RefreshSchedule

if ($RunOnce) {
    while ($null -ne $script:quotaRequestTask) {
        [System.Windows.Forms.Application]::DoEvents()
        Complete-QuotaRefresh
        Start-Sleep -Milliseconds 20
    }
    $notify.Visible = $false
    $notify.Dispose()
    if ($null -ne $script:generatedIcon) { $script:generatedIcon.Dispose() }
    $completionTimer.Dispose()
    $script:httpClient.Dispose()
    if ($null -ne $script:runOnceError) { throw $script:runOnceError }
    exit 0
}

$timer.Start()
[System.Windows.Forms.Application]::Run()
