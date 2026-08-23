Describe 'Schema 15 localization workset' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod/scripts'
    }

    # Scenario: Schema 15 replaces agent-authored byte spans with one deterministic localization workset.
    # Purpose: Require separate static scanning, workset generation, and workset application boundaries.
    It 'UnitT10_PublishesTheLocalizationWorksetEntrypoints' {
        Test-Path -LiteralPath (Join-Path $scriptRoot 'LuaLocalizationScanner.psm1') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1') -PathType Leaf | Should -Be $true
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
        $document.units[2].sourceExpression.startByte | Should -BeGreaterThan 0
        $document.units[2].zhTwExpression.lengthByte | Should -BeGreaterThan 0
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
    zh_only = { en = "Stable", ["zh-tw"] = "舊翻譯" },
    remove_upstream_zh = { en = "No old translation" },
    source_change = { en = "Old source", ["zh-tw"] = "原翻譯" },
    deleted = { en = "Deleted", ["zh-tw"] = "刪除" }
}
'@ | Set-Content -LiteralPath $oldPath -NoNewline
        & git -C $repository add mods/ExampleMod/ExampleMod_localization.lua
        & git -C $repository commit --quiet -m 'base localization'
        $baseOid = (& git -C $repository rev-parse HEAD).Trim()

        $staging = Join-Path $TestDrive 'staging/ExampleMod'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $newPath = Join-Path $staging 'ExampleMod_localization.lua'
        @'
return {
    unchanged = { en = "Same", ["zh-tw"] = "相同" },
    zh_only = { en = "Stable", ["zh-tw"] = "上游改動" },
    remove_upstream_zh = { en = "No old translation", ["zh-tw"] = "不應新增" },
    source_change = { en = "New source", ["zh-tw"] = "原翻譯" },
    new_key = { en = "New source" }
}
'@ | Set-Content -LiteralPath $newPath -NoNewline
        $outputPath = Join-Path $repository 'AI Auto Update/In Progress/example-test/review-artifacts/localization-workset.json'

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
        @($workset.units).Count | Should -Be 6
        (@($workset.units | Where-Object key -eq 'unchanged')).changeType | Should -Be 'unchanged'
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

        $sourceChange = @($workset.units | Where-Object key -eq 'source_change')[0]
        $sourceChange.reviewStatus = 'approved'
        $sourceChange.suggestedZhTwExpression = '"新翻譯"'
        $newKey = @($workset.units | Where-Object key -eq 'new_key')[0]
        $newKey.reviewStatus = 'approved'
        $newKey.suggestedZhTwExpression = '"新增翻譯"'
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outputPath -NoNewline

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
        (@($applied.units | Where-Object key -eq 'zh_only')).zhTwExpression.raw | Should -Be '"舊翻譯"'
        (@($applied.units | Where-Object key -eq 'remove_upstream_zh')).zhTwExpression | Should -BeNullOrEmpty
        (@($applied.units | Where-Object key -eq 'source_change')).sourceExpression.raw | Should -Be '"New source"'
        (@($applied.units | Where-Object key -eq 'source_change')).zhTwExpression.raw | Should -Be '"新翻譯"'
        (@($applied.units | Where-Object key -eq 'new_key')).zhTwExpression.raw | Should -Be '"新增翻譯"'
        @($applied.units | Where-Object key -eq 'deleted').Count | Should -Be 0
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

    # Scenario: A Schema 15 runner reaches localization after raw installation and may need AI decisions before evidence commits.
    # Purpose: Route Schema 15 through the single workset, preserve waiting-input resume, and require an independent workset byte boundary at the Gate.
    It 'UnitT50_RoutesSchema15LocalizationThroughTheWorksetBoundary' {
        $runner = Get-Content -LiteralPath (Join-Path $scriptRoot 'mod-update.ps1') -Raw
        $validator = Get-Content -LiteralPath (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -Raw
        $runner | Should -Match 'function Invoke-LocalizationWorkset'
        $runner | Should -Match 'New-LocalizationWorkset\.ps1'
        $runner | Should -Match 'Apply-LocalizationWorkset\.ps1'
        $runner | Should -Match "result = 'waiting-input'.*stage = 'localization-workset'"
        $validator | Should -Match "Add-ValidationCheck -Name 'localization-workset-boundary'"
        $validator | Should -Match 'replacementBase64'
        $validator | Should -Match 'immutableContractSha256'
        $validator | Should -Match 'outside approved localization workset edits'
    }
}
