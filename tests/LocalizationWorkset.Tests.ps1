Describe 'Schema 15 localization workset' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod/scripts'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:skillSourcePinPath = New-TestSkillSourcePin -SkillRoot (Split-Path -Parent $scriptRoot) -OutputPath (Join-Path $TestDrive 'skill-source-pin.json')
        function Get-TestImmutableWorksetContractSha256 {
            param($Workset)
            $unitContracts = @($Workset.units | ForEach-Object {
                [ordered]@{
                    unitId = $_.unitId; sourceId = $_.sourceId; containerPath = $_.containerPath
                    key = $_.key; occurrence = $_.occurrence; old = $_.old; new = $_.new
                    changeType = $_.changeType; action = $_.action; blockedReason = $_.blockedReason
                }
            })
            $contract = [ordered]@{
                schemaVersion = $Workset.schemaVersion; workflowSchemaVersion = $Workset.workflowSchemaVersion
                generatorVersion = $Workset.generatorVersion; baseOid = $Workset.baseOid; sourceId = $Workset.sourceId
                modRelativePath = $Workset.modRelativePath; old = $Workset.old; new = $Workset.new
                counts = $Workset.counts; units = $unitContracts
            }
            $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($contract | ConvertTo-Json -Depth 40 -Compress))
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
        function Get-TestReviewWorksetContractSha256 {
            param($Workset)
            $reviewContract = @($Workset.units | ForEach-Object {
                [ordered]@{
                    unitId = $_.unitId
                    reviewStatus = $_.reviewStatus
                    suggestedZhTwExpression = $_.suggestedZhTwExpression
                }
            })
            $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($reviewContract | ConvertTo-Json -Depth 10 -Compress))
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
    }

    # Scenario: Schema 15 replaces agent-authored byte spans with one deterministic localization workset.
    # Purpose: Require separate static scanning, workset generation, and workset application boundaries.
    It 'UnitT10_PublishesTheLocalizationWorksetEntrypoints' {
        Test-Path -LiteralPath (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') -PathType Leaf | Should -Be $true
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        Get-Command Test-LuaTableFieldAssignment -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    # Scenario: A localization file uses duplicate keys, bracketed language names, dynamic keys, comments, and multiline expressions.
    # Purpose: Produce stable unit identities and raw expression spans without executing Lua or losing BOM/newline information.
    It 'UnitT20_StaticallyScansComplexLuaLocalizationUnits' {
        $path = Join-Path $TestDrive 'complex_localization.lua'
        $lua = @'
return {
    duplicate = { en = "One", ["zh-tw"] = "壹" }, -- first occurrence
    duplicate = {
        ["en"] = string.format("Two %s", value),
        ['zh-tw'] = cf("貳")
    },
    [SettingNames.Enable] = {en=Localize("enabled"),["zh-tw"]="啟用"}
}
'@ -replace "`n", "`r`n"
        [IO.File]::WriteAllText($path, $lua, [Text.UTF8Encoding]::new($true))
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force

        $document = Get-LuaLocalizationDocument -Path $path -SourceId 'example'

        $document.bom | Should -Be $true
        $document.newline | Should -Be 'crlf'
        @($document.units).Count | Should -Be 3
        $document.units[0].unitId | Should -Be 'example :: $ :: duplicate :: 1'
        $document.units[1].unitId | Should -Be 'example :: $ :: duplicate :: 2'
        $document.units[2].key | Should -Be '[SettingNames.Enable]'
        $document.units[1].sourceExpression.raw | Should -Be 'string.format("Two %s", value)'
        $document.units[1].zhTwExpression.raw | Should -Be 'cf("貳")'
        $document.units[1].sourceExpression.isDirectLocalizeCall | Should -BeFalse
        $document.units[2].sourceExpression.isDirectLocalizeCall | Should -BeTrue
        $document.units[2].sourceExpression.startByte | Should -BeGreaterThan 0
        $document.units[2].zhTwExpression.lengthByte | Should -BeGreaterThan 0
    }

    # Scenario: Localization expressions use a game-global Localize call directly, combine only localized values and neutral separators, or shadow Localize.
    # Purpose: Reserve localized_source for expressions whose visible text is fully locale-resolved without hiding literal or shadowed text.
    It 'UnitT22_RejectsShadowedLocalizeCallsFromTheLocalizedSourceException' {
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        $globalLua = 'return { key = { en = Localize("loc_social_menu_leave_party") } }'
        $contentlessLua = 'return { key = { en = (Localize("loc_weapon_special_defensive_stance") .. " - " .. Localize("loc_weapon_family_ogryn_powermaul_slabshield_p1_m1")) } }'
        $contentfulLua = 'return { key = { en = Localize("loc_social_menu_leave_party") .. " now" } }'
        $shadowedLua = 'local Localize = function(value) return value end; return { key = { en = Localize("plain English") } }'

        $globalDocument = Get-LuaLocalizationDocument `
            -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($globalLua)) `
            -DisplayPath '<global-localize>' -SourceId 'global-localize'
        $shadowedDocument = Get-LuaLocalizationDocument `
            -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($shadowedLua)) `
            -DisplayPath '<shadowed-localize>' -SourceId 'shadowed-localize'
        $contentlessDocument = Get-LuaLocalizationDocument `
            -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($contentlessLua)) `
            -DisplayPath '<contentless-localize>' -SourceId 'contentless-localize'
        $contentfulDocument = Get-LuaLocalizationDocument `
            -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($contentfulLua)) `
            -DisplayPath '<contentful-localize>' -SourceId 'contentful-localize'

        $globalDocument.units[0].sourceExpression.isDirectLocalizeCall | Should -BeTrue
        $shadowedDocument.units[0].sourceExpression.isDirectLocalizeCall | Should -BeFalse
        $globalDocument.units[0].sourceExpression.isFullyLocaleResolvedExpression | Should -BeTrue
        $contentlessDocument.units[0].sourceExpression.isFullyLocaleResolvedExpression | Should -BeTrue
        $contentfulDocument.units[0].sourceExpression.isFullyLocaleResolvedExpression | Should -BeFalse
        $shadowedDocument.units[0].sourceExpression.isFullyLocaleResolvedExpression | Should -BeFalse
    }

    # Scenario: A bracketed zh-tw language key uses a valid Lua hexadecimal escape for the hyphen.
    # Purpose: Decode the key to its Lua value so automation cannot insert a duplicate semantic zh-tw field.
    It 'UnitT23_DecodesEscapesInBracketedLanguageKeys' {
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        foreach ($escapedKey in @('zh\x2dtw', 'zh\45tw', 'zh\u{2D}tw', 'zh\z  -tw')) {
            $lua = 'return {{ escaped = {{ ["en"] = "Hello", ["{0}"] = "哈囉" }} }}' -f $escapedKey
            $document = Get-LuaLocalizationDocument `
                -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($lua)) `
                -DisplayPath '<escaped-language-key>' `
                -SourceId 'escaped-language-key'

            @($document.units).Count | Should -Be 1
            $document.units[0].key | Should -Be 'escaped'
            $document.units[0].zhTwExpression.raw | Should -Be '"哈囉"'
        }
    }

    # Scenario: A bracketed zh-tw language key uses a Lua long-string literal with either the basic or equals-delimited form.
    # Purpose: Decode the key to its Lua value so long-string syntax cannot hide an existing semantic zh-tw field.
    It 'UnitT24_DecodesLongStringsInBracketedLanguageKeys' {
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        foreach ($longKey in @('[[zh-tw]]', '[=[zh-tw]=]')) {
            $lua = 'return {{ escaped = {{ ["en"] = "Hello", [ {0} ] = "哈囉" }} }}' -f $longKey
            $document = Get-LuaLocalizationDocument `
                -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($lua)) `
                -DisplayPath '<long-string-language-key>' `
                -SourceId 'long-string-language-key'

            @($document.units).Count | Should -Be 1
            $document.units[0].key | Should -Be 'escaped'
            $document.units[0].zhTwExpression.raw | Should -Be '"哈囉"'
        }
    }

    # Scenario: Comments and quoted strings mention the loader call syntax while executable code may contain the real call.
    # Purpose: Detect only lexical mod:io_dofile calls so untrusted text cannot falsely exclude a MOD from automation.
    It 'UnitT25_IgnoresLoaderSyntaxInsideCommentsAndStrings' {
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        $textOnly = @'
-- mod:io_dofile("comment-only")
local note = "mod:io_dofile('string-only')"
'@
        $actualCall = 'mod:io_dofile("actual-loader")'
        $loaderWithSideEffect = @'
mod:io_dofile("actual-loader")
local side_effect = os.time()
'@

        $textDocument = Get-LuaLocalizationDocument -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($textOnly)) -DisplayPath '<text-only>' -SourceId 'text-only'
        $callDocument = Get-LuaLocalizationDocument -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($actualCall)) -DisplayPath '<actual-call>' -SourceId 'actual-call'
        $sideEffectDocument = Get-LuaLocalizationDocument -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($loaderWithSideEffect)) -DisplayPath '<side-effect>' -SourceId 'side-effect'

        $textDocument.ioDofileLoaderCallCount | Should -Be 0
        $callDocument.ioDofileLoaderCallCount | Should -Be 1
        $callDocument.isIoDofileOnlyLoader | Should -Be $true
        $sideEffectDocument.ioDofileLoaderCallCount | Should -Be 1
        $sideEffectDocument.isIoDofileOnlyLoader | Should -Be $false
    }

    # Scenario: One localization expression is large enough for tokenization and hashing to cross multiple heartbeat chunks.
    # Purpose: Keep the immutable MOD reservation fresh during CPU-bound Lua scanning, not only file and child-process waits.
    It 'UnitT26_HeartbeatsDuringLargeCpuBoundLuaScans' {
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        $counter = [Runtime.CompilerServices.StrongBox[int]]::new(0)
        $heartbeat = { $counter.Value++; 'heartbeat-noise-must-not-escape' }.GetNewClosure()
        $largeExpression = 'return { key = { en = "' + [string]::new('a', (2MB + 17)) + '", ["zh-tw"] = "保留" } }'
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($largeExpression)

        $document = Get-LuaLocalizationDocument -Bytes $bytes -DisplayPath '<large-heartbeat>' `
            -SourceId 'large-heartbeat' -HeartbeatAction $heartbeat

        ($document -is [Collections.IDictionary]) | Should -BeTrue
        @($document.units).Count | Should -Be 1
        $counter.Value | Should -BeGreaterThan 4
    }

    # Scenario: The staging file changes after its physical-path check and first byte read.
    # Purpose: Parse only the verified byte snapshot so generation has no second path-based TOCTOU read.
    It 'UnitT27_ParsesTheVerifiedNewByteSnapshot' {
        $generator = Get-Content -LiteralPath (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') -Raw
        $applier = Get-Content -LiteralPath (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -Raw

        $generator | Should -Match 'Get-LuaLocalizationDocument\s+-Bytes\s+\$newBytes\s+-DisplayPath\s+\$newPath'
        $generator | Should -Not -Match 'Get-LuaLocalizationDocument\s+-Path\s+\$newPath'
        $applier | Should -Match '(?s)\$currentBytes = Read-FileBytesWithHeartbeat -Path \$newPath.*\$currentSha = Get-Sha256Bytes -Bytes \$currentBytes.*\$originalBytes = \$currentBytes'
        $applier | Should -Not -Match '\$currentSha = Get-FileSha256 -Path \$newPath'
    }

    # Scenario: A canonical MOD directory contains an internal double dot that is part of its legal single-directory name.
    # Purpose: Reject traversal path components without excluding safe identities already accepted by acquisition and claim.
    It 'InterT29_AcceptsInternalDoubleDotsInASafeModDirectoryName' {
        $repository = Join-Path $TestDrive 'double-dot-workset-repository'
        $oldModRoot = Join-Path $repository 'mods/Foo..Bar'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Double Dot Workset Test'
        & git -C $repository config user.email 'double-dot-workset@example.invalid'
        $localization = 'return { key = { en = "Stable", ["zh-tw"] = "穩定" } }'
        $oldPath = Join-Path $oldModRoot 'Foo..Bar_localization.lua'
        [IO.File]::WriteAllText($oldPath, $localization, [Text.UTF8Encoding]::new($false))
        & git -C $repository add mods/Foo..Bar/Foo..Bar_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $staging = Join-Path $TestDrive 'double-dot-staging/Foo..Bar'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $staging 'Foo..Bar_localization.lua'), $localization, [Text.UTF8Encoding]::new($false))
        $outputPath = Join-Path $repository 'AI Auto Update/In Progress/double-dot/review-artifacts/localization-workset.json'

        $result = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/Foo..Bar' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'foo-double-dot-bar' -PassThru

        $result.result | Should -Be 'passed'
        $result.status | Should -Be 'ready'
        Test-Path -LiteralPath $outputPath -PathType Leaf | Should -Be $true
        { & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
                -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/../Escape' `
                -StagingModPath $staging -OutputPath (Join-Path $repository 'AI Auto Update/In Progress/traversal/review-artifacts/localization-workset.json') `
                -SourceId 'escape' -PassThru } | Should -Throw '*ModRelativePath is invalid*'
    }

    # Scenario: One localization table contains two distinct Lua string keys whose only difference is letter casing.
    # Purpose: Preserve Lua's case-sensitive identity semantics through generation, apply, and independent receipt verification.
    It 'InterT29A_PreservesCaseDistinctLuaLocalizationUnitIdentities' {
        $repository = Join-Path $TestDrive 'case-distinct-workset-repository'
        $oldModRoot = Join-Path $repository 'mods/CaseMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Case Distinct Workset Test'
        & git -C $repository config user.email 'case-distinct-workset@example.invalid'
        $oldPath = Join-Path $oldModRoot 'CaseMod_localization.lua'
        @'
return {
    Label = { en = "Upper old", ["zh-tw"] = "大寫" },
    label = { en = "Lower stable", ["zh-tw"] = "小寫" }
}
'@ | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/CaseMod/CaseMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/case-distinct'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/CaseMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'CaseMod_localization.lua'
        @'
return {
    Label = { en = "Upper new", ["zh-tw"] = "大寫" },
    label = { en = "Lower stable", ["zh-tw"] = "小寫" }
}
'@ | Set-Content -LiteralPath $newPath -NoNewline
        $rawNewPath = Join-Path $TestDrive 'case-distinct-raw-new.lua'
        [IO.File]::WriteAllBytes($rawNewPath, [IO.File]::ReadAllBytes($newPath))
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'

        $generation = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/CaseMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'case-mod' -PassThru
        $generation.result | Should -Be 'passed'
        $workset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        @($workset.units).Count | Should -Be 2
        $upper = @($workset.units | Where-Object { $_.key -ceq 'Label' })[0]
        $lower = @($workset.units | Where-Object { $_.key -ceq 'label' })[0]
        $upper.occurrence | Should -Be 1
        $lower.occurrence | Should -Be 1
        $upper.unitId | Should -BeExactly 'case-mod :: $ :: Label :: 1'
        $lower.unitId | Should -BeExactly 'case-mod :: $ :: label :: 1'
        $upper.old.key | Should -BeExactly 'Label'
        $upper.changeType | Should -Be 'source_changed_translation_unchanged'
        $upper.action | Should -Be 'AI_REQUIRED'
        $lower.old.key | Should -BeExactly 'label'
        $lower.changeType | Should -Be 'unchanged'
        $upper.reviewStatus = 'approved'
        $upper.suggestedZhTwExpression = '"大寫新譯"'
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline

        (& (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru).result | Should -Be 'passed'
        (& (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') `
                -WorksetPath $outputPath -NewPath $rawNewPath -MergedPath $newPath `
                -RepositoryRoot $repository -ExpectedBaseOid $baseOid -ExpectedModRelativePath 'mods/CaseMod' -PassThru).result |
            Should -Be 'passed'
    }

    # Scenario: Upstream changes include unchanged entries, zh-tw-only drift, changed English, a new key, and a deleted key.
    # Purpose: Build one deterministic workset from an immutable base OID and staging bytes with no AI classification step.
    It 'InterT30_ClassifiesACompleteLocalizationWorksetDeterministically' {
        $repository = Join-Path $TestDrive 'workset-repository'
        $oldModRoot = Join-Path $repository 'mods/ExampleMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Workset Test'
        & git -C $repository config user.email 'workset@example.invalid'
        $oldPath = Join-Path $oldModRoot 'ExampleMod_localization.lua'
        @'
return {
    unchanged = { en = "Same", ["zh-tw"] = "相同" },
    missing_both = { en = "Needs translation" },
    zh_only = { en = "Stable", ["zh-tw"] = "舊翻譯" },
    remove_upstream_zh = { en = "No old translation" },
    source_change = { en = "Old source", ["zh-tw"] = "原翻譯" },
    deleted = { en = "Deleted", ["zh-tw"] = "刪除" }
}
'@ | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/ExampleMod/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/example-test'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/ExampleMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'ExampleMod_localization.lua'
        @'
return {
    unchanged = { en = "Same", ["zh-tw"] = "相同" },
    missing_both = { en = "Needs translation" },
    zh_only = { en = "Stable", ["zh-tw"] = "上游改動" },
    remove_upstream_zh = { en = "No old translation", ["zh-tw"] = "不應新增" },
    source_change = { en = "New source", ["zh-tw"] = "原翻譯" },
    new_key = { en = "New source" }
}
'@ | Set-Content -LiteralPath $newPath -NoNewline
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'

        $first = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository `
            -BaseOid $baseOid `
            -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging `
            -OutputPath $outputPath `
            -SourceId 'example' `
            -PassThru
        $second = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository `
            -BaseOid $baseOid `
            -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging `
            -OutputPath $outputPath `
            -SourceId 'example' `
            -PassThru

        $first.result | Should -Be 'passed'
        $first.sha256 | Should -Be $second.sha256
        $workset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $workset.workflowSchemaVersion | Should -Be 15
        $workset.baseOid | Should -Be $baseOid
        @($workset.units).Count | Should -Be 7
        (@($workset.units | Where-Object key -eq 'unchanged')).changeType | Should -Be 'unchanged'
        (@($workset.units | Where-Object key -eq 'missing_both')).changeType | Should -Be 'missing_zh_tw'
        (@($workset.units | Where-Object key -eq 'missing_both')).action | Should -Be 'AI_REQUIRED'
        (@($workset.units | Where-Object key -eq 'zh_only')).changeType | Should -Be 'zh_tw_only_changed'
        (@($workset.units | Where-Object key -eq 'zh_only')).action | Should -Be 'RESTORE_OLD_ZH_TW'
        (@($workset.units | Where-Object key -eq 'remove_upstream_zh')).action | Should -Be 'RESTORE_OLD_ZH_TW'
        (@($workset.units | Where-Object key -eq 'source_change')).changeType | Should -Be 'source_changed_translation_unchanged'
        (@($workset.units | Where-Object key -eq 'source_change')).action | Should -Be 'AI_REQUIRED'
        (@($workset.units | Where-Object key -eq 'new_key')).changeType | Should -Be 'new_key'
        (@($workset.units | Where-Object key -eq 'deleted')).action | Should -Be 'ACCEPT_REMOVAL'

        $tamperedPath = Join-Path $repository 'AI Auto Update/In Progress/tampered-test/review-artifacts/localization-workset.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $tamperedPath) -Force | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $tamperedPath
        $tampered = Get-Content -LiteralPath $tamperedPath -Raw | ConvertFrom-Json
        (@($tampered.units | Where-Object key -eq 'source_change'))[0].action = 'NONE'
        $tampered | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tamperedPath -NoNewline
        { & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $tamperedPath -PassThru } |
            Should -Throw '*immutable contract*'

        $nonAiTamperedPath = Join-Path $repository 'AI Auto Update/In Progress/non-ai-tampered/review-artifacts/localization-workset.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $nonAiTamperedPath) -Force | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $nonAiTamperedPath
        $nonAiTampered = Get-Content -LiteralPath $nonAiTamperedPath -Raw | ConvertFrom-Json
        (@($nonAiTampered.units | Where-Object key -eq 'unchanged'))[0].reviewStatus = 'approved'
        $nonAiTampered | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $nonAiTamperedPath -NoNewline
        { & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $nonAiTamperedPath -PassThru } |
            Should -Throw '*outside AI_REQUIRED*'

        $missingTarget = @($workset.units | Where-Object key -eq 'missing_both')[0]
        $missingTarget.reviewStatus = 'approved'
        $missingTarget.suggestedZhTwExpression = '"補譯"'
        $sourceChange = @($workset.units | Where-Object key -eq 'source_change')[0]
        $sourceChange.reviewStatus = 'approved'
        $sourceChange.suggestedZhTwExpression = '"新翻譯"'
        $newKey = @($workset.units | Where-Object key -eq 'new_key')[0]
        $newKey.reviewStatus = 'approved'
        $newKey.suggestedZhTwExpression = '"新增翻譯"'
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline

        $rawNewPath = Join-Path $repository 'AI Auto Update/In Progress/example-test/review-artifacts/new.lua'
        [IO.File]::WriteAllBytes($rawNewPath, [IO.File]::ReadAllBytes($newPath))
        $apply = & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru
        $applyAgain = & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru
        $generationAfterApply = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru
        $apply.result | Should -Be 'passed'
        $applyAgain.idempotent | Should -Be $true
        $generationAfterApply.status | Should -Be 'applied'
        $generationAfterApply.idempotent | Should -Be $true
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        $applied = Get-LuaLocalizationDocument -Path $newPath -SourceId 'example'
        (@($applied.units | Where-Object key -eq 'unchanged')).zhTwExpression.raw | Should -Be '"相同"'
        (@($applied.units | Where-Object key -eq 'missing_both')).zhTwExpression.raw | Should -Be '"補譯"'
        (@($applied.units | Where-Object key -eq 'zh_only')).zhTwExpression.raw | Should -Be '"舊翻譯"'
        (@($applied.units | Where-Object key -eq 'remove_upstream_zh')).zhTwExpression | Should -BeNullOrEmpty
        (@($applied.units | Where-Object key -eq 'source_change')).sourceExpression.raw | Should -Be '"New source"'
        (@($applied.units | Where-Object key -eq 'source_change')).zhTwExpression.raw | Should -Be '"新翻譯"'
        (@($applied.units | Where-Object key -eq 'new_key')).zhTwExpression.raw | Should -Be '"新增翻譯"'
        @($applied.units | Where-Object key -eq 'deleted').Count | Should -Be 0

        $receiptVerification = & (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') `
            -WorksetPath $outputPath -NewPath $rawNewPath -MergedPath $newPath `
            -RepositoryRoot $repository -ExpectedBaseOid $baseOid -ExpectedModRelativePath 'mods/ExampleMod' -PassThru
        $receiptVerification.result | Should -Be 'passed'
        $inventoryTamperedPath = Join-Path $repository 'AI Auto Update/In Progress/inventory-tampered/review-artifacts/localization-workset.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $inventoryTamperedPath) -Force | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $inventoryTamperedPath
        $inventoryTampered = Get-Content -LiteralPath $inventoryTamperedPath -Raw | ConvertFrom-Json -AsHashtable
        $unchangedUnit = @($inventoryTampered.units | Where-Object { $_.key -ceq 'unchanged' })[0]
        for ($index = 0; $index -lt @($inventoryTampered.units).Count; $index++) {
            if ([string]$inventoryTampered.units[$index].key -ceq 'deleted') {
                $inventoryTampered.units[$index] = ($unchangedUnit | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
                break
            }
        }
        $inventoryTampered.counts.unchanged = [int]$inventoryTampered.counts.unchanged + 1
        $inventoryTampered.counts.deleted_key = [int]$inventoryTampered.counts.deleted_key - 1
        $inventoryTampered.immutableContractSha256 = Get-TestImmutableWorksetContractSha256 -Workset $inventoryTampered
        $inventoryTampered.apply.reviewContractSha256 = Get-TestReviewWorksetContractSha256 -Workset $inventoryTampered
        [IO.File]::WriteAllText($inventoryTamperedPath, ($inventoryTampered | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        { & (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') `
                -WorksetPath $inventoryTamperedPath -NewPath $rawNewPath -MergedPath $newPath `
                -RepositoryRoot $repository -ExpectedBaseOid $baseOid -ExpectedModRelativePath 'mods/ExampleMod' -PassThru } |
            Should -Throw '*unit inventory*'
        $classificationTamperedPath = Join-Path $repository 'AI Auto Update/In Progress/classification-tampered/review-artifacts/localization-workset.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $classificationTamperedPath) -Force | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $classificationTamperedPath
        $classificationTampered = Get-Content -LiteralPath $classificationTamperedPath -Raw | ConvertFrom-Json -AsHashtable
        $classificationTamperedUnit = @($classificationTampered.units | Where-Object { $_.key -ceq 'unchanged' })[0]
        $classificationTamperedUnit.action = 'ACCEPT_REMOVAL'
        $classificationTampered.immutableContractSha256 = Get-TestImmutableWorksetContractSha256 -Workset $classificationTampered
        [IO.File]::WriteAllText($classificationTamperedPath, ($classificationTampered | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        { & (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') `
                -WorksetPath $classificationTamperedPath -NewPath $rawNewPath -MergedPath $newPath `
                -RepositoryRoot $repository -ExpectedBaseOid $baseOid -ExpectedModRelativePath 'mods/ExampleMod' -PassThru } |
            Should -Throw '*classification*'
        $appliedReviewTamperedPath = Join-Path $repository 'AI Auto Update/In Progress/applied-review-tampered/review-artifacts/localization-workset.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $appliedReviewTamperedPath) -Force | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $appliedReviewTamperedPath
        $appliedReviewTampered = Get-Content -LiteralPath $appliedReviewTamperedPath -Raw | ConvertFrom-Json
        (@($appliedReviewTampered.units | Where-Object key -eq 'unchanged'))[0].reviewStatus = 'approved'
        $appliedReviewTampered | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $appliedReviewTamperedPath -NoNewline
        { & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $appliedReviewTamperedPath -PassThru } |
            Should -Throw '*outside AI_REQUIRED*'
        $appliedAiTamperedPath = Join-Path $repository 'AI Auto Update/In Progress/applied-ai-tampered/review-artifacts/localization-workset.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $appliedAiTamperedPath) -Force | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $appliedAiTamperedPath
        $appliedWorksetBytes = [IO.File]::ReadAllBytes($outputPath)
        $appliedAiTampered = Get-Content -LiteralPath $appliedAiTamperedPath -Raw | ConvertFrom-Json
        (@($appliedAiTampered.units | Where-Object key -eq 'missing_both'))[0].suggestedZhTwExpression = '"收據後竄改"'
        $appliedAiTampered | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $appliedAiTamperedPath -NoNewline
        $appliedAiTampered | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline
        { & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru } |
            Should -Throw '*receipt is malformed*'
        [IO.File]::WriteAllBytes($outputPath, $appliedWorksetBytes)
        { & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
                -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
                -StagingModPath $staging -OutputPath $appliedAiTamperedPath -SourceId 'example' -PassThru } |
            Should -Throw '*review contract*'
        $receiptTamperedPath = Join-Path $repository 'AI Auto Update/In Progress/receipt-tampered/review-artifacts/localization-workset.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $receiptTamperedPath) -Force | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $receiptTamperedPath
        $receiptTampered = Get-Content -LiteralPath $receiptTamperedPath -Raw | ConvertFrom-Json
        $receiptTampered.apply.edits[0].operation = 'UNAUTHORIZED'
        $receiptTampered | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $receiptTamperedPath -NoNewline
        { & (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') `
                -WorksetPath $receiptTamperedPath -NewPath $rawNewPath -MergedPath $newPath -PassThru } |
            Should -Throw '*deterministic edit plan*'
    }

    # Scenario: A missing zh-tw field follows a final source field with no separator and a trailing Lua comment.
    # Purpose: Insert the approved translation without placing a required separator inside comment trivia.
    It 'InterT31_InsertsBeforeTrailingCommentsAndASeparatorlessFinalField' {
        $repository = Join-Path $TestDrive 'comment-insertion-repository'
        $oldModRoot = Join-Path $repository 'mods/ExampleMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Workset Comment Test'
        & git -C $repository config user.email 'workset-comment@example.invalid'
        $oldPath = Join-Path $oldModRoot 'ExampleMod_localization.lua'
        $lua = @'
return {
    key = {
        en = "Hello" -- retained final-field comment
    }
}
'@
        [IO.File]::WriteAllText($oldPath, $lua, [Text.UTF8Encoding]::new($false))
        & git -C $repository add mods/ExampleMod/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/comment-insertion'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/ExampleMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'ExampleMod_localization.lua'
        [IO.File]::WriteAllText($newPath, $lua, [Text.UTF8Encoding]::new($false))
        $rawNewPath = Join-Path $runRoot 'review-artifacts/raw-new.lua'
        New-Item -ItemType Directory -Path (Split-Path -Parent $rawNewPath) -Force | Out-Null
        [IO.File]::WriteAllBytes($rawNewPath, [IO.File]::ReadAllBytes($newPath))
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'

        $null = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'comment-insertion' -PassThru
        $workset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $unit = @($workset.units | Where-Object key -eq 'key')[0]
        $unit.action | Should -Be 'AI_REQUIRED'
        $unit.reviewStatus = 'approved'
        $unit.suggestedZhTwExpression = '"註解安全"'
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline

        (& (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru).result | Should -Be 'passed'
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        $document = Get-LuaLocalizationDocument -Path $newPath -SourceId 'comment-insertion'
        (@($document.units | Where-Object key -eq 'key'))[0].zhTwExpression.raw | Should -Be '"註解安全"'
        (Get-Content -LiteralPath $newPath -Raw) | Should -Match 'retained final-field comment'
        (& (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') `
                -WorksetPath $outputPath -NewPath $rawNewPath -MergedPath $newPath `
                -RepositoryRoot $repository -ExpectedBaseOid $baseOid -ExpectedModRelativePath 'mods/ExampleMod' -PassThru).result |
            Should -Be 'passed'
    }

    # Scenario: OLD uses CRLF and an AI expression also contains CRLF, while immutable NEW uses LF without a BOM.
    # Purpose: Keep the NEW file's BOM/newline contract when restoring or inserting approved multi-line zh-tw expressions.
    It 'InterT32_PreservesTheNewLocalizationBomAndNewlineStyle' {
        $repository = Join-Path $TestDrive 'newline-workset-repository'
        $oldModRoot = Join-Path $repository 'mods/ExampleMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Workset Newline Test'
        & git -C $repository config user.email 'workset-newline@example.invalid'
        & git -C $repository config core.autocrlf false
        $oldPath = Join-Path $oldModRoot 'ExampleMod_localization.lua'
        $oldText = (@'
return {
    restore = { en = "Stable", ["zh-tw"] = "舊" ..
        "翻譯" },
    ai = { en = "Old", ["zh-tw"] = "原文" }
}
'@) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText($oldPath, $oldText, [Text.UTF8Encoding]::new($false))
        & git -C $repository -c core.autocrlf=false add mods/ExampleMod/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/newline-test'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/ExampleMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'ExampleMod_localization.lua'
        $newText = (@'
return {
    restore = { en = "Stable", ["zh-tw"] = "upstream drift" },
    ai = { en = "New", ["zh-tw"] = "原文" }
}
'@) -replace "`r?`n", "`n"
        [IO.File]::WriteAllText($newPath, $newText, [Text.UTF8Encoding]::new($false))
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'

        $null = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru
        $workset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $aiUnit = @($workset.units | Where-Object key -eq 'ai')[0]
        $aiUnit.reviewStatus = 'approved'
        $aiUnit.suggestedZhTwExpression = '"新" ..' + "`r`n" + '        "翻譯"'
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline

        $null = & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru
        $appliedBytes = [IO.File]::ReadAllBytes($newPath)
        $appliedText = [Text.UTF8Encoding]::new($false, $true).GetString($appliedBytes)
        $document = Get-LuaLocalizationDocument -Path $newPath -SourceId 'example'

        $document.bom | Should -Be $false
        $document.newline | Should -Be 'lf'
        $appliedText.Contains("`r", [StringComparison]::Ordinal) | Should -Be $false
    }

    # Scenario: A reviewed workset is rewritten to name a regular localization file outside its fixed run-local staging tree.
    # Purpose: Prevent mutable workset metadata from authorizing an out-of-run write before the independent Candidate Gate.
    It 'InterT33_RejectsAWorksetNewPathOutsideTheFixedRunRoot' {
        $repository = Join-Path $TestDrive 'workset-path-escape-repository'
        $oldModRoot = Join-Path $repository 'mods/ExampleMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Workset Path Escape Test'
        & git -C $repository config user.email 'workset-path-escape@example.invalid'
        $oldPath = Join-Path $oldModRoot 'ExampleMod_localization.lua'
        'return { key = { en = "Stable", ["zh-tw"] = "舊翻譯" } }' | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/ExampleMod/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/path-escape'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/ExampleMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'ExampleMod_localization.lua'
        'return { key = { en = "Stable", ["zh-tw"] = "upstream drift" } }' | Set-Content -LiteralPath $newPath -NoNewline
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'
        $null = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru

        $outsideRoot = Join-Path $TestDrive 'workset-path-escape-outside'
        New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
        $outsidePath = Join-Path $outsideRoot 'ExampleMod_localization.lua'
        [IO.File]::WriteAllBytes($outsidePath, [IO.File]::ReadAllBytes($newPath))
        $outsideShaBefore = (Get-FileHash -LiteralPath $outsidePath -Algorithm SHA256).Hash
        $workset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -AsHashtable
        $workset.new.root = [IO.Path]::GetFullPath($outsideRoot)
        $workset.new.path = [IO.Path]::GetFullPath($outsidePath)
        $workset.immutableContractSha256 = Get-TestImmutableWorksetContractSha256 -Workset $workset
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline

        { & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru } |
            Should -Throw '*fixed run-local staging*'
        (Get-FileHash -LiteralPath $outsidePath -Algorithm SHA256).Hash | Should -Be $outsideShaBefore
    }

    # Scenario: A nested staging directory is swapped for a junction after workset generation but before apply.
    # Purpose: Re-check every NEW path component at the write boundary so a resume cannot write outside physical staging.
    It 'InterT34_RejectsAReparseParentIntroducedBeforeWorksetApply' {
        $repository = Join-Path $TestDrive 'reparse-workset-repository'
        $oldModRoot = Join-Path $repository 'mods/ExampleMod/nested'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Workset Reparse Test'
        & git -C $repository config user.email 'workset-reparse@example.invalid'
        $oldPath = Join-Path $oldModRoot 'ExampleMod_localization.lua'
        'return { key = { en = "Stable", ["zh-tw"] = "舊翻譯" } }' | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/ExampleMod/nested/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/reparse-test'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/ExampleMod'
        $nested = Join-Path $staging 'nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        $newPath = Join-Path $nested 'ExampleMod_localization.lua'
        'return { key = { en = "Stable", ["zh-tw"] = "upstream drift" } }' | Set-Content -LiteralPath $newPath -NoNewline
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'
        $null = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru

        $outsideWorkset = Join-Path $TestDrive 'workset-output-reparse-target'
        $linkedReviewArtifacts = Join-Path $repository 'AI Auto Update/In Progress/output-reparse/review-artifacts'
        New-Item -ItemType Directory -Path (Split-Path -Parent $linkedReviewArtifacts), $outsideWorkset -Force | Out-Null
        New-Item -ItemType Junction -Path $linkedReviewArtifacts -Target $outsideWorkset | Out-Null
        { & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
                -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
                -StagingModPath $staging -OutputPath (Join-Path $linkedReviewArtifacts 'localization-workset.json') `
                -SourceId 'example' -PassThru } | Should -Throw '*reparse*'

        $outside = Join-Path $TestDrive 'reparse-outside'
        Move-Item -LiteralPath $nested -Destination $outside
        New-Item -ItemType Junction -Path $nested -Target $outside | Out-Null

        { & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru } |
            Should -Throw '*reparse*'
    }

    # Scenario: Entries use direct or composed game Localize calls, with either neutral separators or literal content.
    # Purpose: Skip redundant zh-tw authoring when all visible text is locale-resolved, while translating compositions that add actual text.
    It 'InterT35_SkipsContentlessLocalizeSourcesButStillTranslatesContentfulExpressions' {
        $repository = Join-Path $TestDrive 'direct-localize-workset-repository'
        $oldModRoot = Join-Path $repository 'mods/ExampleMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Direct Localize Workset Test'
        & git -C $repository config user.email 'direct-localize-workset@example.invalid'
        $oldPath = Join-Path $oldModRoot 'ExampleMod_localization.lua'
        @'
return {
    existing_localized = { en = Localize("loc_social_menu_leave_party") },
    existing_translated = { en = Localize("loc_social_menu_leave_party"), ["zh-tw"] = "保留既有翻譯" },
    contentful_composed = { en = Localize("loc_social_menu_leave_party") .. " now" }
}
'@ | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/ExampleMod/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/direct-localize'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/ExampleMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'ExampleMod_localization.lua'
        @'
return {
    existing_localized = { en = Localize("loc_social_menu_leave_party") },
    existing_translated = { en = Localize("loc_social_menu_leave_party") },
    new_localized = { en = Localize("loc_item_type_end_of_round") },
    contentless_composed = { en = Localize("loc_weapon_special_defensive_stance") .. " - " .. Localize("loc_weapon_family_ogryn_powermaul_slabshield_p1_m1") },
    parenthesized_contentless = { en = (Localize("loc_weapon_special_defensive_stance") .. " / " .. Localize("loc_weapon_family_ogryn_powermaul_slabshield_p1_m1")) },
    contentful_composed = { en = Localize("loc_social_menu_leave_party") .. " now" }
}
'@ | Set-Content -LiteralPath $newPath -NoNewline
        $rawNewPath = Join-Path $runRoot 'review-artifacts/new.lua'
        New-Item -ItemType Directory -Path (Split-Path -Parent $rawNewPath) -Force | Out-Null
        [IO.File]::WriteAllBytes($rawNewPath, [IO.File]::ReadAllBytes($newPath))
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'

        (& (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
                -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
                -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru).result |
            Should -Be 'passed'
        $workset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        foreach ($key in @('existing_localized', 'new_localized', 'contentless_composed', 'parenthesized_contentless')) {
            $unit = @($workset.units | Where-Object key -eq $key)[0]
            $unit.changeType | Should -Be 'localized_source'
            $unit.action | Should -Be 'NONE'
            $unit.reviewStatus | Should -Be 'not-required'
        }
        $existingTranslated = @($workset.units | Where-Object key -eq 'existing_translated')[0]
        $existingTranslated.changeType | Should -Be 'zh_tw_only_changed'
        $existingTranslated.action | Should -Be 'RESTORE_OLD_ZH_TW'
        $existingTranslated.reviewStatus | Should -Be 'not-required'
        $composed = @($workset.units | Where-Object key -eq 'contentful_composed')[0]
        $composed.changeType | Should -Be 'missing_zh_tw'
        $composed.action | Should -Be 'AI_REQUIRED'
        $composed.reviewStatus = 'approved'
        $composed.suggestedZhTwExpression = 'Localize("loc_social_menu_leave_party") .. " 現在"'
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline

        (& (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru).result | Should -Be 'passed'
        Import-Module (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -Force
        $applied = Get-LuaLocalizationDocument -Path $newPath -SourceId 'example'
        foreach ($key in @('existing_localized', 'new_localized', 'contentless_composed', 'parenthesized_contentless')) {
            (@($applied.units | Where-Object key -eq $key)[0]).zhTwExpression | Should -BeNullOrEmpty
        }
        (@($applied.units | Where-Object key -eq 'existing_translated')[0]).zhTwExpression.raw |
            Should -Be '"保留既有翻譯"'
        (@($applied.units | Where-Object key -eq 'contentful_composed')[0]).zhTwExpression.raw |
            Should -Be 'Localize("loc_social_menu_leave_party") .. " 現在"'
        (& (Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1') `
                -WorksetPath $outputPath -NewPath $rawNewPath -MergedPath $newPath `
                -RepositoryRoot $repository -ExpectedBaseOid $baseOid -ExpectedModRelativePath 'mods/ExampleMod' -PassThru).result |
            Should -Be 'passed'
    }

    # Scenario: Apply has persisted its deterministic edit plan, then the process stops either before or after replacing NEW bytes.
    # Purpose: Recover both sides of the target-write crash window and persist one finalized applied receipt.
    It 'InterT36_RecoversAPendingLocalizationApplyBeforeAndAfterTargetWrite' {
        $repository = Join-Path $TestDrive 'pending-apply-repository'
        $oldModRoot = Join-Path $repository 'mods/ExampleMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Pending Apply Test'
        & git -C $repository config user.email 'pending-apply@example.invalid'
        $oldPath = Join-Path $oldModRoot 'ExampleMod_localization.lua'
        'return { key = { en = "Stable", ["zh-tw"] = "舊翻譯" } }' | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/ExampleMod/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/pending-apply'
        $staging = Join-Path $runRoot 'staging/localization-workset-input/ExampleMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'ExampleMod_localization.lua'
        'return { key = { en = "Stable", ["zh-tw"] = "upstream drift" } }' | Set-Content -LiteralPath $newPath -NoNewline
        $inputBytes = [IO.File]::ReadAllBytes($newPath)
        $outputPath = Join-Path $runRoot 'review-artifacts/localization-workset.json'
        $null = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru
        $null = & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru
        $outputBytes = [IO.File]::ReadAllBytes($newPath)
        $pending = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -AsHashtable
        $pending.status = 'applying'
        $pending.apply.status = 'pending'

        [IO.File]::WriteAllBytes($newPath, $inputBytes)
        $pending | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline
        $beforeWriteGeneration = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru
        $beforeWriteRecovery = & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru
        $beforeWriteWorkset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -AsHashtable
        $beforeWriteGeneration.status | Should -Be 'applying'
        $beforeWriteRecovery.result | Should -Be 'passed'
        $beforeWriteWorkset.status | Should -Be 'applied'
        $beforeWriteWorkset.apply.status | Should -Be 'applied'
        [IO.File]::ReadAllBytes($newPath) | Should -Be $outputBytes

        $pending | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline
        [IO.File]::WriteAllBytes($newPath, $outputBytes)
        $afterWriteGeneration = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/ExampleMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'example' -PassThru
        $afterWriteRecovery = & (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -WorksetPath $outputPath -PassThru
        $afterWriteWorkset = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -AsHashtable
        $afterWriteGeneration.status | Should -Be 'applying'
        $afterWriteRecovery.result | Should -Be 'passed'
        $afterWriteWorkset.status | Should -Be 'applied'
        $afterWriteWorkset.apply.status | Should -Be 'applied'
    }

    # Scenario: The sole localization entry is only a TeamKills-style io_dofile loader.
    # Purpose: Exclude loader boundaries before creating a workset or update branch instead of treating referenced files as one localization source.
    It 'InterT40_ExcludesLocalizationLoadersBeforeWorksetCreation' {
        $repository = Join-Path $TestDrive 'loader-repository'
        $oldModRoot = Join-Path $repository 'mods/TeamKills'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Loader Test'
        & git -C $repository config user.email 'loader@example.invalid'
        $loader = @'
local localization = {}
mod:io_dofile("TeamKills/scripts/mods/TeamKills/localization/en")
mod:io_dofile("TeamKills/scripts/mods/TeamKills/localization/zh-tw")
return localization
'@
        $oldPath = Join-Path $oldModRoot 'TeamKills_localization.lua'
        $loader | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/TeamKills/TeamKills_localization.lua
        & git -C $repository commit --quiet -m 'loader localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()
        $staging = Join-Path $TestDrive 'loader-staging/TeamKills'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $loader | Set-Content -LiteralPath (Join-Path $staging 'TeamKills_localization.lua') -NoNewline
        $outputPath = Join-Path $repository 'AI Auto Update/In Progress/teamkills-test/review-artifacts/localization-workset.json'

        $result = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository `
            -BaseOid $baseOid `
            -ModRelativePath 'mods/TeamKills' `
            -StagingModPath $staging `
            -OutputPath $outputPath `
            -SourceId 'teamkills' `
            -PassThru

        $result.status | Should -Be 'automation-excluded'
        $result.reason | Should -Be 'localization_entry_is_loader'
        Test-Path -LiteralPath $outputPath | Should -Be $false
    }

    # Scenario: A localization entry invokes io_dofile but also executes unrelated code and exposes no statically provable units.
    # Purpose: Exclude only pure loader routing; all other zero-unit structures must fail closed instead of silently passing.
    It 'InterT42_BlocksZeroUnitFilesThatAreNotPureLoaders' {
        $repository = Join-Path $TestDrive 'non-loader-repository'
        $oldModRoot = Join-Path $repository 'mods/SideEffectMod'
        New-Item -ItemType Directory -Path $oldModRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Non-loader Test'
        & git -C $repository config user.email 'non-loader@example.invalid'
        $content = "mod:io_dofile(`"SideEffectMod/localization/en`")`nlocal side_effect = os.time()"
        $oldPath = Join-Path $oldModRoot 'SideEffectMod_localization.lua'
        $content | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/SideEffectMod/SideEffectMod_localization.lua
        & git -C $repository commit --quiet -m 'non-loader localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()
        $staging = Join-Path $TestDrive 'non-loader-staging/SideEffectMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $content | Set-Content -LiteralPath (Join-Path $staging 'SideEffectMod_localization.lua') -NoNewline
        $outputPath = Join-Path $repository 'AI Auto Update/In Progress/non-loader-test/review-artifacts/localization-workset.json'

        $result = & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') `
            -RepositoryRoot $repository -BaseOid $baseOid -ModRelativePath 'mods/SideEffectMod' `
            -StagingModPath $staging -OutputPath $outputPath -SourceId 'side-effect' -PassThru

        $result.status | Should -Be 'blocked'
        $result.reason | Should -Be 'localization_structure_not_static'
        Test-Path -LiteralPath $outputPath | Should -Be $false
    }

    # Scenario: The sole active localization file moves between OLD and NEW while a Schema 15 run resumes from a stale waiting reason.
    # Purpose: Keep both paths in the target allowlist and clear the resolved waiting reason after successful workset localization.
    It 'InterT45_PreservesMovedTargetsAndClearsTheResolvedWaitingReason' {
        $repository = Join-Path $TestDrive 'rename-runner-repository'
        $oldRoot = Join-Path $repository 'Warhammer 40,000 DARKTIDE/mods/RenameMod/old'
        New-Item -ItemType Directory -Path $oldRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Rename Runner Test'
        & git -C $repository config user.email 'rename-runner@example.invalid'
        'return { key = { en = "Stable", ["zh-tw"] = "穩定" } }' |
            Set-Content -LiteralPath (Join-Path $oldRoot 'RenameMod_localization.lua') -NoNewline
        & git -C $repository add .
        & git -C $repository commit --quiet -m 'base localization'

        $runId = '55555555-6666-4777-8888-999999999999'
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/renamemod-55555555'
        $incoming = Join-Path $runRoot ".incoming-$runId"
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'RenameMod.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('RenameMod/new/RenameMod_localization.lua')
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write('return { key = { en = "Stable", ["zh-tw"] = "穩定" } }') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $TestDrive 'rename-source-request.json'
        [ordered]@{
            schemaVersion = 2; gameDomain = 'warhammer40kdarktide'; modId = 777; mainFileId = 888
            version = '2.0.0'; fileName = 'RenameMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/777'
            pageVersion = '2.0.0'; pageUpdatedAt = '2026-01-02T00:00:00.0000000+00:00'; mainFileUploadedAtUtc = '2026-01-01T00:00:00.0000000+00:00'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'

        $verified = & $runner run -RepositoryRoot $repository -ModDirectory 'RenameMod' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -SkillSourcePinPath $script:skillSourcePinPath -ObservationIntervalMilliseconds 0 -BaseRef HEAD -Until source-verified -PassThru
        $null = & $runner extract -RepositoryRoot $repository -StatePath $verified.statePath -PassThru
        $null = & $runner install -RepositoryRoot $repository -StatePath $verified.statePath -PassThru
        $waitingState = Get-Content -LiteralPath $verified.statePath -Raw | ConvertFrom-Json -AsHashtable
        $waitingState.status = 'waiting-input'
        $waitingState.waitingReason = [ordered]@{
            code = 'localization_workset_review_required'
            message = 'Resume localization after the workset review is complete.'
        }
        $waitingState | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $verified.statePath -NoNewline

        $localized = & $runner localization -RepositoryRoot $repository -StatePath $verified.statePath -PassThru
        $state = Get-Content -LiteralPath $verified.statePath -Raw | ConvertFrom-Json

        $localized.result | Should -Be 'passed'
        $state.waitingReason | Should -BeNullOrEmpty
        @($state.evidenceTargetPaths) | Should -Be @(
            'Warhammer 40,000 DARKTIDE/mods/RenameMod/new/RenameMod_localization.lua',
            'Warhammer 40,000 DARKTIDE/mods/RenameMod/old/RenameMod_localization.lua'
        )
    }

    # Scenario: A Schema 15 runner reaches localization after raw installation and may need AI decisions before evidence commits.
    # Purpose: Route Schema 15 through the single workset, preserve waiting-input resume, and require an independent workset byte boundary at the Gate.
    It 'UnitT50_RoutesSchema15LocalizationThroughTheWorksetBoundary' {
        $runner = Get-Content -LiteralPath (Join-Path $scriptRoot 'mod-update.ps1') -Raw
        $validator = Get-Content -LiteralPath (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -Raw
        $runner | Should -Match 'function Invoke-LocalizationWorkset'
        $runner | Should -Match 'New-LocalizationWorkset\.ps1'
        $runner | Should -Match 'Apply-LocalizationWorkset\.ps1'
        $runner | Should -Not -Match 'Write-ByteFile\s+-Path\s+\$worktreeFile\s+-Bytes\s+\$mergedRawBytes'
        $runner | Should -Match 'Write-ByteFile\s+-Path\s+\$destination\s+-Bytes\s+\(Read-FileBytesWithHeartbeat -Path \$mergedPath\)'
        $runner | Should -Match '(?s)Suspend-Stage -State \$State -Context \$stage -Result ''waiting-input''.*?-OutputStage ''localization-workset'''
        $validator | Should -Match "Add-ValidationCheck -Name 'localization-workset-boundary'"
        $validator | Should -Match 'replacementBase64'
        $validator | Should -Match 'immutableContractSha256'
        $validator | Should -Match 'outside approved localization workset edits'
        $validator | Should -Match '\[string\]\$workset\.apply\.status\s+-cne\s+''applied'''
        $validator | Should -Match 'Test-LocalizationWorksetReceipt\.ps1'
        $runner | Should -Match 'Localization workset SHA-256'
        $runner | Should -Match 'Localization workset deletion receipt SHA-256'
        $runner | Should -Match 'restore the pinned validator before resuming'
    }

    # Scenario: Candidate validation passed, and the process may stop before, during, or after deleting the transient workset JSON.
    # Purpose: Finalize deletion with a recoverable receipt and bind that evidence into the validation report and completed-stage SHA.
    It 'UnitT55_FinalizesWorksetDeletionEvidenceIdempotently' {
        $finalizer = Join-Path $scriptRoot 'Finalize-LocalizationWorksetEvidence.ps1'
        Test-Path -LiteralPath $finalizer -PathType Leaf | Should -Be $true
        $runRoot = Join-Path $TestDrive 'workset-finalization'
        $artifacts = Join-Path $runRoot 'artifacts'
        $reviewArtifacts = Join-Path $runRoot 'review-artifacts'
        New-Item -ItemType Directory -Path $artifacts, $reviewArtifacts -Force | Out-Null
        $worksetPath = Join-Path $reviewArtifacts 'localization-workset.json'
        '{"schemaVersion":1}' | Set-Content -LiteralPath $worksetPath -NoNewline
        $worksetSha = (Get-FileHash -LiteralPath $worksetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $reportPath = Join-Path $artifacts 'validation-report.json'
        [ordered]@{ schemaVersion = 1; result = 'passed'; runId = 'finalization-run' } |
            ConvertTo-Json | Set-Content -LiteralPath $reportPath -NoNewline
        $reportSha = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $statePath = Join-Path $runRoot 'state.json'
        [ordered]@{
            schemaVersion = 15
            runId = 'finalization-run'
            repositoryRoot = $TestDrive
            statePath = $statePath
            runRoot = $runRoot
            artifactsRoot = $artifacts
            completedStages = @('validate')
            stageTimings = [ordered]@{ validate = [ordered]@{ artifactSha256 = $reportSha } }
            candidateGate = [ordered]@{ status = 'passed'; validationReportPath = $reportPath; validationReportSha256 = $reportSha }
            localizationWorkset = [ordered]@{
                status = 'applied'; path = $worksetPath; sha256 = $worksetSha
                counts = [ordered]@{ unchanged = 1; blocked = 0 }; unitCount = 1; editCount = 0
            }
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -NoNewline

        $first = & $finalizer -StatePath $statePath -PassThru
        $second = & $finalizer -StatePath $statePath -PassThru
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $receipt = Get-Content -LiteralPath $first.receiptPath -Raw | ConvertFrom-Json

        $first.result | Should -Be 'passed'
        $second.idempotent | Should -Be $true
        Test-Path -LiteralPath $worksetPath | Should -Be $false
        $receipt.status | Should -Be 'deleted'
        $state.localizationWorkset.deletedBeforePublish | Should -Be $true
        $state.localizationWorkset.deletionReceiptSha256 | Should -Be $first.receiptSha256
        $report.worksetDeletion.receiptSha256 | Should -Be $first.receiptSha256
        $state.candidateGate.validationReportSha256 | Should -Be ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant())
        $state.stageTimings.validate.artifactSha256 | Should -Be $state.candidateGate.validationReportSha256
    }

    # Scenario: The process stops after deleting the workset with a pending receipt, then later stops again after updating the report but before saving state.
    # Purpose: Recover both destructive crash windows without recreating the transient workset or losing the Candidate Gate/report binding.
    It 'UnitT56_RecoversWorksetDeletionAcrossPendingReceiptAndStaleState' {
        $finalizer = Join-Path $scriptRoot 'Finalize-LocalizationWorksetEvidence.ps1'
        $runRoot = Join-Path $TestDrive 'workset-crash-recovery'
        $artifacts = Join-Path $runRoot 'artifacts'
        $reviewArtifacts = Join-Path $runRoot 'review-artifacts'
        New-Item -ItemType Directory -Path $artifacts, $reviewArtifacts -Force | Out-Null
        $worksetPath = Join-Path $reviewArtifacts 'localization-workset.json'
        '{"schemaVersion":1}' | Set-Content -LiteralPath $worksetPath -NoNewline
        $worksetSha = (Get-FileHash -LiteralPath $worksetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $reportPath = Join-Path $artifacts 'validation-report.json'
        [ordered]@{ schemaVersion = 1; result = 'passed'; runId = 'crash-recovery-run' } |
            ConvertTo-Json | Set-Content -LiteralPath $reportPath -NoNewline
        $reportSha = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $statePath = Join-Path $runRoot 'state.json'
        [ordered]@{
            schemaVersion = 15; runId = 'crash-recovery-run'; statePath = $statePath; runRoot = $runRoot; artifactsRoot = $artifacts
            completedStages = @('validate'); stageTimings = [ordered]@{ validate = [ordered]@{ artifactSha256 = $reportSha } }
            candidateGate = [ordered]@{ status = 'passed'; validationReportPath = $reportPath; validationReportSha256 = $reportSha }
            localizationWorkset = [ordered]@{ status = 'applied'; path = $worksetPath; sha256 = $worksetSha }
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -NoNewline
        $receiptPath = Join-Path $artifacts 'localization-workset-deletion-receipt.json'
        [ordered]@{
            schemaVersion = 1; workflowSchemaVersion = 15; runId = 'crash-recovery-run'; status = 'pending'
            worksetPath = $worksetPath; worksetSha256 = $worksetSha
            validationReportPath = $reportPath; validationReportBeforeDeletionSha256 = $reportSha; createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -NoNewline

        $tamperedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        $tamperedReceipt.validationReportBeforeDeletionSha256 = '0' * 64
        $tamperedReceipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -NoNewline
        { & $finalizer -StatePath $statePath -PassThru } | Should -Throw '*Candidate Gate report*'
        Test-Path -LiteralPath $worksetPath -PathType Leaf | Should -Be $true
        $tamperedReceipt.validationReportBeforeDeletionSha256 = $reportSha
        $tamperedReceipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -NoNewline
        [IO.File]::Delete($worksetPath)

        $pendingRecovery = & $finalizer -StatePath $statePath -PassThru
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        $pendingRecovery.result | Should -Be 'passed'
        $receipt.status | Should -Be 'deleted'

        $staleState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $null = $staleState.localizationWorkset.Remove('deletedBeforePublish')
        $null = $staleState.localizationWorkset.Remove('deletedSha256')
        $null = $staleState.localizationWorkset.Remove('deletionReceiptPath')
        $null = $staleState.localizationWorkset.Remove('deletionReceiptSha256')
        $null = $staleState.candidateGate.Remove('localizationWorksetDeletionReceiptSha256')
        $staleState.candidateGate.validationReportSha256 = $reportSha
        $staleState.stageTimings.validate.artifactSha256 = $reportSha
        $staleState | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -NoNewline

        $stateRecovery = & $finalizer -StatePath $statePath -PassThru
        $recoveredState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $stateRecovery.result | Should -Be 'passed'
        $recoveredState.localizationWorkset.deletedBeforePublish | Should -Be $true
        $recoveredState.candidateGate.validationReportSha256 | Should -Be ((Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant())
        $recoveredState.stageTimings.validate.artifactSha256 | Should -Be $recoveredState.candidateGate.validationReportSha256
    }

    # Scenario: StatePath or one of its parents is replaced by a reparse point before finalization starts.
    # Purpose: Reject physical indirection before the first state read and bind the state to its actual run-root tuple.
    It 'UnitT57_ValidatesThePhysicalStateTupleBeforeReadingIt' {
        $finalizer = Get-Content -LiteralPath (Join-Path $scriptRoot 'Finalize-LocalizationWorksetEvidence.ps1') -Raw

        $finalizer | Should -Match '(?s)\$stateFull = \[IO\.Path\]::GetFullPath\(\$StatePath\).*Assert-NoReparsePath -Path \$stateFull -Root \(\[IO\.Path\]::GetPathRoot\(\$stateFull\)\) -Label ''Schema 15 state''.*\$state = Get-Content'
        $finalizer | Should -Match '\[IO\.Path\]::GetFullPath\(\[string\]\$state\.runRoot\) -cne \$stateRunRoot'
        $finalizer | Should -Match '\[IO\.Path\]::GetFullPath\(\[string\]\$state\.statePath\) -cne \$stateFull'
    }

    # Scenario: review-artifacts is swapped for a junction after validation and before transient workset deletion.
    # Purpose: Prevent finalization from deleting or writing through any reparse component outside the physical run root.
    It 'InterT58_RejectsAReparseParentBeforeWorksetDeletion' {
        $finalizer = Join-Path $scriptRoot 'Finalize-LocalizationWorksetEvidence.ps1'
        $runRoot = Join-Path $TestDrive 'workset-deletion-reparse'
        $artifacts = Join-Path $runRoot 'artifacts'
        $reviewArtifacts = Join-Path $runRoot 'review-artifacts'
        New-Item -ItemType Directory -Path $artifacts, $reviewArtifacts -Force | Out-Null
        $worksetPath = Join-Path $reviewArtifacts 'localization-workset.json'
        '{"schemaVersion":1}' | Set-Content -LiteralPath $worksetPath -NoNewline
        $worksetSha = (Get-FileHash -LiteralPath $worksetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $reportPath = Join-Path $artifacts 'validation-report.json'
        [ordered]@{ schemaVersion = 1; result = 'passed'; runId = 'deletion-reparse-run' } |
            ConvertTo-Json | Set-Content -LiteralPath $reportPath -NoNewline
        $reportSha = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $statePath = Join-Path $runRoot 'state.json'
        [ordered]@{
            schemaVersion = 15; runId = 'deletion-reparse-run'; statePath = $statePath; runRoot = $runRoot; artifactsRoot = $artifacts
            completedStages = @('validate'); stageTimings = [ordered]@{ validate = [ordered]@{ artifactSha256 = $reportSha } }
            candidateGate = [ordered]@{ status = 'passed'; validationReportPath = $reportPath; validationReportSha256 = $reportSha }
            localizationWorkset = [ordered]@{ status = 'applied'; path = $worksetPath; sha256 = $worksetSha }
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -NoNewline

        $outside = Join-Path $TestDrive 'workset-deletion-outside'
        Move-Item -LiteralPath $reviewArtifacts -Destination $outside
        New-Item -ItemType Junction -Path $reviewArtifacts -Target $outside | Out-Null

        { & $finalizer -StatePath $statePath -PassThru } | Should -Throw '*reparse*'
        Test-Path -LiteralPath (Join-Path $outside 'localization-workset.json') -PathType Leaf | Should -Be $true
    }
}
