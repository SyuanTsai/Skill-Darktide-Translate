#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorksetPath,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Force

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
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
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Write-AtomicBytes {
    param([string] $Path, [byte[]] $Bytes)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.lua')
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
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
    $current = Get-Item -LiteralPath $Path
    while ($true) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Workset NEW localization path contains a symlink or reparse point.'
        }
        if ($current.FullName.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $current.FullName
        if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Unable to prove Workset NEW localization containment.' }
        $current = Get-Item -LiteralPath $parent
    }
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
    $document = Get-LuaLocalizationDocument -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($wrapper)) -DisplayPath '<approved-expression>' -SourceId 'expression-check'
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
    while ($cursor -ge 0 -and $Bytes[$cursor] -in @(9, 10, 13, 32)) { $cursor-- }
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
    for ($index = $tableOpen; $index -lt $tableClose; $index++) { if ($Bytes[$index] -eq 10) { $multiline = $true; break } }
    if ($multiline) {
        $sourceStart = [int64]$Unit.sourceExpression.fieldStartByte
        $lineStart = $sourceStart - 1
        while ($lineStart -ge 0 -and $Bytes[$lineStart] -ne 10) { $lineStart-- }
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
        if ($start -gt 0) { $memory.Write($result, 0, $start) }
        $replacement = [byte[]]$edit.replacement
        if ($replacement.Length -gt 0) { $memory.Write($replacement, 0, $replacement.Length) }
        $tailStart = $start + $length
        if ($tailStart -lt $result.LongLength) { $memory.Write($result, $tailStart, $result.LongLength - $tailStart) }
        $result = $memory.ToArray()
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
$currentBytes = [IO.File]::ReadAllBytes($newPath)
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
$before = Get-LuaLocalizationDocument -Bytes $originalBytes -DisplayPath $newPath -SourceId ([string]$workset.sourceId)
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
$after = Get-LuaLocalizationDocument -Bytes $updatedBytes -DisplayPath $newPath -SourceId ([string]$workset.sourceId)
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
    $oldBytes = [byte[]]::new([int64]$_.lengthByte)
    if ($oldBytes.Length -gt 0) { [Array]::Copy($originalBytes, [int64]$_.startByte, $oldBytes, 0, $oldBytes.Length) }
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
