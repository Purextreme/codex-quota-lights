param([Parameter(Mandatory)][string]$ScriptPath)
$ErrorActionPreference = 'Stop'
$file = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Script parse failed.' }
$entry = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -eq '$exitCode = 0' })
if ($entry.Count -ne 1) { throw 'Startup boundary missing.' }
. ([scriptblock]::Create([IO.File]::ReadAllText($file).Substring(0, $entry[0].Extent.StartOffset)))
$root = Join-Path $PSScriptRoot ('fixtures-' + [Guid]::NewGuid().ToString('N'))
$personalHome = Join-Path $root 'personal'
$companyHome = Join-Path $root 'company'
$StateDirectory = Join-Path $root 'state'
[void][IO.Directory]::CreateDirectory($personalHome)
[void][IO.Directory]::CreateDirectory($companyHome)
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Token([string]$Plan, [string]$Account, [string]$User = 'user-a', [int]$Seconds = 3600) {
    $payload = @{ exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $Seconds
        'https://api.openai.com/auth' = @{ chatgpt_plan_type=$Plan; chatgpt_account_id=$Account; chatgpt_user_id=$User } } | ConvertTo-Json -Compress
    $part = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')
    return 'eyJhbGciOiJub25lIn0.' + $part + '.fixture'
}
function Write-Auth([string]$AuthDirectory, [string]$Access, [string]$Account) {
    $json = @{ tokens = @{access_token=$Access; account_id=$Account; refresh_token='fixture-refresh-must-not-be-cached'} } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $AuthDirectory 'auth.json'), $json, [Text.UTF8Encoding]::new($false))
}
function New-Profiles {
    $script:profiles = @((New-QuotaProfile 'personal' 'Personal' $personalHome $personalHome),
        (New-QuotaProfile 'company' 'Company' $companyHome $companyHome))
}
function Reply($Profile, [string]$Plan, [int]$Used = 75, [int]$Generation = -1) {
    $body = @{ plan_type=$Plan; rate_limit=@{primary_window=@{used_percent=$Used;reset_after_seconds=3600};secondary_window=@{used_percent=$Used;reset_after_seconds=60000}} } | ConvertTo-Json -Depth 6
    $source = [Threading.Tasks.TaskCompletionSource[QuotaReply]]::new()
    $source.SetResult([QuotaReply]::new('ok', $body))
    $Profile.Pending = $source.Task
    $Profile.RequestGeneration = if ($Generation -lt 0) { $Profile.Generation } else { $Generation }
    Complete-QuotaRefresh
}
try {
    $personal = Token 'plus' 'personal-a'
    $company = Token 'team' 'company-a'
    Write-Auth $personalHome $personal 'personal-a'
    Write-Auth $companyHome $company 'company-a'
    New-Profiles
    Sync-QuotaCredentials
    Assert ($profiles[0].Credential.Account -eq 'personal-a' -and $profiles[1].Credential.Account -eq 'company-a') 'Initial workspaces must be separate.'
    $cache = Get-PersonalCachePath $profiles[0]
    Assert ([IO.File]::Exists($cache)) 'Personal login must be saved for workspace switches.'
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($cache), $null, 'CurrentUser')
    Assert ([Text.Encoding]::UTF8.GetString($bytes) -ceq $personal) 'Cache must contain access token only.'
    [Array]::Clear($bytes, 0, $bytes.Length)
    Assert (-not [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($cache)).Contains($personal)) 'Cache must be encrypted.'
    Reply $profiles[0] 'plus' 75
    Reply $profiles[1] 'team' 4
    $generation = $profiles[0].Generation
    Write-Auth $personalHome $company 'company-a'
    $before = (Get-FileHash -LiteralPath $profiles[0].AuthPath -Algorithm SHA256).Hash
    Sync-QuotaCredentials
    Assert ($profiles[0].Credential.Cached -and $profiles[0].Credential.Account -eq 'personal-a') 'Switching to company must retain the personal credential.'
    Assert ($profiles[0].Generation -eq $generation -and $profiles[0].Five.Remaining -eq 25) 'Workspace switch must not substitute company quota.'
    Assert ($profiles[1].Credential.Account -eq 'company-a') 'Company must remain independent.'
    Assert ((Get-FileHash -LiteralPath $profiles[0].AuthPath -Algorithm SHA256).Hash -ceq $before) 'Authentication source must remain unchanged.'
    New-Profiles
    Sync-QuotaCredentials
    Assert ($profiles[0].Credential.Cached -and $profiles[0].Credential.Account -eq 'personal-a') 'Restart in company workspace must recover personal login.'
    Reply $profiles[0] 'plus' 75
    Assert ($profiles[0].Status -eq 'ok' -and $profiles[0].Five.Remaining -eq 25) 'Personal response must still update after switching.'
    Reply $profiles[0] 'team' 4
    Assert ($profiles[0].Status -eq 'workspace-mismatch' -and $null -eq $profiles[0].Five.Remaining) 'Wrong workspace response must clear quota.'
    Reply $profiles[0] 'plus' 75 ($profiles[0].Generation - 1)
    Assert ($null -eq $profiles[0].Five.Remaining) 'Stale request generation must not restore quota.'
    Write-Auth $personalHome (Token 'team' 'company-b' 'user-b') 'company-b'
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Credential -and $profiles[0].Status -eq 'workspace-login-needed') 'Different user must not reuse personal cache.'
    Write-Auth $personalHome $company 'company-a'
    [IO.File]::Delete($cache)
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Credential -and (Get-IndicatorState $profiles[0].Five.Remaining) -eq '-') 'No personal login must show unavailable instead of company quota.'
    Assert ($null -ne $profiles[1].Credential) 'Missing personal login must not block company.'
    Write-Auth $personalHome $personal 'personal-a'
    New-Profiles
    Sync-QuotaCredentials
    Reply $profiles[0] 'plus' 75
    Write-Auth $personalHome (Token 'plus' 'personal-b') 'personal-b'
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Five.Remaining -and $profiles[0].Credential.Account -eq 'personal-b') 'Changing personal identity must clear old values.'
    Write-Auth $personalHome (Token 'plus' 'personal-b' 'user-a' -10) 'personal-b'
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Credential) 'Expired live login must not be used.'
    $expired = Get-WorkspaceCredential (Token 'plus' 'personal-a' 'user-a' -60) 'personal-a'
    Save-PersonalCache $profiles[0] $expired
    Assert ((Read-PersonalCache $profiles[0]).Expires -lt [DateTime]::UtcNow) 'Existing encrypted cache must be replaceable.'
    Write-Auth $personalHome $company 'company-a'
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Credential) 'Expired cached login must not be used.'
    [IO.File]::WriteAllText($cache, 'corrupt fixture', [Text.UTF8Encoding]::new($false))
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Credential) 'Corrupt cache must fail closed.'
    Write-Auth $personalHome $personal 'wrong-account'
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Credential -and $profiles[0].Status -eq 'invalid-auth') 'Conflicting token and account metadata must be rejected.'
    [IO.File]::WriteAllText((Join-Path $personalHome 'auth.json'), '{invalid', [Text.UTF8Encoding]::new($false))
    Sync-QuotaCredentials
    Assert ($null -eq $profiles[0].Credential) 'Malformed source must not restore cached login.'
    Assert ($null -eq (Get-WorkspaceCredential (Token 'unknown' 'personal-a') 'personal-a')) 'Unknown workspace type must not be guessed.'
    Write-Output "PASS: $script:checks workspace regression checks."
}
finally {
    Close-QuotaResources
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    $allowedRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedRoot).StartsWith('fixtures-')) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
