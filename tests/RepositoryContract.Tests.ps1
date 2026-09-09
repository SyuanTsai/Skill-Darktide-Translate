# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Darktide Translate repository contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $layout = Get-TestRepositoryLayout -RepositoryRoot $repoRoot
    }

    # Scenario: A consumer discovers this repository through its stable catalog.
    # Purpose: Protect the source ID, repository URL, Skill path, and opt-in profile contract.
    It 'UnitT10_ExposesTheStableSourceSkillAndProfileContract' {
        $catalogPath = Join-Path $repoRoot $layout.CatalogPath
        Test-Path -LiteralPath $catalogPath | Should -Be $true

        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
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
            'scripts/Invoke-PrePushValidation.ps1',
            'scripts/Test-CleanRepositoryHead.ps1',
            'tests/Invoke-Tests.ps1',
            'VERSION'
        )
        if ($layout.Name -ceq 'legacy') {
            $expectedPaths += @(
                '.github/workflows/validate.yml',
                '.github/workflows/skill-validator.yml',
                'catalog/skills-catalog.json'
            )
        }
        else {
            $expectedPaths += @(
                '.github/workflows/standard-v1-protected.yml',
                'catalog/source.json',
                'catalog/profiles.json',
                'config/standard-v1.json',
                'scripts/Test-Repository.ps1',
                'scripts/Validate.ps1'
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

        $modulePaths = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.psm1' |
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

        $sourceRepository = Join-Path $TestDrive 'windows-git-source'
        $freshCheckout = Join-Path $TestDrive 'windows-git-checkout'
        New-Item -ItemType Directory -Path $sourceRepository -Force | Out-Null
        Copy-Item -LiteralPath $attributesPath -Destination (Join-Path $sourceRepository '.gitattributes')
        foreach ($modulePath in $modulePaths) {
            $sourcePath = Join-Path $repoRoot $modulePath
            $fixturePath = Join-Path $sourceRepository $modulePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $fixturePath) -Force | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $fixturePath
        }
        & git -C $sourceRepository init --quiet --initial-branch=main
        & git -C $sourceRepository config user.name 'EOL Contract Test'
        & git -C $sourceRepository config user.email 'eol-contract@example.invalid'
        & git -C $sourceRepository config core.autocrlf true
        & git -C $sourceRepository add --all
        & git -C $sourceRepository commit --quiet -m 'fixture LF source'
        $LASTEXITCODE | Should -Be 0
        & git -c core.autocrlf=true clone --quiet $sourceRepository $freshCheckout
        $LASTEXITCODE | Should -Be 0

        foreach ($modulePath in $modulePaths) {
            $sourceBlobOid = (& git -C $sourceRepository rev-parse "HEAD:$modulePath").Trim()
            $checkoutRawOid = (& git -C $freshCheckout hash-object --no-filters -- $modulePath).Trim()
            $LASTEXITCODE | Should -Be 0
            $checkoutRawOid | Should -Be $sourceBlobOid -Because $modulePath
        }
    }

    # Scenario: The independent source remains intentionally outside AI-Instructions fan-out.
    # Purpose: Prevent the Darktide Skill from being reintroduced into an unrelated consumer Catalog or bootstrap contract.
    It 'UnitT25_RemainsAnIndependentRepositorySource' {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $catalog = Get-Content -LiteralPath (Join-Path $repoRoot $layout.CatalogPath) -Raw | ConvertFrom-Json

        $readme | Should -Match 'not added to the AI-Instructions Catalog, Lock, bootstrap, or fan-out'
        @($catalog.sources).Count | Should -Be 1
        $catalog.sources[0].id | Should -Be 'darktide-translate'
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
        if ($layout.Name -ceq 'legacy') {
            $qualityPath = Join-Path $repoRoot $layout.QualityWorkflowPath
            $validatePath = Join-Path $repoRoot $layout.WorkflowPath
            Test-Path -LiteralPath $qualityPath | Should -Be $true
            Test-Path -LiteralPath $validatePath | Should -Be $true

            $quality = Get-Content -LiteralPath $qualityPath -Raw
            $quality | Should -Match 'go-version: stable'
            $quality | Should -Match 'check-latest: true'
            $quality | Should -Match 'skill-validator/cmd/skill-validator@latest'
            $quality | Should -Match "node-version: 'lts/\*'"
            $quality | Should -Match 'skill-tools@latest'
            $quality | Should -Match 'check --strict --allow-dirs=agents --emit-annotations'
            $quality | Should -Match '--fail-on warning'
            $quality | Should -Match '--min-score 91'

            $validate = Get-Content -LiteralPath $validatePath -Raw
            $validate | Should -Match 'MinimumVersion 5\.0\.0'
            $validate | Should -Match 'scripts/Invoke-PrePushValidation\.ps1'

            $exactHeadRef = 'ref: ${{ github.event_name == ''pull_request'' && github.event.pull_request.head.sha || github.sha }}'
            $validate | Should -Match ([regex]::Escape($exactHeadRef))
            ([regex]::Matches($quality, [regex]::Escape($exactHeadRef))).Count | Should -Be 2
        }
        else {
            $workflow = Get-Content -LiteralPath (Join-Path $repoRoot $layout.WorkflowPath) -Raw
            Test-Path -LiteralPath (Join-Path $repoRoot '.github/workflows/skill-validator.yml') | Should -Be $false
            $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
            $workflow | Should -Match 'actions/setup-go@[0-9a-f]{40}'
            $workflow | Should -Match 'persist-credentials:\s*false'
            $workflow | Should -Match "go-version: 'stable'"
            $workflow | Should -Match 'check-latest: true'
            $workflow | Should -Not -Match "go-version: '[0-9]+\.[0-9]+\.[0-9]+'"
            $workflow | Should -Match 'scripts/Validate\.ps1'
        }
    }
}
