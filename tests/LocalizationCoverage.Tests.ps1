# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Describe 'Localization source coverage and OLD zh-tw survival' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $scripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/auto-update-darktide-mod/scripts'
        $fixtures = Join-Path $PSScriptRoot 'fixtures/localization-coverage'
        Import-Module (Join-Path $scripts 'LuaLocalizationScanner.psm1') -Force
        Import-Module (Join-Path $scripts 'LocalizationCoverage.psm1') -Force
        Import-Module (Join-Path $scripts 'LocalizationWorksetContract.psm1') -Force
        $oldLua = [IO.File]::ReadAllText((Join-Path $fixtures 'LoadoutMonitor.old.lua'))
        $newLua = [IO.File]::ReadAllText((Join-Path $fixtures 'LoadoutMonitor.new.lua'))
        function Read-CoverageLua([string] $Text) {
            Get-LuaLocalizationDocument -Bytes ([Text.Encoding]::UTF8.GetBytes($Text)) -SourceId 'coverage'
        }
        function New-CoverageFixture([string] $Old, [string] $New) {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $mod = Join-Path $root 'mods/Example'
            $run = Join-Path $root 'runs/review'
            $stage = Join-Path $run 'staging/localization-workset-input/Example'
            $null = New-Item -ItemType Directory -Path $mod, $stage, (Join-Path $run 'review-artifacts') -Force
            [IO.File]::WriteAllText((Join-Path $mod 'Example_localization.lua'), $Old)
            [IO.File]::WriteAllText((Join-Path $stage 'Example_localization.lua'), $New)
            & git -C $root init --quiet
            & git -C $root config user.name 'Coverage Fixture'
            & git -C $root config user.email 'coverage@example.invalid'
            & git -C $root config core.autocrlf false
            Add-TestTranslationRules $root
            & git -C $root add -- mods
            & git -C $root commit --quiet -m fixture
            if ($LASTEXITCODE) { throw 'Cannot initialize coverage fixture.' }
            @{
                RepositoryRoot = $root; BaseOid = (& git -C $root rev-parse HEAD).Trim()
                ModRelativePath = 'mods/Example'; StagingModPath = $stage; SourceId = 'coverage'
                OutputPath = Join-Path $run 'review-artifacts/localization-workset.json'
            }
        }
        function Save-CoverageWorkset($Workset, [string] $Path) {
            $Workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8
        }
        function New-AppliedCoverageFixture {
            $f = New-CoverageFixture $oldLua $newLua
            $null = & (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru
            $w = Get-Content -LiteralPath $f.OutputPath -Raw | ConvertFrom-Json -AsHashtable
            $w.status | Should -BeExactly 'ready'
            foreach ($u in $w.units | Where-Object action -CEQ 'AI_REQUIRED') {
                $u.reviewStatus = 'approved'; $u.suggestedZhTwExpression = '"新選項"'
            }
            Save-CoverageWorkset $w $f.OutputPath
            $path = Join-Path $f.StagingModPath 'Example_localization.lua'
            $raw = Join-Path (Split-Path -Parent $f.OutputPath) 'new.lua'
            Copy-Item -LiteralPath $path -Destination $raw
            $null = & (Join-Path $scripts 'Apply-LocalizationWorkset.ps1') -WorksetPath $f.OutputPath -PassThru
            @{ fixture = $f; path = $path; raw = $raw }
        }
    }

    # Scenario: OLD has positional, named and numeric translations; upstream has no repository zh-tw.
    # Purpose: Reconstruct each source family and verify the main-file output and repeat application.
    It 'InterT10_RestoresAllOldTranslationsWithoutSidecarsAndIsIdempotent' {
        $a = New-AppliedCoverageFixture
        $w = Get-Content $a.fixture.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        $w.new.coverage.unitCount | Should -Be 8
        @($w.new.coverage.categories | Where-Object method -CEQ 'positional-array').unitCount | Should -Be 3
        @($w.new.coverage.categories | Where-Object method -CEQ 'numeric-loop').unitCount | Should -Be 4
        $w.new.zhTwSurvival.Count | Should -Be 7
        $bytes = [IO.File]::ReadAllBytes($a.path)
        (& (Join-Path $scripts 'Apply-LocalizationWorkset.ps1') -WorksetPath $a.fixture.OutputPath -PassThru).idempotent | Should -BeTrue
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($a.path)) | Should -BeExactly ([Convert]::ToBase64String($bytes))
        $receipt = & (Join-Path $scripts 'Test-LocalizationWorksetReceipt.ps1') -WorksetPath $a.fixture.OutputPath -NewPath $a.raw -MergedPath $a.path `
            -RepositoryRoot $a.fixture.RepositoryRoot -ExpectedBaseOid $a.fixture.BaseOid -ExpectedModRelativePath 'mods/Example' -PassThru
        $receipt.result | Should -BeExactly 'passed'
    }

    # Scenario: A translated field or required language mapping disappears after application.
    # Purpose: Report the affected key, including shared numeric output and positional rows.
    It 'InterT20_RejectsMissingOldZhTwWithKey: <Case>' -ForEach @(
        @{ Case = 'third column'; From = ', "處"'; To = ''; Key = 'def_executioner' }
        @{ Case = 'numeric translation'; From = '["zh-tw"] = "欄位："..tostring(i),'; To = ''; Key = 'player_Feats_order_1' }
        @{ Case = 'locale mapping'; From = ', "zh-tw"'; To = ''; Key = 'def_executioner' }
    ) {
        $a = New-AppliedCoverageFixture
        $text = [IO.File]::ReadAllText($a.path)
        $text.Contains($From) | Should -BeTrue
        [IO.File]::WriteAllText($a.path, $text.Replace($From, $To))
        { & (Join-Path $scripts 'Test-LocalizationWorksetReceipt.ps1') -WorksetPath $a.fixture.OutputPath -NewPath $a.raw -MergedPath $a.path `
            -RepositoryRoot $a.fixture.RepositoryRoot -ExpectedBaseOid $a.fixture.BaseOid -ExpectedModRelativePath 'mods/Example' -PassThru } |
            Should -Throw "*OLD zh-tw survival failed: $Key*"
        # A forged output hash must not bypass the idempotent Apply path.
        $w = Get-Content $a.fixture.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        $w.apply.outputSha256 = (Get-FileHash $a.path -Algorithm SHA256).Hash.ToLowerInvariant()
        $w.apply.outputSize = ([IO.File]::ReadAllBytes($a.path)).Length
        Save-CoverageWorkset $w $a.fixture.OutputPath
        { & (Join-Path $scripts 'Apply-LocalizationWorkset.ps1') -WorksetPath $a.fixture.OutputPath -PassThru } |
            Should -Throw "*OLD zh-tw survival failed: $Key*"
    }

    # Scenario: An attacker updates the outer hash after changing inventory evidence or omitting a unit.
    # Purpose: Require a source-derived comparison at both consumers, beyond hash consistency.
    It 'InterT30_RecomputesCoverageInApplyAndReceipt: <Case>' -ForEach @(
        @{ Case = 'coverage count'; OmitUnit = $false; DuplicateUnit = $false }
        @{ Case = 'omitted unit'; OmitUnit = $true; DuplicateUnit = $false }
        @{ Case = 'duplicate unit'; OmitUnit = $false; DuplicateUnit = $true }
    ) {
        $a = New-AppliedCoverageFixture
        $w = Get-Content $a.fixture.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        if ($OmitUnit) { $w.units = @($w.units | Where-Object key -CNE 'title') }
        elseif ($DuplicateUnit) { $w.units = @($w.units) + @($w.units[0]) }
        else { $w.new.coverage.unitCount-- }
        $w.immutableContractSha256 = Get-ImmutableWorksetContractSha256 $w
        if ($OmitUnit -or $DuplicateUnit) {
            # Rebind mutable review evidence too, so the inventory check is exercised.
            $review = @($w.units | ForEach-Object { [ordered]@{ unitId = $_.unitId; reviewStatus = $_.reviewStatus; suggestedZhTwExpression = $_.suggestedZhTwExpression } })
            $w.apply.reviewContractSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $review -Depth 10 -Compress)))).ToLowerInvariant()
        }
        Save-CoverageWorkset $w $a.fixture.OutputPath
        { & (Join-Path $scripts 'Apply-LocalizationWorkset.ps1') -WorksetPath $a.fixture.OutputPath -PassThru } | Should -Throw '*coverage*'
        $reason = if ($OmitUnit -or $DuplicateUnit) { '*inventory*' } else { '*coverage differs*' }
        { & (Join-Path $scripts 'Test-LocalizationWorksetReceipt.ps1') -WorksetPath $a.fixture.OutputPath -NewPath $a.raw -MergedPath $a.path `
            -RepositoryRoot $a.fixture.RepositoryRoot -ExpectedBaseOid $a.fixture.BaseOid -ExpectedModRelativePath 'mods/Example' -PassThru } | Should -Throw $reason
    }

    # Scenario: A named return table parses but another source cannot be safely attributed.
    # Purpose: Block partial coverage, even when at least one ordinary unit is recognized.
    It 'InterT40_BlocksPartiallyUncoveredSources: <Case>' -ForEach @(
        @{ Case = 'unconsumed source table'; Tail = 'local helper = { en = "Unconsumed", ["zh-tw"] = "既有" }'; Reason = '*uncovered_language_fields*' }
        @{ Case = 'unknown loop'; Tail = 'for k in pairs(runtime_list) do output["dynamic_"..k] = { en = k } end'; Reason = '*unproven_localization_units*' }
    ) {
        $lua = 'local output = { known = { en = "Known", ["zh-tw"] = "已知" } }' + "`n" + $Tail + "`nreturn output"
        $f = New-CoverageFixture $lua $lua
        $result = & (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru
        $result.status | Should -BeExactly 'blocked'
        $w = Get-Content $f.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        $w.new.coverage.unitCount | Should -BeGreaterThan 0
        ($w.new.coverage.blockedReasons -join ',') | Should -BeLike $Reason
    }

    # Scenario: Known keys are added, removed or changed in NEW.
    # Purpose: Retain the existing classifications and provide traceable survival dispositions.
    It 'InterT50_TracksNewChangedAndDeletedKeys' {
        $old = 'return { keep={en="Keep",["zh-tw"]="保留"}, gone={en="Gone",["zh-tw"]="刪除"}, change={en="Before",["zh-tw"]="舊譯"} }'
        $new = 'return { keep={en="Keep"}, added={en="Added"}, change={en="After",["zh-tw"]="舊譯"} }'
        $f = New-CoverageFixture $old $new
        $null = & (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru
        $w = Get-Content $f.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        @($w.units | Where-Object key -CEQ 'added').action | Should -BeExactly 'AI_REQUIRED'
        @($w.units | Where-Object key -CEQ 'change').action | Should -BeExactly 'AI_REQUIRED'
        @($w.new.zhTwSurvival | Where-Object key -CEQ 'gone').reason | Should -BeExactly 'deleted_in_new_source'
        @($w.new.zhTwSurvival | Where-Object key -CEQ 'change').reason | Should -BeExactly 'source_changed_requires_review'
    }

    # Scenario: One return-table field is opaque while its sibling is a proven language table.
    # Purpose: A partial named-table parse cannot silently omit a runtime source.
    It 'InterT45_BlocksAnOpaqueSiblingOfARecognizedTable' {
        $lua = 'return { known={en="Known",["zh-tw"]="已知"}, hidden=build_localization() }'
        $f = New-CoverageFixture $lua $lua
        (& (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru).status | Should -BeExactly 'blocked'
        $w = Get-Content $f.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        ($w.new.coverage.blockedReasons -join ',') | Should -BeLike '*unproven_source_fields*hidden*'
    }

    # Scenario: A source remains in both files but loses its provable language mapping in NEW.
    # Purpose: Do not misclassify a skipped source as an authorized key deletion.
    It 'InterT47_BlocksASourceThatWouldOtherwiseLookDeleted: <Case>' -ForEach @(
        @{ Case = 'named language'; Old = '{en="Hidden",["zh-tw"]="隱藏"}'; New = '{["zh-cn"]="隐藏"}' }
        @{ Case = 'unmapped positional'; Old = '{en="ES",["zh-tw"]="處"}'; New = '{"ES","刽"}' }
    ) {
        $prefix = 'return { known={en="Known",["zh-tw"]="已知"}, hidden='
        $f = New-CoverageFixture ($prefix + $Old + '}') ($prefix + $New + '}')
        (& (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru).status | Should -BeExactly 'blocked'
        $w = Get-Content $f.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        @($w.new.coverage.unprovenFields | Where-Object key -CEQ 'hidden').reason | Should -BeExactly 'unmapped_language_table'
    }

    # Scenario: Real inline locale-list syntax is outside #67's literal-local binding proof.
    # Purpose: Keep the unsupported structure blocked rather than changing the existing parser boundary.
    It 'InterT46_ReportsUnprovenInlineLocaleLists' {
        $lua = $newLua.Replace('generate_translation(def_abb,"def_","",locale_order)', 'generate_translation(def_abb,"def_","",{"en","zh-cn"})')
        $f = New-CoverageFixture $oldLua $lua
        (& (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru).status | Should -BeExactly 'blocked'
        $w = Get-Content $f.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        ($w.new.coverage.blockedReasons -join ',') | Should -BeLike '*unsupported_generated_localization_call*'
    }

    # Scenario: A game list contains a mood absent from the mapping, or the entire mapping is unavailable.
    # Purpose: Never accept an English runtime fallback as complete dynamic localization coverage.
    It 'InterT60_BlocksMoodGapsAndListsCandidates: <Case>' -ForEach @(
        @{ Case = 'no mapping'; Mutation = 'none'; Reason = '*dynamic_entries_uncovered*' }
        @{ Case = 'single loop iterator'; Mutation = 'single'; Reason = '*dynamic_entries_uncovered*' }
        @{ Case = 'new game mood'; Mutation = 'add'; Reason = '*dynamic_list_mapping_incomplete*new_mood*' }
        @{ Case = 'missing mapping'; Mutation = 'remove'; Reason = '*dynamic_list_mapping_incomplete*knocked_down*' }
        @{ Case = 'removed game mood'; Mutation = 'delete'; Reason = '*dynamic_list_mapping_incomplete*knocked_down*' }
        @{ Case = 'complete candidates'; Mutation = 'complete'; Reason = '*dynamic_candidates_require_review*' }
    ) {
        $lua = [IO.File]::ReadAllText((Join-Path $fixtures 'vfx_swapper.lua'))
        if ($Mutation -ceq 'single') { $lua = $lua.Replace('for mood_type, _', 'for mood_type') }
        $f = New-CoverageFixture $lua $lua
        $mapPath = Join-Path $f.RepositoryRoot 'mood-map.json'
        Copy-Item (Join-Path $fixtures 'mood-map.json') $mapPath
        $sourcePath = Join-Path $f.RepositoryRoot 'mood_settings.lua'
        Copy-Item (Join-Path $fixtures 'mood_settings.lua') $sourcePath
        if ($Mutation -ceq 'add') { [IO.File]::WriteAllText($sourcePath, [IO.File]::ReadAllText($sourcePath).Replace('knocked_down = 1', 'new_mood = 3, knocked_down = 1')) }
        if ($Mutation -ceq 'delete') { [IO.File]::WriteAllText($sourcePath, [IO.File]::ReadAllText($sourcePath).Replace('knocked_down = 1, ', '')) }
        if ($Mutation -ceq 'remove') {
            $map = Get-Content $mapPath -Raw | ConvertFrom-Json -AsHashtable
            $map.entries.Remove('knocked_down'); Save-CoverageWorkset $map $mapPath
        }
        if ($Mutation -cnotin @('none', 'single')) { $f.DynamicListMapPath = $mapPath }
        $generated = & (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru
        $generated.status | Should -BeExactly 'blocked'
        $generated.reason | Should -BeLike $Reason
        $repeated = & (Join-Path $scripts 'New-LocalizationWorkset.ps1') @f -PassThru
        $repeated.idempotent | Should -BeTrue
        $repeated.reason | Should -BeExactly $generated.reason
        $w = Get-Content $f.OutputPath -Raw | ConvertFrom-Json -AsHashtable
        ($w.new.coverage.blockedReasons -join ';') | Should -BeLike $Reason
        if ($Mutation -ceq 'complete') {
            $w.new.coverage.dynamicList.sourcePath | Should -BeExactly $sourcePath
            $w.new.coverage.dynamicList.rows.Count | Should -Be 2
            $w.new.coverage.dynamicList.rows[0].candidateZhTw | Should -BeExactly '倒地'
        }
        { & (Join-Path $scripts 'Apply-LocalizationWorkset.ps1') -WorksetPath $f.OutputPath -PassThru } | Should -Throw '*Blocked localization workset*'
    }

    # Scenario: Load only the generated main file in a sandbox without sidecar I/O.
    # Purpose: Assert the actual runtime value of every OLD zh-tw key, not only Lua syntax.
    It 'InterT70_LoadsMainFileAndChecksEveryOldZhTwKey' {
        $luaJit = if ($env:SYP700_LUAJIT) { $env:SYP700_LUAJIT } else { 'C:/Users/carsu/AppData/Local/Temp/syp553-mod-test-tools/LuaJIT/src/luajit.exe' }
        if (-not (Test-Path -LiteralPath $luaJit -PathType Leaf)) {
            Set-ItResult -Skipped -Because "LuaJIT unavailable: $luaJit (set SYP700_LUAJIT)"; return
        }
        $a = New-AppliedCoverageFixture
        $oldPath = Join-Path $fixtures 'LoadoutMonitor.old.lua'
        $harness = Join-Path $TestDrive 'main-only.lua'
        @'
local function load_main(path)
    local env = {pairs=pairs, type=type, tostring=tostring, string=string}
    local chunk = assert(loadfile(path))
    setfenv(chunk, env) -- no io, require, dofile, Mods or extra language files
    return chunk()
end
local old, actual = load_main(arg[1]), load_main(arg[2])
local count = 0
for key, languages in pairs(old) do
    if languages["zh-tw"] then
        assert(actual[key] and actual[key]["zh-tw"] == languages["zh-tw"], "OLD zh-tw missing: "..key)
        count = count + 1
    end
end
assert(count == 7, "unexpected OLD inventory")
for i=1,4 do assert(actual["player_Feats_order_"..i]["zh-tw"] == "欄位："..i) end
print("verified "..count.." OLD zh-tw keys")
'@ | Set-Content -LiteralPath $harness -Encoding utf8
        $output = & $luaJit $harness $oldPath $a.path 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'verified 7 OLD zh-tw keys'
    }
}
