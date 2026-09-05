# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorksetPath,
    [scriptblock] $HeartbeatAction,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PathSafety.psm1') -Force -ErrorAction Stop

function Invoke-Heartbeat { if ($HeartbeatAction) { $null = & $HeartbeatAction } }

function Read-FileBytesWithHeartbeat {
    param([string] $Path)
    Invoke-Heartbeat
    $source = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $readCount); Invoke-Heartbeat
        }
        $memory.ToArray()
    }
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

function Get-FileSha256 {
    param([string] $Path)
    $bytes = Read-FileBytesWithHeartbeat -Path $Path
    Get-Sha256Bytes -Bytes $bytes
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

function Write-AtomicJson {
    param([string] $Path, $Value)
    Invoke-Heartbeat
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Write-AtomicBytes {
    param([string] $Path, [byte[]] $Bytes)
    Invoke-Heartbeat
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.lua')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            for ($offset = [int64]0; $offset -lt $Bytes.LongLength; $offset += 1MB) {
                $count = [int][Math]::Min([int64]1MB, $Bytes.LongLength - $offset)
                $stream.Write($Bytes, [int]$offset, $count)
                Invoke-Heartbeat
            }
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        Invoke-Heartbeat
        [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { [IO.File]::Delete($temporary) }
    }
}

function Write-Result {
    param($Value)
    if ($PassThru) { $Value } else { $Value | ConvertTo-Json -Depth 20 -Compress }
}

function Assert-ContainedPath {
    param([string] $Candidate, [string] $Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not $candidateFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Workset NEW path escapes its recorded staging root.'
    }
    $candidateFull
}

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root)
    $rootFull = [IO.Path]::GetFullPath($Root)
    $currentPath = [IO.Path]::GetFullPath($Path)
    for ($depth = 0; $depth -lt 2048; $depth++) {
        $current = $null
        try {
            $current = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        }
        catch [Management.Automation.ItemNotFoundException] {
            if (Test-PortableReparseItem -Path $currentPath -Label 'Workset NEW localization') {
                throw 'Workset NEW localization path contains a symlink or reparse point.'
            }
            throw
        }
        catch {
            throw "Unable to inspect Workset NEW localization physical containment component: $($_.Exception.Message)"
        }
        if (Test-PortableReparseItem -Path $currentPath -Item $current -Label 'Workset NEW localization') {
            throw 'Workset NEW localization path contains a symlink or reparse point.'
        }
        if ($currentPath.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = [IO.DirectoryInfo]::new($currentPath).Parent
        if ($null -eq $parent) { throw 'Unable to prove Workset NEW localization containment.' }
        $currentPath = $parent.FullName
    }
    throw 'Unable to prove Workset NEW localization containment within 2048 path components.'
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
        $start = [int64]$edit.startByte; $length = [int64]$edit.lengthByte
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

$worksetFull = [IO.Path]::GetFullPath($WorksetPath)
if ((Split-Path -Leaf $worksetFull) -cne 'localization-workset.json' -or (Split-Path -Leaf (Split-Path -Parent $worksetFull)) -cne 'review-artifacts') {
    throw 'WorksetPath must be review-artifacts/localization-workset.json.'
}
if (-not (Test-Path -LiteralPath $worksetFull -PathType Leaf)) { throw 'Localization workset does not exist.' }
$worksetRunRoot = Split-Path -Parent (Split-Path -Parent $worksetFull)
Assert-NoReparsePath -Path $worksetFull -Root $worksetRunRoot
$workset = Get-Content -LiteralPath $worksetFull -Raw | ConvertFrom-Json -AsHashtable
if ([int]$workset.schemaVersion -ne 1 -or [int]$workset.workflowSchemaVersion -ne 15) { throw 'Localization workset schema is unsupported.' }
if ([string]::IsNullOrWhiteSpace([string]$workset.immutableContractSha256) -or
    (Get-ImmutableWorksetContractSha256 -Workset $workset) -cne [string]$workset.immutableContractSha256) {
    throw 'Localization workset immutable contract changed.'
}
if ([string]$workset.status -eq 'blocked' -or @($workset.units | Where-Object { $_.action -ceq 'BLOCKED' }).Count -gt 0) { throw 'Blocked localization workset cannot be applied.' }
foreach ($unit in @($workset.units)) {
    if ([string]$unit.action -cne 'AI_REQUIRED' -and
        ([string]$unit.reviewStatus -cne 'not-required' -or $null -ne $unit.suggestedZhTwExpression)) {
        throw "Localization review fields were edited outside AI_REQUIRED: $($unit.unitId)"
    }
}
$expectedStagingParent = [IO.Path]::GetFullPath((Join-Path $worksetRunRoot 'staging/localization-workset-input'))
$expectedStagingRoot = [IO.Path]::GetFullPath((Join-Path $expectedStagingParent (Split-Path -Leaf ([string]$workset.modRelativePath))))
$recordedStagingRoot = [IO.Path]::GetFullPath([string]$workset.new.root)
if ($recordedStagingRoot -cne $expectedStagingRoot) {
    throw 'Workset NEW root differs from its fixed run-local staging path.'
}
$newPath = Assert-ContainedPath -Candidate ([string]$workset.new.path) -Root ([string]$workset.new.root)
if (-not (Test-Path -LiteralPath $newPath -PathType Leaf)) { throw 'Workset NEW localization file is missing.' }
Assert-NoReparsePath -Path $newPath -Root ([string]$workset.new.root)
if ([string]$workset.new.newline -notin @('lf', 'crlf')) { throw 'Workset NEW localization newline style must be uniformly LF or CRLF.' }
$currentBytes = Read-FileBytesWithHeartbeat -Path $newPath
$currentSha = Get-Sha256Bytes -Bytes $currentBytes
if ($workset.Contains('apply') -and $workset.apply) {
    $applyStatus = if ($workset.apply.Contains('status')) { [string]$workset.apply.status } else { $null }
    if ($applyStatus -notin @('pending', 'applied') -or
        [string]$workset.apply.inputSha256 -cne [string]$workset.new.sha256 -or
        [string]$workset.apply.reviewContractSha256 -cne (Get-ReviewWorksetContractSha256 -Workset $workset) -or
        [string]$workset.apply.outputSha256 -notmatch '^[0-9a-f]{64}$' -or
        [int64]$workset.apply.outputSize -lt 0) {
        throw 'Localization workset apply receipt is malformed.'
    }
    if ($currentSha -ceq [string]$workset.apply.outputSha256) {
        if ($currentBytes.LongLength -ne [int64]$workset.apply.outputSize) {
            throw 'Workset applied output size differs from its pending receipt.'
        }
        if ($applyStatus -ceq 'pending') {
            Assert-NoReparsePath -Path $worksetFull -Root $worksetRunRoot
            $workset.apply.status = 'applied'
            $workset.status = 'applied'
            Write-AtomicJson -Path $worksetFull -Value $workset
        }
        elseif ([string]$workset.status -cne 'applied') {
            throw 'Localization workset status differs from its applied receipt.'
        }
        Write-Result -Value ([ordered]@{ result = 'passed'; status = 'applied'; idempotent = $true; path = $newPath; sha256 = $currentSha; editCount = @($workset.apply.edits).Count; worksetSha256 = Get-FileSha256 -Path $worksetFull })
        return
    }
    if ($applyStatus -cne 'pending' -or $currentSha -cne [string]$workset.apply.inputSha256) {
        throw 'Workset NEW localization SHA-256 differs from both sides of its pending apply receipt.'
    }
}
if ($currentSha -cne [string]$workset.new.sha256) { throw 'Workset NEW localization SHA-256 changed before apply.' }
$originalBytes = $currentBytes
$before = Get-LuaLocalizationDocument -Bytes $originalBytes -DisplayPath $newPath -SourceId ([string]$workset.sourceId) -HeartbeatAction $HeartbeatAction
$beforeById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($unit in @($before.units)) { $beforeById[[string]$unit.unitId] = $unit }
$edits = [Collections.Generic.List[object]]::new()
$expectedZhTw = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($unit in @($workset.units)) {
    $action = [string]$unit.action
    if ($action -cne 'AI_REQUIRED' -and
        ([string]$unit.reviewStatus -cne 'not-required' -or $null -ne $unit.suggestedZhTwExpression)) {
        throw "Localization review fields were edited outside AI_REQUIRED: $($unit.unitId)"
    }
    if ($action -in @('NONE', 'ACCEPT_REMOVAL')) { continue }
    if ($action -eq 'BLOCKED') { throw "Blocked localization unit cannot be applied: $($unit.unitId)" }
    if ($null -eq $unit.new) { throw "Localization action requires a NEW unit: $($unit.unitId)" }
    $currentUnit = $beforeById[[string]$unit.unitId]
    if ($null -eq $currentUnit) { throw "Localization unit is missing from NEW bytes: $($unit.unitId)" }
    $target = $null
    if ($action -eq 'RESTORE_OLD_ZH_TW') {
        $target = if ($null -ne $unit.old.zhTwExpression) {
            [ordered]@{ raw = ConvertTo-NewlineStyle -Text ([string]$unit.old.zhTwExpression.raw) -NewlineStyle ([string]$workset.new.newline); canonical = [string]$unit.old.zhTwExpression.canonical }
        }
        else { $null }
    }
    elseif ($action -eq 'AI_REQUIRED') {
        if ([string]$unit.reviewStatus -cne 'approved') { throw "AI_REQUIRED localization unit is not approved: $($unit.unitId)" }
        $normalizedExpression = ConvertTo-NewlineStyle -Text ([string]$unit.suggestedZhTwExpression) -NewlineStyle ([string]$workset.new.newline)
        $target = Test-SafeLuaExpression -Expression $normalizedExpression
    }
    else { throw "Unsupported localization workset action: $action" }

    if ($null -eq $target -and $null -ne $currentUnit.zhTwExpression) {
        foreach ($edit in Get-RemovalEdits -Expression $currentUnit.zhTwExpression -Bytes $originalBytes -UnitId ([string]$unit.unitId)) { $edits.Add($edit) }
        $expectedZhTw[[string]$unit.unitId] = $null
    }
    elseif ($null -ne $target -and $null -ne $currentUnit.zhTwExpression) {
        $replacement = [Text.UTF8Encoding]::new($false, $true).GetBytes([string]$target.raw)
        $edits.Add((New-Edit -Start ([int64]$currentUnit.zhTwExpression.startByte) -Length ([int64]$currentUnit.zhTwExpression.lengthByte) -Replacement $replacement -UnitId ([string]$unit.unitId) -Operation 'REPLACE'))
        $expectedZhTw[[string]$unit.unitId] = [string]$target.canonical
    }
    elseif ($null -ne $target) {
        $edits.Add((Get-InsertionEdit -Unit $currentUnit -Expression ([string]$target.raw) -Bytes $originalBytes -Newline $(if ($workset.new.newline -ceq 'crlf') { "`r`n" } else { "`n" })))
        $expectedZhTw[[string]$unit.unitId] = [string]$target.canonical
    }
}

$updatedBytes = Invoke-ByteEdits -Bytes $originalBytes -Edits @($edits)
$after = Get-LuaLocalizationDocument -Bytes $updatedBytes -DisplayPath $newPath -SourceId ([string]$workset.sourceId) -HeartbeatAction $HeartbeatAction
if ([bool]$after.bom -ne [bool]$workset.new.bom -or [string]$after.newline -cne [string]$workset.new.newline) {
    throw 'Localization apply changed the immutable NEW BOM or newline style.'
}
$afterById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($unit in @($after.units)) { $afterById[[string]$unit.unitId] = $unit }
foreach ($beforeUnit in @($before.units)) {
    if (-not $afterById.ContainsKey([string]$beforeUnit.unitId)) { throw "Localization apply removed a non-deleted unit: $($beforeUnit.unitId)" }
    $afterUnit = $afterById[[string]$beforeUnit.unitId]
    if ([string]$beforeUnit.sourceExpression.canonical -cne [string]$afterUnit.sourceExpression.canonical) {
        throw "Localization apply changed a non-zh-tw source expression: $($beforeUnit.unitId)"
    }
}
foreach ($entry in $expectedZhTw.GetEnumerator()) {
    $afterUnit = $afterById[[string]$entry.Key]
    $actual = if ($null -ne $afterUnit.zhTwExpression) { [string]$afterUnit.zhTwExpression.canonical } else { $null }
    if ($actual -cne $entry.Value) { throw "Localization apply produced an unexpected zh-tw expression: $($entry.Key)" }
}

$serializedEdits = @($edits | ForEach-Object {
    Invoke-Heartbeat
    $oldBytes = [byte[]]::new([int64]$_.lengthByte)
    if ($oldBytes.Length -gt 0) {
        Copy-ByteRangeWithHeartbeat -Source $originalBytes -SourceOffset ([int64]$_.startByte) `
            -Destination $oldBytes -DestinationOffset 0 -Count $oldBytes.Length
    }
    [ordered]@{
        unitId = $_.unitId
        operation = $_.operation
        startByte = $_.startByte
        lengthByte = $_.lengthByte
        oldSha256 = Get-Sha256Bytes -Bytes $oldBytes
        replacementBase64 = [Convert]::ToBase64String([byte[]]$_.replacement)
        replacementSha256 = $_.replacementSha256
    }
})
$pendingApply = [ordered]@{
    status = 'pending'
    inputSha256 = Get-Sha256Bytes -Bytes $originalBytes
    reviewContractSha256 = Get-ReviewWorksetContractSha256 -Workset $workset
    outputSha256 = Get-Sha256Bytes -Bytes $updatedBytes
    outputSize = $updatedBytes.LongLength
    edits = $serializedEdits
}
$pendingApplyJson = $pendingApply | ConvertTo-Json -Depth 40 -Compress
if ($workset.Contains('apply') -and $workset.apply) {
    if (($workset.apply | ConvertTo-Json -Depth 40 -Compress) -cne $pendingApplyJson) {
        throw 'Recovered localization apply plan differs from its pending receipt.'
    }
}
else {
    $workset.status = 'applying'
    $workset.apply = $pendingApply
    Assert-NoReparsePath -Path $worksetFull -Root $worksetRunRoot
    Write-AtomicJson -Path $worksetFull -Value $workset
}
Assert-NoReparsePath -Path $newPath -Root ([string]$workset.new.root)
Write-AtomicBytes -Path $newPath -Bytes $updatedBytes
if ((Get-FileSha256 -Path $newPath) -cne [string]$workset.apply.outputSha256) { throw 'Localization apply output changed at the write boundary.' }
$workset.status = 'applied'
$workset.apply.status = 'applied'
Assert-NoReparsePath -Path $worksetFull -Root $worksetRunRoot
Write-AtomicJson -Path $worksetFull -Value $workset
Write-Result -Value ([ordered]@{ result = 'passed'; status = 'applied'; idempotent = $false; path = $newPath; sha256 = $workset.apply.outputSha256; editCount = $serializedEdits.Count; worksetSha256 = Get-FileSha256 -Path $worksetFull })
