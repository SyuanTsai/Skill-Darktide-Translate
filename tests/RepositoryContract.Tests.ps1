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

            & git -C $sourceRepository init --quiet --initial-branch=main
            if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the checkout evidence source repository.' }
            & git -C $sourceRepository config user.name 'EOL Contract Test'
            & git -C $sourceRepository config user.email 'eol-contract@example.invalid'
            & git -C $sourceRepository config core.autocrlf true
            & git -C $sourceRepository add --all
            & git -C $sourceRepository commit --quiet -m 'fixture LF source'
            if ($LASTEXITCODE -ne 0) { throw 'Could not commit the checkout evidence source repository.' }
            & git -c core.autocrlf=true clone --quiet $sourceRepository $freshCheckout
            if ($LASTEXITCODE -ne 0) { throw 'Could not clone the checkout evidence source repository.' }

            $modules = foreach ($modulePath in $normalizedModulePaths) {
                $attribute = [string]((& git -C $sourceRepository check-attr eol -- $modulePath) -join '')
                if ($LASTEXITCODE -ne 0) { throw "Could not resolve the effective eol attribute for '$modulePath'." }
                $sourceBlobOid = [string]((& git -C $sourceRepository rev-parse "HEAD:$modulePath") -join '')
                if ($LASTEXITCODE -ne 0) { throw "Could not resolve the source blob for '$modulePath'." }
                $checkoutRawOid = [string]((& git -C $freshCheckout hash-object --no-filters -- $modulePath) -join '')
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
            '.github/workflows/standard-v1-protected.yml',
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
                'scripts/Invoke-PrePushValidation.ps1'
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

    # Scenario: GitHub validates a branch or pull request using the shared tool policy.
    # Purpose: Prevent the repository from silently pinning stale quality tools or weakening the required gates.
    It 'UnitT40_PreservesTheSharedLatestAtRunTimeQualityGate' {
        # Source layout remains legacy during bootstrap, but its old CI was retired.
        $workflow = Get-Content -LiteralPath (Join-Path $repoRoot $layout.WorkflowPath) -Raw
        foreach ($retiredWorkflow in @('validate.yml', 'skill-validator.yml')) {
            Test-Path -LiteralPath (Join-Path $repoRoot ".github/workflows/$retiredWorkflow") | Should -BeFalse
        }
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
        $workflow | Should -Match 'actions/setup-go@[0-9a-f]{40}'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match "go-version: 'stable'"
        $workflow | Should -Match 'check-latest: true'
        $workflow | Should -Not -Match "go-version: '[0-9]+\.[0-9]+\.[0-9]+'"
        $workflow | Should -Match 'scripts/Validate\.ps1'
    }

    # Scenario: The base-owned protected supervisor validates the next migration against the current central authority snapshot.
    # Purpose: Prevent a merged workflow bootstrap from retaining a stale authority pin that rejects the candidate before validation.
    It 'UnitT45_BindsTheProtectedSupervisorToTheCurrentAuthoritySnapshot' {
        if ($layout.Name -ceq 'legacy') {
            $validator = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Validate.ps1') -Raw

            $validator | Should -Match ([regex]::Escape("`$approvedAuthorityCommit = 'a403abdf038a3346d775431a6908a71cc3d35a5b'"))
            $validator | Should -Match ([regex]::Escape("`$approvedAuthorityArchiveSha256 = '17154929fadfa63487263db1efcb78f4948195af9c11c25a66432eff3411b2d3'"))
            $validator | Should -Not -Match ([regex]::Escape('d38eba3faf967504751aba759f38102e7538a519'))
        }
    }

    # Scenario: A hosted Linux runner may expose an inherited module path that the isolated identity cannot read.
    # Purpose: Keep optional module-path probing fail-closed for unexpected errors without blocking on an unavailable optional entry.
    It 'UnitT46_ToleratesUnreadableOptionalLinuxModulePaths' {
        $boundPaths = Invoke-TestModulePathProbe -RepositoryRoot $repoRoot -DeniedPath '/denied/modules'
        @($boundPaths).Count | Should -Be 1
        $boundPaths[0] | Should -Be '/readable/modules'
    }

    # Scenario: An optional path probe fails for a reason other than permission denial.
    # Purpose: Prevent the recovery from hiding unexpected IO failures behind a broad catch.
    It 'UnitT47_PropagatesUnexpectedOptionalModulePathErrors' {
        { Invoke-TestModulePathProbe -RepositoryRoot $repoRoot -UnexpectedError } |
            Should -Throw '*unexpected module-path IO failure*'
    }

    # Scenario: The original unguarded loop encounters the same denied module path.
    # Purpose: Prove the behavioral fixture detects the actual regression instead of accepting both versions.
    It 'UnitT48_DetectsThePreFixModulePathFailure' {
        # Preserve the old loop as a harmless fixture: isolated test snapshots need no Git history.
        $oldSource = @'
foreach ($modulePath in @(([string]$env:PSModulePath -split ':') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    if (Test-Path -LiteralPath $modulePath -PathType Container) {
        & $addLinuxReadonlyBindPath -Path $modulePath
    }
}
'@
        { Invoke-TestModulePathProbe -RepositoryRoot $repoRoot -Source $oldSource -DeniedPath '/denied/modules' } |
            Should -Throw '*denied optional module path*'
    }

    # Scenario: An existing module path fails the subsequent sandbox bind-source validation.
    # Purpose: Ensure optional-path recovery cannot swallow a safety failure after a successful probe.
    It 'UnitT49_PropagatesSandboxBindValidationErrors' {
        { Invoke-TestModulePathProbe -RepositoryRoot $repoRoot -BindError } |
            Should -Throw '*unsafe bind source*'
    }
}

Describe 'Trusted filesystem contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $statCommand = Get-Command stat -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $statCommand) { $script:NativeStatPath = [string]$statCommand.Path }
        else {
            $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $script:NativeStatPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $gitCommand.Path) '../usr/bin/stat.exe'))
        }
        if (-not (Test-Path -LiteralPath $script:NativeStatPath -PathType Leaf)) {
            throw 'GNU stat is required for the native file-classification regression.'
        }
        $statVersion = @(& $script:NativeStatPath --version)
        if ($LASTEXITCODE -ne 0 -or $statVersion[0] -notmatch 'GNU coreutils') {
            throw 'The file-classification regression requires GNU stat.'
        }

        function New-TestFilesystemModule {
            param([Parameter(Mandatory)][string] $RelativePath)
            $tokens = $null
            $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $script:RepositoryRoot $RelativePath), [ref]$tokens, [ref]$errors)
            if (@($errors).Count -ne 0) { throw 'The production filesystem source must parse.' }
            $names = @(
                'Assert-RegularFileForHash', 'Assert-NoReparseAncestors', 'Test-PathEqual',
                'Assert-InstalledClosureSafeRelativePath', 'Get-InstalledClosureSymlinkTarget',
                'Get-InstalledClosureSymlinkIdentitySha256', 'Get-InstalledSafeUnixSymlinkEntry',
                'Get-InstalledClosureAsciiCaseFold', 'Add-InstalledClosureEntry',
                'Sort-InstalledClosureEntriesByOrdinalPath', 'Get-InstalledDirectoryClosureSha256'
            )
            $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -cin $names
            }, $true))
            $source = ($functions | ForEach-Object {
                $text = $_.Extent.Text
                if ($RelativePath -ceq 'scripts/Test-Repository.ps1' -and $_.Name -ceq 'Assert-RegularFileForHash') {
                    $guard = $_.Body.Find({
                        param($node)
                        $node -is [Management.Automation.Language.IfStatementAst] -and
                            $node.Clauses[0].Item1.Extent.Text -ceq '[Environment]::OSVersion.Platform -eq [PlatformID]::Unix'
                    }, $true)
                    if ($null -eq $guard) { throw 'Expected the repository validator native-platform guard.' }
                    # Only select its native branch for the portable GNU-stat harness.
                    # All filesystem checks, native invocation, parsing and locale handling stay unchanged.
                    $condition = $guard.Clauses[0].Item1.Extent
                    $start = $condition.StartOffset - $_.Extent.StartOffset
                    $text = $text.Substring(0, $start) + '$true' + $text.Substring($start + $condition.Text.Length)
                }
                $text
            }) -join "`n"
            $module = New-Module -ScriptBlock ([scriptblock]::Create($source))
            & $module {
                param($statPath)
                # Exercise the production GNU-stat path on either host, using the real native utility.
                $script:IsLinuxHost = $true
                $script:TrustedStatPath = $statPath
            } $script:NativeStatPath
            return $module
        }

        $script:FilesystemModules = @{}
        foreach ($relativePath in @('scripts/Validate.ps1', 'scripts/Test-Repository.ps1')) {
            $script:FilesystemModules[$relativePath] = New-TestFilesystemModule -RelativePath $relativePath
        }
    }

    # Scenario: GNU stat classifies a newly created, zero-byte Git configuration file.
    # Purpose: Accept the exact regular-empty-file shape that the protected Linux preflight creates.
    It 'InterT10_AcceptsNativeGnuEmptyRegularFile_<Source>' -ForEach @(
        @{ Source = 'scripts/Validate.ps1' }
        @{ Source = 'scripts/Test-Repository.ps1' }
    ) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $item = New-Item -ItemType File -Path $path
        { & $script:FilesystemModules[$Source] {
            param($file)
            Assert-RegularFileForHash -Item $file -Context 'Empty Git config fixture'
        } $item } | Should -Not -Throw
    }

    # Scenario: The same native classification checks a nonempty ordinary file.
    # Purpose: Preserve the existing accepted regular-file behavior.
    It 'InterT20_AcceptsNativeGnuNonemptyRegularFile_<Source>' -ForEach @(
        @{ Source = 'scripts/Validate.ps1' }
        @{ Source = 'scripts/Test-Repository.ps1' }
    ) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path, 'fixture', [Text.UTF8Encoding]::new($false))
        $item = Get-Item -LiteralPath $path
        { & $script:FilesystemModules[$Source] {
            param($file)
            Assert-RegularFileForHash -Item $file -Context 'Nonempty file fixture'
        } $item } | Should -Not -Throw
    }

    # Scenario: A directory is supplied where a regular file is required.
    # Purpose: Keep non-file entries rejected before hashing or invoking downstream tools.
    It 'InterT30_RejectsDirectory_<Source>' -ForEach @(
        @{ Source = 'scripts/Validate.ps1' }
        @{ Source = 'scripts/Test-Repository.ps1' }
    ) {
        $item = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        { & $script:FilesystemModules[$Source] {
            param($file)
            Assert-RegularFileForHash -Item $file -Context 'Directory fixture'
        } $item } | Should -Throw '*not a regular non-reparse file*'
    }

    # Scenario: stat encounters a file deleted after its FileInfo was obtained, with a caller locale set.
    # Purpose: Fail closed on native probe errors and restore the exact caller environment on failure.
    It 'InterT40_RejectsFailedStatAndRestoresLocale_<Source>' -ForEach @(
        @{ Source = 'scripts/Validate.ps1' }
        @{ Source = 'scripts/Test-Repository.ps1' }
    ) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path, 'fixture')
        $item = Get-Item -LiteralPath $path
        Remove-Item -LiteralPath $path
        $previous = [Environment]::GetEnvironmentVariable('LC_ALL', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('LC_ALL', 'fixture-caller-locale', 'Process')
            { & $script:FilesystemModules[$Source] {
                param($file)
                Assert-RegularFileForHash -Item $file -Context 'Missing file fixture'
            } $item } | Should -Throw '*trusted filesystem type check*'
            [Environment]::GetEnvironmentVariable('LC_ALL', 'Process') | Should -BeExactly 'fixture-caller-locale'
        }
        finally { [Environment]::SetEnvironmentVariable('LC_ALL', $previous, 'Process') }
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

    # Scenario: An installed closure contains an in-root link on the current OS.
    # Purpose: Reject Windows reparse points and accept only identity-bound, in-root Unix symbolic links.
    It 'InterT80_EnforcesHostSpecificReparsePolicy' {
        $root = Join-Path $TestDrive 'linked-closure'
        $target = Join-Path $root 'target'
        [void](New-Item -ItemType Directory -Path $target -Force)
        [IO.File]::WriteAllText((Join-Path $target 'payload'), 'fixture')
        $link = Join-Path $root 'link'
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
            [void](New-Item -ItemType SymbolicLink -Path $link -Target 'target')
            $entry = & $script:FilesystemModules['scripts/Validate.ps1'] {
                param($link, $root)
                Get-InstalledSafeUnixSymlinkEntry -Item (Get-Item -LiteralPath $link -Force) -Root $root -Context 'Unix link fixture'
            } $link $root
            $entry.path | Should -BeExactly 'link'
            $entry.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
        else {
            [void](New-Item -ItemType Junction -Path $link -Target $target)
            { & $script:FilesystemModules['scripts/Validate.ps1'] {
                param($root)
                Get-InstalledDirectoryClosureSha256 -Path $root -Context 'Windows reparse fixture'
            } $root } | Should -Throw '*not a safe Unix symbolic link*'
        }
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
Describe 'Protected workflow trust binding' {
    BeforeAll {
        $script:TrustRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:TrustWorkflow = Get-Content -LiteralPath (Join-Path $script:TrustRepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $script:TrustValidator = Get-Content -LiteralPath (Join-Path $script:TrustRepositoryRoot 'scripts/Validate.ps1') -Raw

        function Get-TestWorkflowStep {
            param([string] $Name)
            $pattern = '(?ms)^      - name: ' + [regex]::Escape($Name) + '\r?\n(?:(?!^      - name: ).)*?        run: \|\r?\n(?<body>(?:          [^\r\n]*\r?\n|\r?\n)+)'
            $match = [regex]::Match($script:TrustWorkflow, $pattern)
            if (-not $match.Success) { throw "Workflow step not found: $Name" }
            return [regex]::Replace($match.Groups['body'].Value, '(?m)^          ', '')
        }

    }

    # Scenario: An existing summary is rewritten or removed after the trusted preflight emitted its evidence.
    # Purpose: Exercise the real exporter against a tampered regular file, not a regex approximation.
    It 'InterT60_AuthenticatesDiagnosticsBeforeExport_<mode>' -ForEach @(
        @{ mode = 'valid' }, @{ mode = 'tampered' }, @{ mode = 'missing-proof' },
        @{ mode = 'deleted' }, @{ mode = 'pre-summary-failure' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $run = Join-Path $root 'sgv1-fixture'
        [void](New-Item -ItemType Directory -Path $run -Force)
        $names = @('RUNNER_TEMP', 'GITHUB_OUTPUT', 'EVIDENCE_BASE64_LENGTH', 'EXPECTED_DIAGNOSTICS_SHA256')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:RUNNER_TEMP = $root
            $env:GITHUB_OUTPUT = Join-Path $root 'trusted-output'
            $env:EVIDENCE_BASE64_LENGTH = '0'
            $env:EXPECTED_DIAGNOSTICS_SHA256 = ''
            $securityPreflightSummaryPath = Join-Path $run 'security-preflight-summary.json'
            $securityBlockers = @()
            $sanitizedSecurityFindings = @()
            $runId = 'fixture'
            $start = $script:TrustValidator.IndexOf('$securityPreflightSummary =', [StringComparison]::Ordinal)
            $end = $script:TrustValidator.IndexOf('if ($securityBlockers.Count -gt 0)', $start, [StringComparison]::Ordinal)
            & ([scriptblock]::Create($script:TrustValidator.Substring($start, $end - $start)))
            if (Test-Path -LiteralPath $env:GITHUB_OUTPUT) {
                $line = Get-Content -LiteralPath $env:GITHUB_OUTPUT | Where-Object { $_ -like 'standard_v1_diagnostics_sha256=*' }
                $env:EXPECTED_DIAGNOSTICS_SHA256 = ([string]$line).Split('=', 2)[1]
            }
            if ($mode -eq 'tampered') {
                $code = "[IO.File]::WriteAllText('" + $securityPreflightSummaryPath.Replace("'", "''") + "', 'forged summary'); exit 1"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
                & (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) -NoProfile -EncodedCommand $encoded
                $LASTEXITCODE | Should -Be 1
            }
            if ($mode -in @('deleted', 'pre-summary-failure')) {
                [IO.File]::Delete($securityPreflightSummaryPath)
            }
            if ($mode -in @('missing-proof', 'pre-summary-failure')) { $env:EXPECTED_DIAGNOSTICS_SHA256 = '' }
            $env:GITHUB_OUTPUT = Join-Path $root 'export-output'
            $exportPath = Join-Path $root 'export.ps1'
            [IO.File]::WriteAllText($exportPath, '$ErrorActionPreference = ''Stop''' + [Environment]::NewLine +
                (Get-TestWorkflowStep 'Export bounded validation diagnostics for clean upload'), [Text.UTF8Encoding]::new($false))
            # Run the real workflow step in a separate pwsh so its exit 0 cannot
            # terminate the test harness or bypass subsequent assertions.
            $exportOutput = @(& (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) -NoProfile -NonInteractive -File $exportPath 2>&1)
            $exportExitCode = $LASTEXITCODE
            if ($mode -in @('valid', 'pre-summary-failure')) {
                $exportExitCode | Should -Be 0
                if ($mode -eq 'valid') { $env:EXPECTED_DIAGNOSTICS_SHA256 | Should -Match '^[0-9a-f]{64}$' }
                $lines = Get-Content -LiteralPath $env:GITHUB_OUTPUT
                ($lines | Where-Object { $_ -like 'diagnostics_sha256=*' }) | Should -BeExactly "diagnostics_sha256=$env:EXPECTED_DIAGNOSTICS_SHA256"
                if ($mode -eq 'pre-summary-failure') {
                    ($lines | Where-Object { $_ -like 'diagnostics_base64=*' }) | Should -BeExactly 'diagnostics_base64='
                }
            }
            else {
                $exportExitCode | Should -Not -Be 0
                ($exportOutput -join [Environment]::NewLine) | Should -Match 'diagnostics'
                Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
            }
        }
        finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
}
Describe 'Optional Linux read-only path binding' {
    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Validate.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) { throw 'Production validator must parse.' }
        $native = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $true)
        $parameter = @($native.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'ReadOnlyPaths' })
        $loop = @($native.Body.FindAll({ param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -ceq 'readOnlyPath'
        }, $true))
        $reparseGuard = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-NoReparseAncestors'
        }, $true)
        $pathEqual = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-PathEqual'
        }, $true)
        if ($parameter.Count -ne 1 -or $loop.Count -ne 1 -or $null -eq $reparseGuard -or $null -eq $pathEqual) {
            throw 'Expected the production parameter, Linux bind loop and reparse guard.'
        }
        # Execute the unchanged production parameter binding and bind-source loop.
        # This does not emulate or claim to run Linux mount/cgroup isolation.
        $source = 'param(' + $parameter[0].Extent.Text + ')' + [Environment]::NewLine +
            $pathEqual.Extent.Text + [Environment]::NewLine +
            $reparseGuard.Extent.Text + [Environment]::NewLine +
            '$Context = "Read-only fixture"; $linuxReadonlyBindPaths = [Collections.Generic.List[string]]::new()' +
            [Environment]::NewLine + $loop[0].Extent.Text + [Environment]::NewLine +
            'return ,$linuxReadonlyBindPaths'
        $script:ReadOnlyProbe = [scriptblock]::Create($source)
    }

    # Scenario: Bootstrap probes omit the optional read-only path array.
    # Purpose: Absence means zero additional bind sources, not one null path.
    It 'UnitT10_AcceptsOmittedReadOnlyPaths' {
        $actual = & $script:ReadOnlyProbe
        $actual.Count | Should -Be 0
    }

    # Scenario: A caller explicitly provides an empty collection.
    # Purpose: Preserve the documented empty collection behavior.
    It 'UnitT20_AcceptsEmptyReadOnlyPaths' {
        $actual = & $script:ReadOnlyProbe -ReadOnlyPaths @()
        $actual.Count | Should -Be 0
    }

    # Scenario: Existing regular files are provided twice.
    # Purpose: Keep validated full paths and deduplicate repeated bind entries.
    It 'InterT30_PreservesExistingReadOnlyPaths' {
        $path = Join-Path $TestDrive 'existing.txt'
        [IO.File]::WriteAllText($path, 'fixture')
        $actual = & $script:ReadOnlyProbe -ReadOnlyPaths @($path, $path)
        $actual.Count | Should -Be 1
        $actual[0] | Should -BeExactly ([IO.Path]::GetFullPath($path))
    }

    # Scenario: A supplied path does not exist.
    # Purpose: Missing explicit inputs must still fail closed.
    It 'InterT40_RejectsMissingExplicitPath' {
        $path = Join-Path $TestDrive 'missing'
        { & $script:ReadOnlyProbe -ReadOnlyPaths @($path) } | Should -Throw '*read-only child path is missing*'
    }

    # Scenario: A caller explicitly supplies a blank or null path entry.
    # Purpose: The omitted-array default must not silently discard invalid supplied entries.
    It 'UnitT50_RejectsInvalidExplicitEntry_<kind>' -ForEach @(
        @{ kind = 'empty'; value = '' }, @{ kind = 'null'; value = $null }
    ) {
        { & $script:ReadOnlyProbe -ReadOnlyPaths @($value) } | Should -Throw
    }

    # Scenario: A supplied directory is backed by a reparse point.
    # Purpose: Optional-path handling cannot weaken the existing reparse boundary.
    It 'InterT60_RejectsReparseReadOnlyPath' {
        $target = Join-Path $TestDrive 'target'
        $link = Join-Path $TestDrive 'link'
        [void](New-Item -ItemType Directory -Path $target)
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $linkType -Path $link -Target $target)
        { & $script:ReadOnlyProbe -ReadOnlyPaths @($link) } | Should -Throw '*reparse*'
    }
}

Describe 'Bounded writable-root enumeration behavior' {
    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Validate.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) { throw 'Validator must parse before behavioral testing.' }
        $script:HostIsLinux = [Environment]::OSVersion.Platform -eq [PlatformID]::Unix
        foreach ($name in @(
            'ConvertFrom-LinuxProcessResourceUsageMetadata',
            'Get-LinuxCgroupProcessIds',
            'Enable-LinuxWritableRootInspector',
            'Invoke-LinuxWritableRootInspection',
            'Invoke-LinuxOpenUnlinkedInspection',
            'Get-LinuxWritableRootUsage'
        )) {
            $definition = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
            if ($null -ne $definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
            else { throw "Missing production writable-root function: $name" }
        }
    }

    BeforeEach {
        $script:PreviousLinuxHost = $script:IsLinuxHost
        # Cross-platform function test only: this is not namespace/cgroup acceptance.
        $script:IsLinuxHost = $true
        $script:UsageRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:UsageRoot)
        $file = Join-Path $script:UsageRoot 'entry'
        [IO.File]::WriteAllText($file, '')
    }
    AfterEach { $script:IsLinuxHost = $script:PreviousLinuxHost }

    # Scenario: A hostile tree exceeds the bounded entry inventory.
    # Purpose: Keep the exact100000 ceiling inside the descriptor-relative native traversal.
    It 'UnitT10_StopsEnumerationAtTheFirstExcessEntry' {
        $source = $ast.Extent.Text
        $source | Should -Match 'entryCount\+\+;\s+if \(entryCount > maximumEntries\)'
        $source | Should -Match 'Writable root exceeded the aggregate writable-entry-count limit'
        $usage = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-LinuxWritableRootUsage'
        }, $true)
        $usage.Extent.Text | Should -Match '-MaximumEntries\s+100000'
    }

    # Scenario: The native inspector accepts a result at the inclusive limit.
    # Purpose: Preserve the PowerShell return contract without executing libc on a non-Linux unit host.
    It 'UnitT20_AcceptsTheExactEntryLimit' {
        Mock Invoke-LinuxWritableRootInspection {
            [pscustomobject]@{ Bytes = [int64]17; EntryCount = 100000 }
        }
        $usage = Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Exact fixture'
        $usage.fileCount | Should -Be 100000
        $usage.bytes | Should -Be 17
        Should -Invoke Invoke-LinuxWritableRootInspection -Times 1 -Exactly -ParameterFilter {
            $MaximumEntries -eq 100000 -and -not $AllowReparseEntries
        }
    }

    # Scenario: A real directory contains an ordinary file, hidden-name file and nested directory/file.
    # Purpose: Exercise native enumeration and verify that directories count while file bytes remain exact.
    It 'InterT30_CountsRealFilesDirectoriesAndHiddenEntries' {
        if (-not $script:HostIsLinux) {
            Set-ItResult -Skipped -Because 'native descriptor traversal is Linux-only'
            return
        }
        [IO.File]::WriteAllText((Join-Path $script:UsageRoot '.hidden'), 'ab')
        $subdir = Join-Path $script:UsageRoot 'nested'
        [void](New-Item -ItemType Directory -Path $subdir)
        [IO.File]::WriteAllText((Join-Path $subdir 'payload'), 'xyz')
        $usage = Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Real fixture'
        $usage.fileCount | Should -Be 4
        $usage.bytes | Should -Be 5
    }

    # Scenario: Traversal fails while directory descriptors remain stacked.
    # Purpose: Keep fail-closed cleanup on every native traversal exit.
    It 'UnitT40_DisposesEnumeratorWhenMoveNextFails' {
        $source = $ast.Extent.Text
        $source | Should -Match '(?s)finally\s*\{\s*while \(pending\.Count > 0\).*?CloseFrame\(frame\)'
        $source | Should -Match 'CloseDirectory\(directory\)'
    }

    # Scenario: Protected tests intentionally create a temporary symlink or junction and remove it before completion.
    # Purpose: Count but never follow explicitly allowed in-flight reparse entries while retaining strict default rejection.
    It 'UnitT45_AllowsOnlyExplicitEphemeralReparseAccounting' {
        if (-not $script:HostIsLinux) {
            Set-ItResult -Skipped -Because 'native descriptor traversal is Linux-only'
            return
        }
        $target = Join-Path $TestDrive 'ephemeral-target'
        $link = Join-Path $script:UsageRoot 'ephemeral-link'
        [void](New-Item -ItemType Directory -Path $target)
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $linkType -Path $link -Target $target)
        { Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Strict fixture' } | Should -Throw '*reparse*'
        $usage = Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Ephemeral fixture' -AllowReparseEntries
        $usage.fileCount | Should -Be 2
        $usage.bytes | Should -Be 0
    }

    # Scenario: Trusted tool installations share the diagnostic parent with a narrower candidate-writable child root.
    # Purpose: Bound only the declared child-writable surface and never treat trusted package symlinks as candidate output.
    It 'UnitT50_AccountsOnlyTheDeclaredChildWritableRoot' {
        $invokeNative = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $true)
        $invokeNative | Should -Not -BeNullOrEmpty
        $source = $invokeNative.Extent.Text
        ([regex]::Matches($source, 'Get-LinuxWritableRootUsage\s+-Root\s+\$childWritableRootPath')).Count | Should -Be 1
        ([regex]::Matches($source, 'Assert-LinuxWritableRootUsage\s+-Root\s+\$childWritableRootPath')).Count | Should -Be 3
        $source | Should -Not -Match '(?:Get|Assert)-LinuxWritableRootUsage\s+-Root\s+\$DiagnosticRoot'
    }

    # Scenario: Trusted tools and the candidate-writable child share one diagnostic root in both Linux sandboxes.
    # Purpose: Make every sibling read-only before quota accounting narrows to the only writable child mount.
    It 'UnitT60_MountsOnlyTheDeclaredChildWritableRootInsideReadOnlyDiagnosticRoot' {
        $source = $ast.Extent.Text
        $source | Should -Match 'Test-PathWithinOrEqual\s+-Path\s+\$childWritableRootPath\s+-Root\s+\$diagnosticRootFullPath'
        ([regex]::Matches($source, [regex]::Escape('child_writable_root="$6"'))).Count | Should -Be 2
        ([regex]::Matches($source, [regex]::Escape('"$mount_path" -o remount,bind,ro "$sandbox_root$run_root"'))).Count | Should -Be 2
        ([regex]::Matches($source, [regex]::Escape('"$mount_path" --bind "$child_writable_root" "$sandbox_root$child_writable_root"'))).Count | Should -Be 0
        ([regex]::Matches($source, [regex]::Escape('"$mount_path" -o remount,bind,rw "$sandbox_root$child_writable_root"'))).Count | Should -Be 0
        ([regex]::Matches($source, [regex]::Escape('"$mount_path" -t tmpfs -o size=536870912,nr_inodes=100001,nodev,nosuid tmpfs "$sandbox_root$child_writable_root"'))).Count | Should -Be 2
    }

    # Scenario: Contained HOME/TMP and protected-Pester TestDrive share the sole writable child surface.
    # Purpose: Keep those paths usable while bounding aggregate growth and rejecting any reparse left at completion.
    It 'UnitT70_BoundsProtectedPesterChildRootAndKeepsContainedEnvironmentWritable' {
        $invokeNative = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $true)
        $proxy = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ProtectedPesterServerProxy'
        }, $true)
        $runspace = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ProtectedPesterRunspace'
        }, $true)
        $invokeNative.Extent.Text | Should -Match 'New-ContainedProcessEnvironment\s+-DiagnosticRoot\s+\$childWritableRootPath'
        ([regex]::Matches($proxy.Extent.Text, 'New-ContainedProcessEnvironment\s+-DiagnosticRoot\s+\$childWritableRootPath')).Count | Should -Be 2
        ([regex]::Matches($runspace.Extent.Text, 'Get-LinuxWritableRootUsage\s+-Root\s+\$childWritableRootPath')).Count | Should -Be 1
        ([regex]::Matches($runspace.Extent.Text, 'Assert-LinuxWritableRootUsage[\s\x60]+-Root\s+\$childWritableRootPath')).Count | Should -Be 2
        ([regex]::Matches($runspace.Extent.Text, 'Assert-LinuxWritableRootUsage[\s\S]{0,240}-AllowReparseEntries')).Count | Should -Be 1
    }

    # Scenario: The Ubuntu runner's readable /etc snapshot exceeds the former 64 MiB private mount.
    # Purpose: Preserve a fixed sandbox-local ceiling large enough for the trusted snapshot without using host-writable /etc.
    It 'UnitT80_BindsThePrivateEtcSnapshotToTheExpandedFixedLimit' {
        $invokeNative = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $true)
        $source = $invokeNative.Extent.Text
        $source | Should -Match '(?s)if \[ "\$system_root" = "/etc" \]; then.*?size=268435456,nodev,nosuid,noexec tmpfs "\$target"'
        $source | Should -Not -Match '(?s)if \[ "\$system_root" = "/etc" \]; then.*?size=67108864,nodev,nosuid,noexec tmpfs "\$target"'
    }

    # Scenario: A writable directory is replaced with a symlink between enumeration and descent.
    # Purpose: Bind traversal to directory descriptors and refuse link following instead of reopening by pathname.
    It 'UnitT90_UsesDescriptorRelativeNoFollowWritableRootTraversal' {
        $source = $ast.Extent.Text
        $source | Should -Match 'class\s+LinuxWritableRootInspector'
        $source | Should -Match 'EntryPoint\s*=\s*"openat"'
        $source | Should -Match 'O_NOFOLLOW'
        $source | Should -Match 'AT_SYMLINK_NOFOLLOW'
        $inspection = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-LinuxWritableRootInspection'
        }, $true)
        $inspection.Extent.Text | Should -Match 'LinuxWritableRootInspector\]::Inspect'
        $usage = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-LinuxWritableRootUsage'
        }, $true)
        $usage.Extent.Text | Should -Not -Match 'EnumerateFileSystemInfos|Get-ChildItem'
    }

    # Scenario: The validator is parsed and tested on Windows before Linux evidence runs.
    # Purpose: Compile the descriptor walker eagerly without invoking libc on the non-Linux host.
    It 'UnitT95_CompilesTheLinuxWritableRootInspector' {
        $nativeType = Enable-LinuxWritableRootInspector
        $nativeType.FullName | Should -BeExactly 'Codex.Validation.LinuxWritableRootInspector'
    }

    # Scenario: A protected test leaves a detached writer in the Pester cgroup.
    # Purpose: Evacuate every sandbox writer before the final strict reparse scan accepts the child root.
    It 'UnitT100_QuiescesProtectedPesterBeforeTheFinalStrictScan' {
        $runspace = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ProtectedPesterRunspace'
        }, $true)
        $source = $runspace.Extent.Text
        $source | Should -Match '(?s)Remove-LinuxCandidateCgroup\s+-CgroupPath\s+\$linuxPesterCgroupPath\s+\$linuxPesterCgroupPath\s*=\s*\$null.*?Assert-LinuxWritableRootUsage[\s\x60]+-Root\s+\$childWritableRootPath'
    }

    # Scenario: Ubuntu's util-linux setpriv rejects the nonexistent --ambient-clear option.
    # Purpose: Clear the ambient capability set with the documented capability-list syntax in both Linux sandboxes.
    It 'UnitT105_UsesSupportedSetprivAmbientCapabilityClearing' {
        $source = $ast.Extent.Text
        $source | Should -Not -Match '--ambient-clear'
        ([regex]::Matches($source, '--ambient-caps=-all')).Count | Should -Be 2
    }

    # Scenario: Candidate code keeps deleted files open so pathname traversal cannot see their allocated logical bytes.
    # Purpose: Inspect stable duplicated procfs descriptors, require link-count zero, and de-duplicate inode identity.
    It 'UnitT110_AccountsOpenUnlinkedFilesInsideTheWritableRoot' {
        $source = $ast.Extent.Text
        $source | Should -Match 'InspectOpenUnlinked'
        $source | Should -Match 'AT_EMPTY_PATH'
        $source | Should -Match 'EntryPoint\s*=\s*"readlink"'
        $source | Should -Match 'LinkCount\s*!=\s*0'
        $source | Should -Match 'HashSet<string>\s+identities'
        $assertUsage = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-LinuxWritableRootUsage'
        }, $true)
        $assertUsage.Extent.Text | Should -Match 'Get-LinuxBoundaryProcessIds'
        $assertUsage.Extent.Text | Should -Match 'Invoke-LinuxOpenUnlinkedInspection'
    }

    # Scenario: Two live descriptors retain the same deleted file inside the writable root.
    # Purpose: Exercise procfs duplication and verify inode de-duplication with exact logical-byte accounting.
    It 'InterT115_AccountsARealOpenUnlinkedFileOnce' {
        if (-not $script:HostIsLinux) {
            Set-ItResult -Skipped -Because 'open-unlinked procfs accounting is Linux-only'
            return
        }
        $path = Join-Path $script:UsageRoot 'open-unlinked'
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $first = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, $share)
        $second = $null
        try {
            $first.SetLength(65537)
            $first.Flush($true)
            $second = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, $share)
            Remove-Item -LiteralPath $path -Force
            $usage = Invoke-LinuxOpenUnlinkedInspection `
                -ProcessIds ([int[]]@($PID)) `
                -Root $script:UsageRoot `
                -MaximumEntries 100000
            $usage.EntryCount | Should -Be 1
            $usage.Bytes | Should -Be 65537
        }
        finally {
            if ($null -ne $second) { $second.Dispose() }
            $first.Dispose()
        }
    }

    # Scenario: Native tools and protected Pester have different process-boundary identities while both write to the same bounded surface.
    # Purpose: Bind live unlinked-file accounting to process-group or cgroup membership and scan strictly only after writers stop.
    It 'UnitT120_BindsLiveUnlinkedAccountingAndQuiescesNativeFinalScan' {
        $invokeNative = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $true)
        $nativeSource = $invokeNative.Extent.Text
        ([regex]::Matches($nativeSource, 'Assert-LinuxWritableRootUsage[^\r\n]*-RootProcessId\s+\$childProcessId[^\r\n]*-ProcessGroupId\s+\$childProcessGroupId')).Count | Should -Be 2
        $nativeSource | Should -Match '(?s)Stop-ProcessTree.*?\$processTreeStopped\s*=\s*\$true.*?Assert-LinuxWritableRootUsage\s+-Root\s+\$childWritableRootPath'

        $runspace = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ProtectedPesterRunspace'
        }, $true)
        $runspace.Extent.Text | Should -Match '(?s)Assert-LinuxWritableRootUsage[\s\x60]+-Root\s+\$childWritableRootPath.*?-CgroupPath\s+\$linuxPesterCgroupPath'
    }

    # Scenario: A terminated child remains in procfs as a zombie or dead process, whose status omits VmRSS.
    # Purpose: Preserve its accumulated CPU and accept zero memory only when stat and status both report Z/X.
    It 'UnitT125_AcceptsMissingVmRssOnlyForExitedProcesses' {
        $stat = '21242 (fixture) Z 1 1 1 0 0 0 0 0 0 0 3 5 7 11'
        $zombieStatus = "Name:`tfixture`nState:`tZ (zombie)`n"
        $usage = ConvertFrom-LinuxProcessResourceUsageMetadata -ProcessId 21242 -Stat $stat -Status $zombieStatus
        $usage.memoryBytes | Should -Be 0
        $usage.cpuTicks | Should -Be 26

        $deadStat = $stat -replace '\) Z ', ') X '
        $deadStatus = "Name:`tfixture`nState:`tX (dead)`n"
        $deadUsage = ConvertFrom-LinuxProcessResourceUsageMetadata -ProcessId 21243 -Stat $deadStat -Status $deadStatus
        $deadUsage.memoryBytes | Should -Be 0
        $deadUsage.cpuTicks | Should -Be 26

        $liveStat = $stat -replace '\) Z ', ') S '
        { ConvertFrom-LinuxProcessResourceUsageMetadata -ProcessId 21242 -Stat $liveStat -Status "Name:`tfixture`nState:`tS (sleeping)`n" } |
            Should -Throw '*resident memory*'
        { ConvertFrom-LinuxProcessResourceUsageMetadata -ProcessId 21242 -Stat $liveStat -Status $deadStatus } |
            Should -Throw '*resident memory*'
    }

    # Scenario: HashSet<T> exposes ToArray only as a LINQ extension, so PowerShell member enumeration targets its integer elements.
    # Purpose: Return a stable integer collection from both Linux process-boundary helpers without a scalar method call.
    It 'UnitT130_ReturnsCgroupProcessIdsWithoutHashSetToArray' {
        $cgroupPath = Join-Path $TestDrive 'cgroup'
        [void](New-Item -ItemType Directory -Path $cgroupPath)
        [IO.File]::WriteAllLines((Join-Path $cgroupPath 'cgroup.procs'), [string[]]@('21243', '21242', '21243'))

        $actual = @(Get-LinuxCgroupProcessIds -CgroupPath $cgroupPath -Context 'Cgroup fixture')
        (($actual | Sort-Object) -join ',') | Should -BeExactly '21242,21243'

        $boundary = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-LinuxBoundaryProcessIds'
        }, $true)
        $boundary.Extent.Text | Should -Not -Match '\.ToArray\(\)'
    }

    # Scenario: A worker thread unshares CLONE_FILES and owns an fd table that /proc/<tgid>/fd does not expose.
    # Purpose: Require open-unlinked accounting to enumerate every /proc/<tgid>/task/<tid>/fd table.
    It 'UnitT135_EnumeratesEveryBoundaryTaskDescriptorTable' {
        $source = $ast.Extent.Text
        $source | Should -Match 'Path\.Combine\(processPath, "task"\)'
        $source | Should -Match 'Directory\.GetDirectories\(taskRoot\)'
        $source | Should -Match 'Path\.Combine\(taskPath, "fd"\)'
        $source | Should -Not -Match 'Path\.Combine\(processPath, "fd"\)'
    }

    # Scenario: A real managed worker thread owns an unshared descriptor table and retains one deleted file.
    # Purpose: Prove the native inspector accounts the thread-private fd instead of scanning only the TGID table.
    It 'InterT140_AccountsAThreadPrivateOpenUnlinkedFile' {
        if (-not $script:HostIsLinux) {
            Set-ItResult -Skipped -Because 'thread-private procfs descriptor accounting is Linux-only'
            return
        }
        if ($null -eq ('Codex.Validation.Tests.PrivateDescriptorTableFixture' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Codex.Validation.Tests {
    public static class PrivateDescriptorTableFixture {
        private const int CloneFiles = 0x00000400;
        private const int OpenReadWrite = 0x0002;
        private const int OpenCreate = 0x0040;
        private const int OpenExclusive = 0x0080;
        private const int OpenCloseOnExec = 0x80000;
        private static ManualResetEventSlim ready;
        private static ManualResetEventSlim release;
        private static Thread worker;
        private static Exception workerError;

        [DllImport("libc.so.6", EntryPoint = "unshare", SetLastError = true)]
        private static extern int Unshare(int flags);
        [DllImport("libc.so.6", EntryPoint = "open", SetLastError = true)]
        private static extern int Open(string path, int flags, uint mode);
        [DllImport("libc.so.6", EntryPoint = "ftruncate", SetLastError = true)]
        private static extern int Truncate(int fileDescriptor, long length);
        [DllImport("libc.so.6", EntryPoint = "unlink", SetLastError = true)]
        private static extern int Unlink(string path);
        [DllImport("libc.so.6", EntryPoint = "close", SetLastError = true)]
        private static extern int Close(int fileDescriptor);

        public static void Start(string path, long length) {
            if (worker != null) throw new InvalidOperationException("The private descriptor fixture is already running.");
            ready = new ManualResetEventSlim(false);
            release = new ManualResetEventSlim(false);
            workerError = null;
            worker = new Thread(() => {
                int fileDescriptor = -1;
                try {
                    if (Unshare(CloneFiles) != 0) throw new IOException("unshare(CLONE_FILES) failed with errno " + Marshal.GetLastWin32Error() + ".");
                    fileDescriptor = Open(path, OpenReadWrite | OpenCreate | OpenExclusive | OpenCloseOnExec, 384);
                    if (fileDescriptor < 0) throw new IOException("open failed with errno " + Marshal.GetLastWin32Error() + ".");
                    if (Truncate(fileDescriptor, length) != 0) throw new IOException("ftruncate failed with errno " + Marshal.GetLastWin32Error() + ".");
                    if (Unlink(path) != 0) throw new IOException("unlink failed with errno " + Marshal.GetLastWin32Error() + ".");
                    ready.Set();
                    release.Wait();
                }
                catch (Exception error) {
                    workerError = error;
                    ready.Set();
                }
                finally {
                    if (fileDescriptor >= 0) Close(fileDescriptor);
                }
            });
            worker.IsBackground = true;
            worker.Start();
            if (!ready.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("The private descriptor fixture did not become ready.");
            if (workerError != null) throw new InvalidOperationException("The private descriptor fixture failed.", workerError);
        }

        public static void Stop() {
            if (worker == null) return;
            release.Set();
            if (!worker.Join(TimeSpan.FromSeconds(10))) throw new TimeoutException("The private descriptor fixture did not stop.");
            ready.Dispose();
            release.Dispose();
            worker = null;
            ready = null;
            release = null;
            workerError = null;
        }
    }
}
'@
        }

        $path = Join-Path $script:UsageRoot 'thread-private-open-unlinked'
        [Codex.Validation.Tests.PrivateDescriptorTableFixture]::Start($path, 65539)
        try {
            $usage = Invoke-LinuxOpenUnlinkedInspection `
                -ProcessIds ([int[]]@($PID)) `
                -Root $script:UsageRoot `
                -MaximumEntries 100000
            $usage.EntryCount | Should -Be 1
            $usage.Bytes | Should -Be 65539
        }
        finally {
            [Codex.Validation.Tests.PrivateDescriptorTableFixture]::Stop()
        }
    }

    # Scenario: A hostile boundary churns thread-private descriptor tables while quota accounting takes a snapshot.
    # Purpose: Freeze the complete process boundary before both pathname and open-unlinked accounting, then always resume it.
    It 'UnitT145_FreezesTheBoundaryForOneConsistentWritableRootSnapshot' {
        $setCgroupFrozen = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Set-LinuxCgroupFrozen'
        }, $true)
        $testTasksStopped = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Test-LinuxProcessTasksStopped'
        }, $true)
        $suspend = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Suspend-LinuxWritableRootBoundary'
        }, $true)
        $resume = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Resume-LinuxWritableRootBoundary'
        }, $true)
        $assertUsage = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Assert-LinuxWritableRootUsage'
        }, $true)

        $setCgroupFrozen | Should -Not -BeNullOrEmpty
        $testTasksStopped | Should -Not -BeNullOrEmpty
        $suspend | Should -Not -BeNullOrEmpty
        $resume | Should -Not -BeNullOrEmpty
        if ($null -eq $setCgroupFrozen -or $null -eq $testTasksStopped -or $null -eq $suspend -or $null -eq $resume -or $null -eq $assertUsage) { return }

        $cgroupSource = $setCgroupFrozen.Extent.Text
        $taskStateSource = $testTasksStopped.Extent.Text
        $suspendSource = $suspend.Extent.Text
        $resumeSource = $resume.Extent.Text
        $assertSource = $assertUsage.Extent.Text
        $cgroupSource | Should -Match "'cgroup\.freeze'"
        $cgroupSource | Should -Match "'cgroup\.events'"
        $taskStateSource | Should -Match "'task'"
        $taskStateSource | Should -Match "'stat'"
        $suspendSource | Should -Match 'Test-LinuxProcessTasksStopped'
        $suspendSource | Should -Match 'Stop-UnixProcessByIdentity[\s\S]*?-Signal\s+19'
        $resumeSource | Should -Match 'Stop-UnixProcessByIdentity[\s\S]*?-Signal\s+18'
        $assertSource | Should -Match '(?s)Suspend-LinuxWritableRootBoundary.*?Get-LinuxWritableRootUsage.*?Invoke-LinuxOpenUnlinkedInspection.*?finally\s*\{.*?Resume-LinuxWritableRootBoundary'
    }

    # Scenario: A candidate passes deleted writable-root files through SCM_RIGHTS, leaving their only references queued in sockets.
    # Purpose: Make the kernel enforce the live aggregate allocation bound, then export only a bounded visible snapshot after the candidate PID namespace is empty.
    It 'UnitT150_UsesAKernelBoundedWritableTmpfsAndPostNamespaceExport' {
        $invokeNative = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $true)
        $proxy = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ProtectedPesterServerProxy'
        }, $true)
        $invokeNative | Should -Not -BeNullOrEmpty
        $proxy | Should -Not -BeNullOrEmpty
        if ($null -eq $invokeNative -or $null -eq $proxy) { return }

        foreach ($source in @($invokeNative.Extent.Text, $proxy.Extent.Text)) {
            $source | Should -Match ([regex]::Escape('"$mount_path" -t tmpfs -o size=536870912,nr_inodes=100001,nodev,nosuid tmpfs "$sandbox_root$child_writable_root"'))
            $source | Should -Not -Match ([regex]::Escape('"$mount_path" --bind "$child_writable_root" "$sandbox_root$child_writable_root"'))
            $source | Should -Match ([regex]::Escape('"$unshare_path" --mount --pid --fork --kill-child --mount-proc="$sandbox_root/proc"'))
            $source | Should -Match '\[IO\.FileMode\]::CreateNew'
            $source | Should -Match '\.child-writable-export-manifest'
            $source | Should -Match ([regex]::Escape('manifest_path="${11}"'))
            $source | Should -Not -Match ([regex]::Escape('manifest_path="$sandbox_root/'))
            $source | Should -Match "-xdev -mindepth 1 -printf '%y %s\\n'"
            $source | Should -Match 'd\|f\)'
            $source | Should -Not -Match '(?i)remove_path|rm\s+-rf'
            $source | Should -Match 'entry_count\s*=\s*\$\(\(entry_count \+ 1\)\)'
            $source | Should -Match '\[ "\$entry_count" -le 100000 \]'
            $source | Should -Match '\[ "\$total_bytes" -le 536870912 \]'
            $candidateExitIndex = $source.IndexOf('candidate_status=$?', [StringComparison]::Ordinal)
            $manifestIndex = $source.IndexOf('entry_count=0', [StringComparison]::Ordinal)
            $exportIndex = $source.IndexOf('"$copy_path" -a -- "$sandbox_root$child_writable_root/." "$child_writable_root/"', [StringComparison]::Ordinal)
            $statusExitIndex = $source.IndexOf('exit "$candidate_status"', [StringComparison]::Ordinal)
            $candidateExitIndex | Should -BeGreaterOrEqual 0
            $candidateExitIndex | Should -BeLessThan $manifestIndex
            $manifestIndex | Should -BeLessThan $exportIndex
            $exportIndex | Should -BeLessThan $statusExitIndex
        }
    }

    # Scenario: A candidate creates arbitrarily many hard links to one tmpfs inode while it is still running.
    # Purpose: Charge live dentry and other kernel-memory growth to a hard cgroup limit before either sandbox can execute candidate code.
    It 'UnitT155_BindsBothLinuxSandboxesToAKernelMemoryCgroupBeforeCandidateExecution' {
        $newCgroup = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-LinuxCandidateCgroup'
        }, $true)
        $assertCgroup = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-CurrentLinuxCandidateCgroup'
        }, $true)
        $removeCgroup = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Remove-LinuxCandidateCgroup'
        }, $true)
        $invokeNative = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
        }, $true)
        $proxy = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ProtectedPesterServerProxy'
        }, $true)
        $runspace = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-ProtectedPesterRunspace'
        }, $true)

        $newCgroup | Should -Not -BeNullOrEmpty
        $assertCgroup | Should -Not -BeNullOrEmpty
        $removeCgroup | Should -Not -BeNullOrEmpty
        $invokeNative | Should -Not -BeNullOrEmpty
        $proxy | Should -Not -BeNullOrEmpty
        $runspace | Should -Not -BeNullOrEmpty
        if ($null -in @($newCgroup, $assertCgroup, $removeCgroup, $invokeNative, $proxy, $runspace)) { return }

        $newSource = $newCgroup.Extent.Text
        $assertSource = $assertCgroup.Extent.Text
        $newSource | Should -Match 'codex-validation-candidate-\{0\}'
        $newSource | Should -Match '\[IO\.File\]::WriteAllText\(\$memoryMaxPath, ''2147483648''\)'
        $assertSource | Should -Match '/proc/\$PID/cgroup'
        $assertSource | Should -Match '\[IO\.File\]::ReadAllText\(\$memoryMaxPath\)'

        $nativeSource = $invokeNative.Extent.Text
        $nativeSource | Should -Match 'New-LinuxCandidateCgroup\s+-Context\s+\$Context'
        $nativeSource | Should -Match 'Remove-LinuxCandidateCgroup\s+-CgroupPath\s+\$linuxNativeCgroupPath'
        $nativeSource | Should -Match ([regex]::Escape('cgroup_path="${13}"'))
        $selfMigration = 'printf ''%s\n'' "$$" > "$cgroup_path/cgroup.procs"'
        $nativeSource | Should -Match ([regex]::Escape($selfMigration))
        $nativeCgroupIndex = $nativeSource.IndexOf($selfMigration, [StringComparison]::Ordinal)
        $nativeCandidateIndex = $nativeSource.IndexOf('"$unshare_path" --mount --pid --fork --kill-child', [StringComparison]::Ordinal)
        $nativeCgroupIndex | Should -BeGreaterOrEqual 0
        $nativeCgroupIndex | Should -BeLessThan $nativeCandidateIndex

        $proxySource = $proxy.Extent.Text
        $proxySource | Should -Match 'Assert-CurrentLinuxCandidateCgroup'
        $proxySource | Should -Match '\[IO\.File\]::WriteAllText\([\s\S]*?cgroup\.procs'
        $proxySource | Should -Match ([regex]::Escape('cgroup_path="${13}"'))
        $proxySource | Should -Match ([regex]::Escape($selfMigration))
        $proxyMigrationIndex = $proxySource.IndexOf("(Join-Path `$linuxProxyCgroupPath 'cgroup.procs')", [StringComparison]::Ordinal)
        $proxySandboxIndex = $proxySource.IndexOf('$maskHostSocketsScript =', [StringComparison]::Ordinal)
        $proxyMigrationIndex | Should -BeGreaterOrEqual 0
        $proxyMigrationIndex | Should -BeLessThan $proxySandboxIndex
        $runspaceSource = $runspace.Extent.Text
        $runspaceSource | Should -Match 'New-LinuxCandidateCgroup'
        $runspaceSource | Should -Match 'Remove-LinuxCandidateCgroup'
        $runspaceSource | Should -Match '''-PesterProxyCgroupPath'', \$linuxPesterCgroupPath'
        $runspaceSource | Should -Not -Match 'Add-LinuxProcessTreeToCgroup'
    }

    # Scenario: PowerShell's FileSystem provider enumerates cgroupfs control files as children and prompts for recursion.
    # Purpose: Remove an already-unpopulated cgroup with the non-recursive OS directory operation instead of an interactive provider command.
    It 'UnitT160_RemovesUnpopulatedLinuxCgroupsWithoutProviderPrompts' {
        $newCgroup = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-LinuxCandidateCgroup'
        }, $true)
        $removeCgroup = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Remove-LinuxCandidateCgroup'
        }, $true)

        $newCgroup | Should -Not -BeNullOrEmpty
        $removeCgroup | Should -Not -BeNullOrEmpty
        if ($null -in @($newCgroup, $removeCgroup)) { return }

        $newSource = $newCgroup.Extent.Text
        $removeSource = $removeCgroup.Extent.Text
        $newSource | Should -Match '\[IO\.Directory\]::Delete\(\$cgroupPath\)'
        $removeSource | Should -Match '\[IO\.Directory\]::Delete\(\$CgroupPath\)'
        $newSource | Should -Not -Match 'Remove-Item[^\r\n]*\$cgroupPath'
        $removeSource | Should -Not -Match 'Remove-Item[^\r\n]*\$CgroupPath'
        $removeSource | Should -Match '\[string\]\$Matches\[''value''\]\s+-eq\s+''0'''
    }
}
