# Codex Quota Indicator

在 Windows 托盘图标中同时查看个人和公司 Codex 工作空间的 5 小时与 7 天剩余额度。

## 快速开始

1. 下载或克隆仓库，保留同一目录中的 `启动额度指示器.vbs` 和 `CodexQuotaIndicator.ps1`。
2. 确认个人和公司环境已分别登录，并有各自的 `auth.json`。默认位置见[登录目录](#登录目录)。单个账户未登录时，另一个账户仍可显示额度。
3. 双击 `启动额度指示器.vbs`。需要代理时，请按 [HTTP 代理](#http-代理)一节从 PowerShell 启动。主入口使用 Windows PowerShell 5.1，无需安装 .NET SDK。

## 托盘显示

| 位置 | 左侧 | 右侧 |
| --- | --- | --- |
| 上行：个人 | 5 小时剩余额度 | 7 天剩余额度 |
| 下行：公司 | 5 小时剩余额度 | 7 天剩余额度 |

比如个人剩余 `100% / 100%`，公司剩余 `25% / 30%`，托盘图标显示：

```text
F · F
2 · 3
```

`F` 表示恰好剩余 100%。其余值取剩余百分比的十位，低于 10% 显示 `0`，缺失显示 `-`。图标使用白色像素字形和透明背景，包含 16×16 和 20×20 布局。

悬停可查看剩余百分比和重置倒计时。`m`、`h`、`d` 分别表示分钟、小时和天，`due` 表示已到重置时间并等待刷新，`?` 表示重置时间未知。悬停文案在 WinForms 的 63 字符上限内，空间不足时省略时段标签，并用 `~%` 标记缩写的小数。右键菜单显示完整百分比、本地重置时间和账户状态，也可立即刷新、打开官方用量页面或退出。

## 自动刷新

| Codex App 状态 | 查询间隔 |
| --- | --- |
| 前台 | 5 分钟 |
| 后台 | 15 分钟 |
| 已关闭 | 暂停自动查询 |

切回前台时，距上次查询已满 5 分钟的账户会在下次检查时刷新，通常在 1 分钟内。倒计时每分钟在本地更新。查询失败时保留该账户的上次成功值并标记为旧值，另一个账户继续独立更新。

## 登录目录

每个账户读取对应目录中的 `auth.json`：

| 环境 | 默认目录 | 可选环境变量 | 脚本参数 |
| --- | --- | --- | --- |
| 个人 | `%USERPROFILE%\.codex` | `CODEX_QUOTA_PERSONAL_HOME` | `-PersonalHome` |
| 公司 | `%LOCALAPPDATA%\OpenAI\Codex-Company` | `CODEX_QUOTA_COMPANY_HOME` | `-CompanyHome` |

自定义时填入存放 `auth.json` 的目录。脚本参数优先于对应的环境变量，默认目录独立于启动环境中的 `CODEX_HOME`。请为两套登录指定各自的实际目录。

例如，仅对当前 PowerShell 进程及其子进程指定目录：

```powershell
$env:CODEX_QUOTA_PERSONAL_HOME = Join-Path $env:USERPROFILE '.codex'
$env:CODEX_QUOTA_COMPANY_HOME = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex-Company'
wscript.exe '.\启动额度指示器.vbs'
```

也可直接传入 `-PersonalHome 'D:\Profiles\Personal' -CompanyHome 'D:\Profiles\Company'`。工具不会修改登录文件或认证环境，不会把缺失或失效的账户回退到另一个账户。

Codex App 切换空间时可能覆盖个人目录中的登录态。工具会核对令牌及用量响应的空间类型，避免把公司额度显示到个人行。在个人空间点击“立即刷新”一次后，工具会用 Windows DPAPI（当前 Windows 用户）加密缓存个人访问令牌；切到同一用户的公司空间后，仍可单独查询个人额度，重启指示器后也可继续使用。

个人和公司都支持自动续期。在指示器右键菜单分别点击“连接个人自动续期…”和“连接公司自动续期…”，在浏览器为对应空间各完成一次授权。也可运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaIndicator.ps1 -ConnectPersonal` 或 `-ConnectCompany`，每次连接一个空间。已有授权或对应登录目录用于限定空间与用户。完成后，无需再切换 Codex 空间或手动刷新登录态；升级前已连接的个人授权可继续使用。

两行分别绑定授权时选定的个人、公司空间。同一用户切换个人、公司或其他公司空间时，两行仍显示各自绑定空间的额度，不随当前选择串用；重启后也会恢复各自授权。公司行固定显示已授权的公司，并不自动改为其他公司。若需要监控另一家公司，使用独立的 `-CompanyHome` 登录目录并为其连接授权。切换到不同用户时，不使用原用户的独立授权或旧额度；切换回来后可恢复。异步续期过程中切换用户时，已成功轮换的凭据仍会保存，但不会更新新用户的显示。

指示器为两行分别使用独立的 OAuth 授权，刷新令牌由它单独管理，不复制或轮换 Codex 正在使用的刷新令牌，不修改 Codex 登录文件。访问令牌临近到期时，在下一次额度查询前自动续期；收到认证拒绝时续期并重试一次。刷新后的令牌以 Windows DPAPI 加密保存，各自的跨进程锁避免重复消费同一个刷新令牌；一行网络错误不会阻塞另一行。网络错误稍后重试，授权撤销后提示重新连接。

缓存位于 `%LOCALAPPDATA%\CodexQuotaIndicator`。`personal-*.dpapi` 是原有的个人访问令牌缓存，`personal-session-*.dpapi` 和 `company-session-*.dpapi` 分别保存两行独立授权的访问和刷新令牌，均绑定当前 Windows 用户。未连接自动续期时，原有登录态到期后仍需在对应环境重新登录。用户不匹配或授权失效时，不会使用另一空间的额度。`-StateDirectory` 可指定隔离的缓存目录，用于测试。

## HTTP 代理

两个账户共用代理选择规则：`-Proxy` 参数优先，其次是进程继承的 `HTTPS_PROXY`；均未设置时使用 .NET/Windows 默认代理行为。已配置的代理会显式设置到每个 `HttpClientHandler.Proxy`，禁用本地地址绕过；代理失败会报告失败，不会重试直连。无效或显式为空的 `-Proxy` 会报告配置错误。

将下面的示例地址换成你的 HTTP 代理地址，并在同一 PowerShell 窗口启动：

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:8080'
wscript.exe '.\启动额度指示器.vbs'
```

请从设置变量的同一 PowerShell 会话启动 VBS。资源管理器双击只会继承资源管理器已有的环境；若使用 Windows 用户环境变量，需要让启动进程重新获取环境并重启工具。已有实例不会动态读取新的环境变量。

单次验证也可直接覆盖代理：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaIndicator.ps1 -RunOnce -Proxy http://127.0.0.1:8080
```

代理地址支持 HTTP/HTTPS URI，不接受内嵌用户名、密码、路径、查询或片段。无需新增设置文件，也无需修改 VBS；仓库未设置任何机器专用代理默认值。

## 无界面集成验证

`-RunOnce` 不创建托盘图标、菜单或消息循环，也不检查 Codex 是否在前台或运行。它读取两个登录目录，完成一轮查询后输出一个 JSON 对象：`profiles` 包含 `personal`、`company`，每个都包含 `status`、`fiveHour` 和 `sevenDay`。

每个窗口输出 `remainingPercent`、UTC 重置时间、剩余秒数、是否到期、旧值标记及窗口状态。不可用值为 JSON `null`，不会伪装成 0。账户错误使用固定状态码，例如 `missing-auth`、`unauthorized`、`offline`、`timeout`、`proxy-config`；输出不包含登录标识、文件路径、令牌或原始服务错误响应。

两个账户的四个额度均有效时退出码为 0；任何账户或窗口不可用时为 1，同时仍输出另一个账户的结果。包含续期时，网络等待上限约 55 秒，退出取消收尾最多额外等待 2 秒；本地认证文件读取不属于网络超时范围。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaIndicator.ps1 -RunOnce
$LASTEXITCODE
```

## 可选 C# 入口：历史版本

`Program.cs` 是历史 C# WinForms 实现，使用原来的四点图标。双账户数字显示使用 VBS/PowerShell 主入口。

原有项目需要 .NET 8 SDK，可用以下命令构建：

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -o publish
```

## 数据与隐私

工具读取指定目录内现有的 Codex 登录态，并沿用第一方 `https://chatgpt.com/backend-api/wham/usage` 请求及认证头。连接自动续期时，只向 `https://auth.openai.com` 发起独立的 PKCE 授权与令牌续期。两行访问令牌及独立授权的刷新令牌仅以 Windows DPAPI 加密保存；不复制 Codex 刷新令牌，不写回 Codex 认证文件，不在日志或输出中记录令牌，不显示原始错误响应。配置代理时，额度及续期请求均经该代理传输。

该用量接口可能变化。遇到登录失效或响应格式变化，请通过菜单打开官方 Usage 页面核对，并在对应环境重新登录。
