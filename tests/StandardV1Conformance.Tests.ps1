# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Darktide Translate Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
    }

    It 'uses the canonical schema v2 source inventory and source root' {
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -PathType Container | Should -BeTrue
        $source = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json -Depth 20
        @($source.PSObject.Properties.Name) | Should -Be @('schemaVersion','sourceId','repository','skillsRoot','skills')
        $source.schemaVersion | Should -Be 2
        $source.sourceId | Should -Be 'darktide-translate'
        $source.repository | Should -Be 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
        $source.skillsRoot | Should -Be 'skills'
        @($source.skills) | Should -Be @('auto-update-darktide-mod')
        $projectionRoot = Join-Path $script:RepositoryRoot '.agents/skills'
        if (Test-Path -LiteralPath $projectionRoot) {
            $manifestPath = Join-Path $script:RepositoryRoot '.codex/ai-instructions.manifest.json'
            Test-Path -LiteralPath $manifestPath -PathType Leaf | Should -BeTrue
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 30
            @($manifest.files | Where-Object { $_.artifactType -eq 'skill' }).Count | Should -BeGreaterThan 0
            @($manifest.files | Where-Object { $_.targetPath -like '.agents/skills/*' }).Count | Should -BeGreaterThan 0
        }
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.agents/skills/auto-update-darktide-mod') | Should -BeFalse
    }

    It 'binds one immutable central authority snapshot without a local security policy' {
        $adapter = Get-Content -LiteralPath $script:AdapterPath -Raw | ConvertFrom-Json -Depth 20
        $adapter.schemaVersion | Should -Be 1
        $adapter.standardVersion | Should -Be 'v1'
        $adapter.authority.repository | Should -Be 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $adapter.authority.commit | Should -Match '^[0-9a-f]{40}$'
        $adapter.authority.archiveSha256 | Should -Match '^[0-9a-f]{64}$'
        @($adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/skill-repository-standard.md'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/validation-security-gate.json'
        @($adapter.authority.files.path) | Should -Contain 'scripts/Resolve-StandardValidationTool.ps1'
        $adapter.deviations | Should -Be 'None'
    }

    # Scenario: source validation uses the central Core v2 adapter and frozen real tools.
    # Purpose: Bind the current executable gate rather than the inactive legacy fixture.
    It 'exposes the canonical source validator and central tool integration' {
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        foreach ($name in @('Test-Repository.ps1','skillspector','skill-validator','skill-tools','SourceValidation','PrepareSourceTools','Invoke-StandardValidation.ps1','New-StandardCoreAdapterV2','Assert-AuthorityConfig')) {
            $validator | Should -Match ([regex]::Escape($name))
        }
        $validator | Should -Not -Match 'approvedAuthorityCommit|LegacyValidate.ps1'
    }
}