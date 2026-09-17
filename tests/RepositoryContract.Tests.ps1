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

    # Scenario: The Linux sandbox receives no optional read-only bind paths and
    # GNU stat classifies an empty file as a regular empty file.
    # Purpose: Keep the protected base supervisor from turning valid empty
    # files or an omitted optional path list into GetFullPath(empty) failures.
    It 'UnitT50_AcceptsEmptyOptionalReadOnlyPathsAndGnuEmptyFiles' {
        $validator = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Validate.ps1') -Raw
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/Test-Repository.ps1') -Raw

        $validator | Should -Match '\[Parameter\(\)\]\[AllowEmptyCollection\(\)\]\[string\[\]\] \$ReadOnlyPaths = @\(\)'
        $validator | Should -Match 'readOnlyPathText = \[string\]\$readOnlyPath'
        $validator | Should -Match 'IsNullOrWhiteSpace\(\$readOnlyPathText\)'
        $validator | Should -Match "-cnotin @\('regular file', 'regular empty file'\)"
        $repositoryValidator | Should -Match "-cnotin @\('regular file', 'regular empty file'\)"
    }
}
