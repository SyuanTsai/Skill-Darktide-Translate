# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Positional Lua scanner write metadata' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $layout = Get-TestRepositoryLayout -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $layout.ScriptRoot 'LuaLocalizationScanner.psm1') -Force

        function New-TestPositionalSource {
            param(
                [string] $LocaleList,
                [string] $Rows,
                [string] $Calls = 'generate_translation(items, nil, nil, locale_order)'
            )
            $template = @'
local output = {}
-- 中文註解 before each insertion point.
local locale_order = {
    __LOCALES__
}
local function generate_translation(t,prefix,suffix,lids)
    if type(t) ~= "table" then return end
    local prefix = prefix or ""
    local suffix = suffix or ""
    local full_id = ""
    for id,text in pairs(t) do
        full_id = prefix..id..suffix
        output[full_id] = output[full_id] or {}
        if type(text) == "table" and type(lids) == "table" and #lids == #text then
            for i = 1,#lids do
                output[full_id][lids[i]] = text[i]
            end
        elseif type(text) == "string" and type(lids) == "string" then
            output[full_id][lids] = text
        end
    end
end
local items = {
    __ROWS__
}
__CALLS__
return output
'@
            $template.Replace('__LOCALES__', $LocaleList).Replace('__ROWS__', $Rows).Replace('__CALLS__', $Calls)
        }

        function Add-TestPositionalRuntime {
            param(
                [string] $Source,
                [string] $Runtime,
                [switch] $FixedLanguage,
                [string] $Bindings = ('local mod = get_mod("Fixture")' + [char]10 + 'local _io = Mods.lua.io')
            )
            $binding = if ($FixedLanguage) { 'local lid = "en"' } else {
                'mod.lid = Managers and Managers.localization and Managers.localization:language() or Application.user_setting("language_id") or "en"' +
                    [char]10 + 'local lid = mod.lid'
            }
            $Source.Replace('return output', $Bindings + [char]10 + $binding + [char]10 + $Runtime + [char]10 + 'return output')
        }

        function Get-TestPositionalSidecarTail {
            @'
if lid and type(lid) == "string" then
    local _mod_directory = "./../mods/"
    local my_lid = "Fixture/scripts/mods/Fixture/Fixture_localization_" .. lid
    local file = _io.open(_mod_directory .. my_lid .. ".lua","r")
    if file ~= nil then
        file:close()
        my_lid = mod:io_dofile(my_lid)
        if my_lid.common then
            local myl_nt = my_lid.common.player_notable_talents or my_lid.common.setting_player_notable_talents
            if my_nt then
                my_lid.common.mod_description = generate_notable_talents_description(myl_nt)
            end
            generate_translation(my_lid.common,nil,nil,lid)
        end
        if my_lid.talents then generate_translation(my_lid.talents,"def_",nil,lid) end
        if my_lid.notable then generate_translation(my_lid.notable,"highlight_",nil,lid) end
    end
end
'@
        }

        function Get-TestGameLocalizedLoop {
            @'
local datalookup = mod.datalookup
for _,class in pairs(datalookup.class_index) do
    output["game_class_name_"..class] = output["game_class_name_"..class] or {}
    output["game_class_name_"..class][lid] = Localize("loc_class_"..class.."_name")
end
'@
        }

        function Read-TestPositionalSource {
            param([string] $Source)
            Get-LuaLocalizationDocument -Bytes ([Text.Encoding]::UTF8.GetBytes($Source)) -SourceId 'positional-write'
        }
    }

    # Scenario: A two-language source has UTF-8 BOM, CRLF, multibyte text, and trailing separators and comments.
    # Purpose: Confirm both insertion byte offsets end at the last literal token and preserve the following trivia.
    It 'UnitT10_RecordsByteOffsetsBeforeTrailingSeparators' {
        $rows = 'sample = {"English", "简体"; -- row tail' + [char]10 + '    },'
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn", -- locale tail' -Rows $rows
        $source = $source -replace '\r?\n', ([string][char]13 + [char]10)
        $encoding = [Text.UTF8Encoding]::new($true)
        $bytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($source))

        $document = Get-LuaLocalizationDocument -Bytes $bytes -SourceId 'positional-write'

        $document.bom | Should -BeTrue
        $document.newline | Should -BeExactly 'crlf'
        $unit = $document.units[0]
        $unit.blockedReason | Should -BeNullOrEmpty
        $unit.positionalWrite.Keys -join ',' | Should -BeExactly 'localeInsertByte,rowInsertByte,languageCount,zhCnValue'
        $unit.positionalWrite.languageCount | Should -Be 2
        $localeIndex = $source.IndexOf(', -- locale tail', [StringComparison]::Ordinal)
        $rowIndex = $source.IndexOf('; -- row tail', [StringComparison]::Ordinal)
        $unit.positionalWrite.localeInsertByte | Should -Be ($encoding.GetPreamble().Length + $encoding.GetByteCount($source.Substring(0, $localeIndex)))
        $unit.positionalWrite.rowInsertByte | Should -Be ($encoding.GetPreamble().Length + $encoding.GetByteCount($source.Substring(0, $rowIndex)))
        [char]$bytes[$unit.positionalWrite.localeInsertByte] | Should -Be ','
        [char]$bytes[$unit.positionalWrite.rowInsertByte] | Should -Be ';'
    }

    # Scenario: A three-language row already has a literal zh-tw value, followed by whitespace and no separator.
    # Purpose: Keep the existing value and describe the verified language order and last literal boundaries.
    It 'UnitT20_RecordsThreeLanguageRowsAndPreservesZhTw' {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn", "zh-tw" -- locale tail' -Rows 'sample = {"English", "简体", "繁體"   },'
        $document = Read-TestPositionalSource $source
        $unit = $document.units[0]

        $unit.positionalWrite.languageCount | Should -Be 3
        $unit.zhTwExpression.raw | Should -BeExactly '"繁體"'
        $unit.positionalZhTwValue | Should -BeExactly '繁體'
        $localeIndex = $source.IndexOf(' -- locale tail', [StringComparison]::Ordinal)
        $rowIndex = $source.IndexOf('   },', [StringComparison]::Ordinal)
        $unit.positionalWrite.localeInsertByte | Should -Be ([Text.Encoding]::UTF8.GetByteCount($source.Substring(0, $localeIndex)))
        $unit.positionalWrite.rowInsertByte | Should -Be ([Text.Encoding]::UTF8.GetByteCount($source.Substring(0, $rowIndex)))
    }

    # Scenario: A literal Simplified Chinese value contains UTF-8 byte escapes or an invalid standalone byte.
    # Purpose: Expose decoded source text only when an exact comparison is possible.
    It 'UnitT25_RequiresValidUtf8ForSimplifiedChineseWriteEvidence: <Case>' -ForEach @(
        @{ Case = 'escaped UTF-8'; Literal = '"\xe7\xae\x80"'; Expected = '简' }
        @{ Case = 'invalid UTF-8'; Literal = '"\xff"'; Expected = $null }
    ) {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows ('sample = {"English", ' + $Literal + '}')

        $unit = (Read-TestPositionalSource $source).units[0]

        $unit.blockedReason | Should -BeNullOrEmpty
        $unit.positionalLocale | Should -BeTrue
        $unit.Contains('positionalWrite') | Should -Be ($null -ne $Expected)
        if ($null -ne $Expected) { $unit.positionalWrite.zhCnValue | Should -BeExactly $Expected }
    }

    # Scenario: The locale order is non-target or a literal row has fewer values than its locale order.
    # Purpose: Keep existing scan classification and exclude unproven shapes from positional writes.
    It 'UnitT30_OmitsWriteMetadataForUnsupportedLocaleShapes: <Case>' -ForEach @(
        @{ Case = 'reordered locale list'; Locales = '"zh-cn", "en"'; Row = '"简体", "English"'; Reason = $null }
        @{ Case = 'different third locale'; Locales = '"en", "zh-cn", "fr"'; Row = '"English", "简体", "Français"'; Reason = $null }
        @{ Case = 'short row'; Locales = '"en", "zh-cn", "zh-tw"'; Row = '"English", "简体"'; Reason = 'generated_locale_length_mismatch' }
        @{ Case = 'nonliteral row'; Locales = '"en", "zh-cn"'; Row = '"English", look_up()'; Reason = 'generated_row_not_literal' }
    ) {
        $source = New-TestPositionalSource -LocaleList $Locales -Rows ('sample = {' + $Row + '}')

        $unit = (Read-TestPositionalSource $source).units[0]

        $unit.Contains('positionalWrite') | Should -BeFalse
        if ($Reason) { $unit.blockedReason | Should -BeExactly $Reason }
        else {
            $unit.blockedReason | Should -BeNullOrEmpty
            $unit.sourceExpression.raw | Should -BeExactly '"English"'
        }
    }

    # Scenario: Several calls consume the same locale list but each physical row has exactly one call.
    # Purpose: Recognize a reusable locale insertion point without combining the distinct row spans.
    It 'UnitT40_AllowsIndependentInputsToShareTheLocaleList' {
        $calls = @'
local second = { other = {"Other", "另一個"} }
generate_translation(items, nil, nil, locale_order)
generate_translation(second, nil, nil, locale_order)
'@
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows 'sample = {"English", "简体"}' -Calls $calls

        $units = (Read-TestPositionalSource $source).units

        @($units).Count | Should -Be 2
        $units[0].positionalWrite.localeInsertByte | Should -Be $units[1].positionalWrite.localeInsertByte
        $units[0].positionalWrite.rowInsertByte | Should -BeLessThan $units[1].positionalWrite.rowInsertByte
    }

    # Scenario: A second call shares an input table, or distinct input tables generate a duplicate key.
    # Purpose: Prevent the scanner from offering flags for shared or blocked positional outputs.
    It 'UnitT50_OmitsWriteMetadataForAmbiguousOutputs: <Case>' -ForEach @(
        @{
            Case = 'shared physical row'; Duplicate = $false
            Calls = 'generate_translation(items, "a_", nil, locale_order)
generate_translation(items, "b_", nil, locale_order)'
        }
        @{
            Case = 'duplicate output key'; Duplicate = $true
            Calls = 'local second = { sample = {"Other", "不同"} }
generate_translation(items, nil, nil, locale_order)
generate_translation(second, nil, nil, locale_order)'
        }
    ) {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows 'sample = {"English", "简体"}' -Calls $Calls

        $units = (Read-TestPositionalSource $source).units

        @($units).Count | Should -Be 2
        foreach ($unit in $units) {
            $unit.Contains('positionalWrite') | Should -BeFalse
            if ($Duplicate) { $unit.blockedReason | Should -BeExactly 'duplicate_generated_localization_key' }
            else { $unit.blockedReason | Should -BeNullOrEmpty }
        }
    }

    # Scenario: Three unresolved calls form the exact locale-selected sidecar loader.
    # Purpose: Mark the exact calls for independent absence proof while keeping their original blockers.
    It 'UnitT60_MarksOnlyCallsInTheProvenConditionalSidecar' {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows 'sample = {"English", "简体"}'
        $source = Add-TestPositionalRuntime $source (Get-TestPositionalSidecarTail)

        $document = Read-TestPositionalSource $source

        $document.zhTwSidecarLocaleBindingProven | Should -BeTrue
        $calls = @($document.units | Where-Object { $_.Contains('conditionalZhTwSidecar') })
        $calls.Count | Should -Be 3
        foreach ($call in $calls) {
            $call.conditionalZhTwSidecar | Should -BeTrue
            $call.blockedReason | Should -BeExactly 'unsupported_generated_localization_call'
            $call.key | Should -Match '^generate_translation\(my_lid\.(common|talents|notable),'
        }
    }

    # Scenario: A fixed locale or a fourth unresolved call prevents proving the full loader boundary.
    # Purpose: Ensure an unproven runtime call keeps its blocker without a conditional sidecar exemption.
    It 'UnitT65_LeavesUnprovenConditionalSidecarCallsBlocked: <Case>' -ForEach @(
        @{ Case = 'fixed locale'; FixedLanguage = $true; BeforeTail = ''; CallCount = 3 }
        @{ Case = 'multiple assignment to locale'; FixedLanguage = $false; BeforeTail = 'lid, ignored = "en", nil'; CallCount = 3 }
        @{ Case = 'outside unresolved call'; FixedLanguage = $false; BeforeTail = 'generate_translation(mod.unrelated, nil, nil, lid)'; CallCount = 4 }
    ) {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows 'sample = {"English", "简体"}'
        $tail = $BeforeTail + [char]10 + (Get-TestPositionalSidecarTail)
        $source = Add-TestPositionalRuntime $source $tail -FixedLanguage:$FixedLanguage

        $document = Read-TestPositionalSource $source

        @($document.units | Where-Object blockedReason -CEQ 'unsupported_generated_localization_call').Count | Should -Be $CallCount
        @($document.units | Where-Object { $_.Contains('conditionalZhTwSidecar') }).Count | Should -Be 0
    }


    # Scenario: A known sidecar-tail shape borrows a custom or mutated native loader binding.
    # Purpose: Keep disk absence from authorizing removal of a call that could still execute.
    It 'UnitT67_RejectsUnprovenNativeSidecarBindings: <Case>' -ForEach @(
        @{ Case = 'custom mod table'; Mod = 'local mod = { io_dofile = function() return {} end }'; Io = 'local _io = Mods.lua.io'; Extra = '' }
        @{ Case = 'custom file I/O'; Mod = 'local mod = get_mod("Fixture")'; Io = 'local _io = { open = function() return {} end }'; Extra = '' }
        @{ Case = 'different mod name'; Mod = 'local mod = get_mod("OtherFixture")'; Io = 'local _io = Mods.lua.io'; Extra = '' }
        @{ Case = 'shadowed get_mod'; Mod = 'local get_mod = function() return {} end; local mod = get_mod("Fixture")'; Io = 'local _io = Mods.lua.io'; Extra = '' }
        @{ Case = 'replacement mod method'; Mod = 'local mod = get_mod("Fixture")'; Io = 'local _io = Mods.lua.io'; Extra = 'function mod:io_dofile() return {} end' }
        @{ Case = 'replacement open method'; Mod = 'local mod = get_mod("Fixture")'; Io = 'local _io = Mods.lua.io'; Extra = '_io.open = function() return {} end' }
        @{ Case = 'replacement open through Mods'; Mod = 'local mod = get_mod("Fixture")'; Io = 'local _io = Mods.lua.io'; Extra = 'Mods.lua.io.open = function() return {} end' }
        @{ Case = 'alias of mod'; Mod = 'local mod = get_mod("Fixture")'; Io = 'local _io = Mods.lua.io'; Extra = 'local alias = get_mod("Fixture"); alias.io_dofile = function() return {} end' }
        @{ Case = 'new mod binding'; Mod = 'local mod = get_mod("Fixture")'; Io = 'local _io = Mods.lua.io'; Extra = 'mod = {}' }
    ) {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows 'sample = {"English", "简体"}'
        $bindings = @($Mod, $Io, $Extra) -join [char]10
        $source = Add-TestPositionalRuntime $source (Get-TestPositionalSidecarTail) -Bindings $bindings

        $document = Read-TestPositionalSource $source

        @($document.units | Where-Object blockedReason -CEQ 'unsupported_generated_localization_call').Count | Should -Be 3
        @($document.units | Where-Object { $_.Contains('conditionalZhTwSidecar') }).Count | Should -Be 0
    }

    # Scenario: A numeric generator omits zh-tw, so the table no longer calls tostring at scan time.
    # Purpose: Show whether a later write could safely restore an expression that calls the native tostring.
    It 'UnitT80_RecordsTostringBindingForNumericWrites: <Case>' -ForEach @(
        @{ Case = 'native tostring'; Prelude = ''; Expected = $true }
        @{ Case = 'shadowed tostring'; Prelude = 'local tostring = function() return "BAD" end'; Expected = $false }
    ) {
        $source = @'
local output = {}
__PRELUDE__
for i = 1,4 do
    output[string.format("slot_%s",i)] = { en = "Slot" }
end
return output
'@
        $source = $source.Replace('__PRELUDE__', $Prelude)

        $document = Read-TestPositionalSource $source

        $document.units.Count | Should -Be 4
        foreach ($unit in $document.units) {
            $unit.generatedBinding.tostringBindingProven | Should -Be $Expected
        }
    }
    # Scenario: An exact class-index loop produces only game Localize values under a disjoint prefix.
    # Purpose: Keep that runtime-owned prefix auditable without treating it as a user-editable translation.
    It 'UnitT70_RecognizesVerifiedGameLocalizedPassthrough' {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows 'sample = {"English", "简体"}'
        $source = Add-TestPositionalRuntime $source (Get-TestGameLocalizedLoop)

        $document = Read-TestPositionalSource $source

        @($document.gameLocalizedPassthroughPrefixes).Count | Should -Be 1
        $document.gameLocalizedPassthroughPrefixes[0] | Should -BeExactly 'game_class_name_'
        $document.units.Count | Should -Be 1
        $document.units[0].key | Should -BeExactly 'sample'
    }

    # Scenario: A static zh-tw key shares the runtime prefix, or runtime resolution deviates from the exact proof.
    # Purpose: Reject a potentially overriding or shadowed game-localized loop.
    It 'UnitT75_KeepsUnprovenGameLocalizedLoopsBlocked: <Case>' -ForEach @(
        @{ Case = 'static key prefix collision'; Prefix = 'output.game_class_name_veteran = { en = "Veteran", ["zh-tw"] = "老兵" }'; From = ''; To = ''; Collision = $true }
        @{ Case = 'Localize shadowing'; Prefix = 'local Localize = function() return "Unknown" end'; From = ''; To = ''; Collision = $false }
        @{ Case = 'changed lookup key suffix'; Prefix = ''; From = '"_name"'; To = '"_title"'; Collision = $false }
        @{ Case = 'shadowed class lookup'; Prefix = ''; From = 'for _,class'; To = "datalookup = mod.other_lookup; for _,class"; Collision = $false }
    ) {
        $source = New-TestPositionalSource -LocaleList '"en", "zh-cn"' -Rows 'sample = {"English", "简体"}'
        $runtime = Get-TestGameLocalizedLoop
        if ($From) { $runtime = $runtime.Replace($From, $To) }
        $source = Add-TestPositionalRuntime $source ($Prefix + [char]10 + $runtime)

        $document = Read-TestPositionalSource $source

        $document.Contains('gameLocalizedPassthroughPrefixes') | Should -BeFalse
        @($document.units | Where-Object blockedReason).Count | Should -BeGreaterThan 0
        if ($Collision) {
            @($document.units | Where-Object blockedReason -CEQ 'game_localize_passthrough_prefix_collision').Count | Should -Be 1
        }
    }

}
