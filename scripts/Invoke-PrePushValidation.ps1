# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string] $ArtifactsRoot = $(
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP }
        else { [IO.Path]::GetTempPath() }
    ),
    [string] $BaseCommit,
    [string] $AuthorityRepositoryRoot,
    [string] $PowerShellExecutable,
    [int] $TimeoutSeconds = 1800,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1

function Resolve-ImplicitComparisonBase {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot
    )

    $gitConfigArguments = @('-c', "safe.directory=$RepositoryRoot", '-c', "core.worktree=$RepositoryRoot")
    $remoteHeadOutput = @(
        & $GitPath @gitConfigArguments -C $RepositoryRoot symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
    )
    if ($LASTEXITCODE -ne 0 -or $remoteHeadOutput.Count -ne 1) {
        throw 'Could not resolve origin/HEAD to one remote default branch; specify -BaseCommit explicitly.'
    }

    $remoteHeadRef = ([string]$remoteHeadOutput[0]).Trim()
    if ($remoteHeadRef -notmatch '^origin/[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
        $remoteHeadRef -match '(^|/)\.\.?(/|$)') {
        throw "Resolved remote default branch '$remoteHeadRef' is not a safe origin ref; specify -BaseCommit explicitly."
    }

    $mergeBaseOutput = @(
        & $GitPath @gitConfigArguments -C $RepositoryRoot merge-base --all -- $remoteHeadRef HEAD 2>$null
    )
    if ($LASTEXITCODE -ne 0 -or $mergeBaseOutput.Count -ne 1 -or [string]$mergeBaseOutput[0] -cnotmatch '^[0-9a-f]{40}$') {
        throw "Could not derive one immutable comparison base from '$remoteHeadRef' and HEAD; specify -BaseCommit explicitly."
    }

    return ([string]$mergeBaseOutput[0]).Trim()
}

if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
    # Compare every commit reachable from the branch against its remote default
    # branch. An immediate-parent fallback would silently omit earlier commits.
    $BaseCommit = Resolve-ImplicitComparisonBase -GitPath $gitCommand.Path -RepositoryRoot $repoRoot
}
$resolvedBase = @(& $gitCommand.Path -C $repoRoot rev-parse --verify --end-of-options "$BaseCommit^{commit}")
if ($LASTEXITCODE -ne 0 -or $resolvedBase.Count -ne 1 -or [string]$resolvedBase[0] -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Comparison base must resolve to one immutable commit.'
}
$BaseCommit = ([string]$resolvedBase[0]).Trim()
$candidate = ([string](& $gitCommand.Path -C $repoRoot rev-parse HEAD)).Trim()
if ($LASTEXITCODE -ne 0 -or $candidate -cnotmatch '^[0-9a-f]{40}$') { throw 'Could not identify the exact source candidate.' }
$dirty = @(& $gitCommand.Path -C $repoRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Pre-push validation requires a clean immutable candidate.' }
$owned = [IO.Path]::GetFullPath((Join-Path $ArtifactsRoot ('dt-' + [guid]::NewGuid().ToString('N').Substring(0,12))))
if ($owned.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run-owned evidence must remain outside the candidate repository.'
}
if (Test-Path -LiteralPath $owned) { throw 'Run-owned evidence already exists.' }
[void][IO.Directory]::CreateDirectory($owned)
$config = Get-Content -LiteralPath (Join-Path $repoRoot 'config/standard-v1.json') -Raw -Encoding utf8 | ConvertFrom-Json
$approvedAuthorityCommit = 'ff85d5f80fe795b96354e753074b5ce59ad04ecd'
$approvedArchiveSha256 = '3dc38613f2e2316ad8fcc79d4bf48d0b03fd8398f8dacc72d156abcbce95ea9d'
if ($config.authority.repository -isnot [string] -or $config.authority.commit -isnot [string] -or
    $config.authority.archiveUrl -isnot [string] -or $config.authority.archiveSha256 -isnot [string] -or
    $config.authority.repository -cne 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' -or
    $config.authority.commit -cne $approvedAuthorityCommit -or
    $config.authority.archiveUrl -cne "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$approvedAuthorityCommit" -or
    $config.authority.archiveSha256 -cne $approvedArchiveSha256) {
    throw 'Pre-push authority acquisition must use the reviewed immutable source tuple.'
}
$archive = Join-Path $owned 'authority.zip'
Invoke-WebRequest -Uri $config.authority.archiveUrl -OutFile $archive -TimeoutSec 180
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $config.authority.archiveSha256) {
    throw 'Authority archive does not match its immutable pin.'
}
if ([string]::IsNullOrWhiteSpace($AuthorityRepositoryRoot)) {
    $AuthorityRepositoryRoot = Join-Path $owned 'authority'
    & $gitCommand.Path -c core.autocrlf=false clone --quiet --no-checkout -- $config.authority.repository $AuthorityRepositoryRoot
    if ($LASTEXITCODE -ne 0) { throw 'Authority acquisition failed.' }
    & $gitCommand.Path -c core.autocrlf=false -C $AuthorityRepositoryRoot checkout --quiet --detach $config.authority.commit
    if ($LASTEXITCODE -ne 0) { throw 'Immutable authority checkout failed.' }
}
if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) {
    $runtime = & (Join-Path $repoRoot 'scripts/Install-LatestPowerShell.ps1') -InstallRoot (Join-Path $owned 'powershell')
    $PowerShellExecutable = [string]$runtime.executablePath
    $previousOwnedRoot = [Environment]::GetEnvironmentVariable('RUN_OWNED_ROOT', 'Process')
    try {
        $env:RUN_OWNED_ROOT = $owned
        & $PowerShellExecutable -NoLogo -NoProfile -NonInteractive -File (Join-Path $repoRoot 'scripts/Prepare-PesterRuntime.ps1') `
            -RuntimeExecutable $PowerShellExecutable -OwnedRoot $owned
        if ($LASTEXITCODE -ne 0) { throw 'Verified Pester runtime setup failed.' }
    }
    finally { [Environment]::SetEnvironmentVariable('RUN_OWNED_ROOT', $previousOwnedRoot, 'Process') }
}
$PowerShellExecutable = [IO.Path]::GetFullPath($PowerShellExecutable)
$setupRoot = Join-Path $owned 'tools'
$preparedPath = Join-Path $setupRoot 'source-tools.json'
$artifacts = Join-Path $owned 'artifacts'
$reportPath = Join-Path $artifacts 'source-report.json'
$common = @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $repoRoot 'scripts/Validate.ps1'),
    '-RepositoryRoot',$repoRoot,'-BaseCommit',$BaseCommit,'-AuthorityRepositoryRoot',$AuthorityRepositoryRoot,
    '-AuthorityArchivePath',$archive,'-TrustedToolRoot',(Split-Path -Parent $PowerShellExecutable),
    '-SourceToolsPath',$preparedPath,'-TimeoutSeconds',[string]$TimeoutSeconds)
& $PowerShellExecutable @common -PrepareSourceTools -ArtifactsRoot $setupRoot
if ($LASTEXITCODE -ne 0) { throw 'Explicit frozen source tool setup failed.' }
& $PowerShellExecutable @common -SourceValidation -ArtifactsRoot $artifacts -OutputPath $reportPath
$processExit = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw "Source validation exited $processExit without a complete report." }
$report = Get-Content -LiteralPath $reportPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
if ($processExit -ne 0) { throw "Source validation failed with exit $processExit; evidence: $reportPath" }
. (Join-Path $AuthorityRepositoryRoot 'scripts/Invoke-StandardValidation.ps1') -DefineFunctionsOnly `
    -CandidateRoot $repoRoot -AdapterPath $preparedPath -ArtifactsRoot $artifacts `
    -SourceRepository 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git' -SourceRevision $candidate -BaseRevision $BaseCommit
$eventName = switch ([string]$env:GITHUB_EVENT_NAME) {
    { $_ -cin @('pull_request','push','workflow_dispatch','pre-push') } { $_ }
    default { 'local' }
}
[void](Assert-StandardCoreSourceCheckReport -Report $report -ExpectedSourceRevision $candidate `
    -ExpectedBaseRevision $BaseCommit -ExpectedAuthorityRevision $config.authority.commit -ExpectedEventName $eventName `
    -ArtifactsRoot $artifacts -OutputPath $reportPath -ProcessExitCode $processExit)
$pin = (@(& (Join-Path $repoRoot 'scripts/Get-SourcePin.ps1') -Ref $candidate) -join "`n") | ConvertFrom-Json -Depth 50
$pinPath = Join-Path $owned 'source-pin.json'
[IO.File]::WriteAllText($pinPath, (($pin | ConvertTo-Json -Depth 50) + "`n"), [Text.UTF8Encoding]::new($false))
$integrity = & (Join-Path $repoRoot 'skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1') -SkillSourcePinPath $pinPath | ConvertFrom-Json
if ($integrity.result -cne 'passed') { throw 'Source-pin reference integrity failed.' }
$result = [pscustomobject]@{ result='passed'; candidate=@{commit=$candidate;baseCommit=$BaseCommit}; authority=$config.authority;
    sourceReportPath=$reportPath; sourcePinPath=$pinPath; releaseEligible=$false; sourceReport=$report }
if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 100 }
