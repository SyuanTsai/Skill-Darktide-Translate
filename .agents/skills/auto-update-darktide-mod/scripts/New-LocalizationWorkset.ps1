#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $BaseOid,
    [Parameter(Mandatory)][string] $ModRelativePath,
    [Parameter(Mandatory)][string] $StagingModPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $SourceId,
    [scriptblock] $HeartbeatAction,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Force

function Invoke-Heartbeat { if ($HeartbeatAction) { $null = & $HeartbeatAction } }

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    Invoke-Heartbeat
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        for ($offset = 0; $offset -lt $Bytes.Length; $offset += 1MB) {
            $count = [Math]::Min(1MB, $Bytes.Length - $offset)
            $hasher.AppendData($Bytes, $offset, $count)
            Invoke-Heartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
}

function Copy-StreamWithHeartbeat {
    param([IO.Stream] $Source, [IO.Stream] $Destination)
    Invoke-Heartbeat
    $buffer = [byte[]]::new(1MB)
    while (($readCount = $Source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $Destination.Write($buffer, 0, $readCount)
        Invoke-Heartbeat
    }
}

function Read-FileBytesWithHeartbeat {
    param([string] $Path)
    $source = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try { Copy-StreamWithHeartbeat -Source $source -Destination $memory; $memory.ToArray() }
    finally { $memory.Dispose(); $source.Dispose() }
}

function Write-Result {
    param($Value)
    if ($PassThru) { $Value } else { $Value | ConvertTo-Json -Depth 30 -Compress }
}

function Write-AtomicJson {
    param([string] $Path, $Value)
    Invoke-Heartbeat
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Get-FileSha256 {
    param([string] $Path)
    Invoke-Heartbeat
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount); Invoke-Heartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose(); $stream.Dispose() }
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
    Get-Sha256Bytes -Bytes $bytes
}

function Get-ReviewWorksetContractSha256 {
    param($Workset)
    $reviewContract = @($Workset.units | ForEach-Object {
        [ordered]@{
            unitId = $_.unitId
            reviewStatus = $_.reviewStatus
            suggestedZhTwExpression = $_.suggestedZhTwExpression
        }
    })
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($reviewContract | ConvertTo-Json -Depth 10 -Compress))
    Get-Sha256Bytes -Bytes $bytes
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
    while (-not $process.WaitForExit(1000)) { Invoke-Heartbeat }
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
    try {
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
            Invoke-Heartbeat
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Unable to read immutable localization blob: $errorText" }
        $memory.ToArray()
    }
    finally { $memory.Dispose(); $process.Dispose() }
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
    param([string] $Path, [string] $Root, [switch] $AllowMissing)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $current = [IO.Path]::GetFullPath($Path)
    if (-not $current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $current.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Localization workset path escapes its verification root.'
    }
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Localization workset path contains a symlink or reparse point.' }
        }
        elseif (-not $AllowMissing) { throw 'Localization workset path component is missing.' }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Unable to prove NEW localization containment.' }
        $current = $parent
    }
    throw 'Unable to prove localization workset containment within 2048 path components.'
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
    elseif ($null -eq $oldZhTw -and $null -eq $newZhTw) { $changeType = 'missing_zh_tw'; $action = 'AI_REQUIRED' }
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
$outputParent = Split-Path -Parent $outputFull
Assert-NoReparsePath -Path $outputParent -Root $repository -AllowMissing
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { New-Item -ItemType Directory -Path $outputParent -Force | Out-Null }
Assert-NoReparsePath -Path $outputParent -Root $repository
$rawModPath = $ModRelativePath.Replace('\', '/')
$normalizedModPath = $rawModPath.Trim('/')
$modPathSegments = @($normalizedModPath -split '/')
if ([string]::IsNullOrWhiteSpace($normalizedModPath) -or [IO.Path]::IsPathRooted($rawModPath) -or
    @($modPathSegments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -ne 0) {
    throw 'ModRelativePath is invalid.'
}
$resolvedBaseOid = (Invoke-GitText -WorkingDirectory $repository -Arguments @('rev-parse', "$BaseOid^{commit}")).output.Trim()
if ($resolvedBaseOid -notmatch '^[0-9a-f]{40}$') { throw 'BaseOid did not resolve to a 40-character commit OID.' }
$sourceIdentity = if ([string]::IsNullOrWhiteSpace($SourceId)) { $normalizedModPath } else { $SourceId }
$existingWorkset = if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
    Assert-NoReparsePath -Path $outputFull -Root $repository
    Get-Content -LiteralPath $outputFull -Raw | ConvertFrom-Json -AsHashtable
} else { $null }
if ($existingWorkset) {
    foreach ($unit in @($existingWorkset.units)) {
        if ([string]$unit.action -cne 'AI_REQUIRED' -and
            ([string]$unit.reviewStatus -cne 'not-required' -or $null -ne $unit.suggestedZhTwExpression)) {
            throw "Localization review fields were edited outside AI_REQUIRED: $($unit.unitId)"
        }
    }
}
if ($existingWorkset -and [string]$existingWorkset.status -in @('applying', 'applied')) {
    if ([string]$existingWorkset.baseOid -cne $resolvedBaseOid -or [string]$existingWorkset.sourceId -cne $sourceIdentity -or
        [string]$existingWorkset.modRelativePath -cne $normalizedModPath) {
        throw 'Existing applying or applied localization workset belongs to a different immutable input tuple.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$existingWorkset.immutableContractSha256) -or
        (Get-ImmutableWorksetContractSha256 -Workset $existingWorkset) -cne [string]$existingWorkset.immutableContractSha256) {
        throw 'Existing localization workset immutable contract changed.'
    }
    $expectedApplyStatus = if ([string]$existingWorkset.status -ceq 'applied') { 'applied' } else { 'pending' }
    if (-not $existingWorkset.Contains('apply') -or -not $existingWorkset.apply -or
        [string]$existingWorkset.apply.status -cne $expectedApplyStatus -or
        [string]$existingWorkset.apply.inputSha256 -cne [string]$existingWorkset.new.sha256 -or
        [string]$existingWorkset.apply.reviewContractSha256 -cne (Get-ReviewWorksetContractSha256 -Workset $existingWorkset) -or
        [string]$existingWorkset.apply.outputSha256 -notmatch '^[0-9a-f]{64}$' -or [int64]$existingWorkset.apply.outputSize -lt 0) {
        throw 'Existing applying or applied localization workset review contract or apply receipt changed.'
    }
    if ([IO.Path]::GetFullPath([string]$existingWorkset.new.root) -cne $stagingRoot) { throw 'Existing applied workset staging root changed.' }
    $existingNewPath = Assert-ContainedPath -Candidate ([string]$existingWorkset.new.path) -Root $stagingRoot
    Assert-NoReparsePath -Path $existingNewPath -Root $stagingRoot
    if (-not (Test-Path -LiteralPath $existingNewPath -PathType Leaf)) { throw 'Existing applying or applied localization workset output is missing.' }
    $existingNewBytes = Read-FileBytesWithHeartbeat -Path $existingNewPath
    $existingNewSha = Get-Sha256Bytes -Bytes $existingNewBytes
    $allowedHashes = if ([string]$existingWorkset.status -ceq 'applying') {
        @([string]$existingWorkset.apply.inputSha256, [string]$existingWorkset.apply.outputSha256)
    }
    else { @([string]$existingWorkset.apply.outputSha256) }
    if ($existingNewSha -cnotin $allowedHashes -or
        ($existingNewSha -ceq [string]$existingWorkset.apply.inputSha256 -and $existingNewBytes.LongLength -ne [int64]$existingWorkset.new.size) -or
        ($existingNewSha -ceq [string]$existingWorkset.apply.outputSha256 -and $existingNewBytes.LongLength -ne [int64]$existingWorkset.apply.outputSize)) {
        throw 'Existing applying or applied localization workset output changed.'
    }
    Write-Result -Value ([ordered]@{ result = 'passed'; status = [string]$existingWorkset.status; idempotent = $true; path = $outputFull; sha256 = Get-FileSha256 -Path $outputFull; unitCount = @($existingWorkset.units).Count })
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
$newFiles = @(Get-ChildItem -LiteralPath $stagingRoot -File -Recurse | ForEach-Object {
    Invoke-Heartbeat
    if ($_.Name -like '*_localization.lua') { $_ }
})
if ($newFiles.Count -ne 1) {
    Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; reason = 'localization_entry_not_unique'; newCount = $newFiles.Count })
    return
}
$newPath = Assert-ContainedPath -Candidate $newFiles[0].FullName -Root $stagingRoot
Assert-NoReparsePath -Path $newPath -Root $stagingRoot
$oldPath = [string]$oldPaths[0]
$oldBytes = Get-GitBlobBytes -WorkingDirectory $repository -Object "$resolvedBaseOid`:$oldPath"
$newBytes = Read-FileBytesWithHeartbeat -Path $newPath
$oldDocument = Get-LuaLocalizationDocument -Bytes $oldBytes -DisplayPath $oldPath -SourceId $sourceIdentity -HeartbeatAction $HeartbeatAction
$newDocument = Get-LuaLocalizationDocument -Bytes $newBytes -DisplayPath $newPath -SourceId $sourceIdentity -HeartbeatAction $HeartbeatAction

if (@($oldDocument.units).Count -eq 0 -and @($newDocument.units).Count -eq 0 -and
    [bool]$oldDocument.isIoDofileOnlyLoader -and [bool]$newDocument.isIoDofileOnlyLoader) {
    Write-Result -Value ([ordered]@{ result = 'excluded'; status = 'automation-excluded'; reason = 'localization_entry_is_loader'; sourceId = $sourceIdentity })
    return
}
if (@($oldDocument.units).Count -eq 0 -or @($newDocument.units).Count -eq 0) {
    Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; reason = 'localization_structure_not_static'; sourceId = $sourceIdentity })
    return
}

$oldById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($unit in @($oldDocument.units)) { $oldById[[string]$unit.unitId] = $unit }
$newById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($unit in @($newDocument.units)) { $newById[[string]$unit.unitId] = $unit }
$records = [Collections.Generic.List[object]]::new()
foreach ($newUnit in @($newDocument.units)) {
    $oldUnit = if ($oldById.ContainsKey([string]$newUnit.unitId)) { $oldById[[string]$newUnit.unitId] } else { $null }
    $records.Add((New-UnitRecord -OldUnit $oldUnit -NewUnit $newUnit))
}
foreach ($oldUnit in @($oldDocument.units)) {
    if (-not $newById.ContainsKey([string]$oldUnit.unitId)) { $records.Add((New-UnitRecord -OldUnit $oldUnit -NewUnit $null)) }
}
$counts = [ordered]@{}
foreach ($name in @('unchanged', 'missing_zh_tw', 'zh_tw_only_changed', 'source_changed_translation_unchanged', 'source_and_translation_changed', 'new_key', 'deleted_key', 'blocked')) {
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
Assert-NoReparsePath -Path $outputParent -Root $repository
Assert-NoReparsePath -Path $outputFull -Root $repository -AllowMissing
Write-AtomicJson -Path $outputFull -Value $workset
Write-Result -Value ([ordered]@{ result = 'passed'; status = $workset.status; idempotent = $false; path = $outputFull; sha256 = Get-FileSha256 -Path $outputFull; unitCount = $records.Count; counts = $counts })
