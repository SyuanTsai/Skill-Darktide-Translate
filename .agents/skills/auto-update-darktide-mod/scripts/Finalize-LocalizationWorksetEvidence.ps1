# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StatePath,
    [scriptblock] $HeartbeatAction,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-FileSha256 {
    param([string] $Path)
    if ($HeartbeatAction) { $null = & $HeartbeatAction }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount)
            if ($HeartbeatAction) { $null = & $HeartbeatAction }
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose(); $stream.Dispose() }
}

function Assert-ContainedPath {
    param([string] $Candidate, [string] $Root, [string] $Label)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not $candidateFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its allowed root."
    }
    $candidateFull
}

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root, [string] $Label, [switch] $AllowMissingLeaf)
    $rawRoot = [IO.Path]::GetFullPath($Root)
    $rootFull = if ($rawRoot -ceq [IO.Path]::GetPathRoot($rawRoot)) { $rawRoot } else { $rawRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootPrefix = if ($rootFull.EndsWith([IO.Path]::DirectorySeparatorChar) -or $rootFull.EndsWith([IO.Path]::AltDirectorySeparatorChar)) { $rootFull } else { $rootFull + [IO.Path]::DirectorySeparatorChar }
    if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its physical verification root."
    }
    $relative = [IO.Path]::GetRelativePath($rootFull, $pathFull)
    $components = if ($relative -eq '.') { @() } else { @($relative -split '[\\/]') }
    $current = $rootFull
    $paths = @($rootFull)
    foreach ($component in $components) { $current = Join-Path $current $component; $paths += $current }
    for ($index = 0; $index -lt $paths.Count; $index++) {
        $candidate = $paths[$index]
        if (-not (Test-Path -LiteralPath $candidate)) {
            if ($AllowMissingLeaf -and $index -eq ($paths.Count - 1)) { continue }
            throw "$Label path component is missing."
        }
        if ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label path contains a symlink or reparse point."
        }
    }
}

function Write-AtomicJson {
    param([string] $Path, $Value)
    if ($HeartbeatAction) { $null = & $HeartbeatAction }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Atomic JSON parent directory is missing.' }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, $fullPath, $true)
}

function Write-Result {
    param($Value)
    if ($PassThru) { $Value } else { $Value | ConvertTo-Json -Depth 20 -Compress }
}

$stateFull = [IO.Path]::GetFullPath($StatePath)
Assert-NoReparsePath -Path $stateFull -Root ([IO.Path]::GetPathRoot($stateFull)) -Label 'Schema 15 state'
if (-not (Test-Path -LiteralPath $stateFull -PathType Leaf)) { throw 'Schema 15 state file does not exist.' }
$state = Get-Content -LiteralPath $stateFull -Raw | ConvertFrom-Json -AsHashtable
if ([int]$state.schemaVersion -lt 15) { throw 'Localization workset deletion evidence applies only to Schema 15.' }
if (-not $state.localizationWorkset -or [string]$state.localizationWorkset.status -cne 'applied') { throw 'Applied localization workset state is missing.' }
if (-not $state.candidateGate -or [string]$state.candidateGate.status -cne 'passed') { throw 'Localization workset deletion requires a passed Candidate Gate.' }

$stateRunRoot = Split-Path -Parent $stateFull
if (-not $state.Contains('runRoot') -or [string]::IsNullOrWhiteSpace([string]$state.runRoot) -or
    -not $state.Contains('statePath') -or [string]::IsNullOrWhiteSpace([string]$state.statePath) -or
    [IO.Path]::GetFullPath([string]$state.runRoot) -cne $stateRunRoot -or
    [IO.Path]::GetFullPath([string]$state.statePath) -cne $stateFull) {
    throw 'Schema 15 state path differs from its fixed run root tuple.'
}
$runRoot = $stateRunRoot
$securityRoot = if ($state.Contains('repositoryRoot') -and -not [string]::IsNullOrWhiteSpace([string]$state.repositoryRoot)) {
    $null = Assert-ContainedPath -Candidate $runRoot -Root ([string]$state.repositoryRoot) -Label 'Run root'
    [string]$state.repositoryRoot
}
else { $runRoot }
$artifactsRoot = Assert-ContainedPath -Candidate ([string]$state.artifactsRoot) -Root $runRoot -Label 'Artifacts root'
$worksetPath = Assert-ContainedPath -Candidate ([string]$state.localizationWorkset.path) -Root $runRoot -Label 'Localization workset'
$reportPath = Assert-ContainedPath -Candidate ([string]$state.candidateGate.validationReportPath) -Root $artifactsRoot -Label 'Candidate Gate report'
$receiptPathValue = if ($state.localizationWorkset.Contains('deletionReceiptPath') -and -not [string]::IsNullOrWhiteSpace([string]$state.localizationWorkset.deletionReceiptPath)) {
    [string]$state.localizationWorkset.deletionReceiptPath
}
else { Join-Path $artifactsRoot 'localization-workset-deletion-receipt.json' }
$receiptPath = Assert-ContainedPath -Candidate $receiptPathValue -Root $artifactsRoot -Label 'Localization workset deletion receipt'

Assert-NoReparsePath -Path $stateFull -Root $securityRoot -Label 'Schema 15 state'
Assert-NoReparsePath -Path $artifactsRoot -Root $securityRoot -Label 'Artifacts root'
Assert-NoReparsePath -Path $worksetPath -Root $securityRoot -Label 'Localization workset' -AllowMissingLeaf
Assert-NoReparsePath -Path $reportPath -Root $securityRoot -Label 'Candidate Gate report'
Assert-NoReparsePath -Path $receiptPath -Root $securityRoot -Label 'Localization workset deletion receipt' -AllowMissingLeaf

if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'Candidate Gate report is missing before workset deletion.' }
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -AsHashtable
if ([string]$report.result -cne 'passed' -or [string]$report.runId -cne [string]$state.runId) { throw 'Candidate Gate report is not a passed report for this run.' }
$worksetExists = Test-Path -LiteralPath $worksetPath -PathType Leaf
$receipt = if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
$receiptShaBefore = if ($receipt) { Get-FileSha256 -Path $receiptPath } else { $null }
$reportShaBefore = Get-FileSha256 -Path $reportPath
$alreadyFinalized = -not $worksetExists -and $receipt -and [string]$receipt.status -ceq 'deleted' -and
    $state.localizationWorkset.Contains('deletedBeforePublish') -and [bool]$state.localizationWorkset.deletedBeforePublish -and
    $state.localizationWorkset.Contains('deletionReceiptSha256') -and [string]$state.localizationWorkset.deletionReceiptSha256 -ceq $receiptShaBefore -and
    $report.Contains('worksetDeletion') -and [string]$report.worksetDeletion.receiptSha256 -ceq $receiptShaBefore -and
    [string]$state.candidateGate.validationReportSha256 -ceq $reportShaBefore

if (-not $receipt) {
    if (-not $worksetExists) { throw 'Localization workset is missing without recoverable deletion evidence.' }
    $actualWorksetSha = Get-FileSha256 -Path $worksetPath
    if ($actualWorksetSha -cne [string]$state.localizationWorkset.sha256) { throw 'Localization workset SHA-256 changed before deletion.' }
    if ($reportShaBefore -cne [string]$state.candidateGate.validationReportSha256) { throw 'Candidate Gate report changed before deletion evidence was created.' }
    $receipt = [ordered]@{
        schemaVersion = 1
        workflowSchemaVersion = 15
        runId = $state.runId
        status = 'pending'
        worksetPath = $worksetPath
        worksetSha256 = $actualWorksetSha
        validationReportPath = $reportPath
        validationReportBeforeDeletionSha256 = $reportShaBefore
        createdAt = Get-UtcTimestamp
    }
    Assert-NoReparsePath -Path $receiptPath -Root $securityRoot -Label 'Localization workset deletion receipt' -AllowMissingLeaf
    Write-AtomicJson -Path $receiptPath -Value $receipt
}
else {
    if ([int]$receipt.schemaVersion -ne 1 -or [int]$receipt.workflowSchemaVersion -ne 15 -or
        [string]$receipt.runId -cne [string]$state.runId -or [string]$receipt.worksetPath -cne $worksetPath -or
        [string]$receipt.worksetSha256 -cne [string]$state.localizationWorkset.sha256 -or
        [string]$receipt.validationReportPath -cne $reportPath -or [string]$receipt.status -notin @('pending', 'deleted')) {
        throw 'Localization workset deletion receipt does not match the current run tuple.'
    }
}

if (-not $receipt.Contains('validationReportBeforeDeletionSha256') -or
    [string]$receipt.validationReportBeforeDeletionSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Localization workset deletion receipt has an invalid pre-deletion Candidate Gate report SHA-256.'
}
$stateDeletionFinalized = $state.localizationWorkset.Contains('deletedBeforePublish') -and [bool]$state.localizationWorkset.deletedBeforePublish
if (-not $stateDeletionFinalized -and
    [string]$receipt.validationReportBeforeDeletionSha256 -cne [string]$state.candidateGate.validationReportSha256) {
    throw 'Localization workset deletion receipt does not match the pre-deletion Candidate Gate report in state.'
}
if ($worksetExists -and $reportShaBefore -cne [string]$receipt.validationReportBeforeDeletionSha256) {
    throw 'Candidate Gate report changed before localization workset deletion.'
}

if ([string]$receipt.status -ceq 'deleted' -and $worksetExists) { throw 'A finalized deletion receipt exists while the localization workset still exists.' }
if ([string]$receipt.status -ceq 'pending' -and $worksetExists) {
    if ((Get-FileSha256 -Path $worksetPath) -cne [string]$receipt.worksetSha256) { throw 'Localization workset changed after deletion became pending.' }
    Assert-NoReparsePath -Path $worksetPath -Root $securityRoot -Label 'Localization workset'
    if ($HeartbeatAction) { $null = & $HeartbeatAction }
    [IO.File]::Delete($worksetPath)
    $worksetExists = $false
}
if ([string]$receipt.status -ceq 'pending' -and -not $worksetExists) {
    $receipt.status = 'deleted'
    $receipt.deletedAt = Get-UtcTimestamp
    Assert-NoReparsePath -Path $receiptPath -Root $securityRoot -Label 'Localization workset deletion receipt'
    Write-AtomicJson -Path $receiptPath -Value $receipt
}
if ([string]$receipt.status -cne 'deleted' -or (Test-Path -LiteralPath $worksetPath)) { throw 'Localization workset deletion did not finalize.' }
$receiptSha = Get-FileSha256 -Path $receiptPath

$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -AsHashtable
if ($report.Contains('worksetDeletion')) {
    if ([string]$report.worksetDeletion.status -cne 'deleted' -or
        [string]$report.worksetDeletion.worksetSha256 -cne [string]$receipt.worksetSha256 -or
        [string]$report.worksetDeletion.receiptSha256 -cne $receiptSha) {
        throw 'Candidate Gate report contains conflicting localization workset deletion evidence.'
    }
}
else {
    if ((Get-FileSha256 -Path $reportPath) -cne [string]$receipt.validationReportBeforeDeletionSha256) {
        throw 'Candidate Gate report changed before deletion evidence could be bound.'
    }
    $report['worksetDeletion'] = [ordered]@{
        status = 'deleted'
        worksetSha256 = $receipt.worksetSha256
        receiptPath = $receiptPath
        receiptSha256 = $receiptSha
        deletedAt = $receipt.deletedAt
    }
    Assert-NoReparsePath -Path $reportPath -Root $securityRoot -Label 'Candidate Gate report'
    Write-AtomicJson -Path $reportPath -Value $report
}
$reportSha = Get-FileSha256 -Path $reportPath

$state.localizationWorkset.deletedBeforePublish = $true
$state.localizationWorkset.deletedSha256 = $receipt.worksetSha256
$state.localizationWorkset.deletionReceiptPath = $receiptPath
$state.localizationWorkset.deletionReceiptSha256 = $receiptSha
$state.candidateGate.validationReportSha256 = $reportSha
$state.candidateGate.localizationWorksetDeletionReceiptSha256 = $receiptSha
if ($state.Contains('completedStages') -and @($state.completedStages) -contains 'validate' -and
    $state.Contains('stageTimings') -and $state.stageTimings.Contains('validate')) {
    $state.stageTimings.validate.artifactSha256 = $reportSha
}
$state.updatedAt = Get-UtcTimestamp
Assert-NoReparsePath -Path $stateFull -Root $securityRoot -Label 'Schema 15 state'
Write-AtomicJson -Path $stateFull -Value $state

Write-Result -Value ([ordered]@{
    result = 'passed'
    status = 'deleted'
    idempotent = [bool]$alreadyFinalized
    worksetSha256 = $receipt.worksetSha256
    receiptPath = $receiptPath
    receiptSha256 = $receiptSha
    validationReportPath = $reportPath
    validationReportSha256 = $reportSha
})
