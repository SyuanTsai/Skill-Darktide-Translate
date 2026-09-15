# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string] $ArtifactsRoot = $(
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP }
        else { [IO.Path]::GetTempPath() }
    ),
    [string] $BaseCommit,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$arguments = @{
    RepositoryRoot = $repoRoot
    ArtifactsRoot = $ArtifactsRoot
}
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
$arguments.BaseCommit = $BaseCommit

$validationOutput = @(& (Join-Path $repoRoot 'scripts/Validate.ps1') @arguments)
if ($LASTEXITCODE -ne 0) { throw 'Canonical Standard v1 validation failed.' }

if ($PassThru) {
    $validationOutput | Select-Object -Last 1 | ConvertFrom-Json -Depth 100
}
else {
    $validationOutput
}
