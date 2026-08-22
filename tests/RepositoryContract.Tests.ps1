Describe 'Darktide Translate repository contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
    }

    # Scenario: A consumer discovers this repository through its stable catalog.
    # Purpose: Protect the source ID, repository URL, Skill path, and opt-in profile contract.
    It 'UnitT10_ExposesTheStableSourceSkillAndProfileContract' {
        $catalogPath = Join-Path $repoRoot 'catalog/skills-catalog.json'
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
        $skill.source.path | Should -Be '.agents/skills/auto-update-darktide-mod'
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
        $expectedPaths = @(
            '.agents/skills/auto-update-darktide-mod/SKILL.md',
            '.agents/skills/auto-update-darktide-mod/agents/openai.yaml',
            '.agents/skills/auto-update-darktide-mod/references/package-binding.md',
            '.agents/skills/auto-update-darktide-mod/assets/workflow-schema-14.md.gz',
            '.agents/skills/auto-update-darktide-mod/assets/review-baseline.md.gz',
            '.agents/skills/auto-update-darktide-mod/references/source-provenance.json',
            '.agents/skills/auto-update-darktide-mod/references/automation.md',
            '.agents/skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1',
            '.agents/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1',
            '.agents/skills/auto-update-darktide-mod/scripts/mod-update.ps1',
            '.agents/skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1',
            '.github/workflows/validate.yml',
            '.github/workflows/skill-validator.yml',
            'catalog/skills-catalog.json',
            'docs/RELEASE.md',
            'docs/ROLLBACK.md',
            'scripts/Get-SourcePin.ps1',
            'tests/Invoke-Tests.ps1',
            'VERSION'
        )

        foreach ($path in $expectedPaths) {
            Test-Path -LiteralPath (Join-Path $repoRoot $path) | Should -Be $true
        }

        $skillRoot = Join-Path $repoRoot '.agents/skills'
        $actualSkillDirectories = @(
            Get-ChildItem -LiteralPath $skillRoot -Directory |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )
        ($actualSkillDirectories -join "`n") | Should -Be 'auto-update-darktide-mod'
    }

    # Scenario: The independent source remains intentionally outside AI-Instructions fan-out.
    # Purpose: Prevent the Darktide Skill from being reintroduced into an unrelated consumer Catalog or bootstrap contract.
    It 'UnitT25_RemainsAnIndependentRepositorySource' {
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $catalog = Get-Content -LiteralPath (Join-Path $repoRoot 'catalog/skills-catalog.json') -Raw | ConvertFrom-Json

        $readme | Should -Match 'not added to the AI-Instructions Catalog, Lock, bootstrap, or fan-out'
        @($catalog.sources).Count | Should -Be 1
        $catalog.sources[0].id | Should -Be 'darktide-translate'
    }

    # Scenario: A release process resolves the repository version before pin generation.
    # Purpose: Keep source pins compatible with the SYP-81 through SYP-84 SemVer contract.
    It 'UnitT30_UsesASemVerCompatibleRepositoryVersion' {
        $versionPath = Join-Path $repoRoot 'VERSION'
        Test-Path -LiteralPath $versionPath | Should -Be $true
        $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
        $version | Should -Match '^\d+\.\d+\.\d+$'
    }

    # Scenario: GitHub validates a branch or pull request using the shared SYP-81 through SYP-84 tool policy.
    # Purpose: Prevent the repository from silently pinning stale quality tools or weakening the required gates.
    It 'UnitT40_PreservesTheSharedLatestAtRunTimeQualityGate' {
        $qualityPath = Join-Path $repoRoot '.github/workflows/skill-validator.yml'
        $validatePath = Join-Path $repoRoot '.github/workflows/validate.yml'
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
        $validate | Should -Match 'tests/Invoke-Tests\.ps1'
        $validate | Should -Match 'Test-ReferenceIntegrity\.ps1'
        $validate | Should -Match 'scripts/Get-SourcePin\.ps1 -Ref HEAD'

        $exactHeadRef = 'ref: ${{ github.event_name == ''pull_request'' && github.event.pull_request.head.sha || github.sha }}'
        $validate | Should -Match ([regex]::Escape($exactHeadRef))
        ([regex]::Matches($quality, [regex]::Escape($exactHeadRef))).Count | Should -Be 2
    }
}
