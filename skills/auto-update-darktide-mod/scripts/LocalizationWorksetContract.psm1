# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'PathSafety.psm1') -Scope Local -ErrorAction Stop

function Assert-LocalizationWorksetPassthroughCoverage {
    param([string[]] $Prefixes, [object[]] $Units)

    foreach ($prefix in $Prefixes) {
        if (-not $prefix) { continue }
        foreach ($unit in $Units) {
            if (Test-LuaLocalizationUnitInRootNamespace $unit $prefix) {
                throw "A game-localized output could overwrite a known localization key: $($unit.containerPath) / $($unit.key)"
            }
        }
    }
}

function Get-LocalizationWorksetSidecarRelativePath {
    param([Collections.IDictionary] $Document, [string] $ModRelativePath, [string] $MainRelativePath)

    if (-not $Document['zhTwSidecarLocaleBindingProven'] -or
        $MainRelativePath -cnotmatch '\Ascripts/mods/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+_localization\.lua\z') { return }
    $sidecar = $MainRelativePath -creplace '_localization\.lua$', '_localization_zh-tw.lua'
    $modName = ($ModRelativePath -split '/')[-1]
    if ([string]$Document.zhTwSidecarPath -ceq ($modName + '/' + $sidecar)) { $sidecar }
}

function Test-LocalizationWorksetStagedSidecarAbsent {
    param([string] $StagingRoot, [string] $RelativeSidecar)

    if (-not $RelativeSidecar) { return $false }
    $sidecar = Join-Path $StagingRoot $RelativeSidecar
    $directory = Split-Path -Parent $sidecar
    if (Test-PortableReparseItem -Path $directory -TrustedRoot $StagingRoot -Label 'Localization sidecar directory') {
        return $false
    }
    $prefix = (Split-Path -Leaf $sidecar) -creplace 'zh-tw\.lua$', ''
    @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Where-Object {
        $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $_.Name.EndsWith('.lua', [StringComparison]::OrdinalIgnoreCase)
    }).Count -eq 0
}

function Test-LocalizationWorksetTreeSidecarAbsent {
    param([string] $Repository, [string] $Commit, [string] $ModRelativePath, [string] $RelativeSidecar)

    if (-not $RelativeSidecar -or $Commit -cnotmatch '^[a-f0-9]{40}$') { return $false }
    $paths = @(& git -C $Repository -c core.quotePath=false ls-tree -r -t --name-only $Commit -- $ModRelativePath)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot independently inspect the localization sidecar in the immutable Git tree.' }
    $prefix = $ModRelativePath + '/' + ($RelativeSidecar -creplace 'zh-tw\.lua$', '')
    @($paths | Where-Object {
        $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $_.EndsWith('.lua', [StringComparison]::OrdinalIgnoreCase)
    }).Count -eq 0
}

function Get-LocalizationWorksetSharedTableOffsets {
    param([object[]] $Units)
    $tableOffsets = [Collections.Generic.HashSet[long]]::new()
    $sharedOffsets = [Collections.Generic.HashSet[long]]::new()
    foreach ($unit in $Units) {
        if ($null -ne $unit.tableOpenByte -and -not $tableOffsets.Add([long]$unit.tableOpenByte)) {
            $null = $sharedOffsets.Add([long]$unit.tableOpenByte)
        }
    }
    ,$sharedOffsets
}

function Test-LocalizationWorksetPositionalAppend {
    param([Collections.IDictionary] $Unit)

    return $null -ne $Unit -and [bool]$Unit['positionalLocale'] -and
        -not $Unit['blockedReason'] -and $null -eq $Unit['zhTwExpression'] -and
        $null -ne $Unit['positionalWrite'] -and [int]$Unit.positionalWrite.languageCount -eq 2
}

function Get-LocalizationWorksetPositionalZhCnValue {
    param([Collections.IDictionary] $Unit)
    if ($Unit.Contains('positionalZhCnValue')) { return $Unit.positionalZhCnValue }
    # Older worksets recorded this proof only alongside write metadata.
    if ($null -ne $Unit['positionalWrite']) { return $Unit.positionalWrite['zhCnValue'] }
}

function Get-LocalizationWorksetPositionalDecision {
    param([Collections.IDictionary] $OldUnit, [Collections.IDictionary] $NewUnit, [switch] $ReviewSimplifiedChanges)

    $action = 'AI_REQUIRED'
    if ($null -ne $OldUnit -and $null -ne $OldUnit.zhTwExpression -and
        $OldUnit.sourceExpression.raw -ceq $NewUnit.sourceExpression.raw) {
        $action = 'RESTORE_OLD_ZH_TW'
        if ($ReviewSimplifiedChanges) {
            $oldZhCn = Get-LocalizationWorksetPositionalZhCnValue $OldUnit
            $newZhCn = Get-LocalizationWorksetPositionalZhCnValue $NewUnit
            if ($oldZhCn -isnot [string] -or $newZhCn -isnot [string]) {
                return [ordered]@{ changeType = 'blocked'; action = 'BLOCKED'; blockedReason = 'generated_positional_zh_cn_value_unproven' }
            }
            if ($oldZhCn -cne $newZhCn) { $action = 'AI_REQUIRED' }
        }
    }
    [ordered]@{ changeType = 'missing_zh_tw'; action = $action; blockedReason = $null }
}

function Get-LocalizationWorksetPositionalInsertions {
    param([object[]] $ParsedUnits, [object[]] $ReviewedUnits, [switch] $ReviewSimplifiedChanges)

    $targets = @($ParsedUnits | Where-Object { Test-LocalizationWorksetPositionalAppend $_ })
    if ($targets.Count -eq 0) { return }
    if (@($ParsedUnits | Where-Object blockedReason).Count) {
        throw 'Cannot append a positional locale while a generated translation output is unproven.'
    }

    $reviewedById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($unit in $ReviewedUnits) {
        if (-not $reviewedById.TryAdd([string]$unit.unitId, $unit)) {
            throw 'Positional writeback review contains a duplicate unit.'
        }
    }

    $localeOffsets = [Collections.Generic.HashSet[long]]::new()
    $rowOffsets = [Collections.Generic.HashSet[long]]::new()
    $plans = [Collections.Generic.List[object]]::new()
    foreach ($unit in $targets) {
        $review = if ($reviewedById.ContainsKey($unit.unitId)) { $reviewedById[$unit.unitId] }
        if ($null -eq $review -or $null -eq $review.new -or -not (Test-LocalizationWorksetPositionalAppend $review.new)) {
            throw 'Positional zh-tw writeback requires a proven translation decision for every row in the locale group.'
        }
        $decision = Get-LocalizationWorksetPositionalDecision -OldUnit $review.old -NewUnit $unit -ReviewSimplifiedChanges:$ReviewSimplifiedChanges
        $action = $decision.action
        if ($decision.blockedReason) { throw "Positional zh-tw writeback is blocked: $($unit.unitId) ($($decision.blockedReason))" }
        if ($review.action -cne $action) { throw 'Positional zh-tw action differs from the expected source-bound decision.' }
        $literal = if ($action -ceq 'RESTORE_OLD_ZH_TW' -and $review.reviewStatus -ceq 'not-required' -and
            $null -eq $review.suggestedZhTwExpression) { [string]$review.old.zhTwExpression.raw }
        elseif ($action -ceq 'AI_REQUIRED' -and $review.reviewStatus -ceq 'approved') { [string]$review.suggestedZhTwExpression }
        else { throw 'Positional zh-tw writeback requires a proven translation decision for every row in the locale group.' }
        $provenOriginalLiteral = $action -ceq 'RESTORE_OLD_ZH_TW' -and $review.old['positionalLocale'] -and
            $review.old['positionalZhTwValue'] -is [string]
        if (-not $provenOriginalLiteral -and $literal -cnotmatch '\A"(?:[^"\\\p{Cc}]|\\["\\nrt])+"\z') {
            throw "Positional zh-tw approval must be one nonempty double-quoted Lua string: $($unit.unitId)"
        }
        if (-not (Test-LuaNonStringTokenSequence -Source ([string]$unit.sourceExpression.raw) -Translation $literal)) {
            throw "Positional zh-tw approval differs from NEW English token or format structure: $($unit.unitId)"
        }
        $localeOffset = [long]$unit.positionalWrite.localeInsertByte
        $rowOffset = [long]$unit.positionalWrite.rowInsertByte
        if ($localeOffset -le 0 -or $rowOffset -le 0 -or $localeOffset -eq $rowOffset -or -not $rowOffsets.Add($rowOffset)) {
            throw 'Positional zh-tw insertions overlap or have invalid source offsets.'
        }
        if ($localeOffsets.Add($localeOffset)) {
            $plans.Add([ordered]@{ startByte = $localeOffset; unitId = $unit.unitId; text = ', "zh-tw"'; literal = $null })
        }
        $plans.Add([ordered]@{ startByte = $rowOffset; unitId = $unit.unitId; text = ', ' + $literal; literal = $literal })
    }
    if ($localeOffsets.Overlaps($rowOffsets)) { throw 'Positional zh-tw locale and row insertions overlap.' }
    $plans.ToArray()
}

function Test-LocalizationWorksetNumericRestore {
    param([Collections.IDictionary] $OldUnit, [Collections.IDictionary] $NewUnit)

    if ($null -eq $OldUnit -or $null -eq $NewUnit -or $OldUnit['blockedReason'] -or $NewUnit['blockedReason'] -or
        $null -eq $OldUnit.zhTwExpression -or $null -ne $NewUnit.zhTwExpression -or
        $null -eq $OldUnit['generatedBinding'] -or $null -eq $NewUnit['generatedBinding'] -or
        $NewUnit.generatedBinding.kind -cne 'numeric-loop' -or $NewUnit.generatedBinding['tostringBindingProven'] -ne $true -or
        (ConvertTo-Json -InputObject $OldUnit.generatedBinding -Compress) -cne (ConvertTo-Json -InputObject $NewUnit.generatedBinding -Compress) -or
        $OldUnit.sourceExpression.raw -cne $NewUnit.sourceExpression.raw) { return $false }

    $parameter = [regex]::Escape([string]$NewUnit.generatedBinding.parameter)
    $prefix = '"(?:[^"\\\p{Cc}]|\\["\\nrt])+"'
    [string]$OldUnit.zhTwExpression.raw -cmatch ("\A" + $prefix + '[ \t]*\.\.[ \t]*tostring\([ \t]*' + $parameter + '[ \t]*\)\z')
}

function Assert-LocalizationWorksetSharedRestorationCoverage {
    param([object[]] $ParsedUnits, [object[]] $ReviewedUnits)

    $restorations = @($ReviewedUnits | Where-Object {
        $_.action -ceq 'RESTORE_OLD_ZH_TW' -and (Test-LocalizationWorksetNumericRestore $_.old $_.new)
    })
    if ($restorations.Count -eq 0) { return }
    $byId = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $ReviewedUnits) {
        if (-not $byId.TryAdd([string]$entry.unitId, $entry)) { throw 'Localization restoration contains a duplicate unit.' }
    }
    foreach ($group in @($restorations | Group-Object { [long]$_.new.tableOpenByte })) {
        $expectedExpression = [string]$group.Group[0].old.zhTwExpression.raw
        $parsed = @($ParsedUnits | Where-Object { $null -ne $_.tableOpenByte -and [long]$_.tableOpenByte -eq [long]$group.Name })
        if ($parsed.Count -ne $group.Count) { throw 'Shared numeric localization requires all generated outputs.' }
        foreach ($unit in $parsed) {
            $review = if ($byId.ContainsKey($unit.unitId)) { $byId[$unit.unitId] }
            if ($null -eq $review -or $review.action -cne 'RESTORE_OLD_ZH_TW' -or
                -not (Test-LocalizationWorksetNumericRestore $review.old $unit) -or
                [string]$review.old.zhTwExpression.raw -cne $expectedExpression) {
                throw 'Shared numeric localization requires the same proven original zh-tw expression for every output.'
            }
        }
    }
}

function Get-LocalizationWorksetWriteBlockReason {
    param(
        [string] $Action,
        [Collections.IDictionary] $OldUnit,
        [Collections.IDictionary] $NewUnit,
        [switch] $SharedNewTable,
        [Collections.IDictionary] $Review
    )
    $sharedReason = 'generated_shared_translation_span_requires_review'
    if ($Action -ceq 'BLOCKED') { return }
    if ($null -ne $OldUnit -and $null -ne $NewUnit) {
        $oldBinding = $OldUnit['generatedBinding']
        $newBinding = $NewUnit['generatedBinding']
        if (($null -ne $oldBinding -or $null -ne $newBinding) -and
            (ConvertTo-Json -InputObject $oldBinding -Compress) -cne (ConvertTo-Json -InputObject $newBinding -Compress)) {
            return 'generated_binding_changed_requires_review'
        }
    }
    if ($Action -ceq 'NONE') {
        if ($SharedNewTable -and $null -ne $OldUnit -and $null -ne $NewUnit) {
            foreach ($field in @('sourceExpression', 'zhTwExpression')) {
                $oldExpression = $OldUnit[$field]
                $newExpression = $NewUnit[$field]
                $oldRaw = if ($null -ne $oldExpression) { $oldExpression['raw'] } else { $null }
                $newRaw = if ($null -ne $newExpression) { $newExpression['raw'] } else { $null }
                if ($oldRaw -cne $newRaw) { return $sharedReason }
            }
        }
        return
    }
    if ($Action -ceq 'ACCEPT_REMOVAL') {
        if ($null -ne $OldUnit -and $OldUnit['positionalLocale'] -and $null -ne $OldUnit['zhTwExpression']) {
            return 'generated_positional_zh_tw_output_removed'
        }
        return
    }
    if ($null -ne $NewUnit -and $NewUnit['positionalLocale']) {
        if (-not $SharedNewTable -and $Action -cin @('AI_REQUIRED', 'RESTORE_OLD_ZH_TW') -and (Test-LocalizationWorksetPositionalAppend $NewUnit)) { return }
        return 'generated_positional_locale_requires_review'
    }
    $hasLiteralTranslation = $null -ne $NewUnit -and $null -ne $NewUnit['generatedBinding'] -and
        $NewUnit.generatedBinding.kind -ceq 'literal-list-loop' -and $null -ne $NewUnit.zhTwExpression
    $isLiteralOverlay = $false
    if ($hasLiteralTranslation) {
        $fieldStart = [long]$NewUnit.zhTwExpression.fieldStartByte
        $fieldEnd = $fieldStart + [long]$NewUnit.zhTwExpression.fieldLengthByte
        $isLiteralOverlay = $fieldStart -le [long]$NewUnit.tableOpenByte -or $fieldEnd -gt [long]$NewUnit.tableCloseByte
    }
    # A shared or external literal can be approved as it stands. It is unsafe to
    # edit its shared bytes or remove only part of a separate Lua assignment.
    if ($hasLiteralTranslation -and ($SharedNewTable -or $isLiteralOverlay) -and $Action -ceq 'AI_REQUIRED') {
        if ($null -eq $Review -or ($Review['reviewStatus'] -ceq 'preserved' -and $null -eq $Review['suggestedZhTwExpression'])) { return }
        return 'generated_shared_literal_translation_requires_preservation_review'
    }
    if ($isLiteralOverlay) { return 'generated_literal_overlay_write_unproven' }
    if ($SharedNewTable) {
        if ($Action -ceq 'RESTORE_OLD_ZH_TW' -and (Test-LocalizationWorksetNumericRestore $OldUnit $NewUnit)) { return }
        return $sharedReason
    }
}

function Get-ImmutableWorksetContractSha256 {
    param([Collections.IDictionary] $Workset)

    if ($Workset.old.Contains('coverage') -or $Workset.new.Contains('coverage') -or
        $Workset.new.Contains('coverageInputBase64') -or $Workset.new.Contains('zhTwSurvival')) {
        if ($Workset.old['coverage'] -isnot [Collections.IDictionary] -or
            $Workset.new['coverage'] -isnot [Collections.IDictionary] -or
            $Workset.old.coverage['version'] -ne 1 -or $Workset.new.coverage['version'] -ne 1 -or
            $Workset.new['coverageInputBase64'] -isnot [string] -or
            $Workset.new['zhTwSurvival'] -isnot [array] -or
            [string]::IsNullOrWhiteSpace([string]$Workset.old['repositoryRoot'])) {
            throw 'Localization source coverage contract is incomplete or unsupported.'
        }
    }
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
    if ($Workset.Contains('positionalLabelReview')) {
        if ($Workset.generatorVersion -ne 2 -or $Workset.positionalLabelReview -cne 'zh-cn-changes') {
            throw 'Localization workset positional review scope is invalid.'
        }
        $contract.positionalLabelReview = $Workset.positionalLabelReview
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
    foreach ($argument in @('-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) { $start.ArgumentList.Add($argument) }
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

Export-ModuleMember -Function Get-ImmutableWorksetContractSha256, Get-LocalizationTranslationBinding, Get-LocalizationGitBlobBytes, Get-LocalizationWorksetWriteBlockReason, Get-LocalizationWorksetSharedTableOffsets, Test-LocalizationWorksetPositionalAppend, Get-LocalizationWorksetPositionalDecision, Get-LocalizationWorksetPositionalInsertions, Assert-LocalizationWorksetSharedRestorationCoverage, Get-LocalizationWorksetSidecarRelativePath, Test-LocalizationWorksetStagedSidecarAbsent, Test-LocalizationWorksetTreeSidecarAbsent, Assert-LocalizationWorksetPassthroughCoverage
