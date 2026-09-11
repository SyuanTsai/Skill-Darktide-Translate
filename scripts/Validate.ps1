# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidatePattern('^[0-9a-fA-F]{40}$|^HEAD$')]
    [string] $CandidateCommit = 'HEAD',
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $ProductBaselineCommit = '67fdb8c714468b59f5efd8cf4e74abdb4039d765',
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Test-ValidationTransition.ps1') `
    -RepositoryRoot $RepositoryRoot `
    -CandidateCommit $CandidateCommit `
    -ProductBaselineCommit $ProductBaselineCommit `
    -OutputPath $OutputPath `
    -RequireFormalValidation
