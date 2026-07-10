using System.Diagnostics;
using System.Drawing;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace CodexQuotaIndicator;

internal static class Program
{
    private const string InstanceMutexName = "Local\\CodexQuotaIndicator";

    [STAThread]
    private static void Main()
    {
        using var singleInstanceMutex = new Mutex(true, InstanceMutexName, out var createdNew);
        if (!createdNew)
        {
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new QuotaTrayContext());
    }
}

internal sealed class QuotaTrayContext : ApplicationContext
{
    private const string UsageUrl = "https://chatgpt.com/backend-api/wham/usage";
    private static readonly HttpClient HttpClient = new() { Timeout = TimeSpan.FromSeconds(20) };

    private readonly ToolStripMenuItem _fiveHourItem = new("5 小时：读取中…") { Enabled = false };
    private readonly ToolStripMenuItem _weeklyItem = new("周额度：读取中…") { Enabled = false };
    private readonly ToolStripMenuItem _updatedItem = new("上次更新：尚未更新") { Enabled = false };
    private readonly NotifyIcon _notifyIcon;
    private readonly System.Windows.Forms.Timer _stateTimer = new() { Interval = 60 * 1000 };
    private Icon? _generatedIcon;
    private bool _refreshInProgress;
    private bool _hasQuotaSnapshot;
    private DateTime? _lastQuotaAttempt;
    private DesktopState _lastDesktopState = DesktopState.Unknown;

    public QuotaTrayContext()
    {
        var menu = new ContextMenuStrip();
        menu.Items.AddRange([
            _fiveHourItem,
            _weeklyItem,
            _updatedItem,
            new ToolStripSeparator(),
            new ToolStripMenuItem("立即刷新", null, async (_, _) => await RefreshNowAsync()),
            new ToolStripMenuItem("打开 Codex 用量页面", null, (_, _) => OpenUsageDashboard()),
            new ToolStripSeparator(),
            new ToolStripMenuItem("退出", null, (_, _) => ExitThread())
        ]);

        _notifyIcon = new NotifyIcon
        {
            ContextMenuStrip = menu,
            Icon = SystemIcons.Information,
            Text = "Codex 额度：读取中…",
            Visible = true
        };
        _notifyIcon.MouseUp += OnNotifyIconMouseUp;

        _stateTimer.Tick += async (_, _) => await UpdateRefreshScheduleAsync();
        _stateTimer.Start();
        _ = UpdateRefreshScheduleAsync();
    }

    private void OnNotifyIconMouseUp(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            _notifyIcon.ContextMenuStrip?.Show(Cursor.Position);
        }
    }

    private async Task RefreshNowAsync()
    {
        var desktopState = GetCodexDesktopState();
        _lastDesktopState = desktopState;
        if (desktopState == DesktopState.Stopped)
        {
            SetQuotaPausedDisplay();
            return;
        }

        await RefreshQuotaAsync();
    }

    private async Task UpdateRefreshScheduleAsync()
    {
        var desktopState = GetCodexDesktopState();
        if (ShouldRefresh(desktopState, _lastDesktopState, _lastQuotaAttempt))
        {
            await RefreshQuotaAsync();
        }
        else if (desktopState == DesktopState.Stopped)
        {
            SetQuotaPausedDisplay();
        }

        _lastDesktopState = desktopState;
    }

    private async Task RefreshQuotaAsync()
    {
        if (_refreshInProgress)
        {
            return;
        }

        _refreshInProgress = true;
        _lastQuotaAttempt = DateTime.Now;
        try
        {
            var quota = await GetQuotaAsync();
            UpdateQuotaDisplay(quota);
        }
        catch (Exception exception)
        {
            var message = exception.Message.Length > 60 ? exception.Message[..60] + "…" : exception.Message;
            _fiveHourItem.Text = "5 小时：无法读取";
            _weeklyItem.Text = "周额度：无法读取";
            _updatedItem.Text = "请确认 Codex 已登录，然后点击立即刷新";
            _notifyIcon.Text = $"Codex 额度：{message}";
            SetIndicatorIcon(new IndicatorState(0, Color.DimGray, false));
        }
        finally
        {
            _refreshInProgress = false;
        }
    }

    private static bool ShouldRefresh(DesktopState desktopState, DesktopState previousDesktopState, DateTime? lastQuotaAttempt)
    {
        if (desktopState == DesktopState.Stopped)
        {
            return false;
        }

        if (previousDesktopState is DesktopState.Unknown or DesktopState.Stopped ||
            desktopState == DesktopState.Foreground && previousDesktopState != DesktopState.Foreground)
        {
            return true;
        }

        if (lastQuotaAttempt is null)
        {
            return true;
        }

        var interval = desktopState == DesktopState.Foreground ? TimeSpan.FromMinutes(5) : TimeSpan.FromMinutes(15);
        return DateTime.Now - lastQuotaAttempt.Value >= interval;
    }

    private void SetQuotaPausedDisplay()
    {
        if (!_hasQuotaSnapshot)
        {
            _fiveHourItem.Text = "5 小时：尚未读取";
            _weeklyItem.Text = "周额度：尚未读取";
            SetIndicatorIcon(new IndicatorState(0, Color.DimGray, false));
        }

        _updatedItem.Text = "Codex 未运行：已暂停刷新（保留上次额度）";
        _notifyIcon.Text = "Codex 未运行：已暂停刷新";
    }

    private static async Task<QuotaSnapshot> GetQuotaAsync()
    {
        var authPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "auth.json");
        if (!File.Exists(authPath))
        {
            throw new InvalidOperationException("未找到 .codex\\auth.json；请先在 Codex 登录。");
        }

        using var authDocument = JsonDocument.Parse(await File.ReadAllTextAsync(authPath));
        var tokens = authDocument.RootElement.TryGetProperty("tokens", out var tokenElement)
            ? tokenElement
            : throw new InvalidOperationException("Codex 登录信息格式不完整。");
        var accessToken = GetRequiredString(tokens, "access_token");
        var accountId = GetOptionalString(tokens, "account_id");

        using var request = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        request.Headers.TryAddWithoutValidation("OpenAI-Beta", "codex-1");
        request.Headers.TryAddWithoutValidation("originator", "Codex Desktop");
        if (!string.IsNullOrWhiteSpace(accountId))
        {
            request.Headers.TryAddWithoutValidation("ChatGPT-Account-ID", accountId);
        }

        using var response = await HttpClient.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"用量服务返回 HTTP {(int)response.StatusCode}；请重新登录 Codex 后重试。");
        }

        using var usageDocument = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = usageDocument.RootElement;
        if (!root.TryGetProperty("rate_limit", out var rateLimit))
        {
            throw new InvalidOperationException("用量服务未返回额度窗口。");
        }

        return new QuotaSnapshot(
            ReadWindow(rateLimit, "primary_window", "5 小时"),
            ReadWindow(rateLimit, "secondary_window", "周额度"));
    }

    private static QuotaWindow ReadWindow(JsonElement rateLimit, string propertyName, string label)
    {
        if (!rateLimit.TryGetProperty(propertyName, out var window) || window.ValueKind == JsonValueKind.Null)
        {
            return new QuotaWindow(label, null, null);
        }

        var usedPercent = window.TryGetProperty("used_percent", out var usedElement) && usedElement.TryGetDouble(out var used)
            ? Math.Clamp(used, 0, 100)
            : (double?)null;
        var resetAfterSeconds = window.TryGetProperty("reset_after_seconds", out var resetElement) && resetElement.TryGetDouble(out var seconds)
            ? Math.Max(0, seconds)
            : (double?)null;
        return new QuotaWindow(label, usedPercent, resetAfterSeconds);
    }

    private void UpdateQuotaDisplay(QuotaSnapshot quota)
    {
        _fiveHourItem.Text = FormatWindow(quota.FiveHour);
        _weeklyItem.Text = FormatWindow(quota.Weekly);
        _updatedItem.Text = $"上次更新：{DateTime.Now:HH:mm:ss}（前台 5 分钟 / 后台 15 分钟）";

        var fiveHourLeft = quota.FiveHour.RemainingPercent;
        var weeklyLeft = quota.Weekly.RemainingPercent;
        _notifyIcon.Text = $"Codex：5h {FormatShortPercent(fiveHourLeft)} | 周 {FormatShortPercent(weeklyLeft)}";
        SetIndicatorIcon(GetIndicatorState(fiveHourLeft, weeklyLeft, quota.FiveHour.ResetAfterSeconds));
        _hasQuotaSnapshot = true;
    }

    private static DesktopState GetCodexDesktopState()
    {
        var processIds = Process.GetProcessesByName("ChatGPT")
            .Where(IsCodexDesktopProcess)
            .Select(process => process.Id)
            .ToHashSet();
        if (processIds.Count == 0)
        {
            return DesktopState.Stopped;
        }

        var foregroundWindow = GetForegroundWindow();
        GetWindowThreadProcessId(foregroundWindow, out var foregroundProcessId);
        return processIds.Contains((int)foregroundProcessId) ? DesktopState.Foreground : DesktopState.Background;
    }

    private static bool IsCodexDesktopProcess(Process process)
    {
        try
        {
            var path = process.MainModule?.FileName;
            return path is not null &&
                path.Contains("\\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) &&
                path.EndsWith("\\app\\ChatGPT.exe", StringComparison.OrdinalIgnoreCase);
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    private static string FormatWindow(QuotaWindow window)
    {
        if (window.RemainingPercent is null)
        {
            return $"{window.Label}：当前套餐未提供此窗口";
        }

        var reset = window.ResetAfterSeconds is null ? "重置时间未知" : $"{FormatDuration(window.ResetAfterSeconds.Value)} 后重置";
        return $"{window.Label}：剩余 {window.RemainingPercent.Value:0}% · {reset}";
    }

    private static string FormatShortPercent(double? value) => value is null ? "—" : $"剩 {value.Value:0}%";

    private static string FormatDuration(double seconds)
    {
        var duration = TimeSpan.FromSeconds(seconds);
        if (duration.TotalDays >= 1)
        {
            return $"{(int)duration.TotalDays}天{duration.Hours}小时";
        }

        if (duration.TotalHours >= 1)
        {
            return $"{(int)duration.TotalHours}小时{duration.Minutes}分";
        }

        return $"{Math.Max(1, duration.Minutes)}分";
    }

    private static IndicatorState GetIndicatorState(double? fiveHourRemaining, double? weeklyRemaining, double? resetAfterSeconds)
    {
        var showPurple = resetAfterSeconds is >= 0 and < 1200;
        if (fiveHourRemaining is null)
        {
            return new IndicatorState(0, Color.DimGray, showPurple);
        }

        if (weeklyRemaining <= 10 && fiveHourRemaining <= 25)
        {
            return new IndicatorState(2, Color.Firebrick, showPurple);
        }

        var (activeLights, color) = fiveHourRemaining switch
        {
            >= 100 => (4, Color.FromArgb(44, 154, 63)),
            >= 75 => (3, Color.FromArgb(44, 154, 63)),
            >= 50 => (2, Color.FromArgb(44, 154, 63)),
            >= 25 => (1, Color.FromArgb(44, 154, 63)),
            >= 10 => (1, Color.DarkOrange),
            _ => (1, Color.Firebrick)
        };
        return new IndicatorState(activeLights, color, showPurple);
    }

    private void SetIndicatorIcon(IndicatorState state)
    {
        using var bitmap = new Bitmap(32, 32);
        using (var graphics = Graphics.FromImage(bitmap))
        using (var offBrush = new SolidBrush(Color.FromArgb(70, 70, 70)))
        using (var onBrush = new SolidBrush(state.Color))
        using (var purpleBrush = new SolidBrush(Color.MediumPurple))
        using (var borderPen = new Pen(Color.FromArgb(30, 30, 30), 1))
        {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            Point[] positions = [new(3, 3), new(17, 3), new(3, 17), new(17, 17)];
            for (var index = 0; index < positions.Length; index++)
            {
                var brush = index < state.ActiveLights ? onBrush : offBrush;
                graphics.FillEllipse(brush, positions[index].X, positions[index].Y, 12, 12);
                graphics.DrawEllipse(borderPen, positions[index].X, positions[index].Y, 12, 12);
            }

            if (state.ShowPurple)
            {
                graphics.FillEllipse(purpleBrush, 13, 13, 6, 6);
            }
        }

        var handle = bitmap.GetHicon();
        using var handleIcon = Icon.FromHandle(handle);
        var replacement = (Icon)handleIcon.Clone();
        DestroyIcon(handle);
        _generatedIcon?.Dispose();
        _generatedIcon = replacement;
        _notifyIcon.Icon = replacement;
    }

    private static string GetRequiredString(JsonElement element, string propertyName) =>
        GetOptionalString(element, propertyName) ?? throw new InvalidOperationException($"Codex 登录信息缺少 {propertyName}。");

    private static string? GetOptionalString(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;

    private void OpenUsageDashboard()
    {
        Process.Start(new ProcessStartInfo("https://chatgpt.com/codex/settings/usage") { UseShellExecute = true });
    }

    protected override void ExitThreadCore()
    {
        _stateTimer.Stop();
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _generatedIcon?.Dispose();
        base.ExitThreadCore();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}

internal sealed record QuotaSnapshot(QuotaWindow FiveHour, QuotaWindow Weekly);

internal sealed record QuotaWindow(string Label, double? UsedPercent, double? ResetAfterSeconds)
{
    public double? RemainingPercent => UsedPercent is null ? null : 100 - UsedPercent.Value;
}

internal sealed record IndicatorState(int ActiveLights, Color Color, bool ShowPurple);

internal enum DesktopState
{
    Unknown,
    Stopped,
    Background,
    Foreground
}
