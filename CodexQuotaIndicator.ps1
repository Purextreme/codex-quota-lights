param(
    [switch]$RunOnce
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
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

function Format-Duration([double]$Seconds) {
    $duration = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    if ($duration.TotalDays -ge 1) { return "{0}天{1}小时" -f [int]$duration.TotalDays, $duration.Hours }
    if ($duration.TotalHours -ge 1) { return "{0}小时{1}分" -f [int]$duration.TotalHours, $duration.Minutes }
    return "{0}分" -f [Math]::Max(1, $duration.Minutes)
}

function Get-WindowDisplay($Window, [string]$Label) {
    if ($null -eq $Window) {
        return [pscustomobject]@{ Text = "$Label：当前套餐未提供此窗口"; Remaining = $null; ResetAfterSeconds = $null }
    }

    $used = [Math]::Min(100, [Math]::Max(0, [double]$Window.used_percent))
    $remaining = 100 - $used
    $resetText = if ($null -eq $Window.reset_after_seconds) { '重置时间未知' } else { "$(Format-Duration ([double]$Window.reset_after_seconds)) 后重置" }
    return [pscustomobject]@{ Text = "$Label：剩余 $([Math]::Round($remaining))% · $resetText"; Remaining = $remaining; ResetAfterSeconds = $Window.reset_after_seconds }
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
        $activeLights = 4; $color = [System.Drawing.Color]::FromArgb(34, 139, 34)
    }
    elseif ($FiveHourRemaining -ge 75) {
        $activeLights = 3; $color = [System.Drawing.Color]::FromArgb(34, 139, 34)
    }
    elseif ($FiveHourRemaining -ge 50) {
        $activeLights = 2; $color = [System.Drawing.Color]::FromArgb(34, 139, 34)
    }
    elseif ($FiveHourRemaining -ge 25) {
        $activeLights = 1; $color = [System.Drawing.Color]::FromArgb(34, 139, 34)
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

function Update-Quota {
    try {
        $authPath = Join-Path $HOME '.codex\auth.json'
        if (-not (Test-Path -LiteralPath $authPath)) { throw '未找到 .codex\auth.json；请先在 Codex 登录。' }
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
        $token = $auth.tokens.access_token
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Codex 登录信息不完整；请重新登录。' }

        $headers = @{ Authorization = "Bearer $token"; 'OpenAI-Beta' = 'codex-1'; originator = 'Codex Desktop' }
        if (-not [string]::IsNullOrWhiteSpace($auth.tokens.account_id)) { $headers['ChatGPT-Account-ID'] = $auth.tokens.account_id }
        $usage = Invoke-RestMethod -Uri $usageUrl -Headers $headers -TimeoutSec 20
        if ($null -eq $usage.rate_limit) { throw '用量服务未返回额度窗口。' }

        $fiveHour = Get-WindowDisplay $usage.rate_limit.primary_window '5 小时'
        $weekly = Get-WindowDisplay $usage.rate_limit.secondary_window '周额度'
        $fiveHourItem.Text = $fiveHour.Text
        $weeklyItem.Text = $weekly.Text
        $updatedItem.Text = "上次更新：$(Get-Date -Format 'HH:mm:ss')（前台 5 分钟 / 后台 15 分钟）"
        $shortFive = if ($null -eq $fiveHour.Remaining) { '—' } else { "剩 $([Math]::Round($fiveHour.Remaining))%" }
        $shortWeek = if ($null -eq $weekly.Remaining) { '—' } else { "剩 $([Math]::Round($weekly.Remaining))%" }
        $notify.Text = "Codex：5h $shortFive | 周 $shortWeek"
        Set-IndicatorIcon (Get-IndicatorState $fiveHour.Remaining $weekly.Remaining $fiveHour.ResetAfterSeconds)
        $script:hasQuotaSnapshot = $true
        if ($RunOnce) { Write-Output "$($fiveHour.Text)`n$($weekly.Text)" }
    }
    catch {
        $fiveHourItem.Text = '5 小时：无法读取'
        $weeklyItem.Text = '周额度：无法读取'
        $updatedItem.Text = '请确认 Codex 已登录，然后点击立即刷新'
        $notify.Text = 'Codex 额度：读取失败'
        Set-IndicatorIcon (Get-IndicatorState $null $null $null)
        if ($RunOnce) { throw }
    }
}

function Invoke-QuotaRefresh([string]$DesktopState) {
    if ($DesktopState -eq 'Stopped') {
        Set-QuotaPausedDisplay
        return
    }
    $script:lastQuotaAttempt = Get-Date
    Update-Quota
}

function Update-RefreshSchedule {
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
    $notify.Visible = $false
    $notify.Dispose()
    if ($null -ne $script:generatedIcon) { $script:generatedIcon.Dispose() }
    [System.Windows.Forms.Application]::Exit()
})
[void]$menu.Items.Add($refreshItem)
[void]$menu.Items.Add($openItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($exitItem)

$notify.Add_MouseUp({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $menu.Show([System.Windows.Forms.Cursor]::Position) }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60000
$timer.Add_Tick({ Update-RefreshSchedule })
Update-RefreshSchedule

if ($RunOnce) {
    $notify.Visible = $false
    $notify.Dispose()
    if ($null -ne $script:generatedIcon) { $script:generatedIcon.Dispose() }
    exit 0
}

$timer.Start()
[System.Windows.Forms.Application]::Run()
