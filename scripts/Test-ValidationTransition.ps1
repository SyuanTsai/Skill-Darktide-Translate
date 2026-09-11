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
    [string] $OutputPath,
    [switch] $RequireFormalValidation,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitText {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = @(& git -C $script:ResolvedRepositoryRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Resolve-GitCommit {
    param(
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][string] $Context
    )

    $resolved = @(
        Invoke-GitText -Arguments @('rev-parse', '--verify', "$Revision^{commit}")
    )[0].Trim().ToLowerInvariant()
    if ($resolved -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context did not resolve to one full commit SHA."
    }
    return $resolved
}

function Get-ProductInventory {
    param([Parameter(Mandatory)][string] $Commit)

    $productPaths = @(
        '.agents/skills/auto-update-darktide-mod',
        'catalog/skills-catalog.json',
        'VERSION'
    )
    $lines = @(
        Invoke-GitText -Arguments (@('ls-tree', '-r', '--full-tree', $Commit, '--') + $productPaths)
    )
    if ($lines.Count -eq 0) {
        throw "Product inventory is empty at commit '$Commit'."
    }
    foreach ($requiredRoot in $productPaths) {
        $matched = @($lines | Where-Object {
                $_ -match "\t$([regex]::Escape($requiredRoot))(?:/|$)"
            })
        if ($matched.Count -eq 0) {
            throw "Product inventory is missing '$requiredRoot' at commit '$Commit'."
        }
    }

    $canonical = (@($lines | Sort-Object -CaseSensitive) -join "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical)
    $sha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)
    ).ToLowerInvariant()
    return [pscustomobject][ordered]@{
        commit = $Commit
        sha256 = $sha256
        entries = @($lines | Sort-Object -CaseSensitive)
    }
}

function Assert-CandidateRegularBlob {
    param(
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][string] $RelativePath
    )

    $entry = @(Invoke-GitText -Arguments @('ls-tree', '--full-tree', $Commit, '--', $RelativePath))
    if ($entry.Count -ne 1 -or
        $entry[0] -cnotmatch '^(100644|100755) blob [0-9a-f]{40,64}\t') {
        throw "Transition path '$RelativePath' must be exactly one tracked regular blob at '$Commit'."
    }
}

function Assert-CandidatePathAbsent {
    param(
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][string] $RelativePath
    )

    $entry = @(Invoke-GitText -Arguments @('ls-tree', '--full-tree', $Commit, '--', $RelativePath))
    if ($entry.Count -ne 0) {
        throw "Retired validation path '$RelativePath' is still tracked at '$Commit'."
    }
}

$script:ResolvedRepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $script:ResolvedRepositoryRoot -PathType Container)) {
    throw "RepositoryRoot is missing: $($script:ResolvedRepositoryRoot)"
}
$gitRoot = @(Invoke-GitText -Arguments @('rev-parse', '--show-toplevel'))[0].Trim()
$resolvedGitRoot = [IO.Path]::GetFullPath($gitRoot)
if (-not $resolvedGitRoot.Equals($script:ResolvedRepositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'RepositoryRoot must be the Git repository root.'
}

$candidate = Resolve-GitCommit -Revision $CandidateCommit -Context 'Candidate commit'
$baseline = Resolve-GitCommit -Revision $ProductBaselineCommit -Context 'Product baseline commit'
$checkedOutHead = Resolve-GitCommit -Revision 'HEAD' -Context 'Checked-out HEAD'
if ($candidate -cne $checkedOutHead) {
    throw "Candidate commit '$candidate' is not the checked-out HEAD '$checkedOutHead'."
}

$null = & git -C $script:ResolvedRepositoryRoot merge-base --is-ancestor $baseline $candidate 2>$null
$ancestryExitCode = $LASTEXITCODE
if ($ancestryExitCode -eq 1) {
    throw "Product baseline '$baseline' is not an ancestor of candidate '$candidate'."
}
if ($ancestryExitCode -ne 0) {
    throw "Git could not verify candidate ancestry (exit $ancestryExitCode)."
}

$baselineInventory = Get-ProductInventory -Commit $baseline
$candidateInventory = Get-ProductInventory -Commit $candidate
if ($baselineInventory.sha256 -cne $candidateInventory.sha256 -or
    ($baselineInventory.entries -join "`n") -cne ($candidateInventory.entries -join "`n")) {
    throw "Product inventory differs between baseline '$baseline' and candidate '$candidate'."
}

$requiredTransitionPaths = @(
    '.github/workflows/standard-v1-protected.yml',
    '.github/workflows/validation-rebuild.yml',
    'docs/RELEASE.md',
    'scripts/Get-SourcePin.ps1',
    'scripts/Invoke-PrePushValidation.ps1',
    'scripts/Test-CleanRepositoryHead.ps1',
    'scripts/Test-Repository.ps1',
    'scripts/Test-ValidationTransition.ps1',
    'scripts/Validate.ps1',
    'tests/Invoke-Tests.ps1',
    'tests/LocalizationWorkset.Tests.ps1',
    'tests/ModUpdateAutomation.Tests.ps1',
    'tests/RepositoryContract.Tests.ps1',
    'tests/RepositoryValidation.Tests.ps1',
    'tests/Schema15Coordination.Tests.ps1',
    'tests/Schema15SourceAcquisition.Tests.ps1',
    'tests/SkillContract.Tests.ps1',
    'tests/SourcePin.Tests.ps1',
    'tests/TestSupport.ps1',
    'tests/ValidationTransition.Tests.ps1'
)
foreach ($relativePath in $requiredTransitionPaths) {
    Assert-CandidateRegularBlob -Commit $candidate -RelativePath $relativePath
}
foreach ($relativePath in @(
        '.github/workflows/skill-validator.yml',
        '.github/workflows/validate.yml',
        'tests/BootstrapTransition.Tests.ps1',
        'tests/validate-windows-powershell.ps1'
    )) {
    Assert-CandidatePathAbsent -Commit $candidate -RelativePath $relativePath
}

$state = [pscustomobject][ordered]@{
    schemaVersion = 1
    validationScope = 'validation-rebuild-maintenance'
    result = if ($RequireFormalValidation) { 'blocked' } else { 'passed' }
    validationStatus = 'transition-policy-passed'
    formalValidationStatus = 'pending-rebuild'
    releaseEligible = $false
    candidateCommit = $candidate
    productBaselineCommit = $baseline
    productInventorySha256 = [string]$candidateInventory.sha256
    missingFormalCapabilities = @(
        'trusted-cross-platform-executor',
        'independent-test-control',
        'complete-standard-v1-toolchain',
        'formal-code-and-security-review',
        'human-release-approval'
    )
}
$json = $state | ConvertTo-Json -Depth 10
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $outputFullPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }
    [IO.File]::WriteAllText(
        $outputFullPath,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

if ($PassThru) { Write-Output $state }
else { Write-Output $json }

if ($RequireFormalValidation) {
    throw 'Formal Standard v1 validation is pending rebuild; this candidate is not release eligible.'
}
