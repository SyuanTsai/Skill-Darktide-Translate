# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Darktide Translate layout conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Layout = Get-TestRepositoryLayout -RepositoryRoot $script:RepositoryRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot $(if ($script:Layout.Name -ceq 'legacy') { 'catalog/skills-catalog.json' } else { 'catalog/source.json' })
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
    }

    # Scenario: The active layout exposes exactly one source-owned Skill package.
    # Purpose: Validate the legacy catalog without claiming it is Standard v1.
    It 'UnitT10_ValidatesTheActiveLayoutSourceInventory' {
        if ($script:Layout.Name -ceq 'legacy') {
            $catalog = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json -Depth 20
            $catalog.schemaVersion | Should -Be 1
            $catalog.catalogId | Should -Be 'darktide-translate'
            $catalog.sources[0].id | Should -Be 'darktide-translate'
            $catalog.sources[0].repository | Should -Be 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
            $catalog.skills[0].source.path | Should -Be '.agents/skills/auto-update-darktide-mod'
            Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.agents/skills/auto-update-darktide-mod') -PathType Container | Should -BeTrue
            foreach ($marker in @('catalog/source.json', 'config/standard-v1.json', 'skills')) {
                Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $marker) | Should -BeFalse
            }
            return
        }
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

    # Scenario: The active validation mode rejects incompatible source-layout authority markers.
    # Purpose: Keep bootstrap validation bounded before promotion.
    It 'UnitT20_BindsTheActiveValidationAuthority' {
        if ($script:Layout.Name -ceq 'legacy') {
            $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
            $validator | Should -Match 'Invoke-BootstrapTransitionValidation'
            $validator.IndexOf('if ($BootstrapTransition)') | Should -BeLessThan $validator.IndexOf('$adapterPath = Join-Path $repoRoot')
            $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
            $repositoryValidator | Should -Match 'Bootstrap transition is valid only before the Standard v1 source inventory, adapter, or skills/ root is promoted.'
            return
        }
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

    # Scenario: Both layouts retain the trusted validation implementation.
    # Purpose: Keep tool and repository-validator binding independent of source layout.
    It 'UnitT30_ExposesTheCanonicalValidatorAndCentralToolIntegration' {
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validator | Should -Match 'Test-Repository\.ps1'
        $validator | Should -Match 'skillspector'
        $validator | Should -Match 'skill-validator'
        $validator | Should -Match 'skill-tools'
        $validator | Should -Match 'Invoke-Pester'
        $validator | Should -Match '\[string\] \$BaseCommit'
        $validator | Should -Match 'repositoryValidatorBytes'
        $validator | Should -Match 'postPesterRepositoryValidatorScript'
        $validator | Should -Match '\[scriptblock\]::Create'
        $validator | Should -Not -Match 'postPesterRepositoryValidatorPath'
    }

    # Scenario: CI has an event-bound supervisor identity while a local operator starts at a clean immutable candidate.
    # Purpose: Keep trusted Pester test selection independent of the diff base and reject a mismatched supervisor identity.
    It 'UnitT40_BindsProtectedPesterTestsToTheTrustedExecutionAuthority' {
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validator | Should -Match '\$isGitHubActions\s*=\s*\[string\]\$env:GITHUB_ACTIONS\s+-ceq\s+''true'''
        $validator | Should -Match '\$trustedPesterCommit\s*=\s*if \(\$isGitHubActions\) \{ \[string\]\$env:GITHUB_SHA \} else \{ \$candidateCommit \}'
        $validator | Should -Match 'TRUSTED_SUPERVISOR_COMMIT'
        $validator | Should -Match 'does not match the GitHub event-bound trusted supervisor commit'
        $validator | Should -Not -Match '\$trustedPesterCommit\s*=\s*\[string\]\$BaseCommit'
        $validator | Should -Match 'testAuthorityCommit\s*=\s*\$trustedPesterCommit'
    }

    # Scenario: Required workflows retain their event-bound validation routes.
    # Purpose: Exercise the concurrent protected and legacy workflow contracts during transition.
    It 'UnitT50_RoutesCiThroughTheActiveLayoutContract' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_COMMIT: \$\{\{ github\.sha \}\}'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
        $workflow | Should -Match 'actions/setup-go@[0-9a-f]{40}'
        $workflow | Should -Match 'Export canonical evidence for clean upload'
        $workflow | Should -Match 'upload-canonical-validation-evidence'
        $workflow | Should -Match 'evidence_base64'
        $workflow | Should -Not -Match '(?m)^\s*(Install-Module|npm install|go install|pip install)\b'
        if ($script:Layout.Name -ceq 'legacy') {
            foreach ($workflowName in @('validate.yml', 'skill-validator.yml')) {
                $legacyWorkflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot ".github/workflows/$workflowName") -Raw
                $legacyWorkflow | Should -Match '(?m)^  push:'
                $legacyWorkflow | Should -Match '(?m)^  pull_request:'
            }
            $legacyValidate = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validate.yml') -Raw
            $legacyValidate | Should -Match 'scripts/Invoke-PrePushValidation\.ps1'
            return
        }
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/skill-validator.yml') | Should -BeFalse

        foreach ($context in @('repository-contract', 'skill-validator', 'skill-tools')) {
            $pattern = "(?ms)^\s+{0}:\s+name:\s+{0}.*?needs:\s+- canonical-validation.*?{1}" -f `
                [regex]::Escape($context),
                [regex]::Escape("needs['canonical-validation'].result")
            $workflow | Should -Match $pattern
        }
    }
}
