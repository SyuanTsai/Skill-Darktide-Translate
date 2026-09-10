# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Darktide Translate Standard v1 repository contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Layout = Get-TestRepositoryLayout -RepositoryRoot $script:RepositoryRoot
        $script:ValidatorArguments = if ($script:Layout.Name -ceq 'legacy') { @{ BootstrapTransition = $true } } else { @{} }
    }

    BeforeEach {
        $script:FixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FixtureRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination $script:FixtureRoot -Recurse
        if ($script:Layout.Name -ceq 'legacy') {
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot '.agents') -Destination $script:FixtureRoot -Recurse
        }
        else {
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config') -Destination $script:FixtureRoot -Recurse
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination $script:FixtureRoot -Recurse
        }
        & $script:GitPath -C $script:FixtureRoot init --quiet
        $stagePaths = if ($script:Layout.Name -ceq 'legacy') { @('catalog/skills-catalog.json', '.agents/skills') } else { @('catalog/source.json', 'config', 'skills') }
        & $script:GitPath -C $script:FixtureRoot add -- @stagePaths
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the repository contract fixture.' }
        $script:SkillId = 'auto-update-darktide-mod'
        $script:SkillPath = if ($script:Layout.Name -ceq 'legacy') { '.agents/skills/auto-update-darktide-mod' } else { 'skills/auto-update-darktide-mod' }
        $script:SkillRoot = Join-Path $script:FixtureRoot $script:SkillPath
    }

    # Scenario: The active repository layout supplies its catalog and one canonical Skill package.
    # Purpose: Accept the matching Bootstrap or Standard v1 inventory without conflating the two contracts.
    It 'UnitT10_ValidatesTheActiveLayoutInventoryAndSkillPackage' {
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw
    }

    # Scenario: Trusted Git and stat paths are omitted, blank, or explicitly missing.
    # Purpose: Discover only omitted paths and reject an invalid explicit trusted executable.
    It 'UnitT20_ResolvesBlankTrustedExecutableInputsAndRejectsExplicitMissingPaths' {
        # Scenario: Optional trusted tool inputs are blank, then an explicit path is missing.
        # Purpose: Allow only omitted values to use trusted discovery; never silently replace an invalid explicit path.
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments -TrustedGitPath ' ' -TrustedStatPath ' ' } | Should -Not -Throw
        $missingGitPath = Join-Path $TestDrive 'missing-trusted-git.exe'
        $thrown = $null
        try { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments -TrustedGitPath $missingGitPath }
        catch { $thrown = $_.Exception }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Message | Should -Match 'Trusted Git executable'
    }

    # Scenario: The same staged Skill package is validated twice.
    # Purpose: Keep the package content identity stable across equivalent runs.
    It 'UnitT25_ProducesDeterministicPerSkillContentHashes' {
        $first = & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments | Select-Object -Last 1 | ConvertFrom-Json
        $second = & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments | Select-Object -Last 1 | ConvertFrom-Json
        $first.skills[0].contentSha256 | Should -Be $second.skills[0].contentSha256
        $first.skills[0].contentSha256 | Should -Match '^[0-9a-f]{64}$'
    }

    # Scenario: A package file is read through Git normalization and directly from the working tree.
    # Purpose: Preserve raw byte identity independently of Git filter behavior.
    It 'UnitT30_RecordsRawWorkingTreeByteIdentities' {
        $result = & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments | Select-Object -Last 1 | ConvertFrom-Json
        $file = @($result.skills[0].files | Where-Object path -CEq 'SKILL.md')[0]
        $file.rawSha256 | Should -Match '^[0-9a-f]{64}$'
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validator | Should -Match 'function Get-RawFileSha256'
        $supervisor = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        $supervisor | Should -Match 'function Assert-SkillInventoryUnchanged'
        $supervisor | Should -Match 'rawSha256'
        $supervisor | Should -Match 'core\.worktree'
    }

    # Scenario: A staged Skill file changes only its Git executable mode.
    # Purpose: Include Git mode metadata in the per-Skill content identity.
    It 'UnitT35_BindsGitFileModesIntoContentIdentity' {
        $before = & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments | Select-Object -Last 1 | ConvertFrom-Json
        & $script:GitPath -C $script:FixtureRoot update-index --chmod=+x -- "$($script:SkillPath)/SKILL.md"
        if ($LASTEXITCODE -ne 0) { throw 'Could not change the fixture Git mode.' }
        $after = & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments | Select-Object -Last 1 | ConvertFrom-Json
        $beforeFile = @($before.skills | Where-Object skillId -CEq $script:SkillId)[0].files | Where-Object path -CEq 'SKILL.md'
        $afterFile = @($after.skills | Where-Object skillId -CEq $script:SkillId)[0].files | Where-Object path -CEq 'SKILL.md'
        $beforeFile.mode | Should -Be '100644'
        $afterFile.mode | Should -Be '100755'
        $before.skills[0].contentSha256 | Should -Not -Be $after.skills[0].contentSha256
    }

    # Scenario: A staged package resource has a non-ASCII path.
    # Purpose: Parse Git index paths without lossy delimiter or encoding behavior.
    It 'UnitT40_ReadsNonAsciiPathsFromNulDelimitedGitIndex' {
        $unicodePath = Join-Path $script:SkillRoot 'references/使用.md'
        New-Item -ItemType Directory -Path (Split-Path -Parent $unicodePath) -Force | Out-Null
        Set-Content -LiteralPath $unicodePath -Value '# Unicode reference' -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- "$($script:SkillPath)/references/使用.md"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the Unicode fixture path.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw
    }

    # Scenario: The active skills root gains a directory absent from its source inventory.
    # Purpose: Require the discovered package inventory to match the declared layout inventory.
    It 'UnitT45_RejectsAnUnlistedSkillDirectory' {
        $unlistedPath = if ($script:Layout.Name -ceq 'legacy') { '.agents/skills/unlisted-skill' } else { 'skills/unlisted-skill' }
        New-Item -ItemType Directory -Path (Join-Path $script:FixtureRoot $unlistedPath) | Out-Null
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*inventory does not exactly match*'
    }

    # Scenario: A discoverable Skill exists outside the active layout inventory.
    # Purpose: Reject unlisted publisher packages in either Bootstrap or Standard v1 discovery shape.
    It 'UnitT50_RejectsPublisherDiscoverableSkillsOutsideTheActiveInventory' {
        if ($script:Layout.Name -ceq 'legacy') {
            $rogue = Join-Path $script:FixtureRoot '.agents/skills/rogue'
            New-Item -ItemType Directory -Path $rogue -Force | Out-Null
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*inventory does not exactly match*'
            return
        }
        foreach ($relativePath in @(
            'rogue/SKILL.md',
            'docs/skills/rogue/SKILL.md',
            'docs/skills/acme/rogue/SKILL.md',
            'plugins/scope/skills/rogue/SKILL.md'
        )) {
            $roguePath = Join-Path $script:FixtureRoot ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Path (Split-Path -Parent $roguePath) -Force | Out-Null
            Set-Content -LiteralPath $roguePath -Value '# unlisted publisher package' -Encoding utf8NoBOM -NoNewline
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*Publisher-discoverable Skill inventory*'
        }
    }

    # Scenario: The active skills root contains a file that is not a Skill package.
    # Purpose: Require the source root to contain only ordinary package directories.
    It 'UnitT55_RejectsNonPackageContentAtTheActiveSkillsRoot' {
        $nonPackagePath = if ($script:Layout.Name -ceq 'legacy') { '.agents/skills/ignored.ps1' } else { 'skills/ignored.ps1' }
        Set-Content -LiteralPath (Join-Path $script:FixtureRoot $nonPackagePath) -Value 'Write-Output unsafe'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*non-package or reparse entry*'
    }

    # Scenario: A legacy fixture gains Standard v1 markers or a Standard fixture gains an unbound consumer projection.
    # Purpose: Keep Bootstrap pre-promotion and Standard managed-projection contracts distinct.
    It 'UnitT60_RejectsLayoutSpecificUnboundOrPromotedProjection' {
        if ($script:Layout.Name -ceq 'legacy') {
            $adapterPath = Join-Path $script:FixtureRoot 'config/standard-v1.json'
            New-Item -ItemType Directory -Path (Split-Path -Parent $adapterPath) -Force | Out-Null
            Set-Content -LiteralPath $adapterPath -Value '{}' -Encoding utf8NoBOM -NoNewline
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*Bootstrap transition is valid only before*'
            return
        }
        New-Item -ItemType Directory -Path (Join-Path $script:FixtureRoot '.agents/skills/unbound-skill') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FixtureRoot '.agents/skills/unbound-skill/SKILL.md') -Value 'unbound'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*Required JSON file is missing*ai-instructions.manifest.json*'

        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validator | Should -Match 'Get-ChildItem -LiteralPath \$Root -Recurse -Force'
        $validator | Should -Match 'function Get-ManagedProjectionSnapshot'
        $validator | Should -Match '\$projectionSnapshotAfterHash\s*=\s*@\('
        $validator | Should -Match 'Assert-ManagedProjectionSnapshotUnchanged'
        $validator | Should -Match '\$projectionSnapshotAfterFinalHash\s*=\s*@\('
        $validator | Should -Match 'Managed \.agents/skills projection contains a reparse entry'
    }

    # Scenario: The active catalog or source metadata has an obsolete schema or unexpected property.
    # Purpose: Reject metadata outside the exact layout-specific property contract.
    It 'UnitT65_RejectsInvalidActiveLayoutSourceMetadata' {
        $sourcePath = Join-Path $script:FixtureRoot $(if ($script:Layout.Name -ceq 'legacy') { 'catalog/skills-catalog.json' } else { 'catalog/source.json' })
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
        $source.schemaVersion = 1
        if ($script:Layout.Name -ceq 'legacy') { $source | Add-Member -NotePropertyName unexpected -NotePropertyValue @() }
        else { $source | Add-Member -NotePropertyName profiles -NotePropertyValue @() }
        $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*invalid property set*'
    }

    # Scenario: The active inventory repeats a JSON property before parsing.
    # Purpose: Reject ambiguous source metadata before object materialization.
    It 'UnitT70_RejectsDuplicateJsonPropertiesBeforeMaterialization' {
        $sourcePath = Join-Path $script:FixtureRoot $(if ($script:Layout.Name -ceq 'legacy') { 'catalog/skills-catalog.json' } else { 'catalog/source.json' })
        $text = Get-Content -LiteralPath $sourcePath -Raw
        $text = if ($script:Layout.Name -ceq 'legacy') { $text -replace '"catalogId": "darktide-translate",', '"catalogId": "darktide-translate", "catalogId": "other",' } else { $text -replace '"sourceId": "darktide-translate",', '"sourceId": "darktide-translate", "sourceId": "other",' }
        Set-Content -LiteralPath $sourcePath -Value $text -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*duplicate JSON property*'
    }

    # Scenario: A fixture introduces a local security policy marker in the active layout.
    # Purpose: Reject Standard v1 policy forks and Bootstrap promotion markers.
    It 'UnitT75_RejectsLayoutSpecificLocalSecurityPolicyForks' {
        if ($script:Layout.Name -ceq 'legacy') {
            $adapterPath = Join-Path $script:FixtureRoot 'config/standard-v1.json'
            New-Item -ItemType Directory -Path (Split-Path -Parent $adapterPath) -Force | Out-Null
            Set-Content -LiteralPath $adapterPath -Value '{"security":{}}' -Encoding utf8NoBOM -NoNewline
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*Bootstrap transition is valid only before*'
            return
        }
        $adapterPath = Join-Path $script:FixtureRoot 'config/standard-v1.json'
        $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
        $adapter | Add-Member -NotePropertyName security -NotePropertyValue ([pscustomobject]@{ blockSeverities = @('critical', 'high') })
        $adapter | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $adapterPath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*invalid property set*'
    }

    # Scenario: The active inventory has duplicate Bootstrap entries or reversed Standard v1 entries.
    # Purpose: Enforce the active layout's exact one-package and ordering contract.
    It 'UnitT80_RejectsInvalidLayoutSpecificSourceInventoryOrder' {
        if ($script:Layout.Name -ceq 'legacy') {
            $catalogPath = Join-Path $script:FixtureRoot 'catalog/skills-catalog.json'
            $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
            $catalog.skills += $catalog.skills[0]
            $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $catalogPath -Encoding utf8NoBOM
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*exactly one Skill*'
            return
        }
        $sourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
        if (@($source.skills).Count -lt 2) {
            # Keep the full repository gate skip-free. A single-item inventory
            # is already its own ordinally sorted sequence.
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw
            return
        }
        [array]::Reverse($source.skills)
        $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*ordinal ascending order*'
    }

    # Scenario: A package file exists in the working tree but not in the Git index.
    # Purpose: Bind the integrity inventory to tracked content only.
    It 'UnitT85_RejectsUntrackedPackageContent' {
        Set-Content -LiteralPath (Join-Path $script:SkillRoot 'untracked.txt') -Value 'not indexed'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*filesystem inventory does not match the Git index*'
    }

    # Scenario: A tracked package file changes after it is staged.
    # Purpose: Reject working-tree bytes that no longer match their Git index entry.
    It 'UnitT90_RejectsUnstagedPackageBytes' {
        Add-Content -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md') -Value ([Environment]::NewLine + 'Additional valid body text.')
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*working-tree content is not bound*'
    }

    It 'UnitT92_AppliesLayoutSpecificOpenAiMetadataLexicalPolicy' {
        # Scenario: A metadata key uses a quoted YAML mapping form.
        # Purpose: Standard v1 rejects the lexical form itself; Bootstrap enforces
        # the required display-name binding that the altered key no longer satisfies.
        $metadataPath = Join-Path $script:SkillRoot 'agents/openai.yaml'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw
        $metadata = $metadata -replace 'display_name: "Auto Update Darktide MOD"', '"display_name": "Auto Update Darktide MOD"'
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
        if ($script:Layout.Name -ceq 'standard-v1') {
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*quoted mapping key*'
            return
        }
        & $script:GitPath -C $script:FixtureRoot add -- "$($script:SkillPath)/agents/openai.yaml"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the Bootstrap metadata lexical fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw "*Bootstrap agents/openai.yaml display_name is invalid for '$($script:SkillId)'.*"
    }

    It 'UnitT94_AppliesLayoutSpecificMetadataCommentPolicy' {
        # Scenario: Metadata contains a comment outside the SPDX header.
        # Purpose: Standard v1 rejects unsupported YAML syntax, while Bootstrap
        # accepts a staged ordinary comment because its transition contract binds
        # only the required metadata fields.
        Add-Content -LiteralPath (Join-Path $script:SkillRoot 'agents/openai.yaml') -Value '# unsupported comment'
        if ($script:Layout.Name -ceq 'standard-v1') {
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*unsupported or malformed syntax*'
            return
        }
        & $script:GitPath -C $script:FixtureRoot add -- "$($script:SkillPath)/agents/openai.yaml"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the Bootstrap metadata comment fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw
    }

    # Scenario: A Skill frontmatter document includes the optional license field.
    # Purpose: Accept the optional field within the restricted frontmatter grammar.
    It 'UnitT96_AcceptsAllowedOptionalLicenseFrontmatter' {
        $skillPath = Join-Path $script:SkillRoot 'SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw
        $lines = [Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]]($skill.Replace([Environment]::NewLine, ([string][char]10)).Split([char]10)))
        $descriptionIndex = 0
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index].StartsWith('description:', [StringComparison]::Ordinal)) { $descriptionIndex = $index; break }
        }
        $lines.Insert($descriptionIndex + 1, 'license: Apache-2.0')
        $skill = $lines -join [Environment]::NewLine
        Set-Content -LiteralPath $skillPath -Value $skill -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- "$($script:SkillPath)/SKILL.md"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the optional license fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw
    }

    # Scenario: A Skill frontmatter document includes an allowed-tools value.
    # Purpose: Accept the permitted non-empty optional tool declaration.
    It 'UnitT97_AcceptsAllowedOptionalAllowedToolsFrontmatter' {
        $skillPath = Join-Path $script:SkillRoot 'SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw
        $skill = [regex]::Replace($skill, '(?m)^allowed-tools:.*\r?\n', '')
        $lines = [Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]]($skill.Replace([Environment]::NewLine, ([string][char]10)).Split([char]10)))
        $descriptionIndex = 0
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index].StartsWith('description:', [StringComparison]::Ordinal)) { $descriptionIndex = $index; break }
        }
        $lines.Insert($descriptionIndex + 1, 'allowed-tools: "git pwsh"')
        $skill = $lines -join [Environment]::NewLine
        Set-Content -LiteralPath $skillPath -Value $skill -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- "$($script:SkillPath)/SKILL.md"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the optional allowed-tools fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw
    }

    It 'UnitT98_AppliesLayoutSpecificOptionalOpenAiInterfaceFieldPolicy' {
        # Scenario: Metadata contains a malformed optional color and an unsafe optional icon path.
        # Purpose: Standard v1 validates optional interface fields; Bootstrap
        # accepts staged optional fields because they are outside its transition metadata binding.
        $metadataPath = Join-Path $script:SkillRoot 'agents/openai.yaml'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw
        $metadata = $metadata -replace '  default_prompt:', ('  brand_color: "not-a-color"' + [Environment]::NewLine + '  default_prompt:')
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
        if ($script:Layout.Name -ceq 'standard-v1') {
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*brand_color*hexadecimal*'

            $metadata = Get-Content -LiteralPath $metadataPath -Raw
            $metadata = $metadata -replace ('  brand_color: "not-a-color"' + [Environment]::NewLine), ''
            $metadata = $metadata -replace '  default_prompt:', ('  icon_small: "./assets/../../outside.svg"' + [Environment]::NewLine + '  default_prompt:')
            Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
            { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Throw '*unsafe asset path*'
            return
        }

        & $script:GitPath -C $script:FixtureRoot add -- "$($script:SkillPath)/agents/openai.yaml"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the Bootstrap metadata color fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw

        $metadata = Get-Content -LiteralPath $metadataPath -Raw
        $metadata = $metadata -replace ('  brand_color: "not-a-color"' + [Environment]::NewLine), ''
        $metadata = $metadata -replace '  default_prompt:', ('  icon_small: "./assets/../../outside.svg"' + [Environment]::NewLine + '  default_prompt:')
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- "$($script:SkillPath)/agents/openai.yaml"
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the Bootstrap metadata icon fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot @script:ValidatorArguments } | Should -Not -Throw
    }
}
