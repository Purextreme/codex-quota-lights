param([Parameter(Mandatory)][string]$ScriptPath)
$ErrorActionPreference='Stop'
$file=(Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$null,[ref]$errors)
if($errors.Count){throw 'Candidate parse failed.'}
$entry=@($ast.EndBlock.Statements | Where-Object {$_.Extent.Text -eq '$exitCode = 0'})
. ([scriptblock]::Create([IO.File]::ReadAllText($file).Substring(0,$entry[0].Extent.StartOffset)))
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public sealed class QuotaFixtureHandler : HttpMessageHandler {
    public Queue<HttpResponseMessage> TokenReplies = new Queue<HttpResponseMessage>();
    public Queue<HttpResponseMessage> UsageReplies = new Queue<HttpResponseMessage>();
    public int TokenRequests, UsageRequests;
    public string LastTokenBody;
    public bool HoldToken;
    public TaskCompletionSource<HttpResponseMessage> Held = new TaskCompletionSource<HttpResponseMessage>();
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
        if (request.RequestUri.AbsoluteUri == "https://auth.openai.com/oauth/token") {
            TokenRequests++;
            LastTokenBody = request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            if (HoldToken) return Held.Task;
            return Task.FromResult(TokenReplies.Dequeue());
        }
        if (request.RequestUri.AbsoluteUri != "https://chatgpt.com/backend-api/wham/usage")
            throw new Exception("Unexpected destination");
        UsageRequests++;
        return Task.FromResult(UsageReplies.Dequeue());
    }
    public static HttpResponseMessage Response(int code, string body) {
        return new HttpResponseMessage((HttpStatusCode)code) {Content = new StringContent(body ?? "")};
    }
}
'@
$root=Join-Path $PSScriptRoot ('renewal-fixtures-'+[Guid]::NewGuid().ToString('N'))
$personalDirectory=Join-Path $root 'personal'
$companyDirectory=Join-Path $root 'company'
$StateDirectory=Join-Path $root 'state'
[void][IO.Directory]::CreateDirectory($personalDirectory)
[void][IO.Directory]::CreateDirectory($companyDirectory)
$script:checks=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Token([string]$Plan,[string]$Account,[int]$Seconds=3600,[string]$User='user-a'){
    $payload=@{exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+$Seconds;'https://api.openai.com/auth'=@{chatgpt_plan_type=$Plan;chatgpt_account_id=$Account;chatgpt_user_id=$User}} | ConvertTo-Json -Compress
    $part=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')
    return 'eyJhbGciOiJub25lIn0.'+$part+'.fixture'
}
function Session([int]$Seconds=3600,[string]$Refresh='independent-r1',[string]$User='user-a',[string]$Account='personal-a'){
    ConvertTo-QuotaSession @{version=1;access_token=(Token 'plus' $Account $Seconds $User);refresh_token=$Refresh;user=$User;account=$Account;disabled=$false}
}
function Init([int]$Seconds=3600){
    if($script:profiles.Count){Close-QuotaResources}
    $script:profiles=@((New-QuotaProfile 'personal' 'Personal' $personalDirectory $personalDirectory))
    $p=$script:profiles[0]
    $script:handler=[QuotaFixtureHandler]::new()
    $p.Client=[Net.Http.HttpClient]::new($script:handler)
    $p.Client.MaxResponseContentBufferSize=262144
    $p.Client.Timeout=[TimeSpan]::FromSeconds(2)
    Assert (Save-QuotaSession $p (Session $Seconds)) 'Fixture session must save.'
    Sync-QuotaCredentials
    return $p
}
function Enqueue-Token([string]$Refresh='independent-r2',[string]$User='user-a',[string]$Account='personal-a'){
    $json=@{access_token=(Token 'plus' $Account 7200 $User);refresh_token=$Refresh} | ConvertTo-Json -Compress
    $handler.TokenReplies.Enqueue([QuotaFixtureHandler]::Response(200,$json))
}
function Enqueue-Usage([int]$Code=200){
    $json=@{plan_type='plus';rate_limit=@{primary_window=@{used_percent=4;reset_after_seconds=3600};secondary_window=@{used_percent=75;reset_after_seconds=60000}}} | ConvertTo-Json -Depth 5 -Compress
    $handler.UsageReplies.Enqueue([QuotaFixtureHandler]::Response($Code,$json))
}
function Drain{
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while($null -ne $profiles[0].Pending -and [DateTime]::UtcNow -lt $deadline){Complete-QuotaRefresh;Start-Sleep -Milliseconds 10}
    Assert ($null -eq $profiles[0].Pending) 'Fixture requests must complete.'
}
try{
    $companyToken=Token 'team' 'company-a'
    $auth=@{tokens=@{account_id='company-a';access_token=$companyToken;refresh_token='codex-owned-do-not-use'}} | ConvertTo-Json
    $authPath=Join-Path $personalDirectory 'auth.json'
    [IO.File]::WriteAllText($authPath,$auth,[Text.UTF8Encoding]::new($false))
    $before=(Get-FileHash -LiteralPath $authPath).Hash
    $p=Init -60
    Assert ($p.Credential.Dedicated -and $p.Credential.Role -eq 'personal') 'Company space must select the independent personal session.'
    Enqueue-Token
    Enqueue-Usage
    Update-Quota $p
    Drain
    Assert ($handler.TokenRequests -eq 1 -and $handler.UsageRequests -eq 1 -and $p.Status -eq 'ok') 'An expired session must renew and query quota automatically.'
    Assert ($p.Five.Remaining -eq 96 -and $p.Week.Remaining -eq 25) 'Renewed personal values must remain independent.'
    Assert ((Read-QuotaSession $p).RefreshToken -ceq 'independent-r2') 'Rotating refresh token must persist.'
    Assert (($handler.LastTokenBody | ConvertFrom-Json).refresh_token -ceq 'independent-r1') 'Only the independent grant must be refreshed.'
    Assert ((Get-FileHash -LiteralPath $authPath).Hash -ceq $before) 'Automatic renewal must not change Codex authentication.'
    $cipher=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Get-QuotaSessionPath $p)))
    Assert (-not $cipher.Contains('independent-r2')) 'Refresh tokens must be encrypted at rest.'
    $p=Init 180
    Enqueue-Token
    Enqueue-Usage
    Update-Quota $p
    Drain
    Assert ($handler.TokenRequests -eq 1) 'Renewal must start before expiry.'
    $p=Init 3600
    Enqueue-Usage 401
    Enqueue-Token
    Enqueue-Usage
    Update-Quota $p
    Drain
    Assert ($handler.TokenRequests -eq 1 -and $handler.UsageRequests -eq 2 -and $p.Status -eq 'ok') 'A rejected access token must renew and retry quota once.'
    $p=Init 3600
    Enqueue-Usage 401
    Enqueue-Token
    Enqueue-Usage 401
    Update-Quota $p
    Drain
    Assert ($p.Status -eq 'login-needed' -and (Read-QuotaSession $p).Disabled -and $handler.TokenRequests -eq 1) 'Repeated quota rejection must stop and require reconnect instead of looping.'
    $p=Init -60
    $handler.TokenReplies.Enqueue([QuotaFixtureHandler]::Response(503,''))
    Update-Quota $p
    Drain
    Update-Quota $p
    Assert ($handler.TokenRequests -eq 1 -and $handler.UsageRequests -eq 0) 'Offline renewal must back off without using an expired token.'
    Assert ((Read-QuotaSession $p).RefreshToken -ceq 'independent-r1') 'Transient failure must preserve the stored grant.'
    $p=Init -60
    $handler.TokenReplies.Enqueue([QuotaFixtureHandler]::Response(400,''))
    Update-Quota $p
    Drain
    Sync-QuotaCredentials
    Update-Quota $p
    Assert ($p.Status -eq 'login-needed' -and (Read-QuotaSession $p).Disabled -and $handler.TokenRequests -eq 1) 'Revoked authorization must require reconnect without repeated refresh.'
    $p=Init -60
    Enqueue-Token 'wrong-identity-refresh' 'user-b'
    Update-Quota $p
    Drain
    Assert ($p.Status -eq 'login-needed' -and $handler.UsageRequests -eq 0) 'Wrong-user renewal must never query or display quota.'
    $p=Init -60
    $handler.HoldToken=$true
    Update-Quota $p
    $contender=Lock-QuotaSession $p
    Assert ($null -eq $contender) 'Concurrent processes must not consume the same refresh token.'
    $json=@{access_token=(Token 'plus' 'personal-a' 7200);refresh_token='serialized-r2'} | ConvertTo-Json -Compress
    Enqueue-Usage
    $handler.Held.SetResult([QuotaFixtureHandler]::Response(200,$json))
    Drain
    $contender=Lock-QuotaSession $p
    Assert ($null -ne $contender) 'Refresh lock must be released after completion.'
    $contender.Dispose()
    $p=Init 3600
    $bad=@{version=1;access_token=(Token 'team' 'company-a');refresh_token='bad';account='company-a';user='user-a'}
    Assert ($null -eq (ConvertTo-QuotaSession $bad)) 'A company token must never become a personal session.'
    $wrongUser=Token 'team' 'company-b' 3600 'user-b'
    [IO.File]::WriteAllText($authPath,(@{tokens=@{account_id='company-b';access_token=$wrongUser}} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Sync-QuotaCredentials
    Assert ($null -eq $p.Credential) 'Changing Codex users must isolate the independent personal grant.'
    Assert ([QuotaLoginSession]::ValidateCallback('/auth/callback?state=s&code=test','s') -ceq 'test') 'OAuth callback must accept matching state.'
    Assert ($null -eq [QuotaLoginSession]::ValidateCallback('/auth/callback?state=wrong&code=test','s')) 'OAuth callback must reject wrong state.'
    Assert ($null -eq [QuotaLoginSession]::ValidateCallback('/auth/callback?state=s&state=s&code=test','s')) 'OAuth callback must reject duplicate parameters.'
    Assert ($null -eq [QuotaLoginSession]::ValidateCallback('/other?state=s&code=test','s')) 'OAuth callback must reject unexpected paths.'
    $login=[QuotaLoginSession]::new()
    try{
        $url=Get-QuotaAuthorizationUrl $login 'personal-a'
        Assert ($url.StartsWith('https://auth.openai.com/oauth/authorize?') -and $url.Contains('offline_access') -and $url.Contains('allowed_workspace_id=personal-a')) 'Authorization must request independent renewal for the personal workspace.'
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$challenge=[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($login.Verifier))).TrimEnd('=').Replace('+','-').Replace('/','_')}
        finally{$sha.Dispose()}
        Assert ($challenge -ceq $login.Challenge -and $login.State.Length -ge 43) 'OAuth login must use random state and PKCE S256.'
        $localHandler=[Net.Http.HttpClientHandler]::new()
        $localHandler.UseProxy=$false
        $local=[Net.Http.HttpClient]::new($localHandler)
        try{
            $response=$local.GetAsync($login.RedirectUri+'?state='+$login.State+'&code=fixture-code').GetAwaiter().GetResult()
            Assert ($response.IsSuccessStatusCode -and $login.Code.GetAwaiter().GetResult() -ceq 'fixture-code') 'Loopback callback must deliver the code without logging it.'
            Assert (-not $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().Contains('fixture-code')) 'Browser completion page must not echo authorization codes.'
            $response.Dispose()
        }
        finally{$local.Dispose()}
    }
    finally{$login.Dispose()}
    Write-Output "PASS: $script:checks automatic renewal and OAuth checks."
}
finally{
    Close-QuotaResources
    $resolvedRoot=[IO.Path]::GetFullPath($root)
    $allowedRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if($resolvedRoot.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedRoot).StartsWith('renewal-fixtures-')){
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
