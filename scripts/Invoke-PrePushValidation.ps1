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
if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) { $arguments.BaseCommit = $BaseCommit }

$validationOutput = @(& (Join-Path $repoRoot 'scripts/Validate.ps1') @arguments)
if ($LASTEXITCODE -ne 0) { throw 'Canonical Standard v1 validation failed.' }

if ($PassThru) {
    $validationOutput | Select-Object -Last 1 | ConvertFrom-Json -Depth 100
}
else {
    $validationOutput
}
