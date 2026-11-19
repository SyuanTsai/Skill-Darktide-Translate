# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide consumer repository check' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryCheck = Join-Path $script:RepositoryRoot 'scripts/Test-DarktideRepository.ps1'

        function Get-DarktideTestSnapshot {
            param([Parameter(Mandatory)][string] $Root)

            @(
                Get-ChildItem -LiteralPath $Root -Recurse -Force |
                    Where-Object {
                        $relative = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
                        $relative -cne '.git' -and -not $relative.StartsWith('.git/', [StringComparison]::Ordinal)
                    } |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            path = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
                            isContainer = [bool]$_.PSIsContainer
                            length = if ($_.PSIsContainer) { 0 } else { [int64]$_.Length }
                            sha256 = if ($_.PSIsContainer) { $null } else {
                                (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                            }
                        }
                    } |
                    Sort-Object -Property path -CaseSensitive
            )
        }

        function New-DarktideGitlessSnapshot {
            param(
                [Parameter(Mandatory)][string] $Destination,
                [switch] $ConsumerLayout
            )

            [void](New-Item -ItemType Directory -Path $Destination)
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination $Destination -Recurse
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination $Destination -Recurse
            if ($ConsumerLayout) {
                $configRoot = Join-Path $Destination 'config'
                [void](New-Item -ItemType Directory -Path $configRoot)
                $authorityPin = [ordered]@{
                    schemaVersion = 1
                    repository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
                    commit = 'a' * 40
                }
                $consumerGate = [ordered]@{
                    schemaVersion = 1
                    repositoryId = 'skill-darktide-translate'
                    sourceRepository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
                    activeSkills = @('auto-update-darktide-mod')
                    repositoryChecks = @(
                        [ordered]@{ id = 'repository-darktide'; kind = 'general'; path = 'scripts/Test-DarktideRepository.ps1' },
                        [ordered]@{ id = 'repository-pester'; kind = 'pester'; path = 'tests' }
                    )
                }
                [IO.File]::WriteAllText(
                    (Join-Path $configRoot 'authority-pin.json'),
                    ($authorityPin | ConvertTo-Json -Depth 10),
                    [Text.UTF8Encoding]::new($false)
                )
                [IO.File]::WriteAllText(
                    (Join-Path $configRoot 'consumer-gate.json'),
                    ($consumerGate | ConvertTo-Json -Depth 10),
                    [Text.UTF8Encoding]::new($false)
                )
            }
            [IO.Path]::GetFullPath($Destination)
        }
    }

    It 'UnitT10_DeclaresTheGeneralCheckInterfaceWithoutWindowsOnlyDependencies' {
        $source = Get-Content -LiteralPath $script:RepositoryCheck -Raw
        $source | Should -Match '\[string\]\s+\$RepositoryRoot'
        $source | Should -Match '\[switch\]\s+\$ReadOnlySnapshot'
        $source | Should -Not -Match '(?i)pwsh\.exe|icacls|kernel32|advapi32|DllImport|Add-Type'
    }

    It 'InterT20_ValidatesTheTrackedRepositoryAsAReadOnlySnapshot' {
        $before = @(Get-DarktideTestSnapshot -Root $script:RepositoryRoot)
        $powerShell = Get-TestPowerShellExecutablePath
        $output = @(& $powerShell -NoProfile -NonInteractive -File $script:RepositoryCheck `
                -RepositoryRoot $script:RepositoryRoot -ReadOnlySnapshot)
        $LASTEXITCODE | Should -Be 0
        $evidence = $output[-1] | ConvertFrom-TestJson
        $evidence.schemaVersion | Should -Be 1
        $evidence.report | Should -Be 'darktide-repository-check-v1'
        $evidence.result | Should -Be 'passed'
        $expectedInventoryMode = if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.git')) {
            'git'
        }
        else {
            'snapshot'
        }
        $evidence.inventoryMode | Should -Be $expectedInventoryMode
        $evidence.activeSkillCount | Should -Be 1
        @($evidence.skills[0].files).Count | Should -BeGreaterThan 0
        $after = @(Get-DarktideTestSnapshot -Root $script:RepositoryRoot)
        ($after | ConvertTo-Json -Depth 5 -Compress) |
            Should -BeExactly ($before | ConvertTo-Json -Depth 5 -Compress)
    }

    It 'UnitT30_RejectsOutputMutationInReadOnlySnapshotMode' {
        { & $script:RepositoryCheck -RepositoryRoot $script:RepositoryRoot -ReadOnlySnapshot `
                -OutputPath (Join-Path $TestDrive 'forbidden.json') } |
            Should -Throw '*does not permit an output file*'
    }

    Context 'git-less snapshot inventory' {
        It 'InterT31_ValidatesPreConversionAndConsumerSnapshotsWithoutGitMetadata_<layout>' -ForEach @(
            @{ layout = 'pre-conversion'; consumer = $false },
            @{ layout = 'consumer'; consumer = $true }
        ) {
            $snapshot = New-DarktideGitlessSnapshot -Destination (Join-Path $TestDrive $layout) -ConsumerLayout:$consumer

            $powerShell = Get-TestPowerShellExecutablePath
            $output = @(& $powerShell -NoProfile -NonInteractive -File $script:RepositoryCheck `
                    -RepositoryRoot $snapshot -ReadOnlySnapshot)
            $LASTEXITCODE | Should -Be 0
            $evidence = $output[-1] | ConvertFrom-TestJson

            $evidence.schemaVersion | Should -Be 1
            $evidence.report | Should -Be 'darktide-repository-check-v1'
            $evidence.result | Should -Be 'passed'
            $evidence.layout | Should -Be $layout
            $evidence.inventoryMode | Should -Be 'snapshot'
            $evidence.activeSkillCount | Should -Be 1
            @($evidence.skills[0].files).Count | Should -BeGreaterThan 0
        }

        It 'UnitT32_RejectsCatalogIdentityDriftInASnapshot' {
            $snapshot = New-DarktideGitlessSnapshot -Destination (Join-Path $TestDrive 'catalog-drift')
            $sourcePath = Join-Path $snapshot 'catalog/source.json'
            $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
            $source.sourceId = 'other-source'
            $source | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM -NoNewline

            { & $script:RepositoryCheck -RepositoryRoot $snapshot -ReadOnlySnapshot } |
                Should -Throw '*sourceId must be exact string*'
        }

        It 'UnitT33_RejectsInvalidUtf8SkillBytesInASnapshot' {
            $snapshot = New-DarktideGitlessSnapshot -Destination (Join-Path $TestDrive 'invalid-utf8')
            $invalidPath = Join-Path $snapshot 'skills/auto-update-darktide-mod/references/invalid.md'
            [IO.File]::WriteAllBytes($invalidPath, [byte[]]@(0xC3, 0x28))

            { & $script:RepositoryCheck -RepositoryRoot $snapshot -ReadOnlySnapshot } |
                Should -Throw
        }

        It 'UnitT34_RejectsPresentButInvalidGitMetadata' {
            $snapshot = New-DarktideGitlessSnapshot -Destination (Join-Path $TestDrive 'invalid-git')
            [void](New-Item -ItemType Directory -Path (Join-Path $snapshot '.git'))

            { & $script:RepositoryCheck -RepositoryRoot $snapshot -ReadOnlySnapshot } |
                Should -Throw '*contains .git but is not a valid Git repository root*'
        }

        It 'InterT35_ValidatesASnapshotWithoutGitOnPath' {
            $snapshot = New-DarktideGitlessSnapshot -Destination (Join-Path $TestDrive 'no-git-command')
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = Get-TestPowerShellExecutablePath
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @(
                    '-NoProfile', '-NonInteractive', '-File', $script:RepositoryCheck,
                    '-RepositoryRoot', $snapshot, '-ReadOnlySnapshot'
                )) {
                [void]$start.ArgumentList.Add($argument)
            }
            $start.Environment['PATH'] = ''
            $process = [Diagnostics.Process]::new()
            try {
                $process.StartInfo = $start
                [void]$process.Start()
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                $standardOutput = $stdout.GetAwaiter().GetResult()
                $standardError = $stderr.GetAwaiter().GetResult()
                $process.ExitCode | Should -Be 0 -Because $standardError
                ($standardOutput | ConvertFrom-TestJson).inventoryMode | Should -Be 'snapshot'
            }
            finally {
                $process.Dispose()
            }
        }

        if ([OperatingSystem]::IsWindows()) {
            It 'InterT36W_RejectsANativeWindowsReparseDirectoryInASnapshot' {
                $snapshot = New-DarktideGitlessSnapshot -Destination (Join-Path $TestDrive 'windows-reparse')
                $target = Join-Path $TestDrive 'windows-reparse-target'
                [void](New-Item -ItemType Directory -Path $target)
                [void](New-TestReparsePoint -Path (Join-Path $snapshot 'skills/auto-update-darktide-mod/reparse') -Target $target)

                { & $script:RepositoryCheck -RepositoryRoot $snapshot -ReadOnlySnapshot } |
                    Should -Throw '*contains a reparse point*'
            }
        }
        else {
            It 'InterT36U_RejectsANativeUnixSymlinkDirectoryInASnapshot' {
                $snapshot = New-DarktideGitlessSnapshot -Destination (Join-Path $TestDrive 'unix-reparse')
                $target = Join-Path $TestDrive 'unix-reparse-target'
                [void](New-Item -ItemType Directory -Path $target)
                [void](New-TestReparsePoint -Path (Join-Path $snapshot 'skills/auto-update-darktide-mod/reparse') -Target $target)

                { & $script:RepositoryCheck -RepositoryRoot $snapshot -ReadOnlySnapshot } |
                    Should -Throw '*contains a reparse point*'
            }
        }
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
            $script:SkillsRoot = Join-Path $script:FixtureRoot 'skills'
            $script:SkillRoot = Join-Path $script:SkillsRoot 'auto-update-darktide-mod'
            $script:SkillPath = Join-Path $script:SkillRoot 'SKILL.md'
            $script:MetadataPath = Join-Path $script:SkillRoot 'agents/openai.yaml'
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

        It 'UnitT46_RejectsMixedLegacyAndStandardCatalogs' {
            $legacyCatalogPath = Join-Path $script:FixtureRoot 'catalog/skills-catalog.json'
            [IO.File]::WriteAllText($legacyCatalogPath, '{}', [Text.UTF8Encoding]::new($false))

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } |
                Should -Throw '*Legacy source-owned cross-source catalog must not coexist with catalog/source.json*'
        }

        It 'UnitT47_RejectsNonPackageEntriesAtTheSkillsRoot' {
            [IO.File]::WriteAllText(
                (Join-Path $script:SkillsRoot 'README.md'),
                'not a package',
                [Text.UTF8Encoding]::new($false)
            )

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } |
                Should -Throw '*Source Skill root contains a non-package or reparse entry*'
        }

        It 'UnitT48_RejectsInvalidStructuredSkillFrontmatter_<scenario>' -ForEach @(
            @{ scenario = 'duplicate-key'; mutation = 'duplicate'; expected = '*unsupported or duplicate frontmatter key*' },
            @{ scenario = 'unsupported-key'; mutation = 'unsupported'; expected = '*unsupported or duplicate frontmatter key*' },
            @{ scenario = 'implicit-type'; mutation = 'implicit'; expected = '*must be a YAML string scalar*' },
            @{ scenario = 'invalid-double-quoted-string'; mutation = 'double-quoted'; expected = '*invalid double-quoted YAML string*' },
            @{ scenario = 'invalid-single-quoted-string'; mutation = 'single-quoted'; expected = '*invalid single-quoted YAML string*' },
            @{ scenario = 'missing-required-key'; mutation = 'missing'; expected = '*must define name and description*' },
            @{ scenario = 'wrong-name'; mutation = 'identity'; expected = '*does not match package*' },
            @{ scenario = 'malformed-syntax'; mutation = 'syntax'; expected = '*unsupported or malformed frontmatter syntax*' },
            @{ scenario = 'invalid-description'; mutation = 'description'; expected = '*violates the Standard v1 text contract*' },
            @{ scenario = 'empty-allowed-tools'; mutation = 'allowed-tools'; expected = '*must be a non-empty string*' },
            @{ scenario = 'unclosed-frontmatter'; mutation = 'unclosed'; expected = '*closed YAML frontmatter*' },
            @{ scenario = 'empty-body'; mutation = 'body'; expected = '*non-empty Markdown body*' }
        ) {
            $text = (Get-Content -LiteralPath $script:SkillPath -Raw).Replace("`r`n", "`n")
            switch ($mutation) {
                'duplicate' { $text = $text.Replace("name: auto-update-darktide-mod`n", "name: auto-update-darktide-mod`nname: auto-update-darktide-mod`n") }
                'unsupported' { $text = $text.Replace("name: auto-update-darktide-mod`n", "name: auto-update-darktide-mod`nversion: `"1`"`n") }
                'implicit' { $text = $text -replace '(?m)^allowed-tools:.*$', 'allowed-tools: true' }
                'double-quoted' { $text = $text -replace '(?m)^allowed-tools:.*$', 'allowed-tools: "\q"' }
                'single-quoted' { $text = $text -replace '(?m)^allowed-tools:.*$', "allowed-tools: 'unterminated" }
                'missing' { $text = $text -replace '(?m)^description:.*\n', '' }
                'identity' { $text = $text.Replace('name: auto-update-darktide-mod', 'name: other-skill') }
                'syntax' { $text = $text.Replace('name: auto-update-darktide-mod', 'Name: auto-update-darktide-mod') }
                'description' { $text = $text -replace '(?m)^description:.*$', 'description: bad <tag>' }
                'allowed-tools' { $text = $text -replace '(?m)^allowed-tools:.*$', 'allowed-tools: " "' }
                'unclosed' { $text = $text.Substring(4) }
                'body' {
                    $closing = $text.IndexOf("`n---`n", 4, [StringComparison]::Ordinal)
                    $text = $text.Substring(0, $closing + 5)
                }
            }
            [IO.File]::WriteAllText($script:SkillPath, $text, [Text.UTF8Encoding]::new($false))

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }

        It 'UnitT49_RejectsInvalidOrIncompleteStructuredOpenAiMetadata_<scenario>' -ForEach @(
            @{ scenario = 'duplicate-interface-key'; mutation = 'duplicate-interface'; expected = '*unsupported or duplicate interface key*' },
            @{ scenario = 'unsupported-interface-key'; mutation = 'unsupported-interface'; expected = '*unsupported or duplicate interface key*' },
            @{ scenario = 'tab'; mutation = 'tab'; expected = '*must not contain tabs*' },
            @{ scenario = 'quoted-key'; mutation = 'quoted-key'; expected = '*contains a quoted mapping key*' },
            @{ scenario = 'invalid-quoted-string'; mutation = 'invalid-string'; expected = '*invalid quoted string*' },
            @{ scenario = 'missing-required-key'; mutation = 'missing-default'; expected = '*missing interface.default_prompt*' },
            @{ scenario = 'wrong-value-type'; mutation = 'non-string'; expected = '*unsupported or malformed syntax*' },
            @{ scenario = 'short-description-length'; mutation = 'short-description'; expected = '*25 to 64 Unicode scalar values*' },
            @{ scenario = 'unbound-default-prompt'; mutation = 'default-prompt'; expected = '*must reference exact token*' },
            @{ scenario = 'duplicate-section'; mutation = 'duplicate-section'; expected = '*unsupported or duplicate section*' },
            @{ scenario = 'empty-dependencies'; mutation = 'empty-dependencies'; expected = '*non-empty tools list*' },
            @{ scenario = 'duplicate-dependencies-tools'; mutation = 'duplicate-tools'; expected = '*duplicate dependencies.tools*' },
            @{ scenario = 'invalid-dependency-type-string'; mutation = 'dependency-type-string'; expected = '*invalid dependency type*' },
            @{ scenario = 'unsupported-dependency-key'; mutation = 'dependency-key'; expected = '*unsupported or duplicate dependency key*' },
            @{ scenario = 'invalid-dependency-string'; mutation = 'dependency-string'; expected = '*invalid dependency string*' },
            @{ scenario = 'unsupported-policy-key'; mutation = 'policy'; expected = '*must contain only allow_implicit_invocation*' },
            @{ scenario = 'duplicate-policy-key'; mutation = 'duplicate-policy'; expected = '*duplicate policy key*' },
            @{ scenario = 'invalid-dependency-contract'; mutation = 'dependency'; expected = '*must declare quoted type*' },
            @{ scenario = 'empty-dependency-description'; mutation = 'dependency-description'; expected = '*dependency.description*cannot be empty*' },
            @{ scenario = 'non-https-dependency-url'; mutation = 'dependency-url'; expected = '*must be absolute HTTPS*' },
            @{ scenario = 'non-relative-icon-path'; mutation = 'icon-relative'; expected = '*must be a relative ./assets/ path*' },
            @{ scenario = 'unsafe-icon-path'; mutation = 'icon-unsafe'; expected = '*contains an unsafe asset path*' },
            @{ scenario = 'invalid-icon-path'; mutation = 'icon'; expected = '*must identify an existing file*' },
            @{ scenario = 'invalid-brand-color'; mutation = 'brand'; expected = '*six-digit hexadecimal color*' },
            @{ scenario = 'wrong-display-name'; mutation = 'display-name'; expected = '*identity is invalid*' }
        ) {
            $text = (Get-Content -LiteralPath $script:MetadataPath -Raw).Replace("`r`n", "`n")
            switch ($mutation) {
                'duplicate-interface' { $text += "  display_name: `"Auto Update Darktide MOD`"`n" }
                'unsupported-interface' { $text += "  unsupported: `"value`"`n" }
                'tab' { $text = $text.Replace('  display_name:', "`tdisplay_name:") }
                'quoted-key' { $text += "  `"quoted`": `"value`"`n" }
                'invalid-string' { $text = $text -replace '(?m)^  display_name:.*$', '  display_name: "\q"' }
                'missing-default' { $text = $text -replace '(?m)^  default_prompt:.*\n?', '' }
                'non-string' { $text = $text -replace '(?m)^  default_prompt:.*$', '  default_prompt: true' }
                'short-description' { $text = $text -replace '(?m)^  short_description:.*$', '  short_description: "short"' }
                'default-prompt' { $text = $text.Replace('$auto-update-darktide-mod', '$other-skill') }
                'duplicate-section' { $text += "interface:`n" }
                'empty-dependencies' { $text += "dependencies:`n" }
                'duplicate-tools' { $text += "dependencies:`n  tools:`n  tools:`n" }
                'dependency-type-string' { $text += "dependencies:`n  tools:`n    - type: `"\q`"`n" }
                'dependency-key' { $text += "dependencies:`n  tools:`n    - type: `"mcp`"`n      unsupported: `"value`"`n" }
                'dependency-string' { $text += "dependencies:`n  tools:`n    - type: `"mcp`"`n      value: `"\q`"`n" }
                'policy' { $text += "policy:`n  other: true`n" }
                'duplicate-policy' { $text += "policy:`n  allow_implicit_invocation: true`n  allow_implicit_invocation: false`n" }
                'dependency' { $text += "dependencies:`n  tools:`n    - type: `"http`"`n      value: `"example`"`n" }
                'dependency-description' { $text += "dependencies:`n  tools:`n    - type: `"mcp`"`n      value: `"example`"`n      description: `"`"`n" }
                'dependency-url' { $text += "dependencies:`n  tools:`n    - type: `"mcp`"`n      value: `"example`"`n      url: `"http://example.com`"`n" }
                'icon-relative' { $text += "  icon_small: `"assets/icon.svg`"`n" }
                'icon-unsafe' { $text += "  icon_small: `"./assets/../icon.svg`"`n" }
                'icon' { $text += "  icon_small: `"./assets/missing.svg`"`n" }
                'brand' { $text += "  brand_color: `"blue`"`n" }
                'display-name' { $text = $text.Replace('"Auto Update Darktide MOD"', '"Other"') }
            }
            [IO.File]::WriteAllText($script:MetadataPath, $text, [Text.UTF8Encoding]::new($false))

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }

        It 'UnitT50_RejectsMalformedOrDuplicateProductJson_<scenario>' -ForEach @(
            @{ scenario = 'invalid-json'; mutation = 'invalid'; expected = '*JSON is invalid*' },
            @{ scenario = 'duplicate-key'; mutation = 'duplicate'; expected = '*duplicate JSON property*' },
            @{ scenario = 'missing-file'; mutation = 'missing'; expected = '*Required JSON file is missing*' }
        ) {
            switch ($mutation) {
                'invalid' { [IO.File]::WriteAllText($script:SourcePath, '{', [Text.UTF8Encoding]::new($false)) }
                'duplicate' {
                    $text = Get-Content -LiteralPath $script:SourcePath -Raw
                    $text = $text -replace '^\s*\{', '{ "schemaVersion": 2,'
                    [IO.File]::WriteAllText($script:SourcePath, $text, [Text.UTF8Encoding]::new($false))
                }
                'missing' { Remove-Item -LiteralPath $script:ProfilePath -Force }
            }

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }

        It 'UnitT51_RejectsUnexpectedProductCatalogProperties_<scenario>' -ForEach @(
            @{ scenario = 'source-root'; target = 'source-root' },
            @{ scenario = 'profile-root'; target = 'profile-root' },
            @{ scenario = 'profile-source'; target = 'profile-source' },
            @{ scenario = 'profile'; target = 'profile' },
            @{ scenario = 'skill'; target = 'skill' },
            @{ scenario = 'skill-source'; target = 'skill-source' },
            @{ scenario = 'lifecycle'; target = 'lifecycle' },
            @{ scenario = 'compatibility'; target = 'compatibility' },
            @{ scenario = 'required-capability'; target = 'required-capability' },
            @{ scenario = 'alternative-capability'; target = 'alternative-capability' }
        ) {
            if ($target -ceq 'source-root') {
                $document = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json
                $document | Add-Member -NotePropertyName unexpected -NotePropertyValue 'value'
                $path = $script:SourcePath
            }
            else {
                $document = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
                $node = switch ($target) {
                    'profile-root' { $document }
                    'profile-source' { $document.sources[0] }
                    'profile' { $document.profiles[0] }
                    'skill' { $document.skills[0] }
                    'skill-source' { $document.skills[0].source }
                    'lifecycle' { $document.skills[0].lifecycle }
                    'compatibility' { $document.skills[0].compatibility }
                    'required-capability' { $document.skills[0].compatibility.requiredCapabilities[0] }
                    'alternative-capability' { $document.skills[0].compatibility.anyOfCapabilities[0] }
                }
                $node | Add-Member -NotePropertyName unexpected -NotePropertyValue 'value'
                $path = $script:ProfilePath
            }
            $document | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM -NoNewline

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw '*invalid property set*'
        }

        It 'UnitT52_RejectsInvalidSourceSkillInventory_<scenario>' -ForEach @(
            @{ scenario = 'invalid-id'; skills = @('Invalid') ; expected = '*Invalid Skill ID*' },
            @{ scenario = 'duplicate-id'; skills = @('auto-update-darktide-mod', 'auto-update-darktide-mod'); expected = '*Duplicate Skill ID*' },
            @{ scenario = 'non-ordinal-order'; skills = @('z-skill', 'auto-update-darktide-mod'); expected = '*ordinal ascending order*' },
            @{ scenario = 'wrong-identity'; skills = @('other-skill'); expected = '*Source inventory identity is invalid*' }
        ) {
            $source = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json
            $source.skills = $skills
            $source | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:SourcePath -Encoding utf8NoBOM -NoNewline

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }

        It 'UnitT53_RejectsAdditionalPublisherDiscoverableSkills' {
            $otherRoot = Join-Path $script:FixtureRoot 'other'
            [void](New-Item -ItemType Directory -Path $otherRoot)
            [IO.File]::WriteAllText(
                (Join-Path $otherRoot 'SKILL.md'),
                "---`nname: other`ndescription: other`n---`nbody`n",
                [Text.UTF8Encoding]::new($false)
            )

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } |
                Should -Throw '*Publisher-discoverable Skill inventory is invalid*'
        }

        It 'UnitT54_RejectsIncompleteOrExtraCanonicalPackages_<scenario>' -ForEach @(
            @{ scenario = 'missing-skill-file'; mutation = 'missing-skill'; expected = '*Required Skill metadata is missing*' },
            @{ scenario = 'missing-openai-metadata'; mutation = 'missing-metadata'; expected = '*Required Skill metadata is missing*' },
            @{ scenario = 'extra-package-directory'; mutation = 'extra-package'; expected = '*Source Skill directories do not match catalog/source.json*' }
        ) {
            switch ($mutation) {
                'missing-skill' { Remove-Item -LiteralPath $script:SkillPath -Force }
                'missing-metadata' { Remove-Item -LiteralPath $script:MetadataPath -Force }
                'extra-package' { [void](New-Item -ItemType Directory -Path (Join-Path $script:SkillsRoot 'other-skill')) }
            }

            { & $script:RepositoryCheck -RepositoryRoot $script:FixtureRoot } | Should -Throw $expected
        }
    }
}
