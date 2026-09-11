# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $ProductBaselineCommit = '67fdb8c714468b59f5efd8cf4e74abdb4039d765',
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$initialState = & (Join-Path $repoRoot 'scripts/Test-CleanRepositoryHead.ps1') `
    -RepositoryRoot $repoRoot `
    -PassThru

$testOutput = @(& (Join-Path $repoRoot 'tests/Invoke-Tests.ps1'))
$testSummary = @($testOutput | Where-Object {
        $_.PSObject.Properties.Name -contains 'result' -and $_.result -ceq 'passed'
    } | Select-Object -Last 1)
if ($testSummary.Count -ne 1) {
    throw 'Repository tests did not return one passing summary.'
}

$repositoryJson = & (Join-Path $repoRoot 'scripts/Test-Repository.ps1') `
    -RepositoryRoot $repoRoot `
    -ValidationTransition `
    -NoFilters |
    Select-Object -Last 1
$repositoryResult = $repositoryJson | ConvertFrom-Json
if ($repositoryResult.result -cne 'passed' -or
    $repositoryResult.validationMode -cne 'validation-rebuild-maintenance' -or
    $repositoryResult.formalValidationStatus -cne 'pending-rebuild' -or
    $repositoryResult.releaseEligible -ne $false) {
    throw 'Repository integrity did not return the expected rebuild-maintenance-only state.'
}

$integrity = & (Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1') `
    -PassThru
if ($integrity.result -cne 'passed') {
    throw 'Packaged reference integrity validation did not pass.'
}

$pinJson = @(& (Join-Path $repoRoot 'scripts/Get-SourcePin.ps1') -Ref $initialState.headOid) -join "`n"
$pin = $pinJson | ConvertFrom-Json
if ($pin.sourceId -cne 'darktide-translate' -or
    $pin.resolvedCommit -cne $initialState.headOid -or
    $pin.contentSha256 -notmatch '^[0-9a-f]{64}$' -or
    $pin.resolvedVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw 'The reproducible source pin does not match the validated repository HEAD.'
}

$transition = & (Join-Path $repoRoot 'scripts/Test-ValidationTransition.ps1') `
    -RepositoryRoot $repoRoot `
    -CandidateCommit $initialState.headOid `
    -ProductBaselineCommit $ProductBaselineCommit `
    -PassThru
if ($transition.result -cne 'passed' -or
    $transition.validationStatus -cne 'transition-policy-passed' -or
    $transition.formalValidationStatus -cne 'pending-rebuild' -or
    $transition.releaseEligible -ne $false) {
    throw 'Validation transition did not return the expected release-blocked maintenance state.'
}

$finalState = & (Join-Path $repoRoot 'scripts/Test-CleanRepositoryHead.ps1') `
    -RepositoryRoot $repoRoot `
    -ExpectedHeadOid $initialState.headOid `
    -PassThru

$result = [ordered]@{
    result = 'passed'
    validationStatus = 'rebuild-checks-passed'
    formalValidationStatus = 'pending-rebuild'
    releaseEligible = $false
    headOid = $finalState.headOid
    productBaselineCommit = $transition.productBaselineCommit
    productInventorySha256 = $transition.productInventorySha256
    resolvedVersion = $pin.resolvedVersion
    contentSha256 = $pin.contentSha256
    testCount = $testSummary[0].testCount
    passedCount = $testSummary[0].passedCount
}

if ($PassThru) { [PSCustomObject]$result }
else { $result | ConvertTo-Json }
