# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide consumer repository check' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryCheck = Join-Path $script:RepositoryRoot 'scripts/Test-DarktideRepository.ps1'
    }

    It 'UnitT10_DeclaresTheGeneralCheckInterfaceWithoutWindowsOnlyDependencies' {
        $source = Get-Content -LiteralPath $script:RepositoryCheck -Raw
        $source | Should -Match '\[string\]\s+\$RepositoryRoot'
        $source | Should -Match '\[switch\]\s+\$ReadOnlySnapshot'
        $source | Should -Not -Match '(?i)pwsh\.exe|icacls|kernel32|advapi32|DllImport|Add-Type'
    }

    It 'InterT20_ValidatesTheTrackedRepositoryAsAReadOnlySnapshot' {
        $before = @(git -C $script:RepositoryRoot status --porcelain=v1 --untracked-files=all)
        $powerShell = Get-TestPowerShellExecutablePath
        $output = @(& $powerShell -NoProfile -NonInteractive -File $script:RepositoryCheck `
                -RepositoryRoot $script:RepositoryRoot -ReadOnlySnapshot)
        $LASTEXITCODE | Should -Be 0
        $evidence = $output[-1] | ConvertFrom-TestJson
        $evidence.schemaVersion | Should -Be 1
        $evidence.report | Should -Be 'darktide-repository-check-v1'
        $evidence.result | Should -Be 'passed'
        $evidence.activeSkillCount | Should -Be 1
        @($evidence.skills[0].files).Count | Should -BeGreaterThan 0
        $after = @(git -C $script:RepositoryRoot status --porcelain=v1 --untracked-files=all)
        ($after -join "`n") | Should -BeExactly ($before -join "`n")
    }

    It 'UnitT30_RejectsOutputMutationInReadOnlySnapshotMode' {
        { & $script:RepositoryCheck -RepositoryRoot $script:RepositoryRoot -ReadOnlySnapshot `
                -OutputPath (Join-Path $TestDrive 'forbidden.json') } |
            Should -Throw '*does not permit an output file*'
    }

    Context 'product-local catalog domain contract' {
        BeforeEach {
            $script:FixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:FixtureRoot | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination $script:FixtureRoot -Recurse
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination $script:FixtureRoot -Recurse
            $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
            & $script:GitPath -C $script:FixtureRoot init --quiet
            & $script:GitPath -C $script:FixtureRoot add -- catalog skills
            if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Darktide repository check fixture.' }
            $script:ProfilePath = Join-Path $script:FixtureRoot 'catalog/profiles.json'
            $script:SourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        }

        It 'rejects profile membership drift in the product-local catalog' {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            $catalog.profiles[0].includes = @('unlisted-skill')
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*profile identity or membership*'
        }

        It 'rejects a non-Boolean product-local profile default' {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            $catalog.profiles[0].default = 0
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*profile identity or membership*'
        }

        It 'rejects a product-local profile source path that leaves the canonical source package' {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            $catalog.skills[0].source.path = 'skills/other-skill'
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*source binding*'
        }

        It 'rejects an inactive product-local Skill lifecycle' {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            $catalog.skills[0].lifecycle.status = 'retired'
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*lifecycle*'
        }

        It 'rejects a changed required capability in the product-local catalog' {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            $catalog.skills[0].compatibility.requiredCapabilities[0].state = 'missing'
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*required capability*'
        }

        # Scenario: Each alternative capability field changes only its case, or stays canonical.
        # Purpose: Exercise the extracted repository checker so case-only contract drift cannot pass.
        It 'InterT30_ProfileAlternativeCapabilityCase_<scenario>' -ForEach @(
            @{ scenario = 'canonical'; alternativeIndex = 0; field = ''; value = '' },
            @{ scenario = 'connector-kind'; alternativeIndex = 0; field = 'kind'; value = 'Connector' },
            @{ scenario = 'connector-id'; alternativeIndex = 0; field = 'id'; value = 'GitHub' },
            @{ scenario = 'connector-state'; alternativeIndex = 0; field = 'state'; value = 'Configured' },
            @{ scenario = 'command-kind'; alternativeIndex = 1; field = 'kind'; value = 'Command' },
            @{ scenario = 'command-id'; alternativeIndex = 1; field = 'id'; value = 'GH' },
            @{ scenario = 'command-state'; alternativeIndex = 1; field = 'state'; value = 'Authenticated' }
        ) {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            if ($field) { $catalog.skills[0].compatibility.anyOfCapabilities[$alternativeIndex].$field = $value }
            [IO.File]::WriteAllText($script:ProfilePath, ($catalog | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
            if ($field) {
                { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*alternative capability contract*'
            }
            else { { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw }
        }

        It 'UnitT40_RejectsStringSourceAndProfileSchemaVersions' -ForEach @(
            @{ target = 'source' },
            @{ target = 'profile' }
        ) {
            $path = if ($target -ceq 'source') { $script:SourcePath } else { $script:ProfilePath }
            $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $document.schemaVersion = '1'
            $document | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*schemaVersion must be integer*'
        }

        It 'UnitT41_RejectsScalarSourceSkillInventory' {
            $source = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json
            $source.skills = 'auto-update-darktide-mod'
            $source | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:SourcePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*skills must be a non-empty array*'
        }

        It 'UnitT42_RejectsMissingOrNonStringProfileDescription_<scenario>' -ForEach @(
            @{ scenario = 'blank'; value = ' ' },
            @{ scenario = 'non-string'; value = 1 }
        ) {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            $catalog.profiles[0].description = $value
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*profile identity or membership*'
        }

        It 'UnitT43_RejectsScalarCatalogArrays_<scenario>' -ForEach @(
            @{ scenario = 'profile-includes'; expected = '*profile identity or membership*' },
            @{ scenario = 'profile-excludes'; expected = '*profile identity or membership*' },
            @{ scenario = 'skill-profiles'; expected = '*identity or profile binding*' },
            @{ scenario = 'dependencies'; expected = '*dependencies must be empty*' },
            @{ scenario = 'lifecycle-aliases'; expected = '*lifecycle*' },
            @{ scenario = 'platforms'; expected = '*platform compatibility*' },
            @{ scenario = 'shells'; expected = '*platform compatibility*' },
            @{ scenario = 'required-capabilities'; expected = '*exactly one required capability*' },
            @{ scenario = 'alternative-capabilities'; expected = '*exactly two alternative capabilities*' }
        ) {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            switch ($scenario) {
                'profile-includes' { $catalog.profiles[0].includes = 'auto-update-darktide-mod' }
                'profile-excludes' { $catalog.profiles[0].excludes = '' }
                'skill-profiles' { $catalog.skills[0].profiles = 'darktide-mod-maintenance' }
                'dependencies' { $catalog.skills[0].dependencies = '' }
                'lifecycle-aliases' { $catalog.skills[0].lifecycle.aliases = '' }
                'platforms' { $catalog.skills[0].compatibility.platforms = 'windows' }
                'shells' { $catalog.skills[0].compatibility.shells = 'pwsh>=7' }
                'required-capabilities' { $catalog.skills[0].compatibility.requiredCapabilities = 'command|git|available' }
                'alternative-capabilities' { $catalog.skills[0].compatibility.anyOfCapabilities = 'connector|github|configured' }
            }
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }

        It 'UnitT44_RejectsExactCatalogIdentityDrift_<scenario>' -ForEach @(
            @{ scenario = 'source-id'; expected = '*sourceId must be exact string*' },
            @{ scenario = 'source-repository'; expected = '*source.json repository identity*' },
            @{ scenario = 'source-skills-root'; expected = '*skillsRoot must be exact string*' },
            @{ scenario = 'source-skill-id'; expected = '*Source inventory identity*' },
            @{ scenario = 'catalog-id'; expected = '*catalogId must be exact string*' },
            @{ scenario = 'catalog-source-id'; expected = '*source identity*' },
            @{ scenario = 'catalog-source-repository'; expected = '*source identity*' },
            @{ scenario = 'profile-id'; expected = '*profile identity or membership*' },
            @{ scenario = 'skill-id'; expected = '*identity or profile binding*' },
            @{ scenario = 'skill-group'; expected = '*identity or profile binding*' },
            @{ scenario = 'skill-source-id'; expected = '*source binding*' },
            @{ scenario = 'platform'; expected = '*platform compatibility*' },
            @{ scenario = 'shell'; expected = '*platform compatibility*' }
        ) {
            if ($scenario -like 'source-*') {
                $source = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json
                switch ($scenario) {
                    'source-id' { $source.sourceId = 'other' }
                    'source-repository' { $source.repository = 'https://example.invalid/repository.git' }
                    'source-skills-root' { $source.skillsRoot = 'other' }
                    'source-skill-id' { $source.skills = @('other-skill') }
                }
                $source | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:SourcePath -Encoding utf8NoBOM -NoNewline
            }
            else {
                $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
                switch ($scenario) {
                    'catalog-id' { $catalog.catalogId = 'other' }
                    'catalog-source-id' { $catalog.sources[0].id = 'other' }
                    'catalog-source-repository' { $catalog.sources[0].repository = 'https://example.invalid/repository.git' }
                    'profile-id' { $catalog.profiles[0].id = 'other' }
                    'skill-id' { $catalog.skills[0].id = 'other' }
                    'skill-group' { $catalog.skills[0].group = 'other' }
                    'skill-source-id' { $catalog.skills[0].source.sourceId = 'other' }
                    'platform' { $catalog.skills[0].compatibility.platforms = @('linux') }
                    'shell' { $catalog.skills[0].compatibility.shells = @('powershell') }
                }
                $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            }
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }

        It 'UnitT45_RejectsCatalogCardinalityAndDependencyDrift_<scenario>' -ForEach @(
            @{ scenario = 'sources'; expected = '*exactly one source*' },
            @{ scenario = 'profiles'; expected = '*exactly one profile*' },
            @{ scenario = 'skills'; expected = '*exactly one Skill*' },
            @{ scenario = 'dependencies'; expected = '*dependencies must be empty*' }
        ) {
            $catalog = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
            switch ($scenario) {
                'sources' { $catalog.sources = @() }
                'profiles' { $catalog.profiles = @() }
                'skills' { $catalog.skills = @() }
                'dependencies' { $catalog.skills[0].dependencies = @('other-skill') }
            }
            $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ProfilePath -Encoding utf8NoBOM -NoNewline
            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }
    }
}
