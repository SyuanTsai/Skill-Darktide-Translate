# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Scope Local

function Get-LocalizationDynamicListEvidence {
    param([string] $Path)
    if (-not $Path) { return }
    $full = [IO.Path]::GetFullPath($Path)
    $bytes = [IO.File]::ReadAllBytes($full)
    $map = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -AsHashtable
    if ($map['schemaVersion'] -ne 1 -or $map['entries'] -isnot [Collections.IDictionary] -or
        [string]::IsNullOrWhiteSpace([string]$map['sourcePath'])) { throw 'dynamic_list_mapping_invalid' }
    $source = [IO.Path]::GetFullPath([string]$map.sourcePath, (Split-Path -Parent $full))
    $sourceBytes = [IO.File]::ReadAllBytes($source)
    $keys = @(Get-LuaMoodListKeys $sourceBytes)
    $rows = @(foreach ($key in $keys) {
        $candidate = $map.entries[$key]
        [ordered]@{
            name = $key; key = 'hide_mood_vfx_' + $key; source = 'Disable ' + $key.Replace('_', ' ')
            candidateZhTw = if ($candidate -is [string] -and -not [string]::IsNullOrWhiteSpace($candidate)) { $candidate } else { $null }
            reviewStatus = 'pending'
        }
    })
    [ordered]@{
        path = $full; sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        sourcePath = $source; sourceSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes)).ToLowerInvariant()
        rows = $rows
        missingNames = @($rows | Where-Object { $null -eq $_.candidateZhTw } | ForEach-Object name)
        extraNames = @($map.entries.Keys | Where-Object { $_ -cnotin $keys } | Sort-Object -CaseSensitive)
    }
}

function Get-LocalizationSourceCoverage {
    param([Collections.IDictionary] $Document, [Collections.IDictionary] $DynamicList)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($unit in $Document.units) { $null = $ids.Add($unit.unitId) }
    $methods = @($Document.sourceInventory.methods | Where-Object { $ids.Contains($_.unitId) })
    $blocked = @($Document.units | Where-Object blockedReason | ForEach-Object {
        [ordered]@{ key = $_.key; reason = $_.blockedReason }
    })
    $uncovered = @($Document.sourceInventory.languageFieldsOutsideUnits)
    $prefixes = @($Document['gameLocalizedPassthroughPrefixes'] | Where-Object { $_ })
    $dynamic = 'MoodSettings.mood_types' -cin $Document.sourceInventory.dynamicSources
    $reasons = [Collections.Generic.List[string]]::new()
    if ($blocked.Count) { $reasons.Add('unproven_localization_units: ' + (($blocked | ForEach-Object { $_.key + ' (' + $_.reason + ')' }) -join '; ')) }
    if ($uncovered.Count) { $reasons.Add('uncovered_language_fields') }
    if ($Document.sourceInventory.unprovenFields.Count) { $reasons.Add('unproven_source_fields: ' + (($Document.sourceInventory.unprovenFields | ForEach-Object key) -join ', ')) }
    if ($Document.units.Count -eq 0 -and -not $Document.isIoDofileOnlyLoader) { $reasons.Add('no_proven_localization_units') }
    if ($dynamic) {
        if ($null -eq $DynamicList) { $reasons.Add('dynamic_entries_uncovered: MoodSettings.mood_types requires a source and name mapping') }
        elseif ($DynamicList.missingNames.Count -or $DynamicList.extraNames.Count) {
            $reasons.Add('dynamic_list_mapping_incomplete: ' + ((@($DynamicList.missingNames) + @($DynamicList.extraNames)) -join ', '))
        }
        else {
            # A terminology candidate is not a translation in the output file.
            # Keep the existing writer boundary: do not silently authorize a new
            # runtime lookup or accept the English fallback as translated output.
            $reasons.Add('dynamic_candidates_require_review: hide_mood_vfx_* has English-only runtime output')
        }
    }
    [ordered]@{
        version = 1; unitCount = $Document.units.Count
        categories = @(
            foreach ($category in @('named-language-table', 'positional-array', 'dynamic-assignment', 'numeric-loop', 'literal-helper', 'literal-list-loop')) {
                [ordered]@{ method = $category; unitCount = @($methods | Where-Object method -CEQ $category).Count }
            }
        )
        units = $methods; blockedUnits = $blocked; uncoveredLanguageFields = $uncovered; unprovenFields = $Document.sourceInventory.unprovenFields
        runtimePrefixes = $prefixes; dynamicSources = $Document.sourceInventory.dynamicSources
        dynamicEntryCount = if ($dynamic -and $null -ne $DynamicList) { $DynamicList.rows.Count } elseif ($dynamic) { $null } else { 0 }
        dynamicList = if ($dynamic) { $DynamicList } else { $null }
        blockedReasons = @($reasons)
    }
}

function Assert-LocalizationSourceCoverage {
    param([Collections.IDictionary] $Recorded, [Collections.IDictionary] $Document, [string] $Side)
    if ($null -eq $Recorded) { return } # Existing pre-coverage worksets remain readable.
    $list = if ($null -ne $Recorded['dynamicList']) { Get-LocalizationDynamicListEvidence $Recorded.dynamicList.path }
    $actual = Get-LocalizationSourceCoverage $Document $list
    if (($Recorded | ConvertTo-Json -Depth 40 -Compress) -cne ($actual | ConvertTo-Json -Depth 40 -Compress)) {
        throw "Localization source coverage differs from independently scanned $Side bytes."
    }
    if ($actual.blockedReasons.Count) { throw "Localization source coverage BLOCKED ($Side): $($actual.blockedReasons -join '; ')" }
}

function Get-LocalizationZhTwSurvival {
    param([object[]] $OldUnits, [object[]] $NewUnits, [switch] $ReviewSimplifiedChanges)
    $newById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($unit in $NewUnits) { $newById.Add($unit.unitId, $unit) }
    @(foreach ($old in $OldUnits) {
        if ($null -eq $old.zhTwExpression) { continue }
        $new = if ($newById.ContainsKey($old.unitId)) { $newById[$old.unitId] }
        $reason = if ($null -eq $new) { 'deleted_in_new_source' }
            elseif ($null -eq $old.sourceExpression -or $null -eq $new.sourceExpression -or
                $old.sourceExpression.canonical -cne $new.sourceExpression.canonical) { 'source_changed_requires_review' }
            elseif ($ReviewSimplifiedChanges -and $old['positionalLocale'] -and $new['positionalLocale'] -and
                $old['positionalZhCnValue'] -cne $new['positionalZhCnValue']) { 'positional_label_changed_requires_review' }
            elseif (($old['generatedBinding'] | ConvertTo-Json -Compress) -cne ($new['generatedBinding'] | ConvertTo-Json -Compress)) { 'structure_changed_requires_review' }
            else { 'preserve_old_zh_tw' }
        [ordered]@{ unitId = $old.unitId; key = $old.key; reason = $reason; oldExpression = $old.zhTwExpression.raw }
    })
}

function Assert-LocalizationZhTwSurvival {
    param([object[]] $OldUnits, [object[]] $NewUnits, [object[]] $OutputUnits, [object[]] $Recorded, [switch] $ReviewSimplifiedChanges)
    $actual = @(Get-LocalizationZhTwSurvival $OldUnits $NewUnits -ReviewSimplifiedChanges:$ReviewSimplifiedChanges)
    if ($PSBoundParameters.ContainsKey('Recorded') -and
        (ConvertTo-Json -InputObject @($Recorded) -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $actual -Depth 20 -Compress)) {
        throw 'OLD zh-tw survival inventory differs from independently scanned sources.'
    }
    $outputs = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($unit in $OutputUnits) { $outputs[$unit.unitId] = $unit }
    foreach ($entry in $actual) {
        if ($entry.reason -ceq 'deleted_in_new_source') { continue }
        $output = if ($outputs.ContainsKey($entry.unitId)) { $outputs[$entry.unitId] }
        if ($null -eq $output -or $output.blockedReason -or $null -eq $output.zhTwExpression) {
            throw "OLD zh-tw survival failed: $($entry.key) (missing translation or unproven output)"
        }
        if ($entry.reason -ceq 'preserve_old_zh_tw' -and
            ($entry.oldExpression -replace '\r\n', "`n") -cne ($output.zhTwExpression.raw -replace '\r\n', "`n")) {
            throw "OLD zh-tw survival failed: $($entry.key) (unchanged source lost its original translation)"
        }
    }
}

Export-ModuleMember -Function Get-LocalizationDynamicListEvidence, Get-LocalizationSourceCoverage, Assert-LocalizationSourceCoverage, Get-LocalizationZhTwSurvival, Assert-LocalizationZhTwSurvival
