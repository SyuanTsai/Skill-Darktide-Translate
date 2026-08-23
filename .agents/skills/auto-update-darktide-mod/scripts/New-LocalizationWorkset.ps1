#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $BaseOid,
    [Parameter(Mandatory)][string] $ModRelativePath,
    [Parameter(Mandatory)][string] $StagingModPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $SourceId,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Force

function Write-Result {
    param($Value)
    if ($PassThru) { $Value } else { $Value | ConvertTo-Json -Depth 30 -Compress }
}

function Write-AtomicJson {
    param([string] $Path, $Value)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Get-FileSha256 {
    param([string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ImmutableWorksetContractSha256 {
    param($Workset)
    $unitContracts = @($Workset.units | ForEach-Object {
        [ordered]@{
            unitId = $_.unitId; sourceId = $_.sourceId; containerPath = $_.containerPath
            key = $_.key; occurrence = $_.occurrence; old = $_.old; new = $_.new
            changeType = $_.changeType; action = $_.action; blockedReason = $_.blockedReason
        }
    })
    $contract = [ordered]@{
        schemaVersion = $Workset.schemaVersion
        workflowSchemaVersion = $Workset.workflowSchemaVersion
        generatorVersion = $Workset.generatorVersion
        baseOid = $Workset.baseOid
        sourceId = $Workset.sourceId
        modRelativePath = $Workset.modRelativePath
        old = $Workset.old
        new = $Workset.new
        counts = $Workset.counts
        units = $unitContracts
    }
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($contract | ConvertTo-Json -Depth 40 -Compress))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Invoke-GitText {
    param([string] $WorkingDirectory, [string[]] $Arguments, [switch] $AllowFailure)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start Git for localization workset generation.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $result = [ordered]@{ exitCode = $process.ExitCode; output = $stdoutTask.Result.TrimEnd(); warning = $stderrTask.Result.TrimEnd() }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) { throw "Git localization query failed: $($result.warning) $($result.output)" }
    $result
}

function Get-GitBlobBytes {
    param([string] $WorkingDirectory, [string] $Object)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start Git blob reader for localization workset generation.' }
    $memory = [IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $errorText = $process.StandardError.ReadToEnd(); $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Unable to read immutable localization blob: $errorText" }
    $memory.ToArray()
}

function Assert-ContainedPath {
    param([string] $Candidate, [string] $Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not $candidateFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'NEW localization path escapes the staging MOD root.'
    }
    $candidateFull
}

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root)
    $rootFull = [IO.Path]::GetFullPath($Root)
    $current = Get-Item -LiteralPath $Path
    while ($true) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'NEW localization path contains a symlink or reparse point.' }
        if ($current.FullName -eq $rootFull) { break }
        $parent = Split-Path -Parent $current.FullName
        if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Unable to prove NEW localization containment.' }
        $current = Get-Item -LiteralPath $parent
    }
}

function Get-Utf8Text {
    param([byte[]] $Bytes)
    $offset = if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { 3 } else { 0 }
    [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $offset, $Bytes.Length - $offset)
}

function Get-CanonicalExpression {
    param($Expression)
    if ($null -eq $Expression) { return $null }
    [string]$Expression.canonical
}

function New-UnitRecord {
    param($OldUnit, $NewUnit)
    $identity = if ($null -ne $NewUnit) { $NewUnit } else { $OldUnit }
    $blockedReason = if ($null -ne $NewUnit -and -not [string]::IsNullOrWhiteSpace([string]$NewUnit.blockedReason)) { [string]$NewUnit.blockedReason }
        elseif ($null -ne $OldUnit -and -not [string]::IsNullOrWhiteSpace([string]$OldUnit.blockedReason)) { [string]$OldUnit.blockedReason }
        else { $null }
    $oldSource = if ($null -ne $OldUnit) { Get-CanonicalExpression $OldUnit.sourceExpression } else { $null }
    $newSource = if ($null -ne $NewUnit) { Get-CanonicalExpression $NewUnit.sourceExpression } else { $null }
    $oldZhTw = if ($null -ne $OldUnit) { Get-CanonicalExpression $OldUnit.zhTwExpression } else { $null }
    $newZhTw = if ($null -ne $NewUnit) { Get-CanonicalExpression $NewUnit.zhTwExpression } else { $null }

    $changeType = $null; $action = $null
    if (-not [string]::IsNullOrWhiteSpace($blockedReason)) { $changeType = 'blocked'; $action = 'BLOCKED' }
    elseif ($null -eq $OldUnit) { $changeType = 'new_key'; $action = 'AI_REQUIRED' }
    elseif ($null -eq $NewUnit) { $changeType = 'deleted_key'; $action = 'ACCEPT_REMOVAL' }
    elseif ($oldSource -ceq $newSource -and $oldZhTw -ceq $newZhTw) { $changeType = 'unchanged'; $action = 'NONE' }
    elseif ($oldSource -ceq $newSource) { $changeType = 'zh_tw_only_changed'; $action = 'RESTORE_OLD_ZH_TW' }
    elseif ($oldZhTw -ceq $newZhTw) { $changeType = 'source_changed_translation_unchanged'; $action = 'AI_REQUIRED' }
    else { $changeType = 'source_and_translation_changed'; $action = 'AI_REQUIRED' }

    [ordered]@{
        unitId = $identity.unitId
        sourceId = $identity.sourceId
        containerPath = $identity.containerPath
        key = $identity.key
        occurrence = $identity.occurrence
        old = $OldUnit
        new = $NewUnit
        changeType = $changeType
        action = $action
        blockedReason = $blockedReason
        reviewStatus = if ($action -eq 'AI_REQUIRED') { 'pending' } else { 'not-required' }
        suggestedZhTwExpression = $null
    }
}

$repository = [IO.Path]::GetFullPath($RepositoryRoot)
$stagingRoot = [IO.Path]::GetFullPath($StagingModPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $repository -PathType Container)) { throw 'RepositoryRoot does not exist.' }
if (-not (Test-Path -LiteralPath $stagingRoot -PathType Container)) { throw 'StagingModPath does not exist.' }
if ((Split-Path -Leaf $outputFull) -cne 'localization-workset.json' -or (Split-Path -Leaf (Split-Path -Parent $outputFull)) -cne 'review-artifacts') {
    throw 'Localization workset must be review-artifacts/localization-workset.json.'
}
$normalizedModPath = $ModRelativePath.Replace('\', '/').Trim('/')
if ([string]::IsNullOrWhiteSpace($normalizedModPath) -or $normalizedModPath.Contains('..')) { throw 'ModRelativePath is invalid.' }
$resolvedBaseOid = (Invoke-GitText -WorkingDirectory $repository -Arguments @('rev-parse', "$BaseOid^{commit}")).output.Trim()
if ($resolvedBaseOid -notmatch '^[0-9a-f]{40}$') { throw 'BaseOid did not resolve to a 40-character commit OID.' }
$sourceIdentity = if ([string]::IsNullOrWhiteSpace($SourceId)) { $normalizedModPath } else { $SourceId }
$existingWorkset = if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
    Get-Content -LiteralPath $outputFull -Raw | ConvertFrom-Json -AsHashtable
} else { $null }
if ($existingWorkset -and [string]$existingWorkset.status -ceq 'applied') {
    if ([string]$existingWorkset.baseOid -cne $resolvedBaseOid -or [string]$existingWorkset.sourceId -cne $sourceIdentity -or
        [string]$existingWorkset.modRelativePath -cne $normalizedModPath) {
        throw 'Existing applied localization workset belongs to a different immutable input tuple.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$existingWorkset.immutableContractSha256) -or
        (Get-ImmutableWorksetContractSha256 -Workset $existingWorkset) -cne [string]$existingWorkset.immutableContractSha256) {
        throw 'Existing localization workset immutable contract changed.'
    }
    if ([IO.Path]::GetFullPath([string]$existingWorkset.new.root) -cne $stagingRoot) { throw 'Existing applied workset staging root changed.' }
    $existingNewPath = Assert-ContainedPath -Candidate ([string]$existingWorkset.new.path) -Root $stagingRoot
    Assert-NoReparsePath -Path $existingNewPath -Root $stagingRoot
    if (-not (Test-Path -LiteralPath $existingNewPath -PathType Leaf) -or
        (Get-FileSha256 -Path $existingNewPath) -cne [string]$existingWorkset.apply.outputSha256) {
        throw 'Existing applied localization workset output changed.'
    }
    Write-Result -Value ([ordered]@{ result = 'passed'; status = 'applied'; idempotent = $true; path = $outputFull; sha256 = Get-FileSha256 -Path $outputFull; unitCount = @($existingWorkset.units).Count })
    return
}

$oldListing = (Invoke-GitText -WorkingDirectory $repository -Arguments @('-c', 'core.quotePath=false', 'ls-tree', '-r', '--name-only', $resolvedBaseOid, '--', $normalizedModPath)).output
$oldPaths = @(
    $oldListing -split "`r?`n" |
        Where-Object { $_ -and [IO.Path]::GetFileName($_) -like '*_localization.lua' }
)
if ($oldPaths.Count -ne 1) {
    Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; reason = 'localization_entry_not_unique'; oldCount = $oldPaths.Count })
    return
}
$newFiles = @(Get-ChildItem -LiteralPath $stagingRoot -File -Recurse | Where-Object { $_.Name -like '*_localization.lua' })
if ($newFiles.Count -ne 1) {
    Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; reason = 'localization_entry_not_unique'; newCount = $newFiles.Count })
    return
}
$newPath = Assert-ContainedPath -Candidate $newFiles[0].FullName -Root $stagingRoot
Assert-NoReparsePath -Path $newPath -Root $stagingRoot
$oldPath = [string]$oldPaths[0]
$oldBytes = Get-GitBlobBytes -WorkingDirectory $repository -Object "$resolvedBaseOid`:$oldPath"
$newBytes = [IO.File]::ReadAllBytes($newPath)
$oldDocument = Get-LuaLocalizationDocument -Bytes $oldBytes -DisplayPath $oldPath -SourceId $sourceIdentity
$newDocument = Get-LuaLocalizationDocument -Path $newPath -SourceId $sourceIdentity

$loaderPattern = '(?s)\bmod\s*:\s*io_dofile\s*\('
if (@($oldDocument.units).Count -eq 0 -and @($newDocument.units).Count -eq 0 -and
    ((Get-Utf8Text -Bytes $oldBytes) -match $loaderPattern -or (Get-Utf8Text -Bytes $newBytes) -match $loaderPattern)) {
    Write-Result -Value ([ordered]@{ result = 'excluded'; status = 'automation-excluded'; reason = 'localization_entry_is_loader'; sourceId = $sourceIdentity })
    return
}

$oldById = @{}; foreach ($unit in @($oldDocument.units)) { $oldById[[string]$unit.unitId] = $unit }
$newById = @{}; foreach ($unit in @($newDocument.units)) { $newById[[string]$unit.unitId] = $unit }
$records = [Collections.Generic.List[object]]::new()
foreach ($newUnit in @($newDocument.units)) {
    $oldUnit = if ($oldById.ContainsKey([string]$newUnit.unitId)) { $oldById[[string]$newUnit.unitId] } else { $null }
    $records.Add((New-UnitRecord -OldUnit $oldUnit -NewUnit $newUnit))
}
foreach ($oldUnit in @($oldDocument.units)) {
    if (-not $newById.ContainsKey([string]$oldUnit.unitId)) { $records.Add((New-UnitRecord -OldUnit $oldUnit -NewUnit $null)) }
}
$counts = [ordered]@{}
foreach ($name in @('unchanged', 'zh_tw_only_changed', 'source_changed_translation_unchanged', 'source_and_translation_changed', 'new_key', 'deleted_key', 'blocked')) {
    $counts[$name] = @($records | Where-Object { $_.changeType -ceq $name }).Count
}
$workset = [ordered]@{
    schemaVersion = 1
    workflowSchemaVersion = 15
    generatorVersion = 1
    status = if ($counts.blocked -gt 0) { 'blocked' } else { 'ready' }
    baseOid = $resolvedBaseOid
    sourceId = $sourceIdentity
    modRelativePath = $normalizedModPath
    old = [ordered]@{ path = $oldPath; sha256 = $oldDocument.sha256; size = $oldDocument.size; bom = $oldDocument.bom; newline = $oldDocument.newline }
    new = [ordered]@{ root = $stagingRoot; path = $newPath; sha256 = $newDocument.sha256; size = $newDocument.size; bom = $newDocument.bom; newline = $newDocument.newline }
    counts = $counts
    units = @($records)
}
$workset.immutableContractSha256 = Get-ImmutableWorksetContractSha256 -Workset $workset

if ($existingWorkset) {
    $existing = $existingWorkset
    if ($existing.baseOid -cne $workset.baseOid -or $existing.sourceId -cne $workset.sourceId -or
        $existing.old.sha256 -cne $workset.old.sha256 -or $existing.new.sha256 -cne $workset.new.sha256) {
        throw 'Existing localization workset belongs to a different immutable input tuple.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$existing.immutableContractSha256) -or
        (Get-ImmutableWorksetContractSha256 -Workset $existing) -cne [string]$existing.immutableContractSha256 -or
        [string]$existing.immutableContractSha256 -cne [string]$workset.immutableContractSha256) {
        throw 'Existing localization workset immutable contract changed.'
    }
    Write-Result -Value ([ordered]@{ result = 'passed'; status = $existing.status; idempotent = $true; path = $outputFull; sha256 = Get-FileSha256 -Path $outputFull; unitCount = @($existing.units).Count })
    return
}
Write-AtomicJson -Path $outputFull -Value $workset
Write-Result -Value ([ordered]@{ result = 'passed'; status = $workset.status; idempotent = $false; path = $outputFull; sha256 = Get-FileSha256 -Path $outputFull; unitCount = $records.Count; counts = $counts })
