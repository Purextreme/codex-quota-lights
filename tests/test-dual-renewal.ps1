param([Parameter(Mandatory)][string]$ScriptPath)
$ErrorActionPreference='Stop'
$file=(Resolve-Path -LiteralPath $ScriptPath).ProviderPath
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$null,[ref]$errors)
if($errors.Count){throw 'Candidate parse failed.'}
$entry=@($ast.EndBlock.Statements | Where-Object {$_.Extent.Text -eq '$exitCode = 0'})
. ([scriptblock]::Create([IO.File]::ReadAllText($file).Substring(0,$entry[0].Extent.StartOffset)))
# Keep the regression executable against the frozen personal-only implementation too.
foreach($part in @('Session','Renewal')){
    foreach($verb in @('Read','Save','Lock','Get')){
        $suffix=if($verb -eq 'Get'){$part+'Path'}else{$part}
        if(-not (Get-Command ($verb+'-Quota'+$suffix) -ErrorAction SilentlyContinue)){
            Set-Alias -Name ($verb+'-Quota'+$suffix) -Value ($verb+'-Personal'+$suffix)
        }
    }
}
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
public sealed class DualQuotaHandler : HttpMessageHandler {
    public Queue<HttpResponseMessage> Tokens = new Queue<HttpResponseMessage>();
    public Queue<HttpResponseMessage> Usages = new Queue<HttpResponseMessage>();
    public int TokenCount, UsageCount;
    public string UsageAccount, RefreshUsed;
    public bool HoldToken, HoldUsage;
    public TaskCompletionSource<HttpResponseMessage> Held = new TaskCompletionSource<HttpResponseMessage>();
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
        if (request.RequestUri.AbsoluteUri == "https://auth.openai.com/oauth/token") {
            TokenCount++;
            RefreshUsed = request.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            return HoldToken ? Held.Task : Task.FromResult(Tokens.Dequeue());
        }
        if (request.RequestUri.AbsoluteUri != "https://chatgpt.com/backend-api/wham/usage")
            throw new Exception("Unexpected destination");
        UsageCount++;
        UsageAccount = String.Join("", request.Headers.GetValues("ChatGPT-Account-Id"));
        return HoldUsage ? Held.Task : Task.FromResult(Usages.Dequeue());
    }
    public static HttpResponseMessage Reply(int code, string body) {
        return new HttpResponseMessage((HttpStatusCode)code) {Content = new StringContent(body ?? "")};
    }
}
'@
$root=Join-Path $PSScriptRoot ('dual-fixtures-'+[Guid]::NewGuid().ToString('N'))
$StateDirectory=Join-Path $root 'state'
$script:checks=0
$script:handlers=@()
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Token([string]$Plan,[string]$Account,[int]$Seconds=3600,[string]$User='user-a'){
    $payload=@{exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+$Seconds;'https://api.openai.com/auth'=@{chatgpt_plan_type=$Plan;chatgpt_account_id=$Account;chatgpt_user_id=$User}} | ConvertTo-Json -Compress
    $part=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')
    return 'eyJhbGciOiJub25lIn0.'+$part+'.fixture'
}
function Write-Auth($Profile,[string]$Plan,[string]$Account,[string]$User='user-a'){
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Profile.AuthPath))
    $data=@{tokens=@{account_id=$Account;access_token=(Token $Plan $Account 3600 $User);refresh_token='codex-owned-'+$Profile.Name}}
    [IO.File]::WriteAllText($Profile.AuthPath,($data | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
}
function Init([int]$Seconds=-60){
    if($script:profiles.Count){Close-QuotaResources}
    $script:profiles=@()
    $script:handlers=@()
    foreach($role in @('personal','company')){
        $directory=Join-Path $root $role
        $p=New-QuotaProfile $role $role $directory $directory
        $plan=if($role -eq 'personal'){'plus'}else{'team'}
        Write-Auth $p $plan ($role+'-a')
        $credential=Get-WorkspaceCredential (Token $plan ($role+'-a') $Seconds) ($role+'-a')
        $credential | Add-Member -NotePropertyName Dedicated -NotePropertyValue $true
        $session=[pscustomobject]@{Credential=$credential;RefreshToken=('indicator-'+$role+'-r1');Disabled=$false}
        Assert (Save-QuotaSession $p $session) 'Each independent session must save.'
        $handler=[DualQuotaHandler]::new()
        $p.Client=[Net.Http.HttpClient]::new($handler)
        $p.Client.MaxResponseContentBufferSize=262144
        $script:handlers+=,$handler
        $script:profiles+=,$p
    }
    Sync-QuotaCredentials
}
function Queue-Token([int]$Index,[int]$Code=200,[string]$Account='',[string]$Plan=''){
    $role=$profiles[$Index].Name
    if(-not $Account){$Account=$role+'-a'}
    if(-not $Plan){$Plan=if($Index -eq 0){'plus'}else{'team'}}
    $json=@{access_token=(Token $Plan $Account 7200);refresh_token=('indicator-'+$role+'-r2')} | ConvertTo-Json -Compress
    $handlers[$Index].Tokens.Enqueue([DualQuotaHandler]::Reply($Code,$json))
}
function Usage-Reply([int]$Index,[int]$Code=200,[string]$Plan=''){
    if(-not $Plan){$Plan=if($Index -eq 0){'plus'}else{'team'}}
    $five=if($Index -eq 0){4}else{22};$week=if($Index -eq 0){75}else{7}
    $json=@{plan_type=$Plan;rate_limit=@{primary_window=@{used_percent=$five;reset_after_seconds=3600};secondary_window=@{used_percent=$week;reset_after_seconds=60000}}}|ConvertTo-Json -Depth 5 -Compress
    return [DualQuotaHandler]::Reply($Code,$json)
}
function Queue-Usage([int]$Index,[int]$Code=200,[string]$Plan=''){$handlers[$Index].Usages.Enqueue((Usage-Reply $Index $Code $Plan))}
function Drain{
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while(@($profiles | Where-Object {$null -ne $_.Pending}).Count -and [DateTime]::UtcNow -lt $deadline){Complete-QuotaRefresh;Start-Sleep -Milliseconds 10}
    Assert (@($profiles | Where-Object {$null -ne $_.Pending}).Count -eq 0) 'Both rows must finish their requests.'
}
try{
    Init
    Assert ($profiles[1].Credential.Dedicated -eq $true) 'Company expiry must select its independent renewable session.'
    $hashes=@($profiles | ForEach-Object {(Get-FileHash -LiteralPath $_.AuthPath).Hash})
    foreach($i in 0..1){Queue-Token $i;Queue-Usage $i;Update-Quota $profiles[$i]}
    Drain
    foreach($i in 0..1){
        Assert ($profiles[$i].Status -eq 'ok' -and $handlers[$i].TokenCount -eq 1 -and $handlers[$i].UsageCount -eq 1) 'Both expired sessions must automatically renew and fetch quota.'
        Assert ((Read-QuotaSession $profiles[$i]).RefreshToken -ceq ('indicator-'+$profiles[$i].Name+'-r2')) 'Each rotated grant must persist independently.'
        Assert ($handlers[$i].UsageAccount -ceq ($profiles[$i].Name+'-a')) 'Usage header must select the row account.'
        Assert (($handlers[$i].RefreshUsed | ConvertFrom-Json).refresh_token -ceq ('indicator-'+$profiles[$i].Name+'-r1')) 'Renewal must use the corresponding independent grant.'
        Assert ((Get-FileHash -LiteralPath $profiles[$i].AuthPath).Hash -ceq $hashes[$i]) 'Neither source login file may be changed.'
    }
    Assert ($profiles[0].Week.Remaining -eq 25 -and $profiles[1].Week.Remaining -eq 93) 'Rows must display different real response values.'
    Assert ((Get-QuotaSessionPath $profiles[0]) -cne (Get-QuotaSessionPath $profiles[1])) 'Independent stores must have different paths.'
    $identities=@($profiles | ForEach-Object {$_.Identity})
    $generations=@($profiles | ForEach-Object {$_.Generation})
    # Include a second company workspace of the same type, not merely personal/company.
    for($switch=0;$switch -lt 60;$switch++){
        $choice=$switch%3
        $plan=if($choice -eq 0){'plus'}else{'team'}
        $account=@('personal-a','company-a','other-company')[ $choice ]
        foreach($p in $profiles){Write-Auth $p $plan $account}
        Sync-QuotaCredentials
        foreach($i in 0..1){Assert ($profiles[$i].Identity -ceq $identities[$i] -and $profiles[$i].Generation -eq $generations[$i]) 'Workspace switching must preserve each pinned identity.'}
    }
    foreach($i in 0..1){Queue-Usage $i;Update-Quota $profiles[$i]};Drain
    Assert ($profiles[0].Week.Remaining -eq 25 -and $profiles[1].Week.Remaining -eq 93) 'Frequent switching must not exchange row values.'
    # Rebuild the profiles to exercise process restart and encrypted restoration.
    Close-QuotaResources
    $script:profiles=@($profiles | ForEach-Object {New-QuotaProfile $_.Name $_.Label ([IO.Path]::GetDirectoryName($_.AuthPath)) ([IO.Path]::GetDirectoryName($_.AuthPath))})
    Sync-QuotaCredentials
    foreach($i in 0..1){Assert ($profiles[$i].Credential.Dedicated -and $profiles[$i].Identity -ceq $identities[$i]) 'Restart must restore both independent authorizations despite a third selected workspace.'}
    Init 180
    foreach($i in 0..1){Queue-Token $i;Queue-Usage $i;Update-Quota $profiles[$i]};Drain
    Assert ($handlers[1].TokenCount -eq 1) 'Company grant must renew before expiry.'
    Init 3600
    Queue-Usage 1 401;Queue-Token 1;Queue-Usage 1
    Update-Quota $profiles[1];Drain
    Assert ($profiles[1].Status -eq 'ok' -and $handlers[1].TokenCount -eq 1 -and $handlers[1].UsageCount -eq 2) 'A rejected company token must renew and retry once.'
    Init
    Queue-Token 1 503;Update-Quota $profiles[1];Drain;Update-Quota $profiles[1]
    Queue-Token 0;Queue-Usage 0;Update-Quota $profiles[0];Drain
    Assert ($handlers[1].TokenCount -eq 1 -and $handlers[1].UsageCount -eq 0 -and $profiles[0].Status -eq 'ok') 'Company outage must back off while personal continues to work.'
    Init
    Queue-Token 1 400;Update-Quota $profiles[1];Drain;Sync-QuotaCredentials;Update-Quota $profiles[1]
    Assert ((Read-QuotaSession $profiles[1]).Disabled -and $handlers[1].TokenCount -eq 1) 'Revoked company consent must stop renewal without looping.'
    Assert (-not (Read-QuotaSession $profiles[0]).Disabled) 'Revoking company consent must not disable personal.'
    Init
    Queue-Token 1 200 'wrong-company';Update-Quota $profiles[1];Drain
    Assert ($handlers[1].UsageCount -eq 0 -and (Read-QuotaSession $profiles[1]).Disabled) 'Renewal for a different company must never query quota.'
    Init 3600
    Queue-Usage 1 200 'plus';Update-Quota $profiles[1];Drain
    Assert ($profiles[1].Status -eq 'workspace-mismatch' -and $null -eq $profiles[1].Week.Remaining) 'Company row must reject a personal quota response.'
    Init
    # Locks for the two grants must allow independent concurrent renewal.
    foreach($i in 0..1){$handlers[$i].HoldToken=$true;Update-Quota $profiles[$i]}
    foreach($i in 0..1){$lock=Lock-QuotaSession $profiles[$i];Assert ($null -eq $lock) 'Both rotating grants must be locked while their requests are pending.'}
    # Change the source user while both renewals are in flight.
    foreach($p in $profiles){Write-Auth $p 'team' 'other-user-company' 'user-b'}
    Sync-QuotaCredentials
    foreach($i in 0..1){
        $role=$profiles[$i].Name;$plan=if($i -eq 0){'plus'}else{'team'}
        $json=@{access_token=(Token $plan ($role+'-a') 7200);refresh_token=('saved-during-switch-'+$role)}|ConvertTo-Json -Compress
        $handlers[$i].Held.SetResult([DualQuotaHandler]::Reply(200,$json))
    }
    Drain
    foreach($i in 0..1){
        Assert ($null -eq $profiles[$i].Credential -and $null -eq $profiles[$i].Week.Remaining -and $handlers[$i].UsageCount -eq 0) 'An old-user renewal must not populate the new user display.'
        Assert ((Read-QuotaSession $profiles[$i]).RefreshToken -ceq ('saved-during-switch-'+$profiles[$i].Name)) 'An in-flight successful rotation must survive switching users.'
        $lock=Lock-QuotaSession $profiles[$i];Assert ($null -ne $lock) 'Both refresh locks must be released after stale completion.';$lock.Dispose()
        Write-Auth $profiles[$i] 'team' 'other-company'
    }
    Sync-QuotaCredentials
    foreach($i in 0..1){Queue-Usage $i;Update-Quota $profiles[$i]};Drain
    Assert ($profiles[0].Status -eq 'ok' -and $profiles[1].Status -eq 'ok') 'Returning to the original user must restore both renewed sessions.'
    # A personal session file copied into company storage must be rejected.
    [IO.File]::Copy((Get-QuotaSessionPath $profiles[0]),(Get-QuotaSessionPath $profiles[1]),$true)
    Assert ($null -eq (Read-QuotaSession $profiles[1])) 'A company store must reject a personal session even when encrypted correctly.'
    Write-Output "PASS: $script:checks dual renewal, restart and 60 workspace-switch checks."
}
finally{
    Close-QuotaResources
    $resolvedRoot=[IO.Path]::GetFullPath($root)
    $allowedRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if($resolvedRoot.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedRoot).StartsWith('dual-fixtures-')){Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
}
