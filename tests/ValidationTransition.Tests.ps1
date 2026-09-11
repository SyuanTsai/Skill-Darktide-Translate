# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Standard v1 migration and canonical validation contracts' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:CanonicalValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:PrePushPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PrePushValidation.ps1'
        $script:WorkflowRoot = Join-Path $script:RepositoryRoot '.github/workflows'
    }

    # Scenario: The live source candidate is inspected after the migration.
    # Purpose: Keep source-owned packages in the canonical root and prevent a mixed legacy/Standard tree.
    It 'UnitT10_UsesOnlyTheCanonicalSourceRootAndRejectsLegacyLiveMarkers' {
        $sourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -Depth 20
        $source.schemaVersion | Should -Be 2
        $source.skillsRoot | Should -Be 'skills'

        $actualSkillIds = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Directory -Force |
            Select-Object -ExpandProperty Name | Sort-Object)
        @($source.skills | Sort-Object) | Should -Be $actualSkillIds
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.agents/skills/auto-update-darktide-mod') -PathType Container | Should -BeFalse
    }

    # Scenario: Standard v1 validation acquires the exact authority revision named by the migration request.
    # Purpose: Make authority drift, archive substitution, and stale required-file hashes fail closed.
    It 'UnitT20_BindsTheRequestedImmutableAuthorityArchiveAndRequiredFiles' {
        $adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 30
        $adapter.authority.repository | Should -Be 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $adapter.authority.commit | Should -Be 'd38eba3faf967504751aba759f38102e7538a519'
        $adapter.authority.archiveUrl | Should -Be 'https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/d38eba3faf967504751aba759f38102e7538a519'
        $adapter.authority.archiveSha256 | Should -Be 'ca1b20dc79ae978d30cc7f400aa6ebd3dbe321e96e526cfbb2b421d6a477f38f'

        $expected = [ordered]@{
            'docs/standards/README.md' = '202f180ff1b32badb37c135e5eec3b7938db35f4137822c6a91aee3d3f8c29dd'
            'docs/standards/managed-skill-lifecycle.md' = '70950cf8bdd02819efae6f6e06ac5be1da3e70f809c23e3c6f8d3b217797416c'
            'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json' = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863'
            'docs/standards/schemas/openai-agent-metadata.schema.json' = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a'
            'docs/standards/schemas/source-inventory-v2.schema.json' = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e'
            'docs/standards/schemas/validation-security-gate-v1.schema.json' = '2502efc27c823fcc4109b767fe360579e4de9f59e509a4500eb92753349d3ced'
            'docs/standards/skill-repository-review-matrix.md' = '93b3ced32506196a333b85aaa964995d46d95d75f0b7f6ffee31d1d692aada7e'
            'docs/standards/skill-repository-standard.md' = 'd6dfbd47bf350daaeb3cb3139abe9cd563cf73977e0df0493c3b3e2681e8c4bf'
            'docs/standards/upstream-interoperability.md' = '9c544fbfb6b77a589514f1926aa1488882e932786a303a42ce6c6c9b2ba80c7e'
            'docs/standards/validation-security-gate.json' = '8c0a7e9e739e600817c4e5ef34c18db3e22ed19907bda589de0f8252e6763181'
            'docs/standards/validation-toolchain.json' = '5925dcb1aea1e545b9787a29825e7a0cc03a04c777cd68ab44c9bdd7482ff579'
            'scripts/Invoke-StandardAuthorityGate.ps1' = '9243ee067e20000e75293f74662df98332225183d34673e248ef0b9f7662dabd'
            'scripts/Resolve-PythonWheelClosure.py' = '7fa1511a3e3ba257c6d9e37f929f68e5684184a3a2756a3f9e765ccc6e69d208'
            'scripts/Resolve-StandardValidationTool.ps1' = 'f8ae4fdd98c653aa00cd170ddedd1621dcc6306bc2580a6ad69f5c6ace46c521'
        }
        @($adapter.authority.files).Count | Should -Be $expected.Count
        foreach ($entry in @($adapter.authority.files)) {
            $expected.Contains([string]$entry.path) | Should -BeTrue
            $entry.sha256 | Should -Be $expected[[string]$entry.path]
        }
    }

    # Scenario: A validation-related workflow or pre-push entry point is added beside the canonical adapter.
    # Purpose: Prevent a second validator/policy from handling the same candidate or event.
    It 'UnitT30_RejectsAlternateWorkflowPoliciesAndRequiresTheCanonicalEntry' {
        $workflowFiles = @(Get-ChildItem -LiteralPath $script:WorkflowRoot -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.yml', '.yaml') })
        $workflowFiles.Count | Should -BeGreaterThan 0
        foreach ($workflowFile in $workflowFiles) {
            $workflow = Get-Content -LiteralPath $workflowFile.FullName -Raw
            $workflow | Should -Not -Match '(?m)^\s*pull_request:\s*$'
            $workflow | Should -Not -Match 'skill-validator@latest|skill-tools@latest'
            if ($workflow -match '(?i)skill-validator|skill-tools|SkillSpector|Invoke-Pester|Test-Repository|validation') {
                $workflow | Should -Match 'scripts/Validate\.ps1'
            }
        }

        Test-Path -LiteralPath (Join-Path $script:WorkflowRoot 'skill-validator.yml') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:WorkflowRoot 'validate.yml') -PathType Leaf | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.githooks') -PathType Container | Should -BeFalse

        $prePush = Get-Content -LiteralPath $script:PrePushPath -Raw
        $prePush | Should -Match 'scripts/Validate\.ps1'
        $prePush | Should -Not -Match 'Test-CleanRepositoryHead|Test-Repository|Test-ReferenceIntegrity|Invoke-Pester|skill-validator|skill-tools|SkillSpector|security'
    }

    # Scenario: Protected pull requests, trusted pushes, and manually dispatched runs enter the same validation contract.
    # Purpose: Preserve one candidate execution while allowing only trigger/security-adapter differences.
    It 'UnitT40_MapsProtectedTrustedAndManualEventsToOneCanonicalValidator' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:WorkflowRoot 'standard-v1-protected.yml') -Raw
        $workflow | Should -Match '(?m)^\s{2}pull_request_target:\s*$'
        $workflow | Should -Match '(?ms)^\s{2}push:\s*\r?\n\s{4}branches:\s*\r?\n\s{6}- main'
        $workflow | Should -Match '(?m)^\s{2}workflow_dispatch:\s*$'
        $workflow | Should -Not -Match '(?m)^\s{2}pull_request:\s*$'
        $workflow | Should -Match 'trustedValidator = Join-Path \$env:TRUSTED_SUPERVISOR_ROOT .+scripts/Validate\.ps1'
        ([regex]::Matches($workflow, 'id: canonical-validation')).Count | Should -Be 1
        ([regex]::Matches($workflow, 'scripts/Validate\.ps1')).Count | Should -BeGreaterThan 0
    }

    # Scenario: Compatibility check names are retained for existing required-status consumers.
    # Purpose: Make every retained status a direct mirror of canonical-validation result, never an always-success policy.
    It 'UnitT50_MakesCompatibilityStatusesMirrorCanonicalResult' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:WorkflowRoot 'standard-v1-protected.yml') -Raw
        foreach ($name in @('repository-contract', 'skill-validator', 'skill-tools')) {
            $workflow | Should -Match ("(?sm)^\s+{0}:.*?needs:\s*\r?\n\s+- canonical-validation.*?CANONICAL_RESULT.*?needs\['canonical-validation'\]\.result" -f [regex]::Escape($name))
            $workflow | Should -Match ("(?sm)^\s+{0}:.*?CANONICAL_RESULT.*?!= 'success'.*?exit 1" -f [regex]::Escape($name))
        }
    }

    # Scenario: Documentation describes validation entry points after the migration.
    # Purpose: Keep component diagnostics from becoming an undocumented alternate release gate.
    It 'UnitT60_DocumentsValidateAsTheOnlyCompleteLocalGate' {
        foreach ($path in @('README.md', 'docs/RELEASE.md', 'docs/ROLLBACK.md')) {
            $text = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $path) -Raw
            $text | Should -Match 'scripts/Validate\.ps1'
            $text | Should -Match 'component'
        }
        (Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'README.md') -Raw) |
            Should -Match 'pwsh -NoLogo -NoProfile -File ./scripts/Validate\.ps1'
    }

    # Scenario: The repository validator receives a caller-selected output path.
    # Purpose: Require exclusive UTF-8 creation and prevent overwrite/partial-output races.
    It 'UnitT70_UsesExclusiveNoBomValidationOutputWriters' {
        $repositoryValidator = Get-Content -LiteralPath $script:RepositoryValidatorPath -Raw
        $canonicalValidator = Get-Content -LiteralPath $script:CanonicalValidatorPath -Raw
        foreach ($source in @($repositoryValidator, $canonicalValidator)) {
            $source | Should -Match '\[IO\.File\]::Open\(\s*\$Path\s*,\s*\[IO\.FileMode\]::CreateNew\s*,\s*\[IO\.FileAccess\]::Write\s*,\s*\[IO\.FileShare\]::None'
            $source | Should -Match '\[Text\.UTF8Encoding\]::new\(\$false\)'
            $source | Should -Match '(?s)try\s*\{.*?\.Flush\(\$true\).*?finally\s*\{.*?Dispose\(\)'
        }
        $repositoryValidator | Should -Not -Match '\[IO\.File\]::WriteAllText\(\$outputFullPath'
    }
}
