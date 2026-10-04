# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Darktide Translate repository contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $layout = Get-TestRepositoryLayout -RepositoryRoot $repoRoot

        function New-WindowsCheckoutEvidence {
            param(
                [Parameter(Mandatory = $true)][string] $RepositoryRoot,
                [Parameter(Mandatory = $true)][string] $FixtureRoot,
                [Parameter(Mandatory = $true)][string[]] $ModulePaths
            )

            if ($ModulePaths.Count -eq 0) { throw 'The checkout evidence fixture requires at least one PowerShell module.' }
            $normalizedModulePaths = @($ModulePaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
            $attributePathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            [void]$attributePathSet.Add('.gitattributes')
            foreach ($modulePath in $normalizedModulePaths) {
                $segments = @($modulePath -split '/')
                $relativeDirectory = ''
                for ($index = 0; $index -lt $segments.Count - 1; $index++) {
                    $relativeDirectory = if ([string]::IsNullOrEmpty($relativeDirectory)) {
                        [string]$segments[$index]
                    }
                    else {
                        "$relativeDirectory/$($segments[$index])"
                    }
                    $candidateAttributePath = "$relativeDirectory/.gitattributes"
                    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $candidateAttributePath) -PathType Leaf) {
                        [void]$attributePathSet.Add($candidateAttributePath)
                    }
                }
            }
            $attributePaths = @($attributePathSet | Sort-Object)
            if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot '.gitattributes') -PathType Leaf)) {
                throw 'The checkout evidence fixture requires the repository root .gitattributes file.'
            }

            $sourceRepository = Join-Path $FixtureRoot 'windows-git-source'
            $freshCheckout = Join-Path $FixtureRoot 'windows-git-checkout'
            New-Item -ItemType Directory -Path $sourceRepository -Force | Out-Null
            foreach ($relativePath in @($attributePaths + $normalizedModulePaths | Sort-Object -Unique)) {
                $sourcePath = Join-Path $RepositoryRoot $relativePath
                $fixturePath = Join-Path $sourceRepository $relativePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $fixturePath) -Force | Out-Null
                Copy-Item -LiteralPath $sourcePath -Destination $fixturePath
            }

            & git -c core.longpaths=true -C $sourceRepository init --quiet --initial-branch=main
            if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the checkout evidence source repository.' }
            & git -c core.longpaths=true -C $sourceRepository config user.name 'EOL Contract Test'
            & git -c core.longpaths=true -C $sourceRepository config user.email 'eol-contract@example.invalid'
            & git -c core.longpaths=true -C $sourceRepository config core.autocrlf true
            & git -c core.longpaths=true -C $sourceRepository add --all
            & git -c core.longpaths=true -C $sourceRepository commit --quiet -m 'fixture LF source'
            if ($LASTEXITCODE -ne 0) { throw 'Could not commit the checkout evidence source repository.' }
            & git -c core.longpaths=true -c core.autocrlf=true clone --quiet $sourceRepository $freshCheckout
            if ($LASTEXITCODE -ne 0) { throw 'Could not clone the checkout evidence source repository.' }

            $modules = foreach ($modulePath in $normalizedModulePaths) {
                $attribute = [string]((& git -c core.longpaths=true -C $sourceRepository check-attr eol -- $modulePath) -join '')
                if ($LASTEXITCODE -ne 0) { throw "Could not resolve the effective eol attribute for '$modulePath'." }
                $sourceBlobOid = [string]((& git -c core.longpaths=true -C $sourceRepository rev-parse "HEAD:$modulePath") -join '')
                if ($LASTEXITCODE -ne 0) { throw "Could not resolve the source blob for '$modulePath'." }
                $checkoutRawOid = [string]((& git -c core.longpaths=true -C $freshCheckout hash-object --no-filters -- $modulePath) -join '')
                if ($LASTEXITCODE -ne 0) { throw "Could not hash the checkout bytes for '$modulePath'." }
                [pscustomobject][ordered]@{
                    path = $modulePath
                    attribute = $attribute.Trim()
                    sourceBlobOid = $sourceBlobOid.Trim()
                    checkoutRawOid = $checkoutRawOid.Trim()
                }
            }

            return [pscustomobject][ordered]@{
                attributePaths = @($attributePaths | Sort-Object -Unique)
                modules = @($modules)
            }
        }
    }

    # Scenario: A consumer discovers this repository through its stable catalog.
    # Purpose: Protect the source ID, repository URL, Skill path, and opt-in profile contract.
    It 'UnitT10_ExposesTheStableSourceSkillAndProfileContract' {
        $catalogPath = Join-Path $repoRoot $layout.CatalogPath
        Test-Path -LiteralPath $catalogPath | Should -Be $true

        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
        if ($layout.Name -ceq 'legacy') {
            $catalog.schemaVersion | Should -Be 1
            $catalog.catalogId | Should -Be 'darktide-translate'
            @($catalog.sources).Count | Should -Be 1
            $catalog.sources[0].id | Should -Be 'darktide-translate'
            $catalog.sources[0].repository | Should -Be 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'

            @($catalog.skills).Count | Should -Be 1
            $skill = @($catalog.skills)[0]
            $skill.id | Should -Be 'auto-update-darktide-mod'
            $skill.source.sourceId | Should -Be 'darktide-translate'
            $skill.source.path | Should -Be $layout.SkillPath
            @($skill.profiles).Count | Should -Be 1
            $skill.profiles[0] | Should -Be 'darktide-mod-maintenance'
        }
        else {
            $sourcePath = Join-Path $repoRoot $layout.SourcePath
            Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -Be $true

            $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
            $source.schemaVersion | Should -Be 2
            $source.sourceId | Should -Be 'darktide-translate'
            $source.repository | Should -Be 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
            $source.skillsRoot | Should -Be 'skills'
            @($source.skills).Count | Should -Be 1
            $source.skills[0] | Should -Be 'auto-update-darktide-mod'
            "$($source.skillsRoot)/$($source.skills[0])" | Should -Be $layout.SkillPath
        }

        @($catalog.profiles).Count | Should -Be 1
        $profile = @($catalog.profiles)[0]
        $profile.id | Should -Be 'darktide-mod-maintenance'
        $profile.default | Should -Be $false
        @($profile.includes).Count | Should -Be 1
        $profile.includes[0] | Should -Be 'auto-update-darktide-mod'
    }

    # Scenario: The repository is packaged as one independently versioned Skill source.
    # Purpose: Prevent missing metadata, tests, workflows, or release/rollback controls.
    It 'UnitT20_ContainsEveryRequiredRepositoryArtifact' {
        $skillPrefix = $layout.SkillPath
        $assetWorkflow = if ($layout.Name -ceq 'legacy') { 'assets/workflow-schema-14.md.gz' } else { 'assets/workflow-schema-14.md' }
        $assetReviewBaseline = if ($layout.Name -ceq 'legacy') { 'assets/review-baseline.md.gz' } else { 'assets/review-baseline.md' }
        $expectedPaths = @(
            "$skillPrefix/SKILL.md",
            "$skillPrefix/agents/openai.yaml",
            "$skillPrefix/references/package-binding.md",
            "$skillPrefix/$assetWorkflow",
            "$skillPrefix/$assetReviewBaseline",
            "$skillPrefix/references/source-provenance.json",
            "$skillPrefix/references/automation.md",
            "$skillPrefix/references/schema-15.md",
            "$skillPrefix/references/schema-15-provenance.json",
            "$skillPrefix/references/translation-quality.md",
            "$skillPrefix/scripts/Expand-Schema14Reference.ps1",
            "$skillPrefix/scripts/Test-ReferenceIntegrity.ps1",
            "$skillPrefix/scripts/mod-update.ps1",
            "$skillPrefix/scripts/Test-ModUpdateCandidate.ps1",
            "$skillPrefix/scripts/Receive-NexusMainFile.ps1",
            "$skillPrefix/scripts/Test-SourceReceipt.ps1",
            "$skillPrefix/scripts/Invoke-ModUpdateQueue.ps1",
            "$skillPrefix/scripts/SharedCoordinationLock.psm1",
            "$skillPrefix/scripts/LuaLocalizationScanner.psm1",
            "$skillPrefix/scripts/New-LocalizationWorkset.ps1",
            "$skillPrefix/scripts/Apply-LocalizationWorkset.ps1",
            "$skillPrefix/scripts/Test-LocalizationWorksetReceipt.ps1",
            "$skillPrefix/scripts/Finalize-LocalizationWorksetEvidence.ps1",
            "$skillPrefix/scripts/Finalize-ModUpdateMerge.ps1",
            'docs/RELEASE.md',
            'docs/ROLLBACK.md',
            'scripts/Get-SourcePin.ps1',
            'scripts/Test-CleanRepositoryHead.ps1',
            '.github/workflows/standard-v1-candidate-windows.yml',
            'scripts/Install-LatestPowerShell.ps1',
            'scripts/PowerShellRelease.psm1',
            'scripts/Test-Repository.ps1',
            'scripts/Validate.ps1',
            'tests/Invoke-Tests.ps1',
            'VERSION'
        )
        if ($layout.Name -ceq 'legacy') {
            $expectedPaths += @(
                'catalog/skills-catalog.json'
            )
        }
        else {
            $expectedPaths += @(
                'catalog/source.json',
                'catalog/profiles.json',
                'config/standard-v1.json',
                'scripts/Invoke-PrePushValidation.ps1',
                'tests/CanonicalValidation.Tests.ps1',
                'tests/StandardV1Conformance.Tests.ps1',
                'tests/Test-Repository.Tests.ps1'
            )
        }

        foreach ($path in $expectedPaths) {
            Test-Path -LiteralPath (Join-Path $repoRoot $path) | Should -Be $true
        }

        $actualSkillDirectories = @(
            Get-ChildItem -LiteralPath $layout.SkillsRoot -Directory -Force |
                ForEach-Object { [string]$_.Name } |
                Sort-Object -Unique
        )
        ($actualSkillDirectories -join "`n") | Should -Be 'auto-update-darktide-mod'
    }

    # Scenario: Windows Git checkout applies core.autocrlf while immutable Skill bytes are verified exactly.
    # Purpose: Ensure PowerShell module sources use LF so git mode and archive/download mode produce identical package bytes.
    It 'UnitT22_PreservesPowerShellModuleBytesAcrossWindowsCheckout' {
        $attributesPath = Join-Path $repoRoot '.gitattributes'
        Test-Path -LiteralPath $attributesPath | Should -Be $true
        $attributes = Get-Content -LiteralPath $attributesPath -Raw
        $attributes | Should -Match '(?m)^\*\.psm1 text eol=lf\r?$'

        $modulePaths = @(Get-ChildItem -LiteralPath $layout.SkillRoot -Recurse -File -Filter '*.psm1' |
            ForEach-Object { [IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/') })
        $modulePaths.Count | Should -BeGreaterThan 0
        foreach ($modulePath in $modulePaths) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot $modulePath))
            for ($index = 0; $index -lt $bytes.Length - 1; $index++) {
                if ($bytes[$index] -eq 13 -and $bytes[$index + 1] -eq 10) {
                    throw "PowerShell module contains CRLF bytes despite the LF contract: $modulePath"
                }
            }
        }

        $checkoutEvidence = New-WindowsCheckoutEvidence `
            -RepositoryRoot $repoRoot `
            -FixtureRoot $TestDrive `
            -ModulePaths $modulePaths
        $checkoutEvidence.attributePaths | Should -Contain '.gitattributes'
        foreach ($module in @($checkoutEvidence.modules)) {
            $module.attribute | Should -Match ': eol: lf$' -Because $module.path
            $module.checkoutRawOid | Should -Be $module.sourceBlobOid -Because $module.path
        }
    }

    # Scenario: A nested .gitattributes overrides the repository-level LF rule for one PowerShell module.
    # Purpose: Prove checkout evidence preserves nested attributes and detects bytes that would differ from the immutable Git blob.
    It 'UnitT23_DetectsNestedGitattributesOverridesThatChangeWindowsCheckoutBytes' {
        $nestedFixtureRoot = Join-Path $TestDrive 'nested-attribute-fixture'
        $nestedModuleRoot = Join-Path $nestedFixtureRoot 'skills/example/scripts'
        New-Item -ItemType Directory -Path $nestedModuleRoot -Force | Out-Null
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $nestedFixtureRoot '.gitattributes'), "*.psm1 text eol=lf`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $nestedModuleRoot '.gitattributes'), "*.psm1 text eol=crlf`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $nestedModuleRoot 'Nested.psm1'), "function Get-NestedValue { 'value' }`n", $utf8)

        $checkoutEvidence = New-WindowsCheckoutEvidence `
            -RepositoryRoot $nestedFixtureRoot `
            -FixtureRoot (Join-Path $TestDrive 'nested-attribute-evidence') `
            -ModulePaths @('skills/example/scripts/Nested.psm1')
        $module = @($checkoutEvidence.modules | Where-Object { $_.path -ceq 'skills/example/scripts/Nested.psm1' })

        $checkoutEvidence.attributePaths | Should -Contain 'skills/example/scripts/.gitattributes'
        $module.Count | Should -Be 1
        $module[0].attribute | Should -Match ': eol: crlf$'
        $module[0].checkoutRawOid | Should -Not -Be $module[0].sourceBlobOid
    }

    # Scenario: The independent source remains intentionally outside AI-Instructions fan-out.
    # Purpose: Prevent the Darktide Skill from being reintroduced into an unrelated consumer Catalog or bootstrap contract.
    It 'UnitT25_RemainsAnIndependentRepositorySource' {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw

        $readme | Should -Match 'not added to the AI-Instructions Catalog, Lock, bootstrap, or fan-out'
        if ($layout.Name -ceq 'legacy') {
            $catalog = Get-Content -LiteralPath (Join-Path $repoRoot $layout.CatalogPath) -Raw | ConvertFrom-Json
            @($catalog.sources).Count | Should -Be 1
            $catalog.sources[0].id | Should -Be 'darktide-translate'
        }
        else {
            $source = Get-Content -LiteralPath (Join-Path $repoRoot $layout.SourcePath) -Raw | ConvertFrom-Json
            $source.sourceId | Should -Be 'darktide-translate'
            @($source.skills).Count | Should -Be 1
            $source.skills[0] | Should -Be 'auto-update-darktide-mod'
        }
    }

    # Scenario: A release process resolves the repository version before pin generation.
    # Purpose: Keep source pins compatible with the shared SemVer contract.
    It 'UnitT30_UsesASemVerCompatibleRepositoryVersion' {
        $versionPath = Join-Path $repoRoot 'VERSION'
        Test-Path -LiteralPath $versionPath | Should -Be $true
        $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
        $version | Should -Match '^\d+\.\d+\.\d+$'
    }

    # Scenario: A release bumps VERSION while the Nexus API download client remains part of the packaged Skill.
    # Purpose: Keep the outbound User-Agent aligned with the immutable repository version for traceable client identity.
    It 'UnitT35_UsesTheRepositoryVersionInTheNexusClientUserAgent' {
        $version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
        $receiverPath = Join-Path $repoRoot "$($layout.SkillPath)/scripts/Receive-NexusMainFile.ps1"
        $receiver = Get-Content -LiteralPath $receiverPath -Raw

        $userAgentMatches = @([regex]::Matches(
            $receiver,
            "UserAgent\.ParseAdd\('Skill-Darktide-Translate/(?<version>[^']+)'\)"
        ))
        $userAgentMatches.Count | Should -Be 1
        $userAgentMatches[0].Groups['version'].Value | Should -Be $version
    }

    # Scenario: A legacy bootstrap snapshot validates the migration against its pinned central authority.
    # Purpose: Prevent a migration from retaining a stale authority pin that rejects the candidate before validation.
    It 'UnitT44_BindsTheBootstrapSupervisorToTheCurrentAuthoritySnapshot' {
        if ($layout.Name -ceq 'legacy') {
            $validator = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Validate.ps1') -Raw

            $validator | Should -Match ([regex]::Escape("`$approvedAuthorityCommit = 'a403abdf038a3346d775431a6908a71cc3d35a5b'"))
            $validator | Should -Match ([regex]::Escape("`$approvedAuthorityArchiveSha256 = '17154929fadfa63487263db1efcb78f4948195af9c11c25a66432eff3411b2d3'"))
            $validator | Should -Not -Match ([regex]::Escape('d38eba3faf967504751aba759f38102e7538a519'))
        }
    }










}

Describe 'Trusted filesystem contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        function New-TestFilesystemModule {
            param([Parameter(Mandatory)][string] $RelativePath)
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $script:RepositoryRoot $RelativePath), [ref]$tokens, [ref]$errors)
            if (@($errors).Count -ne 0) { throw 'The production filesystem source must parse.' }
            $names = @(
                'Assert-RegularFileForHash', 'Assert-NoReparseAncestors', 'Test-PathEqual',
                'Assert-InstalledClosureSafeRelativePath', 'Get-InstalledClosureAsciiCaseFold', 'Add-InstalledClosureEntry',
                'Sort-InstalledClosureEntriesByOrdinalPath', 'Get-InstalledDirectoryClosureSha256'
            )
            $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -cin $names
            }, $true))
            $source = ($functions | ForEach-Object {
                $_.Extent.Text
            }) -join "`n"
            $module = New-Module -ScriptBlock ([scriptblock]::Create($source))
            return $module
        }

        $script:FilesystemModules = @{}
        foreach ($relativePath in @('scripts/Validate.ps1', 'scripts/Test-Repository.ps1')) {
            $script:FilesystemModules[$relativePath] = New-TestFilesystemModule -RelativePath $relativePath
        }
    }

    # Scenario: A closure contains names whose culture sort differs from the authority's Ordinal order.
    # Purpose: Bind canonical UTF-8 path/hash bytes to the same digest as the approved resolver contract.
    It 'InterT50_MatchesOrdinalCanonicalClosureDigest' {
        $root = Join-Path $TestDrive 'closure'
        [void](New-Item -ItemType Directory -Path $root)
        $names = [string[]]@('a.txt', 'Z.txt', 'é.txt', '中.txt')
        foreach ($name in $names) {
            [IO.File]::WriteAllText((Join-Path $root $name), "content:$name", [Text.UTF8Encoding]::new($false))
        }
        [Array]::Sort($names, [StringComparer]::Ordinal)
        $canonical = ($names | ForEach-Object {
            $hash = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant()
            "$_`t$hash`n"
        }) -join ''
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $actual = & $script:FilesystemModules['scripts/Validate.ps1'] {
            param($path)
            Get-InstalledDirectoryClosureSha256 -Path $path -Context 'Authority closure fixture'
        } $root
        $actual | Should -BeExactly $expected
    }

    # Scenario: A closure entry repeats a path or collides after authority normalization.
    # Purpose: Preserve duplicate, Unicode NFC, ASCII case and unsafe-path rejection before sorting.
    It 'UnitT60_RejectsInvalidClosureIdentity_<Case>' -ForEach @(
        @{ Case = 'duplicate'; Paths = @('same', 'same'); Error = '*duplicate path*' }
        @{ Case = 'unicode'; Paths = @('é', "e$([char]0x301)"); Error = '*Unicode-normalization-colliding*' }
        @{ Case = 'ascii-case'; Paths = @('A.txt', 'a.txt'); Error = '*ASCII-case-colliding*' }
        @{ Case = 'parent'; Paths = @('../outside'); Error = '*unsafe relative path*' }
        @{ Case = 'separator'; Paths = @('folder\file'); Error = '*unsafe relative path*' }
    ) {
        { & $script:FilesystemModules['scripts/Validate.ps1'] {
            param($paths)
            $entries = [Collections.Generic.List[object]]::new()
            $ordinal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $nfc = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $ascii = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            foreach ($path in $paths) {
                Add-InstalledClosureEntry -Entries $entries -OrdinalPaths $ordinal -NfcPaths $nfc -AsciiCasePaths $ascii `
                    -Entry ([pscustomobject]@{ path = $path; sha256 = ('a' * 64) }) -Context 'Closure fixture'
            }
        } $Paths } | Should -Throw $Error
    }

    # Scenario: Installed file bytes change after a closure receipt is created.
    # Purpose: Ensure content tampering changes the digest even when paths remain identical.
    It 'InterT70_DetectsContentTampering' {
        $root = Join-Path $TestDrive 'tamper-closure'
        [void](New-Item -ItemType Directory -Path $root)
        $path = Join-Path $root 'payload.txt'
        [IO.File]::WriteAllText($path, 'before')
        $before = & $script:FilesystemModules['scripts/Validate.ps1'] {
            param($root)
            Get-InstalledDirectoryClosureSha256 -Path $root -Context 'Tamper fixture'
        } $root
        [IO.File]::WriteAllText($path, 'after')
        $after = & $script:FilesystemModules['scripts/Validate.ps1'] {
            param($root)
            Get-InstalledDirectoryClosureSha256 -Path $root -Context 'Tamper fixture'
        } $root
        $after | Should -Not -Be $before
    }

    # Scenario: A Windows installed closure contains a junction.
    # Purpose: Reject reparse points before their contents can enter a trusted closure digest.
    It 'InterT80_RejectsWindowsReparsePointsInInstalledClosures' {
        $root = Join-Path $TestDrive 'linked-closure'
        $target = Join-Path $root 'target'
        [void](New-Item -ItemType Directory -Path $target -Force)
        [IO.File]::WriteAllText((Join-Path $target 'payload'), 'fixture')
        $link = Join-Path $root 'link'
        [void](New-Item -ItemType Junction -Path $link -Target $target)
        { & $script:FilesystemModules['scripts/Validate.ps1'] {
            param($root)
            Get-InstalledDirectoryClosureSha256 -Path $root -Context 'Windows reparse fixture'
        } $root } | Should -Throw '*reparse*'
    }

    # Scenario: A large closure must be sorted while preserving its independently computed canonical bytes.
    # Purpose: Prevent reintroducing quadratic insertion ordering or silently changing the Ordinal digest input.
    It 'UnitT90_PreservesLargeClosureCanonicalBytesWithinABoundedSort' {
        $entries = @(15278..0 | ForEach-Object {
            [pscustomobject]@{ path = ('entry/{0:D5}' -f $_); sha256 = ('a' * 64) }
        })
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $actual = & $script:FilesystemModules['scripts/Validate.ps1'] {
            param($entries)
            (Sort-InstalledClosureEntriesByOrdinalPath -Entries $entries).ToArray()
        } $entries
        $timer.Stop()
        $actual.Count | Should -Be 15279
        $expectedPaths = [string[]]@($entries | ForEach-Object path)
        [Array]::Sort($expectedPaths, [StringComparer]::Ordinal)
        $actualCanonical = ($actual | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
        $expectedCanonical = ($expectedPaths | ForEach-Object { "$_`t$('a' * 64)`n" }) -join ''
        $actualCanonical | Should -BeExactly $expectedCanonical
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 10
        Write-Host "Ordinal ordering: 15279 entries in $($timer.Elapsed.TotalMilliseconds) ms; canonical bytes equal."
    }
}
