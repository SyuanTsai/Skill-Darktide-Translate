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
if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
    $BaseCommit = ([string](@(
        & $gitCommand.Path -c "safe.directory=$repoRoot" -C $repoRoot rev-parse --verify --end-of-options 'HEAD^{}' 2>$null
    ) | Select-Object -First 1)).Trim()
    if ($LASTEXITCODE -ne 0 -or $BaseCommit -notmatch '^[0-9a-f]{40}$') {
        throw 'Pre-push validation requires an explicit BaseCommit or a distinct committed parent of HEAD.'
    }
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
