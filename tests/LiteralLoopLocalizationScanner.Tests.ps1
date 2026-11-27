# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Finite literal loop localization scanner' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $layout = Get-TestRepositoryLayout -RepositoryRoot (Split-Path -Parent $PSScriptRoot)
        $scriptRoot = $layout.ScriptRoot
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force

        function Read-TestLiteralLoop {
            param([string] $Source)
            Get-LuaLocalizationDocument -Bytes ([Text.Encoding]::UTF8.GetBytes($Source)) -SourceId 'literal-loops'
        }

        function Get-TestColorLoop {
            @'
local output = {}
local prefixes = { "fire", "blight" }
for _, prefix in ipairs(prefixes) do
    output[prefix .. "_red"] = { en = "Red", ["zh-cn"] = "红" }
    output[prefix .. "_alpha"] = { en = "Opacity", ["zh-cn"] = "透明度" }
end
'@
        }

        function Get-TestMoodLoop {
            @'
local MoodSettings = require("scripts/settings/camera/mood/mood_settings")
output.mood_vfx_group = { en = "Mood settings" }
output.mood_vfx_tt = { en = "Restart the game." }
for mood_type, _ in pairs(MoodSettings.mood_types) do
    local label = string.gsub(mood_type, "_", " ")
    output["hide_mood_vfx_" .. mood_type] = {
        en = "Disable " .. label,
    }
end
'@
        }
    }

    # Scenario: A finite loop defines English tables and a separate literal loop supplies their curated zh-tw values.
    # Purpose: Preserve the actual generated keys, literal bytes, and shared source table identity.
    It 'UnitT10_ProjectsLiteralLoopAndCuratedOverlayOnTheSameKeys' {
        $overlay = @'
for _, prefix in ipairs({ "fire", "blight" }) do
    output[prefix .. "_red"]["zh-tw"] = "紅"
    output[prefix .. "_alpha"]["zh-tw"] = "不透明度"
end
'@
        $source = @((Get-TestColorLoop), $overlay, 'return output') -join [char]10

        $document = Read-TestLiteralLoop $source

        @($document.units | Where-Object blockedReason).Count | Should -Be 0
        $document.units.key | Should -Be @('fire_red', 'blight_red', 'fire_alpha', 'blight_alpha')
        @($document.units | Where-Object zhTwExpression).Count | Should -Be 4
        $redRows = @($document.units | Where-Object key -CLike '*_red')
        $redRows[0].tableOpenByte | Should -Be $redRows[1].tableOpenByte
        $redRows[0].generatedBinding.kind | Should -BeExactly 'literal-list-loop'
        $redRows[0].generatedBinding.prefix | Should -BeExactly 'fire'
        $raw = [Text.Encoding]::UTF8.GetBytes($source)
        foreach ($row in $redRows) {
            [Text.Encoding]::UTF8.GetString($raw, $row.zhTwExpression.startByte, $row.zhTwExpression.lengthByte) | Should -BeExactly '"紅"'
        }
    }

    # Scenario: A later input adds a localized literal group and two named mood fields alongside engine-only mood entries.
    # Purpose: Keep reviewable keys addressable and publish a collision guard for the unenumerated runtime namespace.
    It 'UnitT20_EmitsNewColorKeysAndRecognizesExactEnglishOnlyMoodNamespace' {
        $color = (Get-TestColorLoop).Replace('    output[prefix .. "_alpha"]',
            '    output[prefix .. "_colors"] = { en = "Colors", ["zh-tw"] = "顏色" }' + [char]10 + '    output[prefix .. "_alpha"]')
        $source = @($color, (Get-TestMoodLoop), 'return output') -join [char]10

        $document = Read-TestLiteralLoop $source

        @($document.units | Where-Object blockedReason).Count | Should -Be 0
        @($document.units | Where-Object key -CLike '*_colors').key | Should -Be @('fire_colors', 'blight_colors')
        @($document.units | Where-Object key -CLike 'mood_vfx_*').key | Should -Be @('mood_vfx_group', 'mood_vfx_tt')
        $document.gameLocalizedPassthroughPrefixes | Should -Be @('hide_mood_vfx_')
    }

    # Scenario: A finite-looking loop calls a shadowed iterator, uses a replaced prefix list, or has nonliteral field values.
    # Purpose: Keep unsupported side effects and translations blocked.
    It 'UnitT30_BlocksUnprovenLiteralLoopShapes: <Case>' -ForEach @(
        @{ Case = 'shadowed iterator'; From = 'local prefixes'; To = "local ipairs = replacement; local prefixes" }
        @{ Case = 'replaced list'; From = 'for _, prefix'; To = "prefixes = another_list; for _, prefix" }
        @{ Case = 'computed field'; From = 'en = "Red"'; To = 'en = get_label(prefix)' }
        @{ Case = 'unrelated loop body'; From = '    output[prefix .. "_red"]'; To = '    do_other_work(); output[prefix .. "_red"]' }
    ) {
        $source = (Get-TestColorLoop).Replace($From, $To) + [char]10 + 'return output'

        $document = Read-TestLiteralLoop $source

        @($document.units | Where-Object blockedReason).Count | Should -BeGreaterThan 0
        @($document.units | Where-Object key -CEQ 'fire_red').Count | Should -Be 0
    }

    # Scenario: A literal zh-tw overlay targets a key absent from the returned accumulator.
    # Purpose: Require an earlier proven source table for every overlay write.
    It 'UnitT40_BlocksCuratedOverlayWithNoPriorTarget' {
        $source = @'
local output = {}
for _, prefix in ipairs({ "fire" }) do
    output[prefix .. "_red"] = { en = "Red" }
end
for _, prefix in ipairs({ "unknown" }) do
    output[prefix .. "_red"]["zh-tw"] = "新"
end
return output
'@

        $document = Read-TestLiteralLoop $source

        $blocked = @($document.units | Where-Object { $_.containerPath -ceq '$generated' -and $_.key -ceq 'unknown_red' })
        $blocked.Count | Should -Be 1
        $blocked[0].blockedReason | Should -BeExactly 'generated_literal_overlay_target_unproven'
    }

    # Scenario: A literal overlay would replace zh-tw supplied by an earlier source table.
    # Purpose: Verify the original root row and the conflict record independently.
    It 'UnitT41_KeepsTheLocalizedRowWhenAnOverlayConflicts' {
        $base = @'
local output = {}
local prefixes = { "fire", "blight" }
for _, prefix in ipairs(prefixes) do
    output[prefix .. "_red"] = { en = "Red", ["zh-cn"] = "红", ["zh-tw"] = "舊" }
    output[prefix .. "_alpha"] = { en = "Opacity", ["zh-cn"] = "透明度" }
end
'@
        $overlay = @'
for _, prefix in ipairs({ "fire" }) do
    output[prefix .. "_red"]["zh-tw"] = "新"
end
'@
        $baseline = Read-TestLiteralLoop (@($base, 'return output') -join [char]10)
        $before = @($baseline.units | Where-Object { $_.containerPath -ceq '$' -and $_.key -ceq 'fire_red' })
        $before.Count | Should -Be 1
        $before[0].zhTwExpression.raw | Should -BeExactly '"舊"'

        $document = Read-TestLiteralLoop (@($base, $overlay, 'return output') -join [char]10)

        $rows = @($document.units | Where-Object { $_.containerPath -ceq '$' -and $_.key -ceq 'fire_red' })
        $blocked = @($document.units | Where-Object { $_.containerPath -ceq '$generated' -and $_.key -ceq 'fire_red' })
        $rows.Count | Should -Be 1
        $rows[0].blockedReason | Should -BeNullOrEmpty
        $rows[0].zhTwExpression.raw | Should -BeExactly $before[0].zhTwExpression.raw
        $blocked.Count | Should -Be 1
        $blocked[0].blockedReason | Should -BeExactly 'generated_literal_overlay_target_unproven'
    }

    # Scenario: A single overlay expression targets keys established by distinct source table spans.
    # Purpose: Keep a review of one source table from changing another table's effective zh-tw.
    It 'UnitT45_BlocksAnOverlayThatSharesBytesAcrossSeparateSourceTables' {
        $source = @'
local output = {}
for _, prefix in ipairs({ "fire" }) do
    output[prefix .. "_red"] = { en = "Red" }
end
for _, prefix in ipairs({ "blight" }) do
    output[prefix .. "_red"] = { en = "Blight red" }
end
for _, prefix in ipairs({ "fire", "blight" }) do
    output[prefix .. "_red"]["zh-tw"] = "舊"
end
return output
'@

        $document = Read-TestLiteralLoop $source

        @($document.units | Where-Object blockedReason -CEQ 'generated_literal_overlay_target_unproven').Count | Should -Be 1
        @($document.units | Where-Object zhTwExpression).Count | Should -Be 0
    }

    # Scenario: A runtime mood loop writes zh-tw or collides with a known static key.
    # Purpose: Never treat a dynamic overlay as a disjoint engine-only namespace.
    It 'UnitT50_BlocksUnprovenMoodNamespace: <Case>' -ForEach @(
        @{ Case = 'generated zh-tw'; From = 'en = "Disable " .. label,'; To = 'en = "Disable " .. label, ["zh-tw"] = "不安全",'; Prefix = '' }
        @{ Case = 'known key collision'; From = ''; To = ''; Prefix = 'output.hide_mood_vfx_safe = { en = "Old", ["zh-tw"] = "既有" }' }
        @{ Case = 'shadowed required table'; From = ''; To = ''; Prefix = 'local require = alternate_loader' }
    ) {
        $mood = Get-TestMoodLoop
        if ($From) { $mood = $mood.Replace($From, $To) }
        $source = @('local output = {}', $Prefix, $mood, 'return output') -join [char]10

        $document = Read-TestLiteralLoop $source

        $document.Contains('gameLocalizedPassthroughPrefixes') | Should -BeFalse
        @($document.units | Where-Object blockedReason).Count | Should -BeGreaterThan 0
    }

    # Scenario: A game-owned mood key has a translated descendant in the current input or in OLD.
    # Purpose: Detect namespace collisions even when the localization unit is a nested child.
    It 'UnitT55_BlocksNestedSameVersionAndCrossVersionMoodCollisions' {
        $nested = 'local output = { hide_mood_vfx_knocked_down = { detail = { en = "Known", ["zh-tw"] = "舊譯" } } }'
        $old = Read-TestLiteralLoop (@($nested, 'return output') -join [char]10)
        $sameVersion = Read-TestLiteralLoop (@($nested, (Get-TestMoodLoop), 'return output') -join [char]10)
        $new = Read-TestLiteralLoop (@('local output = {}', (Get-TestMoodLoop), 'return output') -join [char]10)
        Import-Module (Join-Path $scriptRoot 'LocalizationWorksetContract.psm1') -Force

        $old.units[0].containerPath | Should -BeExactly '$.hide_mood_vfx_knocked_down'
        $sameVersion.Contains('gameLocalizedPassthroughPrefixes') | Should -BeFalse
        @($sameVersion.units | Where-Object blockedReason -CEQ 'game_localize_passthrough_prefix_collision').Count | Should -Be 1
        { Assert-LocalizationWorksetPassthroughCoverage -Prefixes $new.gameLocalizedPassthroughPrefixes -Units $old.units } |
            Should -Throw '*could overwrite*'
    }

    # Scenario: A computed root key or its descendant may occupy the engine-owned mood namespace.
    # Purpose: Treat unresolved bracket keys as potential collisions in either input.
    It 'UnitT56_BlocksUnresolvedRootKeysUnderMoodPassthrough: <Case>' -ForEach @(
        @{ Case = 'computed localized key'; Entry = '["hide_mood_vfx_" .. "knocked_down"] = { en = "Known", ["zh-tw"] = "舊譯" }' }
        @{ Case = 'descendant under a computed key'; Entry = '[get_mood_id()] = { detail = { en = "Known", ["zh-tw"] = "舊譯" } }' }
    ) {
        $root = 'local output = { ' + $Entry + ' }'
        $old = Read-TestLiteralLoop (@($root, 'return output') -join [char]10)
        $sameVersion = Read-TestLiteralLoop (@($root, (Get-TestMoodLoop), 'return output') -join [char]10)
        $new = Read-TestLiteralLoop (@('local output = {}', (Get-TestMoodLoop), 'return output') -join [char]10)
        Import-Module (Join-Path $scriptRoot 'LocalizationWorksetContract.psm1') -Force

        $sameVersion.Contains('gameLocalizedPassthroughPrefixes') | Should -BeFalse
        @($sameVersion.units | Where-Object blockedReason -CEQ 'game_localize_passthrough_prefix_collision').Count | Should -Be 1
        { Assert-LocalizationWorksetPassthroughCoverage -Prefixes $new.gameLocalizedPassthroughPrefixes -Units $old.units } |
            Should -Throw '*could overwrite*'
    }

    # Scenario: NEW adds a zh-tw overlay after establishing a single generated key.
    # Purpose: Keep a removal or replacement from corrupting the separate Lua assignment statement.
    It 'UnitT57_TreatsAnExternalOverlayLiteralAsPreserveOnly' {
        $base = @'
local output = {}
for _, prefix in ipairs({ "fire" }) do
    output[prefix .. "_red"] = { en = "Red" }
end
'@
        $overlay = @'
for _, prefix in ipairs({ "fire" }) do
    output[prefix .. "_red"]["zh-tw"] = "新增"
end
'@
        $old = (Read-TestLiteralLoop (@($base, 'return output') -join [char]10)).units[0]
        $new = (Read-TestLiteralLoop (@($base, $overlay, 'return output') -join [char]10)).units[0]
        Import-Module (Join-Path $scriptRoot 'LocalizationWorksetContract.psm1') -Force

        $new.zhTwExpression.startByte | Should -BeGreaterThan $new.tableCloseByte
        Get-LocalizationWorksetWriteBlockReason -Action 'RESTORE_OLD_ZH_TW' -OldUnit $old -NewUnit $new |
            Should -BeExactly 'generated_literal_overlay_write_unproven'
        $equalBytes = @{ reviewStatus = 'approved'; suggestedZhTwExpression = $new.zhTwExpression.raw }
        Get-LocalizationWorksetWriteBlockReason -Action 'AI_REQUIRED' -OldUnit $old -NewUnit $new -Review $equalBytes |
            Should -BeExactly 'generated_shared_literal_translation_requires_preservation_review'
        $preserved = @{ reviewStatus = 'preserved'; suggestedZhTwExpression = $null }
        Get-LocalizationWorksetWriteBlockReason -Action 'AI_REQUIRED' -OldUnit $old -NewUnit $new -Review $preserved |
            Should -BeNullOrEmpty
        Get-LocalizationWorksetWriteBlockReason -Action 'NONE' -OldUnit $new -NewUnit $new | Should -BeNullOrEmpty
    }

    # Scenario: Two new generated keys share a source field that already contains reviewed zh-tw.
    # Purpose: Permit explicit zero-write approval while rejecting approval that supplies replacement bytes.
    It 'InterT60_RequiresExplicitZeroWriteReviewForSharedLiteralFields' {
        $repository = Join-Path $TestDrive 'literal-preservation'
        $oldMod = Join-Path $repository 'mods/LiteralMod'
        $run = Join-Path $repository 'runs/literal'
        $staging = Join-Path $run 'staging/localization-workset-input/LiteralMod'
        $artifacts = Join-Path $run 'review-artifacts'
        New-Item -ItemType Directory -Path $oldMod, $staging, $artifacts -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Workset Fixture'
        & git -C $repository config user.email 'workset-fixture@example.invalid'
        & git -C $repository config core.autocrlf false
        $oldFile = Join-Path $oldMod 'LiteralMod_localization.lua'
        $newFile = Join-Path $staging 'LiteralMod_localization.lua'
        $rawArtifact = Join-Path $artifacts 'new.lua'
        $worksetPath = Join-Path $artifacts 'localization-workset.json'
        $old = 'return { base = { en = "Base", ["zh-tw"] = "基礎" } }'
        $new = @'
local output = { base = { en = "Base", ["zh-tw"] = "基礎" } }
local prefixes = { "fire", "blight" }
for _, prefix in ipairs(prefixes) do
    output[prefix .. "_colors"] = { en = "Colors", ["zh-cn"] = "颜色", ["zh-tw"] = "顏色" }
end
return output
'@
        [IO.File]::WriteAllText($oldFile, $old, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($newFile, $new, [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $newFile -Destination $rawArtifact
        Add-TestTranslationRules -RepositoryRoot $repository
        & git -C $repository add -- mods
        & git -C $repository commit -m fixture --quiet
        $LASTEXITCODE | Should -Be 0
        $base = (& git -C $repository rev-parse HEAD).Trim()
        $generator = Join-Path $scriptRoot 'New-LocalizationWorkset.ps1'
        $generationArgs = @{
            RepositoryRoot = $repository; BaseOid = $base; ModRelativePath = 'mods/LiteralMod'
            StagingModPath = $staging; OutputPath = $worksetPath; PassThru = $true
        }

        $result = & $generator @generationArgs

        $result.status | Should -BeExactly 'ready'
        $workset = Get-Content -LiteralPath $worksetPath -Raw | ConvertFrom-Json -AsHashtable
        $colored = @($workset.units | Where-Object key -CLike '*_colors')
        $colored.Count | Should -Be 2
        $colored.action | Should -Be @('AI_REQUIRED', 'AI_REQUIRED')
        $apply = Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1'
        { & $apply -WorksetPath $worksetPath -PassThru } | Should -Throw '*requires_preservation_review*'
        foreach ($unit in $colored) { $unit.reviewStatus = 'preserved' }
        $colored[0].reviewStatus = 'approved'
        $colored[0].suggestedZhTwExpression = '"顏色"'
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $worksetPath
        { & $apply -WorksetPath $worksetPath -PassThru } | Should -Throw '*requires_preservation_review*'
        (Get-FileHash -LiteralPath $newFile).Hash | Should -BeExactly (Get-FileHash -LiteralPath $rawArtifact).Hash

        $colored[0].reviewStatus = 'preserved'
        $colored[0].suggestedZhTwExpression = $null
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $worksetPath
        (& $apply -WorksetPath $worksetPath -PassThru).editCount | Should -Be 0
        (Get-FileHash -LiteralPath $newFile).Hash | Should -BeExactly (Get-FileHash -LiteralPath $rawArtifact).Hash
        $receipt = Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1'
        $receiptArgs = @{
            WorksetPath = $worksetPath; NewPath = $rawArtifact; MergedPath = $newFile; RepositoryRoot = $repository
            ExpectedBaseOid = $base; ExpectedModRelativePath = 'mods/LiteralMod'; PassThru = $true
        }
        (& $receipt @receiptArgs).result | Should -BeExactly 'passed'
    }

}
