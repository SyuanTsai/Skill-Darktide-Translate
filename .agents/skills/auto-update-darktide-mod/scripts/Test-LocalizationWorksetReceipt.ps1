# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorksetPath,
    [Parameter(Mandatory)][string] $NewPath,
    [Parameter(Mandatory)][string] $MergedPath,
    [string] $RunRoot,
    [string] $RepositoryRoot,
    [string] $ExpectedBaseOid,
    [string] $ExpectedModRelativePath,
    [scriptblock] $HeartbeatAction,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Force

function Invoke-Heartbeat { if ($HeartbeatAction) { $null = & $HeartbeatAction } }

function Copy-StreamWithHeartbeat {
    param([IO.Stream] $Source, [IO.Stream] $Destination)
    Invoke-Heartbeat
    $buffer = [byte[]]::new(1MB)
    while (($readCount = $Source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $Destination.Write($buffer, 0, $readCount); Invoke-Heartbeat
    }
}

function Read-FileBytesWithHeartbeat {
    param([string] $Path)
    $source = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try { Copy-StreamWithHeartbeat -Source $source -Destination $memory; $memory.ToArray() }
    finally { $memory.Dispose(); $source.Dispose() }
}

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

function Write-ByteRangeWithHeartbeat {
    param([IO.Stream] $Destination, [byte[]] $Bytes, [int64] $Offset, [int64] $Count)
    for ($written = [int64]0; $written -lt $Count; $written += 1MB) {
        $chunk = [int][Math]::Min([int64]1MB, $Count - $written)
        $Destination.Write($Bytes, [int]($Offset + $written), $chunk)
        Invoke-Heartbeat
    }
}

function Copy-ByteRangeWithHeartbeat {
    param(
        [byte[]] $Source,
        [int64] $SourceOffset,
        [byte[]] $Destination,
        [int64] $DestinationOffset,
        [int64] $Count
    )
    for ($copied = [int64]0; $copied -lt $Count; $copied += 1MB) {
        $chunk = [int64][Math]::Min([int64]1MB, $Count - $copied)
        [Array]::Copy($Source, $SourceOffset + $copied, $Destination, $DestinationOffset + $copied, $chunk)
        Invoke-Heartbeat
    }
}

function Assert-RegularFile {
    param([string] $Path, [string] $Label)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "$Label does not exist." }
    $item = Get-Item -LiteralPath $full
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Label must not be a symlink or reparse point." }
    $parent = Get-Item -LiteralPath (Split-Path -Parent $full)
    if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Label parent must not be a symlink or reparse point." }
    $full
}

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root, [string] $Label)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the source run root."
    }
    $current = $pathFull
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (-not (Test-Path -LiteralPath $current)) { throw "$Label path component is missing." }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label path contains a symlink or reparse point."
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $pathFull }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) { throw "Unable to prove $Label physical containment." }
        $current = $parent
    }
    throw "Unable to prove $Label physical containment within 2048 path components."
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
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes(($contract | ConvertTo-Json -Depth 40 -Compress)))
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
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes(($reviewContract | ConvertTo-Json -Depth 10 -Compress)))
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
    if (-not $process.Start()) { throw 'Unable to start Git for independent OLD localization verification.' }
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
        if ($process.ExitCode -ne 0) { throw "Unable to read immutable OLD localization blob: $errorText" }
        $memory.ToArray()
    }
    finally { $memory.Dispose(); $process.Dispose() }
}

function Get-ExpressionSnapshot {
    param($Expression)
    if ($null -eq $Expression) { return $null }
    [ordered]@{
        raw = $Expression.raw; canonical = $Expression.canonical
        isDirectLocalizeCall = $Expression.isDirectLocalizeCall
        isFullyLocaleResolvedExpression = $Expression.isFullyLocaleResolvedExpression
        startByte = $Expression.startByte; lengthByte = $Expression.lengthByte
        fieldStartByte = $Expression.fieldStartByte; fieldLengthByte = $Expression.fieldLengthByte
        separatorStartByte = $Expression.separatorStartByte; separatorLengthByte = $Expression.separatorLengthByte
    }
}

function Get-UnitSnapshotJson {
    param($Unit)
    if ($null -eq $Unit) { return $null }
    $snapshot = [ordered]@{
        sourceId = $Unit.sourceId; containerPath = $Unit.containerPath; key = $Unit.key
        occurrence = $Unit.occurrence; unitId = $Unit.unitId; blockedReason = $Unit.blockedReason
        sourceExpression = Get-ExpressionSnapshot -Expression $Unit.sourceExpression
        zhTwExpression = Get-ExpressionSnapshot -Expression $Unit.zhTwExpression
        tableOpenByte = $Unit.tableOpenByte; tableCloseByte = $Unit.tableCloseByte
    }
    $snapshot | ConvertTo-Json -Depth 20 -Compress
}

function Get-CanonicalExpression {
    param($Expression)
    if ($null -eq $Expression) { return $null }
    [string]$Expression.canonical
}

function Get-ExpectedClassification {
    param($OldUnit, $NewUnit)
    $blockedReason = if ($null -ne $NewUnit -and -not [string]::IsNullOrWhiteSpace([string]$NewUnit.blockedReason)) { [string]$NewUnit.blockedReason }
        elseif ($null -ne $OldUnit -and -not [string]::IsNullOrWhiteSpace([string]$OldUnit.blockedReason)) { [string]$OldUnit.blockedReason }
        else { $null }
    $oldSource = if ($null -ne $OldUnit) { Get-CanonicalExpression -Expression $OldUnit.sourceExpression } else { $null }
    $newSource = if ($null -ne $NewUnit) { Get-CanonicalExpression -Expression $NewUnit.sourceExpression } else { $null }
    $oldZhTw = if ($null -ne $OldUnit) { Get-CanonicalExpression -Expression $OldUnit.zhTwExpression } else { $null }
    $newZhTw = if ($null -ne $NewUnit) { Get-CanonicalExpression -Expression $NewUnit.zhTwExpression } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($blockedReason)) { return [ordered]@{ changeType = 'blocked'; action = 'BLOCKED'; blockedReason = $blockedReason } }
    if ($null -eq $NewUnit) { return [ordered]@{ changeType = 'deleted_key'; action = 'ACCEPT_REMOVAL'; blockedReason = $null } }
    if ([bool]$NewUnit.sourceExpression.isFullyLocaleResolvedExpression -and $null -eq $oldZhTw -and $null -eq $newZhTw) { return [ordered]@{ changeType = 'localized_source'; action = 'NONE'; blockedReason = $null } }
    if ($null -eq $OldUnit) { return [ordered]@{ changeType = 'new_key'; action = 'AI_REQUIRED'; blockedReason = $null } }
    if ($null -eq $oldZhTw -and $null -eq $newZhTw) { return [ordered]@{ changeType = 'missing_zh_tw'; action = 'AI_REQUIRED'; blockedReason = $null } }
    if ($oldSource -ceq $newSource -and $oldZhTw -ceq $newZhTw) { return [ordered]@{ changeType = 'unchanged'; action = 'NONE'; blockedReason = $null } }
    if ($oldSource -ceq $newSource) { return [ordered]@{ changeType = 'zh_tw_only_changed'; action = 'RESTORE_OLD_ZH_TW'; blockedReason = $null } }
    if ($oldZhTw -ceq $newZhTw) { return [ordered]@{ changeType = 'source_changed_translation_unchanged'; action = 'AI_REQUIRED'; blockedReason = $null } }
    [ordered]@{ changeType = 'source_and_translation_changed'; action = 'AI_REQUIRED'; blockedReason = $null }
}

function ConvertTo-NewlineStyle {
    param([string] $Text, [string] $NewlineStyle)
    if ($NewlineStyle -notin @('lf', 'crlf')) { throw 'Workset NEW localization newline style must be uniformly LF or CRLF.' }
    $normalized = $Text -replace "`r`n|`r|`n", "`n"
    if ($NewlineStyle -ceq 'crlf') { return $normalized.Replace("`n", "`r`n") }
    $normalized
}

function Test-SafeLuaExpression {
    param([string] $Expression)
    if ([string]::IsNullOrWhiteSpace($Expression)) { throw 'Approved zh-tw expression cannot be empty.' }
    $trimmed = $Expression.Trim()
    $wrapper = "return { unit = { en = $trimmed } }"
    $document = Get-LuaLocalizationDocument -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($wrapper)) -DisplayPath '<approved-expression>' -SourceId 'expression-check' -HeartbeatAction $HeartbeatAction
    if (@($document.units).Count -ne 1 -or $document.units[0].sourceExpression.raw -cne $trimmed) {
        throw 'Approved zh-tw expression escapes a single Lua field value.'
    }
    [ordered]@{ raw = $trimmed; canonical = $document.units[0].sourceExpression.canonical }
}

function New-Edit {
    param([int64] $Start, [int64] $Length, [byte[]] $Replacement, [string] $UnitId, [string] $Operation)
    [ordered]@{
        startByte = $Start
        lengthByte = $Length
        replacement = $Replacement
        replacementSha256 = Get-Sha256Bytes -Bytes $Replacement
        unitId = $UnitId
        operation = $Operation
    }
}

function Get-RemovalEdits {
    param([Collections.IDictionary] $Expression, [byte[]] $Bytes, [string] $UnitId)
    $edits = [Collections.Generic.List[object]]::new()
    $fieldStart = [int64]$Expression.fieldStartByte
    $fieldLength = [int64]$Expression.fieldLengthByte
    if ([int64]$Expression.separatorLengthByte -gt 0) {
        $edits.Add((New-Edit -Start $fieldStart -Length $fieldLength -Replacement ([byte[]]::new(0)) -UnitId $UnitId -Operation 'REMOVE'))
        return @($edits)
    }
    $cursor = $fieldStart - 1
    while ($cursor -ge 0 -and $Bytes[$cursor] -in @(9, 10, 13, 32)) {
        if (($cursor -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
        $cursor--
    }
    if ($cursor -ge 0 -and $Bytes[$cursor] -in @(44, 59)) {
        $edits.Add((New-Edit -Start $cursor -Length 1 -Replacement ([byte[]]::new(0)) -UnitId $UnitId -Operation 'REMOVE_SEPARATOR'))
    }
    $edits.Add((New-Edit -Start $fieldStart -Length $fieldLength -Replacement ([byte[]]::new(0)) -UnitId $UnitId -Operation 'REMOVE'))
    @($edits)
}

function Get-InsertionEdit {
    param([Collections.IDictionary] $Unit, [string] $Expression, [byte[]] $Bytes, [string] $Newline)
    if ($null -eq $Unit.sourceExpression) { throw 'Cannot insert zh-tw without a stable en source field.' }
    $tableClose = [int64]$Unit.tableCloseByte
    $tableOpen = [int64]$Unit.tableOpenByte
    $multiline = $false
    for ($index = $tableOpen; $index -lt $tableClose; $index++) {
        if (($index -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
        if ($Bytes[$index] -eq 10) { $multiline = $true; break }
    }
    if ($multiline) {
        $sourceStart = [int64]$Unit.sourceExpression.fieldStartByte
        $lineStart = $sourceStart - 1
        while ($lineStart -ge 0 -and $Bytes[$lineStart] -ne 10) {
            if (($lineStart -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
            $lineStart--
        }
        $indentLength = $sourceStart - ($lineStart + 1)
        $indent = if ($indentLength -gt 0) { [Text.Encoding]::UTF8.GetString($Bytes, $lineStart + 1, $indentLength) } else { '' }
        if ($indent -notmatch '^[\t ]*$') { throw 'Unable to derive safe localization field indentation.' }
        $replacementText = $Newline + $indent + '["zh-tw"] = ' + $Expression + ','
    }
    else {
        $replacementText = ' ["zh-tw"] = ' + $Expression + ','
    }
    New-Edit -Start ($tableOpen + 1) -Length 0 -Replacement ([Text.UTF8Encoding]::new($false, $true).GetBytes($replacementText)) -UnitId ([string]$Unit.unitId) -Operation 'INSERT'
}

function Invoke-ByteEdits {
    param([byte[]] $Bytes, [object[]] $Edits)
    $ordered = @($Edits | Sort-Object { [int64]$_.startByte } -Descending)
    $previousStart = [int64]$Bytes.LongLength
    $result = $Bytes
    foreach ($edit in $ordered) {
        $start = [int64]$edit.startByte
        $length = [int64]$edit.lengthByte
        if ($start -lt 0 -or $length -lt 0 -or ($start + $length) -gt $previousStart -or ($start + $length) -gt $result.LongLength) {
            throw 'Localization workset edits overlap or escape NEW bytes.'
        }
        $memory = [IO.MemoryStream]::new()
        try {
            if ($start -gt 0) { Write-ByteRangeWithHeartbeat -Destination $memory -Bytes $result -Offset 0 -Count $start }
            $replacement = [byte[]]$edit.replacement
            if ($replacement.Length -gt 0) { Write-ByteRangeWithHeartbeat -Destination $memory -Bytes $replacement -Offset 0 -Count $replacement.Length }
            $tailStart = $start + $length
            if ($tailStart -lt $result.LongLength) {
                Write-ByteRangeWithHeartbeat -Destination $memory -Bytes $result -Offset $tailStart -Count ($result.LongLength - $tailStart)
            }
            $updated = $memory.ToArray()
        }
        finally { $memory.Dispose() }
        $result = $updated
        $previousStart = $start
    }
    $result
}

$worksetFull = if ([string]::IsNullOrWhiteSpace($RunRoot)) { Assert-RegularFile -Path $WorksetPath -Label 'Localization workset' }
    else { Assert-NoReparsePath -Path $WorksetPath -Root $RunRoot -Label 'Localization workset' }
$newFull = if ([string]::IsNullOrWhiteSpace($RunRoot)) { Assert-RegularFile -Path $NewPath -Label 'Raw NEW localization evidence' }
    else { Assert-NoReparsePath -Path $NewPath -Root $RunRoot -Label 'Raw NEW localization evidence' }
$mergedFull = if ([string]::IsNullOrWhiteSpace($RunRoot)) { Assert-RegularFile -Path $MergedPath -Label 'Merged localization evidence' }
    else { Assert-NoReparsePath -Path $MergedPath -Root $RunRoot -Label 'Merged localization evidence' }
if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
    $runRootFull = [IO.Path]::GetFullPath($RunRoot)
    if ($worksetFull -cne [IO.Path]::GetFullPath((Join-Path $runRootFull 'review-artifacts/localization-workset.json')) -or
        (Split-Path -Leaf $newFull) -cne 'new.lua' -or (Split-Path -Leaf $mergedFull) -cne 'merged.lua') {
        throw 'Localization receipt verification requires the fixed run-local artifact paths.'
    }
}
$bindingValues = @($RepositoryRoot, $ExpectedBaseOid, $ExpectedModRelativePath)
$bindingValueCount = @($bindingValues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
if ($bindingValueCount -notin @(0, 3)) {
    throw 'Independent OLD verification requires RepositoryRoot, ExpectedBaseOid, and ExpectedModRelativePath together.'
}
$repositoryFull = if ($bindingValueCount -eq 3) { [IO.Path]::GetFullPath($RepositoryRoot) } else { $null }
if ($bindingValueCount -eq 3 -and (-not (Test-Path -LiteralPath $repositoryFull -PathType Container) -or $ExpectedBaseOid -notmatch '^[0-9a-f]{40}$')) {
    throw 'Independent OLD verification repository or base OID is invalid.'
}
$workset = Get-Content -LiteralPath $worksetFull -Raw | ConvertFrom-Json -AsHashtable
if ([int]$workset.schemaVersion -ne 1 -or [int]$workset.workflowSchemaVersion -ne 15 -or [string]$workset.status -cne 'applied') {
    throw 'Localization workset is not an applied Schema 15 artifact.'
}
if ([string]::IsNullOrWhiteSpace([string]$workset.immutableContractSha256) -or
    (Get-ImmutableWorksetContractSha256 -Workset $workset) -cne [string]$workset.immutableContractSha256) {
    throw 'Localization workset immutable contract changed.'
}
if ($bindingValueCount -eq 3) {
    $normalizedExpectedModPath = $ExpectedModRelativePath.Replace('\', '/').Trim('/')
    if ([string]$workset.baseOid -cne $ExpectedBaseOid -or [string]$workset.modRelativePath -cne $normalizedExpectedModPath) {
        throw 'Localization workset base OID or MOD path differs from Candidate state.'
    }
    if (-not ([string]$workset.old.path).StartsWith($normalizedExpectedModPath + '/', [StringComparison]::Ordinal)) {
        throw 'Localization workset OLD path escapes the expected MOD path.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
        $expectedStagingRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $RunRoot 'staging/localization-workset-input') (Split-Path -Leaf $normalizedExpectedModPath)))
        if ([IO.Path]::GetFullPath([string]$workset.new.root) -cne $expectedStagingRoot) {
            throw 'Localization workset NEW root differs from the fixed run-local staging path.'
        }
        $stagedOutput = [IO.Path]::GetFullPath([string]$workset.new.path)
        if (-not $stagedOutput.StartsWith($expectedStagingRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Localization workset NEW path escapes the fixed run-local staging path.'
        }
        $null = Assert-NoReparsePath -Path $stagedOutput -Root $RunRoot -Label 'Applied staging localization output'
    }
}
if (-not $workset.Contains('apply') -or -not $workset.apply -or [string]$workset.apply.status -cne 'applied') {
    throw 'Localization workset apply receipt is not finalized.'
}
$applyKeys = @($workset.apply.Keys | Sort-Object)
if (($applyKeys -join ',') -cne 'edits,inputSha256,outputSha256,outputSize,reviewContractSha256,status' -or
    [string]$workset.apply.reviewContractSha256 -cne (Get-ReviewWorksetContractSha256 -Workset $workset)) {
    throw 'Localization workset apply receipt fields are malformed.'
}

$newBytes = Read-FileBytesWithHeartbeat -Path $newFull
$mergedBytes = Read-FileBytesWithHeartbeat -Path $mergedFull
if ((Get-Sha256Bytes -Bytes $newBytes) -cne [string]$workset.new.sha256 -or
    (Get-Sha256Bytes -Bytes $newBytes) -cne [string]$workset.apply.inputSha256) {
    throw 'Raw NEW localization evidence differs from the workset input.'
}
$before = Get-LuaLocalizationDocument -Bytes $newBytes -DisplayPath $newFull -SourceId ([string]$workset.sourceId) -HeartbeatAction $HeartbeatAction
$beforeById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($unit in @($before.units)) { $beforeById[[string]$unit.unitId] = $unit }
$oldDocument = $null
$oldById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
if ($bindingValueCount -eq 3) {
    $oldBytes = Get-GitBlobBytes -WorkingDirectory $repositoryFull -Object "$ExpectedBaseOid`:$([string]$workset.old.path)"
    $oldDocument = Get-LuaLocalizationDocument -Bytes $oldBytes -DisplayPath ([string]$workset.old.path) -SourceId ([string]$workset.sourceId) -HeartbeatAction $HeartbeatAction
    if ((Get-Sha256Bytes -Bytes $oldBytes) -cne [string]$workset.old.sha256 -or
        $oldBytes.LongLength -ne [int64]$workset.old.size -or [bool]$oldDocument.bom -ne [bool]$workset.old.bom -or
        [string]$oldDocument.newline -cne [string]$workset.old.newline) {
        throw 'Localization workset OLD metadata differs from the immutable base blob.'
    }
    foreach ($unit in @($oldDocument.units)) { $oldById[[string]$unit.unitId] = $unit }
}
if ([int64]$before.size -ne [int64]$workset.new.size -or [bool]$before.bom -ne [bool]$workset.new.bom -or
    [string]$before.newline -cne [string]$workset.new.newline) {
    throw 'Localization workset NEW metadata differs from raw NEW evidence.'
}
$expectedIdentityIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($unit in @($before.units)) { $null = $expectedIdentityIds.Add([string]$unit.unitId) }
if ($bindingValueCount -eq 3) { foreach ($unit in @($oldDocument.units)) { $null = $expectedIdentityIds.Add([string]$unit.unitId) } }
$worksetIdentityIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($unit in @($workset.units)) {
    $unitId = [string]$unit.unitId
    if ([string]::IsNullOrWhiteSpace($unitId) -or -not $worksetIdentityIds.Add($unitId)) {
        throw 'Localization workset unit inventory contains a missing or duplicate unit ID.'
    }
}
if ($bindingValueCount -eq 3 -and
    ($expectedIdentityIds.Count -ne $worksetIdentityIds.Count -or -not $expectedIdentityIds.SetEquals($worksetIdentityIds))) {
    throw 'Localization workset unit inventory differs from independently parsed OLD and NEW bytes.'
}
$classificationCounts = [ordered]@{}
foreach ($name in @('unchanged', 'localized_source', 'missing_zh_tw', 'zh_tw_only_changed', 'source_changed_translation_unchanged', 'source_and_translation_changed', 'new_key', 'deleted_key', 'blocked')) {
    $classificationCounts[$name] = 0
}
foreach ($unit in @($workset.units)) {
    $unitId = [string]$unit.unitId
    $parsedNew = if ($beforeById.ContainsKey($unitId)) { $beforeById[$unitId] } else { $null }
    $parsedOld = if ($bindingValueCount -eq 3 -and $oldById.ContainsKey($unitId)) { $oldById[$unitId] } elseif ($bindingValueCount -eq 0) { $unit.old } else { $null }
    if ((Get-UnitSnapshotJson -Unit $unit.new) -cne (Get-UnitSnapshotJson -Unit $parsedNew) -or
        ($bindingValueCount -eq 3 -and (Get-UnitSnapshotJson -Unit $unit.old) -cne (Get-UnitSnapshotJson -Unit $parsedOld))) {
        throw "Localization workset unit snapshot differs from independently parsed OLD or NEW bytes: $unitId"
    }
    $identity = if ($null -ne $parsedNew) { $parsedNew } else { $parsedOld }
    if ($null -eq $identity -or [string]$unit.sourceId -cne [string]$identity.sourceId -or
        [string]$unit.containerPath -cne [string]$identity.containerPath -or [string]$unit.key -cne [string]$identity.key -or
        [int]$unit.occurrence -ne [int]$identity.occurrence) {
        throw "Localization workset unit identity differs from independently parsed bytes: $unitId"
    }
    $classification = Get-ExpectedClassification -OldUnit $parsedOld -NewUnit $parsedNew
    if ([string]$unit.changeType -cne [string]$classification.changeType -or [string]$unit.action -cne [string]$classification.action -or
        [string]$unit.blockedReason -cne [string]$classification.blockedReason) {
        throw "Localization workset classification or action differs from OLD and NEW bytes: $unitId"
    }
    $classificationCounts[[string]$classification.changeType]++
}
$countKeys = @($workset.counts.Keys | Sort-Object)
if (($countKeys -join ',') -cne 'blocked,deleted_key,localized_source,missing_zh_tw,new_key,source_and_translation_changed,source_changed_translation_unchanged,unchanged,zh_tw_only_changed') {
    throw 'Localization workset classification counts are malformed.'
}
foreach ($name in $classificationCounts.Keys) {
    if ([int]$workset.counts[$name] -ne [int]$classificationCounts[$name]) {
        throw "Localization workset classification count differs from independent classification: $name"
    }
}
$expectedEdits = [Collections.Generic.List[object]]::new()
foreach ($unit in @($workset.units)) {
    $action = [string]$unit.action
    if ($action -cne 'AI_REQUIRED' -and
        ([string]$unit.reviewStatus -cne 'not-required' -or $null -ne $unit.suggestedZhTwExpression)) {
        throw "Localization review fields were edited outside AI_REQUIRED: $($unit.unitId)"
    }
    if ($action -in @('NONE', 'ACCEPT_REMOVAL')) { continue }
    if ($action -eq 'BLOCKED') { throw "Blocked localization unit cannot have an apply receipt: $($unit.unitId)" }
    if ($null -eq $unit.new) { throw "Localization action requires a NEW unit: $($unit.unitId)" }
    $currentUnit = $beforeById[[string]$unit.unitId]
    if ($null -eq $currentUnit) { throw "Localization unit is missing from raw NEW bytes: $($unit.unitId)" }
    if ($action -ceq 'RESTORE_OLD_ZH_TW') {
        $target = if ($null -ne $unit.old.zhTwExpression) {
            [ordered]@{
                raw = ConvertTo-NewlineStyle -Text ([string]$unit.old.zhTwExpression.raw) -NewlineStyle ([string]$workset.new.newline)
                canonical = [string]$unit.old.zhTwExpression.canonical
            }
        }
        else { $null }
    }
    elseif ($action -ceq 'AI_REQUIRED') {
        if ([string]$unit.reviewStatus -cne 'approved') { throw "AI_REQUIRED localization unit is not approved: $($unit.unitId)" }
        $normalized = ConvertTo-NewlineStyle -Text ([string]$unit.suggestedZhTwExpression) -NewlineStyle ([string]$workset.new.newline)
        $target = Test-SafeLuaExpression -Expression $normalized
    }
    else { throw "Unsupported localization workset action: $action" }

    if ($null -eq $target -and $null -ne $currentUnit.zhTwExpression) {
        foreach ($edit in Get-RemovalEdits -Expression $currentUnit.zhTwExpression -Bytes $newBytes -UnitId ([string]$unit.unitId)) { $expectedEdits.Add($edit) }
    }
    elseif ($null -ne $target -and $null -ne $currentUnit.zhTwExpression) {
        $replacement = [Text.UTF8Encoding]::new($false, $true).GetBytes([string]$target.raw)
        $expectedEdits.Add((New-Edit -Start ([int64]$currentUnit.zhTwExpression.startByte) -Length ([int64]$currentUnit.zhTwExpression.lengthByte) -Replacement $replacement -UnitId ([string]$unit.unitId) -Operation 'REPLACE'))
    }
    elseif ($null -ne $target) {
        $expectedEdits.Add((Get-InsertionEdit -Unit $currentUnit -Expression ([string]$target.raw) -Bytes $newBytes -Newline $(if ($workset.new.newline -ceq 'crlf') { "`r`n" } else { "`n" })))
    }
}

$expectedReceiptEdits = @($expectedEdits | ForEach-Object {
    Invoke-Heartbeat
    $oldBytes = [byte[]]::new([int64]$_.lengthByte)
    if ($oldBytes.Length -gt 0) {
        Copy-ByteRangeWithHeartbeat -Source $newBytes -SourceOffset ([int64]$_.startByte) `
            -Destination $oldBytes -DestinationOffset 0 -Count $oldBytes.Length
    }
    [ordered]@{
        unitId = [string]$_.unitId
        operation = [string]$_.operation
        startByte = [int64]$_.startByte
        lengthByte = [int64]$_.lengthByte
        oldSha256 = Get-Sha256Bytes -Bytes $oldBytes
        replacementBase64 = [Convert]::ToBase64String([byte[]]$_.replacement)
        replacementSha256 = [string]$_.replacementSha256
    }
})
$actualReceiptEdits = @($workset.apply.edits)
if ($actualReceiptEdits.Count -ne $expectedReceiptEdits.Count) { throw 'Localization apply receipt differs from the deterministic edit plan.' }
for ($index = 0; $index -lt $expectedReceiptEdits.Count; $index++) {
    if (($index -band 0x3FF) -eq 0) { Invoke-Heartbeat }
    $actual = $actualReceiptEdits[$index]
    $expected = $expectedReceiptEdits[$index]
    $actualKeys = @($actual.Keys | Sort-Object)
    if (($actualKeys -join ',') -cne 'lengthByte,oldSha256,operation,replacementBase64,replacementSha256,startByte,unitId' -or
        [string]$actual.unitId -cne [string]$expected.unitId -or
        [string]$actual.operation -cne [string]$expected.operation -or
        [int64]$actual.startByte -ne [int64]$expected.startByte -or
        [int64]$actual.lengthByte -ne [int64]$expected.lengthByte -or
        [string]$actual.oldSha256 -cne [string]$expected.oldSha256 -or
        [string]$actual.replacementBase64 -cne [string]$expected.replacementBase64 -or
        [string]$actual.replacementSha256 -cne [string]$expected.replacementSha256) {
        throw 'Localization apply receipt differs from the deterministic edit plan.'
    }
}

$expectedMergedBytes = Invoke-ByteEdits -Bytes $newBytes -Edits @($expectedEdits)
$expectedMergedSha = Get-Sha256Bytes -Bytes $expectedMergedBytes
if ($mergedBytes.LongLength -ne $expectedMergedBytes.LongLength -or
    (Get-Sha256Bytes -Bytes $mergedBytes) -cne $expectedMergedSha -or
    [string]$workset.apply.outputSha256 -cne $expectedMergedSha -or
    [int64]$workset.apply.outputSize -ne $expectedMergedBytes.LongLength) {
    throw 'Merged localization evidence differs from the deterministic edit plan.'
}

$result = [ordered]@{
    result = 'passed'
    worksetPath = $worksetFull
    inputSha256 = Get-Sha256Bytes -Bytes $newBytes
    outputSha256 = $expectedMergedSha
    editCount = $expectedReceiptEdits.Count
}
if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 10 -Compress }
