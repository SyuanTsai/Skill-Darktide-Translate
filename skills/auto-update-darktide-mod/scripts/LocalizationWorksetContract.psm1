# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1')
Import-Module (Join-Path $PSScriptRoot 'PathSafety.psm1')

function Get-ImmutableWorksetContractSha256 {
    param([Collections.IDictionary] $Workset)

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
    switch ($Workset.generatorVersion) {
        1 {
            if ($Workset.Contains('translationBinding')) { throw 'Version 1 immutable contract cannot contain a translation binding.' }
        }
        2 {
            $binding = $Workset['translationBinding']
            if ($binding -isnot [Collections.IDictionary] -or $binding.Count -ne 6 -or
                ($binding['bindingVersion'] -isnot [int] -and $binding['bindingVersion'] -isnot [long]) -or
                $binding.bindingVersion -ne 1 -or $binding['mode'] -cnotin @('update', 'improve') -or
                $binding['modelId'] -isnot [string] -or [string]::IsNullOrWhiteSpace($binding.modelId) -or
                $binding['rulesSha256'] -isnot [string] -or $binding.rulesSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $binding['glossarySha256'] -isnot [string] -or $binding.glossarySha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $binding['rulesManifest'] -isnot [array]) {
                throw 'Version 2 immutable contract requires a valid translation binding.'
            }
            $contract.translationBinding = $binding
        }
        default { throw 'Localization workset generator version is unsupported.' }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($contract | ConvertTo-Json -Depth 40 -Compress))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-LocalizationGitBlobBytes {
    param([string] $WorkingDirectory, [string] $Object, [scriptblock] $HeartbeatAction)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['GIT_NO_LAZY_FETCH'] = '1'
    foreach ($argument in @('--no-replace-objects', '-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $memory = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw 'Unable to start Git for immutable localization blob.' }
        $process.StandardInput.Close()
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
            if ($HeartbeatAction) { $null = & $HeartbeatAction }
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Unable to read immutable localization blob: $errorText" }
        return ,$memory.ToArray()
    }
    finally { $memory.Dispose(); $process.Dispose() }
}

function Read-LocalizationRuleFile {
    param([string] $SkillRoot, [string] $RelativePath)

    $path = $SkillRoot
    foreach ($part in @('.') + $RelativePath.Split('/')) {
        $path = Join-Path $path $part
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Skill translation rule path is a reparse point: $path"
        }
    }
    return ,[IO.File]::ReadAllBytes($path)
}

function Get-LocalizationTranslationBinding {
    param(
        [Parameter(Mandatory)][string] $SkillRoot,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $BaseOid,
        [Parameter(Mandatory)][ValidateSet('update', 'improve')][string] $Mode,
        [Parameter(Mandatory)][string] $ModRelativePath,
        [string] $ModelId,
        [scriptblock] $HeartbeatAction
    )

    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $manifestBytes = Read-LocalizationRuleFile -SkillRoot $skillRoot -RelativePath 'assets/api-rules-manifest.json'
    $manifest = $utf8.GetString($manifestBytes).TrimStart([char]0xfeff) | ConvertFrom-Json -AsHashtable
    if ($manifest.manifestVersion -ne 1) { throw 'Translation rules manifest version is unsupported.' }
    if ([string]::IsNullOrEmpty($ModelId)) {
        $configBytes = Read-LocalizationRuleFile -SkillRoot $skillRoot -RelativePath 'assets/api-translation.json'
        $config = $utf8.GetString($configBytes).TrimStart([char]0xfeff) | ConvertFrom-Json -AsHashtable
        $ModelId = $config.model
    }
    if ([string]::IsNullOrWhiteSpace($ModelId)) { throw 'Translation model ID is required.' }
    $Mode = $Mode.ToLowerInvariant()
    $modName = $ModRelativePath.Split('/')[-1]
    $prefix = 'skills/auto-update-darktide-mod/'
    $selected = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $manifest.files) {
        if ($Mode -cnotin $entry.modes -or
            ($null -ne $entry.modFilter -and -not [string]::Equals($entry.modFilter, $modName, [StringComparison]::OrdinalIgnoreCase))) {
            continue
        }
        $path = [string]$entry.path
        if ($entry.repo -cnotin @('skill', 'mods') -or $path -cmatch '[\\:\x00-\x1f]' -or
            @($path.Split('/') | Where-Object { $_ -cin @('', '.', '..') }).Count -ne 0 -or
            ($entry.repo -ceq 'skill' -and -not $path.StartsWith($prefix, [StringComparison]::Ordinal))) {
            throw "Invalid translation rule path: $path"
        }
        $key = "$($entry.repo)`t$path"
        if ($selected.ContainsKey($key)) { throw "Duplicate translation rule: $key" }
        $selected.Add($key, $entry)
    }
    $payload = [Text.StringBuilder]::new()
    $rows = @(foreach ($key in $selected.Keys) {
        $entry = $selected[$key]
        [byte[]]$bytes = if ($entry.repo -ceq 'skill') {
            Read-LocalizationRuleFile -SkillRoot $skillRoot -RelativePath $entry.path.Substring($prefix.Length)
        }
        else {
            Get-LocalizationGitBlobBytes -WorkingDirectory $RepositoryRoot -Object ("${BaseOid}:" + $entry.path) -HeartbeatAction $HeartbeatAction
        }
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $null = $payload.Append("$key`t$sha256`n")
        [ordered]@{ repo = $entry.repo; path = $entry.path; sha256 = $sha256 }
    })
    $glossary = Get-LocalizationGitBlobBytes -WorkingDirectory $RepositoryRoot -Object "${BaseOid}:Referneces/Translation.md" -HeartbeatAction $HeartbeatAction
    [ordered]@{
        bindingVersion = 1
        mode = $Mode
        modelId = $ModelId
        rulesSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($payload.ToString()))).ToLowerInvariant()
        glossarySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($glossary)).ToLowerInvariant()
        rulesManifest = $rows
    }
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

function Assert-LocalizationTranslationBinding {
    param($Binding, [string] $RepositoryRoot, [string] $BaseOid, [string] $ModRelativePath, [scriptblock] $HeartbeatAction)

    $expected = Get-LocalizationTranslationBinding -SkillRoot (Split-Path -Parent $PSScriptRoot) `
        -RepositoryRoot $RepositoryRoot -BaseOid $BaseOid -Mode $Binding.mode -ModRelativePath $ModRelativePath `
        -ModelId $Binding.modelId -HeartbeatAction $HeartbeatAction
    if ($Binding.rulesSha256 -cne $expected.rulesSha256 -or $Binding.glossarySha256 -cne $expected.glossarySha256 -or
        (ConvertTo-Json -InputObject $Binding.rulesManifest -Depth 10 -Compress) -cne
        (ConvertTo-Json -InputObject $expected.rulesManifest -Depth 10 -Compress)) {
        throw 'Localization workset translation binding differs from the immutable rules or glossary.'
    }
}

function Assert-LocalizationDocumentMetadata {
    param($Document, $Expected, [string] $Label)

    if (-not [string]::Equals($Document.sha256, $Expected.sha256) -or $Document.size -ne [int64]$Expected.size -or
        $Document.bom -ne [bool]$Expected.bom -or $Document.newline -cne [string]$Expected.newline) {
        throw "Localization workset $Label."
    }
}

function Read-ReviewedTerminologyObject {
    param([Text.Json.JsonElement] $Object, [Collections.IDictionary] $Fields)

    if ($Object.ValueKind -ne 'Object') { throw 'Reviewed terminology request requires a JSON object.' }
    $allowedFields = [Collections.Generic.HashSet[string]]::new([string[]]@($Fields.Keys), [StringComparer]::Ordinal)
    $values = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($property in $Object.EnumerateObject()) {
        if (-not $allowedFields.Contains($property.Name) -or $values.ContainsKey($property.Name)) {
            throw 'Reviewed terminology request contains a duplicate or unexpected field.'
        }
        $value = $property.Value
        switch ($Fields[$property.Name]) {
            'integer' {
                $number = [long]0
                if ($value.ValueKind -ne 'Number' -or -not $value.TryGetInt64([ref]$number) -or $number -le 0) {
                    throw 'Reviewed terminology request requires positive JSON integers.'
                }
                $values.Add($property.Name, $number)
            }
            'string' {
                if ($value.ValueKind -ne 'String') { throw 'Reviewed terminology request requires JSON strings.' }
                $string = $value.GetString()
                if ([string]::IsNullOrWhiteSpace($string) -or $string.Length -gt 8192) {
                    throw 'Reviewed terminology request contains an empty or oversized string.'
                }
                $values.Add($property.Name, $string)
            }
            'empty-array' {
                if ($value.ValueKind -ne 'Array' -or $value.GetArrayLength() -ne 0) {
                    throw 'Reviewed terminology request units must be an empty JSON array.'
                }
                $values.Add($property.Name, @())
            }
            default { $values.Add($property.Name, (Read-ReviewedTerminologyObject -Object $value -Fields $Fields[$property.Name])) }
        }
    }
    if ($values.Count -ne $Fields.Count) { throw 'Reviewed terminology request is missing a required field.' }
    $values
}

function Read-ReviewedTerminologyRequest {
    param([string] $Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = [byte[]]::new(64KB + 1)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -eq 0 -or $count -gt 64KB) { throw 'Reviewed terminology request must be between 1 and 65536 bytes.' }
    }
    finally { $stream.Dispose() }
    $bytes = [ReadOnlyMemory[byte]]::new($buffer, 0, $count)
    $offset = if ($count -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { 3 } else { 0 }
    $options = [Text.Json.JsonDocumentOptions]@{ MaxDepth = 5 }
    $document = [Text.Json.JsonDocument]::Parse($bytes.Slice($offset), $options)
    try {
        $sides = @{ sourceRaw = 'string'; zhTwRaw = 'string' }
        $request = Read-ReviewedTerminologyObject -Object $document.RootElement -Fields @{
            schemaVersion = 'integer'; nexusId = 'integer'; fileId = 'integer'; units = 'empty-array'
            oldSha256 = 'string'; newSha256 = 'string'; immutableContractSha256 = 'string'
            rulesSha256 = 'string'; glossarySha256 = 'string'; reviewer = 'string'; reviewReference = 'string'
            terminologyCorrection = @{
                sourceId = 'string'; containerPath = 'string'; key = 'string'; occurrence = 'integer'
                unitId = 'string'; action = 'string'; old = $sides; new = $sides; translation = 'string'
            }
        }
    }
    finally { $document.Dispose() }
    if ($request.schemaVersion -ne 1 -or $request.reviewer -cnotmatch '\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z' -or
        $request.reviewer.Length -gt 39 -or $request.reviewReference.Length -gt 2048 -or
        $request.reviewReference -cmatch '[\p{Cc}\p{Cf}]' -or -not [string]::Equals($request.reviewReference, $request.reviewReference.Trim())) {
        throw 'Reviewed terminology request has an unsupported version or malformed review attestation.'
    }
    foreach ($field in @('oldSha256', 'newSha256', 'immutableContractSha256', 'rulesSha256', 'glossarySha256')) {
        if ($request[$field] -cnotmatch '\A[0-9a-f]{64}\z') { throw 'Reviewed terminology request requires lowercase SHA-256 digests.' }
    }
    $request.Add('requestSha256', [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes.ToArray())).ToLowerInvariant())
    $request
}

function Get-ReviewedTerminologyContext {
    param($Workset, [string] $RequestPath, [string] $RawNewPath, [string] $RunRoot,
        [string] $BaseOid, [string] $ModRelativePath, [long] $NexusId, [long] $MainFileId)

    if ($Workset.generatorVersion -ne 2 -or $BaseOid -cnotmatch '\A[0-9a-f]{40}\z' -or
        -not [string]::Equals($BaseOid, $Workset.baseOid) -or $NexusId -le 0 -or $MainFileId -le 0) {
        throw 'Reviewed terminology requires a version 2 workset, pinned base OID, and trusted Nexus and MAIN file IDs.'
    }
    $modPath = $ModRelativePath.Replace('\', '/')
    if (-not [string]::Equals($modPath, $Workset.modRelativePath) -or $modPath -cmatch '[:\x00-\x1f]' -or
        @($modPath.Split('/') | Where-Object { $_ -cin @('', '.', '..') }).Count -ne 0) {
        throw 'Reviewed terminology MOD path differs from the trusted MOD path.'
    }
    $stagingRoot = [IO.Path]::GetFullPath([string]$Workset.new.root)
    $stagingPath = [IO.Path]::GetFullPath([string]$Workset.new.path)
    $target = $modPath + '/' + [IO.Path]::GetRelativePath($stagingRoot, $stagingPath).Replace('\', '/')
    if (-not [string]::Equals($target, $Workset.old.path) -or $target -cmatch '[:\x00-\x1f]' -or
        @($target.Split('/') | Where-Object { $_ -cin @('', '.', '..') }).Count -ne 0 -or
        $target -notlike '*_localization.lua') {
        throw 'Reviewed terminology OLD and staged NEW localization must have the same safe MOD-relative path.'
    }
    $targetSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($target))).ToLowerInvariant()
    $artifactDirectory = Join-Path $RunRoot ('artifacts/localization/' + $targetSha.Substring(0, 16))
    $expectedRawPath = [IO.Path]::GetFullPath((Join-Path $artifactDirectory 'new.lua'))
    if (-not $RawNewPath.Equals($expectedRawPath, (Get-PortablePathComparison -Paths @($RawNewPath, $expectedRawPath)))) {
        throw 'Reviewed terminology requires the fixed raw NEW localization evidence path.'
    }
    $expectedSourceId = 'nexus-' + $NexusId.ToString([Globalization.CultureInfo]::InvariantCulture)
    $request = Read-ReviewedTerminologyRequest -Path $RequestPath
    if ($request.nexusId -ne $NexusId -or $request.fileId -ne $MainFileId -or
        -not [string]::Equals($request.terminologyCorrection.sourceId, $expectedSourceId) -or
        -not [string]::Equals($Workset.sourceId, $expectedSourceId)) {
        throw 'Reviewed terminology Nexus, MAIN file, or generated source ID differs from trusted context.'
    }
    if (-not [string]::Equals($request.oldSha256, $Workset.old.sha256) -or
        -not [string]::Equals($request.newSha256, $Workset.new.sha256) -or
        -not [string]::Equals($request.immutableContractSha256, $Workset.immutableContractSha256) -or
        -not [string]::Equals($request.rulesSha256, $Workset.translationBinding.rulesSha256) -or
        -not [string]::Equals($request.glossarySha256, $Workset.translationBinding.glossarySha256)) {
        throw 'Reviewed terminology request is stale or differs from the workset and translation binding.'
    }
    $request
}

function Get-ReviewedTerminologyProtectedTokens {
    param([string] $Text)

    $pattern = @(
        '\{[^{}\r\n]*\}|[{}]'
        '</?[A-Za-z][^<>\r\n]*>'
        '%(?:%|(?:[0-9]+\$)?[-+ #0]*(?:[0-9]*|\*(?:[0-9]+\$)?)(?:\.(?:[0-9]+|\*(?:[0-9]+\$)?))?[acdiouxXeEfgGqsA])|%'
        '\r\n|[\p{Cc}\p{Cf}\p{Co}\u2028\u2029\uFE00-\uFE0F]|\uDB40[\uDD00-\uDDEF]|[\uD800-\uDBFF][\uDC00-\uDFFF]'
    ) -join '|'
    foreach ($token in [regex]::Matches($Text, $pattern)) {
        $value = $token.Value
        if ($value.Length -ne 2 -or -not [char]::IsSurrogatePair($value, 0) -or
            [Globalization.CharUnicodeInfo]::GetUnicodeCategory($value, 0) -in @('Format', 'PrivateUse') -or
            $value -cmatch '\A\uDB40[\uDD00-\uDDEF]\z') {
            $value
        }
    }
}

function Get-ReviewedTerminologyEdit {
    param($Request, $Workset, $OldDocument, $NewDocument, [byte[]] $NewBytes)

    $correction = $Request.terminologyCorrection
    $selected = @($Workset.units | Where-Object { [string]::Equals($_.unitId, $correction.unitId) })
    $matchesLocator = { [string]::Equals($_.containerPath, $correction.containerPath) -and [string]::Equals($_.key, $correction.key) }
    $oldSelected = @($OldDocument.units | Where-Object $matchesLocator)
    $newSelected = @($NewDocument.units | Where-Object $matchesLocator)
    if ($selected.Count -ne 1 -or $oldSelected.Count -ne 1 -or $newSelected.Count -ne 1 -or
        -not [string]::Equals($selected[0].containerPath, $correction.containerPath) -or
        -not [string]::Equals($selected[0].key, $correction.key) -or
        -not [string]::Equals($selected[0].sourceId, $correction.sourceId) -or $selected[0].occurrence -ne $correction.occurrence) {
        throw 'Reviewed terminology locator is missing, relocated, or ambiguous.'
    }
    $oldUnit = $oldSelected[0]
    $newUnit = $newSelected[0]
    foreach ($unit in @($oldUnit, $newUnit)) {
        if (-not [string]::Equals($unit.unitId, $correction.unitId) -or -not [string]::Equals($unit.sourceId, $correction.sourceId) -or
            $unit.occurrence -ne $correction.occurrence -or $null -ne $unit.blockedReason) {
            throw 'Reviewed terminology locator differs from an unambiguous parsed unit.'
        }
    }
    if (-not [string]::Equals($selected[0].changeType, 'unchanged') -or
        -not [string]::Equals($selected[0].action, 'NONE') -or -not [string]::Equals($correction.action, 'NONE') -or
        -not [string]::Equals((Get-UnitSnapshotJson -Unit $selected[0].old), (Get-UnitSnapshotJson -Unit $oldUnit)) -or
        -not [string]::Equals((Get-UnitSnapshotJson -Unit $selected[0].new), (Get-UnitSnapshotJson -Unit $newUnit)) -or
        $null -eq $oldUnit.sourceExpression -or $null -eq $newUnit.sourceExpression -or
        $null -eq $oldUnit.zhTwExpression -or $null -eq $newUnit.zhTwExpression -or
        -not [string]::Equals($oldUnit.sourceExpression.raw, $newUnit.sourceExpression.raw) -or
        -not [string]::Equals($oldUnit.zhTwExpression.raw, $newUnit.zhTwExpression.raw)) {
        throw 'Reviewed terminology requires an independently verified unchanged NONE action with exact OLD and NEW literals.'
    }
    if (-not [string]::Equals($correction.old.sourceRaw, $oldUnit.sourceExpression.raw) -or
        -not [string]::Equals($correction.new.sourceRaw, $newUnit.sourceExpression.raw) -or
        -not [string]::Equals($correction.old.zhTwRaw, $oldUnit.zhTwExpression.raw) -or
        -not [string]::Equals($correction.new.zhTwRaw, $newUnit.zhTwExpression.raw)) {
        throw 'Reviewed terminology prior literals differ from independently parsed OLD or NEW bytes.'
    }
    $null = ConvertFrom-LuaQuotedLiteral -Expression $newUnit.sourceExpression.raw
    $prior = ConvertFrom-LuaQuotedLiteral -Expression $newUnit.zhTwExpression.raw
    $translation = $correction.translation
    if ([string]::Equals($translation, $prior)) { throw 'Reviewed terminology translation is a no-op.' }
    if ($translation -cmatch '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]') {
        throw 'Reviewed terminology translation contains an unsupported control character.'
    }
    $newline = '\r\n|[\r\n\u2028\u2029]'
    $priorTokens = (Get-ReviewedTerminologyProtectedTokens -Text $prior) -join [char]0
    $translationTokens = (Get-ReviewedTerminologyProtectedTokens -Text $translation) -join [char]0
    $priorLines = ([regex]::Split($prior, $newline) | ForEach-Object { [string]::IsNullOrWhiteSpace($_) }) -join ','
    $translationLines = ([regex]::Split($translation, $newline) | ForEach-Object { [string]::IsNullOrWhiteSpace($_) }) -join ','
    if (-not [string]::Equals($priorTokens, $translationTokens) -or $priorLines -cne $translationLines) {
        throw 'Reviewed terminology changes protected placeholders, markup, glyphs, controls, or newline structure.'
    }
    $raw = [string]$newUnit.zhTwExpression.raw
    $quote = [string]$raw[0]
    $replacement = $quote + $translation.Replace('\', '\\').Replace($quote, '\' + $quote).Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t') + $quote
    if (-not [string]::Equals((ConvertFrom-LuaQuotedLiteral -Expression $replacement), $translation) -or
        -not (Test-LuaNonStringTokenSequence -Source $raw -Translation $replacement)) {
        throw 'Reviewed terminology replacement cannot preserve the Lua literal and format controls.'
    }
    $expression = $newUnit.zhTwExpression
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    if (-not [string]::Equals($utf8.GetString($NewBytes, $expression.startByte, $expression.lengthByte), $raw)) {
        throw 'Reviewed terminology prior span differs from exact raw NEW bytes.'
    }
    [ordered]@{
        startByte = $expression.startByte
        lengthByte = $expression.lengthByte
        replacement = $utf8.GetBytes($replacement)
        unitId = $newUnit.unitId
        operation = 'TERMINOLOGY_REPLACE'
    }
}

function New-ReviewedTerminologyEvidence {
    param($Request, $Workset, $Edit)

    $correction = $Request.terminologyCorrection
    [ordered]@{
        schemaVersion = 1
        requestSha256 = $Request.requestSha256
        nexusId = $Request.nexusId
        fileId = $Request.fileId
        baseOid = $Workset.baseOid
        modRelativePath = $Workset.modRelativePath
        localizationRelativePath = $Workset.old.path
        oldSha256 = $Request.oldSha256
        newSha256 = $Request.newSha256
        immutableContractSha256 = $Request.immutableContractSha256
        rulesSha256 = $Request.rulesSha256
        glossarySha256 = $Request.glossarySha256
        reviewer = $Request.reviewer
        reviewReference = $Request.reviewReference
        sourceId = $correction.sourceId
        containerPath = $correction.containerPath
        key = $correction.key
        occurrence = $correction.occurrence
        unitId = $correction.unitId
        action = $correction.action
        edit = $Edit
    }
}

Export-ModuleMember -Function Get-ImmutableWorksetContractSha256, Get-LocalizationTranslationBinding, Get-LocalizationGitBlobBytes,
    Get-UnitSnapshotJson, Assert-LocalizationTranslationBinding, Assert-LocalizationDocumentMetadata,
    Get-ReviewedTerminologyContext, Get-ReviewedTerminologyEdit,
    New-ReviewedTerminologyEvidence
