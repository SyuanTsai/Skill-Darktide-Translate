# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('prepare', 'validate', 'finalize', 'aggregate')][string] $Phase,
    [string] $BaseRoot, [string] $CandidateRoot, [string] $WorkRoot,
    [ValidateSet('pull_request_target', 'pull_request', 'push')][string] $TriggerEvent,
    [string] $BaseRevision, [string] $CandidateRevision, [string] $HeadRevision,
    [string] $WorkflowRunId, [string] $WorkflowRunAttempt,
    [ValidateSet('windows', 'linux', 'macos', 'aggregate')][string] $Platform,
    [switch] $TransitionFromLegacy, [switch] $DefineFunctionsOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:ExitCodes = @{ BLOCKED = 10
 FAILED = 20
 INVALID = 30
 CANCELLED = 40 }
$script:PinnedGitHooksPath = $null

function Throw-ConsumerResult([string]$State, [string]$Message) { throw "$State|$Message" }
function Get-Sha256([byte[]]$Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-FileSha256([string]$Path) { Get-Sha256 ([IO.File]::ReadAllBytes($Path)) }
function Test-PathInside([string]$Path, [string]$Root) {
    $p = [IO.Path]::GetFullPath($Path)
     $r = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $p.Equals($r, $comparison) -or $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar, $comparison)
}
function Assert-PlainPath([string]$Path, [string]$Context, [switch]$Leaf) {
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = if (Test-Path -LiteralPath $full) { $full } else { Split-Path -Parent $full }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) { Throw-ConsumerResult INVALID `
            "$Context has a reparse ancestor." }
        $parent = Split-Path -Parent $cursor
         if ($parent -eq $cursor) { break }
         $cursor = $parent
    }
    if ($Leaf) { if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Throw-ConsumerResult INVALID "$Context must be a regular file." }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer) { Throw-ConsumerResult INVALID "$Context must be a regular file." }
    }
    $full
}
function Assert-ExactProperties($Value, [string[]]$Names, [string]$Context) {
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count -or @($actual | Where-Object { $_ -cnotin $Names }).Count -ne 0) { Throw-ConsumerResult INVALID `
        "$Context has an unexpected property set." }
}
function Assert-NoDuplicateJson([Text.Json.JsonElement]$Element, [string]$Context) {
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { Throw-ConsumerResult INVALID "$Context has a duplicate or case-conflicting key." }
            Assert-NoDuplicateJson $property.Value $Context
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) { foreach ($item in $Element.EnumerateArray()) { Assert-NoDuplicateJson `
        $item $Context } }
}
function Read-StrictJson([string]$Path, [string]$Context, [int]$MaximumBytes = 1048576) {
    $full = Assert-PlainPath $Path $Context -Leaf
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -gt $MaximumBytes) { Throw-ConsumerResult INVALID "$Context exceeds its size limit." }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { Throw-ConsumerResult INVALID `
        "$Context must not contain a UTF-8 BOM." }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $document = [Text.Json.JsonDocument]::Parse($text)
        try { Assert-NoDuplicateJson $document.RootElement $Context } finally { $document.Dispose() }
        [pscustomobject]@{ Value = ($text | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
         Bytes = $bytes
         Sha256 = Get-Sha256 $bytes }
    } catch { if ($_.Exception.Message -match '^(INVALID|FAILED|BLOCKED|CANCELLED)\|') { throw }
     Throw-ConsumerResult INVALID "$Context is not unambiguous UTF-8 JSON." }
}
function New-PinnedGitHooksDirectory(
    [string]$WorkRoot,
    [string]$DirectoryName = ("git-hooks-{0}" -f [guid]::NewGuid().ToString('N'))
) {
    $root = Assert-PlainPath $WorkRoot 'WorkRoot'
    if ($DirectoryName -cnotmatch '^git-hooks-[0-9a-f]{32}$') {
        Throw-ConsumerResult INVALID 'The dedicated Git hooks directory name is invalid.'
    }
    $hooks = Join-Path $root $DirectoryName
    if (Test-Path -LiteralPath $hooks) { Throw-ConsumerResult INVALID 'The dedicated Git hooks directory already exists.' }
    [void](New-Item -ItemType Directory -Path $hooks -ErrorAction Stop)
    $item = Get-Item -LiteralPath $hooks -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $null -ne $item.LinkType -or @(Get-ChildItem -LiteralPath $hooks -Force).Count -ne 0) {
        Throw-ConsumerResult INVALID 'The dedicated Git hooks directory is not an empty physical directory.'
    }
    $item.FullName
}
function Initialize-PinnedGitHooks([string]$WorkRoot) {
    if ($null -ne $script:PinnedGitHooksPath) { Throw-ConsumerResult INVALID 'Git hooks isolation was initialized more than once.' }
    $script:PinnedGitHooksPath = New-PinnedGitHooksDirectory $WorkRoot
}
function Invoke-PinnedGit([string]$RepositoryRoot, [string[]]$Arguments, [int[]]$AllowedExitCodes = @(0), [switch]$AllowFileProtocol) {
    if ([string]::IsNullOrWhiteSpace($script:PinnedGitHooksPath)) { Throw-ConsumerResult INVALID 'Git hooks isolation is not initialized.' }
    $protocol = if ($AllowFileProtocol) { 'always' } else { 'never' }
    $all = @('-c', "core.hooksPath=$script:PinnedGitHooksPath", '-c', "protocol.file.allow=$protocol", '-c', 'credential.helper=', '-C', $RepositoryRoot) + $Arguments
    foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process');Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
    $output=@(& git @all 2>&1);$exit=$LASTEXITCODE
    if ($exit -notin $AllowedExitCodes) { Throw-ConsumerResult INVALID "git failed ($exit): $($output -join ' ')" }
    [pscustomobject]@{ ExitCode = $exit; Output = $output }
}
function Get-ConsumerRunId([string]$Repository, [string]$RunId, [string]$Attempt) {
    if ($RunId -cnotmatch '^[0-9]+$' -or $Attempt -cnotmatch '^[1-9][0-9]*$') { Throw-ConsumerResult INVALID 'Workflow run identity is invalid.' }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes("consumer-gate-runid-v1`n$Repository`n$RunId`n$Attempt")
    $value = [Security.Cryptography.SHA256]::HashData($bytes)[0..15]
    $value[6] = ($value[6] -band 0x0f) -bor 0x80
     $value[8] = ($value[8] -band 0x3f) -bor 0x80
    ([Convert]::ToHexString($value)).ToLowerInvariant()
}
function Assert-Revisions([string]$Event, [string]$Base, [string]$Candidate, [string]$Head, [string]$BasePath, [string]$CandidatePath) {
    foreach ($revision in @($Base, $Candidate, $Head)) { if ($revision -cnotmatch '^[0-9a-f]{40}$') { Throw-ConsumerResult INVALID `
        'Revision inputs must be full lowercase commit IDs.' } }
    $candidateHead = ([string](Invoke-PinnedGit $CandidatePath @('rev-parse', 'HEAD^{commit}')).Output[0]).Trim()
    if ($candidateHead -cne $Candidate) { Throw-ConsumerResult FAILED 'Candidate checkout HEAD differs from CandidateRevision.' }
    if ($Event -in @('pull_request_target', 'pull_request')) {
        $parents = @((Invoke-PinnedGit $CandidatePath @('show', '-s', '--format=%P', $Candidate)).Output[0] -split ' ')
        if ($parents.Count -ne 2 -or $parents[0] -cne $Base -or $parents[1] -cne $Head) { Throw-ConsumerResult FAILED `
            'Merge parents differ from the event binding; base may have advanced, please retrigger.' }
    } else {
        $ancestor = Invoke-PinnedGit $CandidatePath @('merge-base', '--is-ancestor', $Base, $Candidate) @(0, 1)
        if ($ancestor.ExitCode -ne 0 -or $Candidate -cne $Head) { Throw-ConsumerResult FAILED 'Push before revision is not an ancestor of the candidate.' }
    }
    $baseHead = ([string](Invoke-PinnedGit $BasePath @('rev-parse', 'HEAD^{commit}')).Output[0]).Trim()
    if ($baseHead -cne $Base) { Throw-ConsumerResult FAILED 'Base checkout HEAD differs from BaseRevision.' }
}
function Read-AuthorityPin([string]$Root) {
    $snapshot = Read-StrictJson (Join-Path $Root 'config/authority-pin.json') 'authority pin' 4096
    Assert-ExactProperties $snapshot.Value @('schemaVersion', 'repository', 'commit') 'authority pin'
    if ($snapshot.Value.schemaVersion -ne 1 -or [string]$snapshot.Value.repository -cne $script:AuthorityRepository -or`
        [string]$snapshot.Value.commit -cnotmatch '^[0-9a-f]{40}$') { Throw-ConsumerResult FAILED 'Authority pin is not valid.' }
    $snapshot
}
function Assert-ConsumerInterface($Contract) {
    Assert-ExactProperties $Contract @('schemaVersion','supportedInterfaces','currentInterface','retiredInterfaces','phaseEnvironment',`
        'requiredContexts','canonicalEventMap') 'consumer gate interface'
    if ($Contract.schemaVersion -ne 1 -or [string]$Contract.currentInterface -cne 'consumer-gate-v1' -or $Contract.supportedInterfaces -isnot`
        [array] -or @($Contract.supportedInterfaces) -cnotcontains 'consumer-gate-v1' -or $Contract.retiredInterfaces -isnot [array]) {`
            Throw-ConsumerResult INVALID 'Pinned authority does not support consumer-gate-v1; the pin cannot cross a retired interface boundary.' }
    Assert-ExactProperties $Contract.phaseEnvironment @('prepare','validate','finalize','aggregate') 'consumer phase environment'
    foreach ($phaseName in @('prepare','validate','finalize','aggregate')) {
        $names=@($Contract.phaseEnvironment.$phaseName)
        if($Contract.phaseEnvironment.$phaseName-isnot[array]-or@($names|Select-Object -Unique).Count-ne$names.Count){Throw-ConsumerResult `
            INVALID 'Consumer phase environment is invalid.'}
        foreach($name in $names){if($name-isnot[string]-or[string]$name-cnotmatch'^[A-Z][A-Z0-9_]*$'){Throw-ConsumerResult INVALID `
            'Consumer phase environment contains an unsafe name.'}}
        if($phaseName-cne'prepare'-and@($names|Where-Object{$_-match'(?i)(TOKEN|SECRET|KEY|PASSWORD)'}).Count-ne0){Throw-ConsumerResult INVALID `
            'Only prepare may receive a credential environment variable.'}
    }
    if(@($Contract.phaseEnvironment.prepare|Where-Object{[string]$_-ceq'STANDARD_VALIDATION_GITHUB_API_TOKEN'}).Count-ne1){Throw-ConsumerResult `
        INVALID 'Prepare must declare the resolver token exactly once.'}
    if((@($Contract.phaseEnvironment.prepare|Where-Object{$_-match'(?i)(TOKEN|SECRET|KEY|PASSWORD)'})-join',')`
        -cne'STANDARD_VALIDATION_GITHUB_API_TOKEN'){Throw-ConsumerResult INVALID 'Prepare declares an unsupported credential environment variable.'}
    if((@($Contract.requiredContexts)-join',')-cne'repository-contract,skill-validator,skill-tools'){Throw-ConsumerResult INVALID `
        'Consumer required contexts are invalid.'}
    Assert-ExactProperties $Contract.canonicalEventMap @('pull_request_target','push','pull_request(transition)') 'consumer canonical event map'
    if (
        [string]$Contract.canonicalEventMap.pull_request_target -cne 'pull_request' -or
        [string]$Contract.canonicalEventMap.push -cne 'push' -or
        [string]$Contract.canonicalEventMap.'pull_request(transition)' -cne 'pull_request'
    ) {
        Throw-ConsumerResult INVALID 'Consumer canonical event map is invalid.'
    }
}
function Assert-AuthorityTree([string]$GitRoot, [string]$AuthorityRoot, [string]$Commit) {
    $rawRecords = ((Invoke-PinnedGit $GitRoot @('ls-tree', '-r', '-z', '--format=%(objectmode)%x09%(objectname)%x09%(path)', $Commit)).Output -join "`n")
    $records = @($rawRecords -split "`0" | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $records) {
        $parts = [string]$record -split "`t", 3
         if ($parts.Count -ne 3 -or $parts[0] -in @('120000', '160000')) { Throw-ConsumerResult FAILED 'Authority tree contains an unsupported entry.' }
        [void]$expected.Add($parts[2])
         $path = Join-Path $AuthorityRoot $parts[2]
        [void](Assert-PlainPath $path 'authority file' -Leaf)
        $actual = ([string](Invoke-PinnedGit $AuthorityRoot @('hash-object', '--no-filters', '--', $parts[2])).Output[0]).Trim()
        if ($actual -cne $parts[1]) { Throw-ConsumerResult FAILED "Authority file differs from its Git blob: $($parts[2])" }
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $AuthorityRoot -Recurse -File -Force | Where-Object { $_.FullName -notmatch `
        '[\\/]\.git(?:[\\/]|$)' } | ForEach-Object { [IO.Path]::GetRelativePath($AuthorityRoot, $_.FullName).Replace('\','/') })
    if ($actualFiles.Count -ne $expected.Count -or @($actualFiles | Where-Object { -not $expected.Contains($_) }).Count -ne 0) { `
        Throw-ConsumerResult FAILED 'Authority checkout has missing or extra files.' }
}
function New-PinnedAuthority([string]$Root, [string]$Commit, [string]$Repository = $script:AuthorityRepository, [switch]$AllowFileProtocol) {
    $gitRoot = Join-Path $Root 'authority-git'
     $authorityRoot = Join-Path $Root 'authority'
    if ((Test-Path $gitRoot) -or (Test-Path $authorityRoot)) { Throw-ConsumerResult INVALID 'Authority acquisition paths must not already exist.' }
    [IO.Directory]::CreateDirectory($gitRoot) | Out-Null
    [void](Invoke-PinnedGit $gitRoot @('init', '--quiet'));[void](Invoke-PinnedGit $gitRoot @('remote','add','origin',$Repository));$remote=@('-c',"remote.origin.url=$Repository")
    if(([string](Invoke-PinnedGit $gitRoot ($remote+@('ls-remote','--get-url','origin')) -AllowFileProtocol:$AllowFileProtocol).Output[0]).Trim()-cne$Repository){Throw-ConsumerResult INVALID 'Authority origin cannot be resolved in the Git acquisition environment.'}
    [void](Invoke-PinnedGit $gitRoot ($remote+@('fetch','--no-tags','--filter=blob:none','origin','+refs/heads/main:refs/remotes/aii/main')) -AllowFileProtocol:$AllowFileProtocol)
    if(([string](Invoke-PinnedGit $gitRoot ($remote+@('ls-remote','--get-url','origin')) -AllowFileProtocol:$AllowFileProtocol).Output[0]).Trim()-cne$Repository){Throw-ConsumerResult INVALID 'Authority origin cannot be resolved in the Git acquisition environment.'}
    $pinFetch=Invoke-PinnedGit $gitRoot ($remote+@('fetch','--no-tags','origin',$Commit)) @(0,1,128) -AllowFileProtocol:$AllowFileProtocol
    if ($pinFetch.ExitCode -ne 0) {
        if (($pinFetch.Output -join ' ') -match '(?i)(not our ref|couldn''t find remote ref|unadvertised object|not a valid object)') {
            Throw-ConsumerResult FAILED 'Authority pin does not exist in the official repository.'
        }
        Throw-ConsumerResult INVALID 'Authority pin acquisition failed before ancestry verification.'
    }
    $ancestor = Invoke-PinnedGit $gitRoot @('merge-base', '--is-ancestor', $Commit, 'refs/remotes/aii/main') @(0, 1) -AllowFileProtocol:$AllowFileProtocol
    if ($ancestor.ExitCode -eq 1) { Throw-ConsumerResult FAILED 'Authority pin is not on official AII main.' }
    [void](Invoke-PinnedGit $gitRoot ($remote+@('-c','core.autocrlf=false','-c','core.eol=lf','-c','core.symlinks=false','worktree','add', `
        '--quiet','--detach',$authorityRoot,$Commit)) -AllowFileProtocol:$AllowFileProtocol)
    Assert-AuthorityTree $gitRoot $authorityRoot $Commit
    $tip = ([string](Invoke-PinnedGit $gitRoot @('rev-parse', 'refs/remotes/aii/main^{commit}')).Output[0]).Trim()
    $tree = ([string](Invoke-PinnedGit $gitRoot @('rev-parse', "$Commit^{tree}")).Output[0]).Trim()
    [pscustomobject]@{ GitRoot = $gitRoot
     Root = $authorityRoot
     MainTip = $tip
     Tree = $tree }
}
function Write-CreateOnlyJson([string]$Path, $Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 30) + "`n")
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes)
     $stream.Flush($true) } finally { $stream.Dispose() }
}
function Invoke-ConsumerGateProcess([string]$Executable, [string]$GatePath, [string]$InterfacePath, [string]$CurrentPhase, [string]$BindingPath, [string]$Token) {
    $contract = (Read-StrictJson $InterfacePath 'consumer gate interface').Value
    Assert-ConsumerInterface $contract
    $allowed = @($contract.phaseEnvironment.$CurrentPhase)
    $start = [Diagnostics.ProcessStartInfo]::new();$start.FileName = $Executable;$start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true;$start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$GatePath,'-Interface','consumer-gate-v1','-Phase',$CurrentPhase,`
        '-AuthorityBindingPath',$BindingPath,'-BaseRoot',$BaseRoot,'-CandidateRoot',$CandidateRoot,'-WorkRoot',$WorkRoot,'-Platform',$Platform))`
            { [void]$start.ArgumentList.Add($argument) }
    if ($TransitionFromLegacy) { [void]$start.ArgumentList.Add('-TransitionFromLegacy') }
    $preserved = @{};foreach ($name in $allowed) { $preserved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    if($allowed-ccontains'STANDARD_VALIDATION_GITHUB_API_TOKEN'){$preserved['STANDARD_VALIDATION_GITHUB_API_TOKEN']=$Token}
    foreach ($name in @('PATH','Path','SystemRoot','WINDIR','TEMP','TMP','HOME','USERPROFILE','ComSpec','PATHEXT','PSModulePath')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
         if (-not [string]::IsNullOrWhiteSpace($value)) { $preserved[$name] = $value }
    }
    $start.Environment.Clear()
     foreach ($name in $preserved.Keys) { if ($null -ne $preserved[$name]) { $start.Environment[[string]$name] = [string]$preserved[$name] } }
    $osNames = @('PATH','Path','PATHEXT','SystemRoot','WINDIR','OS','TEMP','TMP','TMPDIR','HOME','USERPROFILE','HOMEDRIVE','HOMEPATH','APPDATA',`
        'LOCALAPPDATA','PROGRAMDATA','PROGRAMFILES','PROGRAMFILES(X86)','PROGRAMW6432','COMMONPROGRAMFILES','COMMONPROGRAMFILES(X86)',`
            'COMMONPROGRAMW6432','COMSPEC','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE','PROCESSOR_IDENTIFIER','LANG','LC_ALL','LC_CTYPE',`
                'DOTNET_ROOT','DOTNET_ROOT_X64','XDG_RUNTIME_DIR','PSExecutionPolicyPreference')
    $start.Environment.Clear()
     foreach ($name in $osNames + $allowed) { $value = if ($preserved.ContainsKey($name)) { $preserved[$name] } else {`
         [Environment]::GetEnvironmentVariable($name, 'Process') }
     try { if ($null -ne $value) { $start.Environment[$name] = $value } }finally{$value=$null;Remove-Variable value -ErrorAction SilentlyContinue} }
    $credentialNames = @($allowed | Where-Object { $_ -match '(?i)(TOKEN|SECRET|KEY|PASSWORD)' })
    $process = [Diagnostics.Process]::new()
    $resultCode = 30
    try {
        $process.StartInfo = $start
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $stdout.GetAwaiter().GetResult()
        $standardError = $stderr.GetAwaiter().GetResult()
        $credentialLeak = $false
        foreach ($name in $credentialNames) {
            try {$sentinel = [string]$preserved[$name]
                if (-not [string]::IsNullOrEmpty($sentinel) -and
                    ($standardOutput.Contains($sentinel, [StringComparison]::Ordinal) -or
                     $standardError.Contains($sentinel, [StringComparison]::Ordinal))) {
                    $credentialLeak = $true
                }}finally{$sentinel = $null
            Remove-Variable sentinel -ErrorAction SilentlyContinue}
        }

        if ($credentialLeak) {
            [Console]::Error.WriteLine('Gate output contained a credential sentinel and was suppressed.')
            $resultCode = 20
        }
        else {
            [Console]::Out.Write($standardOutput)
            [Console]::Error.Write($standardError)
            $resultCode = if ($process.ExitCode -in @(0,10,20,30,40)) { $process.ExitCode } else { 30 }
        }
    }
    finally {
        foreach ($name in $credentialNames) {
            [void]$start.Environment.Remove([string]$name)
            if ($preserved.ContainsKey($name)) {
                $preserved[$name] = $null
                [void]$preserved.Remove($name)
            }
        }
        $standardOutput = $null
        $standardError = $null
        $stdout = $null
        $stderr = $null
        $credentialLeak = $null
        $preserved.Clear()
        $start.Environment.Clear()
        $process.Dispose();$value = $null
        $Token=$null
        Remove-Variable standardOutput, standardError, stdout, stderr, credentialLeak, preserved, process, value, Token -ErrorAction SilentlyContinue
    }
    $resultCode
}
if ($DefineFunctionsOnly) { return }
$bootstrapToken=[string][Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN','Process')
foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){[Environment]::SetEnvironmentVariable($name,$null,'Process');Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
try {
    foreach ($required in @('Phase','BaseRoot','CandidateRoot','WorkRoot','TriggerEvent','BaseRevision','CandidateRevision','HeadRevision',`
        'WorkflowRunId','WorkflowRunAttempt','Platform')) { if ([string]::IsNullOrWhiteSpace([string](Get-Variable $required -ValueOnly))) {`
            Throw-ConsumerResult INVALID "$required is required." } }
    if ($TriggerEvent -eq 'pull_request' -and -not $TransitionFromLegacy) { Throw-ConsumerResult INVALID 'pull_request is accepted only for transition.' }
    if ($Phase -eq 'aggregate' -and $Platform -ne 'aggregate') { Throw-ConsumerResult INVALID 'Aggregate phase requires aggregate platform.' }
    $BaseRoot = Assert-PlainPath $BaseRoot 'BaseRoot'
     $CandidateRoot = Assert-PlainPath $CandidateRoot 'CandidateRoot'
    if(-not[IO.Path]::IsPathRooted($WorkRoot)){Throw-ConsumerResult INVALID 'WorkRoot must be an absolute path.'}
    $WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
    if ((Test-PathInside $WorkRoot $BaseRoot) -or (Test-PathInside $WorkRoot $CandidateRoot)) { Throw-ConsumerResult INVALID `
        'WorkRoot is outside the permitted boundary.' }
    $tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:CONSUMER_GATE_TEST_TEMP_ROOT }
    if ([string]::IsNullOrWhiteSpace($tempRoot) -or -not (Test-PathInside $WorkRoot $tempRoot)) { Throw-ConsumerResult INVALID `
        'WorkRoot must be under RUNNER_TEMP or the local test temp root.' }
    if (-not (Test-Path $WorkRoot)) { [IO.Directory]::CreateDirectory($WorkRoot) | Out-Null }
     [void](Assert-PlainPath $WorkRoot 'WorkRoot')
    Initialize-PinnedGitHooks $WorkRoot
    Assert-Revisions $TriggerEvent $BaseRevision $CandidateRevision $HeadRevision $BaseRoot $CandidateRoot
    if ($TransitionFromLegacy -and ((Test-Path (Join-Path $BaseRoot 'scripts/Invoke-PinnedAuthority.ps1')) -or (Test-Path (Join-Path $BaseRoot `
        'config/authority-pin.json')))) { Throw-ConsumerResult FAILED 'Transition base already contains the bootstrap or pin.' }
    $pin = Read-AuthorityPin $CandidateRoot
     $bindingPath = Join-Path $WorkRoot 'authority-binding.json'
    $repository = [string]$env:CONSUMER_GATE_EVENT_REPOSITORY
     if ([string]::IsNullOrWhiteSpace($repository)) { Throw-ConsumerResult INVALID 'Event repository binding is missing.' }
    $runId = Get-ConsumerRunId $repository $WorkflowRunId $WorkflowRunAttempt
    if ($Phase -in @('prepare','aggregate')) {
        $authority = New-PinnedAuthority $WorkRoot ([string]$pin.Value.commit)
        $interfacePath = Join-Path $authority.Root 'consumer/consumer-gate-interface.json'
         $interface = (Read-StrictJson $interfacePath 'consumer gate interface').Value
        Assert-ConsumerInterface $interface
        $bootstrapPath = [string]$MyInvocation.MyCommand.Path
        $binding = [ordered]@{ schemaVersion=1
         scope=if($Phase -eq 'aggregate'){'aggregate'}else{'platform'}
         interface='consumer-gate-v1'
         repository=$repository
         commit=[string]$pin.Value.commit
         aiiMainTip=$authority.MainTip
         treeSha=$authority.Tree
         baseRevision=$BaseRevision
         candidateRevision=$CandidateRevision
         headRevision=$HeadRevision
         triggerEvent=$TriggerEvent
         runId=$runId
         platform=$Platform
         pinSha256=$pin.Sha256
         bootstrapSha256=Get-FileSha256 $bootstrapPath }
        Write-CreateOnlyJson $bindingPath $binding
    } else {
        $binding = (Read-StrictJson $bindingPath 'authority binding').Value
        Assert-ExactProperties $binding @('schemaVersion','scope','interface','repository','commit','aiiMainTip','treeSha','baseRevision',`
            'candidateRevision','headRevision','triggerEvent','runId','platform','pinSha256','bootstrapSha256') 'authority binding'
        $bootstrapSha256=Get-FileSha256 ([string]$MyInvocation.MyCommand.Path)
        foreach ($pair in @(@('schemaVersion','1'),@('scope','platform'),@('interface','consumer-gate-v1'),@('repository',$repository),@(`
            'commit',[string]$pin.Value.commit),@('pinSha256',$pin.Sha256),@('bootstrapSha256',$bootstrapSha256),@('baseRevision',$BaseRevision),`
                @('candidateRevision',$CandidateRevision),@('headRevision',$HeadRevision),@('triggerEvent',$TriggerEvent),@('runId',$runId),@(`
                    'platform',$Platform))) { if ([string]$binding.($pair[0]) -cne [string]$pair[1]) { Throw-ConsumerResult FAILED`
                        "Authority binding changed: $($pair[0])." } }
        $authority = [pscustomobject]@{ GitRoot=Join-Path $WorkRoot 'authority-git'
         Root=Join-Path $WorkRoot 'authority' }
         Assert-AuthorityTree $authority.GitRoot $authority.Root ([string]$binding.commit)
        $boundTip=([string](Invoke-PinnedGit $authority.GitRoot @('rev-parse','refs/remotes/aii/main^{commit}')).Output[0]).Trim()
        $boundTree=([string](Invoke-PinnedGit $authority.GitRoot @('rev-parse',"$($binding.commit)^{tree}")).Output[0]).Trim()
        if($boundTip-cne[string]$binding.aiiMainTip-or$boundTree-cne[string]$binding.treeSha){Throw-ConsumerResult FAILED `
            'Authority binding no longer matches the acquired repository.'}
        $interfacePath = Join-Path $authority.Root 'consumer/consumer-gate-interface.json'
    }
    $executable = (Get-Process -Id $PID).Path
    if ($Phase -in @('validate','finalize')) {
        $runtime = (Read-StrictJson (Join-Path $WorkRoot 'runtime/consumer-runtime-receipt.json') 'consumer runtime receipt').Value
        Assert-ExactProperties $runtime @('schemaVersion','report','executablePath','executableSha256','version','archiveSha256') 'consumer runtime receipt'
        $runtimeRoot=Join-Path $WorkRoot 'runtime'
        $runtimeExecutable=Assert-PlainPath ([string]$runtime.executablePath) 'verified PowerShell runtime' -Leaf
        if($runtime.schemaVersion-ne1-or[string]$runtime.report-cne'consumer-runtime-receipt-v1'-or
            [string]$runtime.version-cnotmatch'^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$'-or
            [string]$runtime.archiveSha256-cnotmatch'^[0-9a-f]{64}$'-or
            [string]$runtime.executableSha256-cnotmatch'^[0-9a-f]{64}$'-or-not(Test-PathInside $runtimeExecutable `
            $runtimeRoot)-or(Get-FileSha256 $runtimeExecutable)-cne[string]$runtime.executableSha256){Throw-ConsumerResult FAILED `
                'Verified PowerShell runtime changed.'}
        $executable = $runtimeExecutable
    }
    $code = Invoke-ConsumerGateProcess $executable (Join-Path $authority.Root 'scripts/consumer/Invoke-ConsumerSourceGate.ps1') $interfacePath `
        $Phase $bindingPath $bootstrapToken
    exit $code
} catch {
    $message = [string]$_.Exception.Message
    if(-not[string]::IsNullOrEmpty($bootstrapToken)){$message=$message.Replace($bootstrapToken,'[REDACTED]')}
    if ($message -match '^(BLOCKED|FAILED|INVALID|CANCELLED)\|(.*)$') { [Console]::Error.WriteLine($Matches[2])
     exit $script:ExitCodes[$Matches[1]] }
    [Console]::Error.WriteLine($message)
     exit 20
} finally {
    $bootstrapToken=$null;$message=$null
    Remove-Variable bootstrapToken,message -ErrorAction SilentlyContinue}
