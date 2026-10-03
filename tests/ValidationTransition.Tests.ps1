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
        $adapter.authority.commit | Should -Be 'a403abdf038a3346d775431a6908a71cc3d35a5b'
        $adapter.authority.archiveUrl | Should -Be 'https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/a403abdf038a3346d775431a6908a71cc3d35a5b'
        $adapter.authority.archiveSha256 | Should -Be '17154929fadfa63487263db1efcb78f4948195af9c11c25a66432eff3411b2d3'

        $expected = [ordered]@{
            'docs/standards/README.md' = '5e1ddd737d26a5ec1ff1ebd08e158376ddaf1ea21008bb987fc7f51376923f7c'
            'docs/standards/managed-skill-lifecycle.md' = '70950cf8bdd02819efae6f6e06ac5be1da3e70f809c23e3c6f8d3b217797416c'
            'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json' = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863'
            'docs/standards/schemas/openai-agent-metadata.schema.json' = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a'
            'docs/standards/schemas/source-inventory-v2.schema.json' = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e'
            'docs/standards/schemas/validation-security-gate-v1.schema.json' = '56979baa08f3ec5534e3a17f925d53e69accd4cdc500872e92ca56b694044ea6'
            'docs/standards/skill-repository-review-matrix.md' = 'c345ad3ec32d1941df5c5757ce96b4430c0223b3f8ed99f2a4de7dc9923410f2'
            'docs/standards/skill-repository-standard.md' = '78a72aa8214acd5a5e202df34bbb20f8cfd841ab3d181de10645a777267cfd5d'
            'docs/standards/upstream-interoperability.md' = '9c544fbfb6b77a589514f1926aa1488882e932786a303a42ce6c6c9b2ba80c7e'
            'docs/standards/validation-security-gate.json' = 'e303e8c3d484012022f5c4da694c3fe21ff02395b0b9b7e973a4234d4182f485'
            'docs/standards/validation-toolchain.json' = '5925dcb1aea1e545b9787a29825e7a0cc03a04c777cd68ab44c9bdd7482ff579'
            'scripts/Invoke-StandardAuthorityGate.ps1' = 'c98d3f1b181ba0e7d3894729a8f1636984407c20454a27e0e383799c2f90425f'
            'scripts/Resolve-PythonWheelClosure.py' = '7fa1511a3e3ba257c6d9e37f929f68e5684184a3a2756a3f9e765ccc6e69d208'
            'scripts/Resolve-StandardValidationTool.ps1' = '3744bc4549612e5997361315a8fd5e1ea803ade26052cf4eaf2ccdc1776fcf6e'
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
            if ($workflowFile.Name -cne 'standard-v1-candidate-windows.yml') {
                $workflow | Should -Not -Match '(?m)^\s*pull_request:\s*$'
            }
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

    # Scenario: A normal pull request tests its own immutable head on Windows.
    # Purpose: Keep candidate tests and evidence bound to that head with read-only permissions.
    It 'UnitT31_BindsReadOnlyWindowsCandidateWorkflowToExactHead' {
        $path = Join-Path $script:WorkflowRoot 'standard-v1-candidate-windows.yml'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $workflow = Get-Content -LiteralPath $path -Raw
        $workflow | Should -Match '(?m)^  pull_request:\s*$'
        $workflow | Should -Match '(?m)^permissions:\s*\r?\n  contents: read\s*$'
        $workflow | Should -Match 'runs-on: windows-latest'
        $workflow | Should -Match 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020'
        $workflow | Should -Match "node-version: '24'"
        $workflow | Should -Match 'Require npm 11 lockfile semantics'
        $workflow | Should -Match ([regex]::Escape('^11\.[0-9]+\.[0-9]+$'))
        $workflow.IndexOf('Require npm 11 lockfile semantics') | Should -BeLessThan $workflow.IndexOf('Validate exact commit with verified PowerShell')
        $workflow | Should -Match "runnerNpmPrefix -ceq 'C:\\npm\\prefix'"
        $workflow | Should -Match 'SetEnvironmentVariable\(''NPM_CONFIG_PREFIX'', \$null, ''Process''\)'
        $workflow | Should -Match 'Unexpected npm prefix in the candidate runner environment'
        $workflow | Should -Match 'github\.event\.pull_request\.head\.sha'
        $workflow | Should -Match 'persist-credentials: false'
        $workflow | Should -Match 'checkoutHead -cne \$env:EXPECTED_HEAD_SHA'
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'TrustedTestCommit \$checkoutHead'
        $workflow | Should -Match '\[regex\]::Match\('
        $workflow | Should -Match "Groups\['version'\]\.Value"
        $workflow | Should -Match 'ExpectedGoRuntimeVersion \$expectedGoRuntimeVersion'
        $workflow | Should -Match 'report\.candidate\.commit -cne \$checkoutHead'
        $workflow | Should -Not -Match 'pull_request_target|checks: write|CODEX_PESTER_CGROUP_ROOT'
    }

    # Scenario: the central authority script is dot-sourced to define validation functions.
    # Purpose: preserve the run-resolved Go version across its same-named script parameter binding.
    It 'UnitT32_PreservesGoVersionWhenLoadingAuthorityFunctions' {
        $validator = Get-Content -LiteralPath $script:CanonicalValidatorPath -Raw
        $validator | Should -Match '(?m)^\. \$authorityGatePath -DefineFunctionsOnly -ExpectedGoRuntimeVersion \$ExpectedGoRuntimeVersion$'
    }

    # Scenario: A multi-commit branch is validated locally before it is pushed.
    # Purpose: Compare the complete branch against the remote default branch instead of only HEAD's parent.
    It 'UnitT35_UsesTheRemoteDefaultBranchMergeBaseForImplicitComparison' {
        $prePush = Get-Content -LiteralPath $script:PrePushPath -Raw
        $prePush | Should -Match 'symbolic-ref --quiet --short refs/remotes/origin/HEAD'
        $prePush | Should -Match 'merge-base --all'
        $prePush | Should -Match 'specify -BaseCommit explicitly'
        $prePush | Should -Not -Match 'HEAD\^'
        foreach ($path in @('README.md', 'docs/RELEASE.md', 'docs/ROLLBACK.md')) {
            $documentation = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $path) -Raw
            $documentation | Should -Match 'merge-base'
            $documentation | Should -Not -Match 'HEAD\^'
        }
    }

    # Scenario: A pull request or push to main enters the single latest-stable Windows route.
    # Purpose: Bind one canonical validation run to the immutable event SHA and verified runtime.
    It 'UnitT40_MapsPullRequestAndMainPushToOneCanonicalValidator' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:WorkflowRoot 'standard-v1-candidate-windows.yml') -Raw
        $workflow | Should -Match '(?m)^  pull_request:\s*$'
        $workflow | Should -Match '(?ms)^  push:\s*\r?\n\s{4}branches:\s*\r?\n\s{6}- main'
        $workflow | Should -Not -Match 'pull_request_target|workflow_dispatch|checks: write'
        $workflow | Should -Match 'github\.event\.pull_request\.head\.sha'
        $workflow | Should -Match 'persist-credentials:\s*false'
        $workflow | Should -Match 'Install-LatestPowerShell\.ps1'
        $workflow | Should -Match 'PowerShellRelease\.psm1'
        $installer = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Install-LatestPowerShell.ps1') -Raw
        $installer | Should -Match 'https://aka\.ms/powershell-release\?tag=stable'
        $installer | Should -Match 'BaseResponse\.RequestMessage\.RequestUri'
        $installer | Should -Match 'Get-VerifiedPowerShellStableTagFromUri'
        $installer | Should -Match 'Assert-PowerShellReleaseTagMatchesStableChannel'
        $installer | Should -Match 'releases/tags/\$stableTag'
        $workflow | Should -Not -Match 'actions/upload-artifact|GITHUB_STEP_SUMMARY'
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'TrustedTestCommit \$checkoutHead'
        $workflow | Should -Match 'report\.candidate\.commit -cne \$checkoutHead'
        ([regex]::Matches($workflow, 'scripts/Validate\.ps1')).Count | Should -Be 1
    }

    # Scenario: The latest-only route finishes under a finite job deadline and removes its run-owned files.
    # Purpose: Prevent unbounded runner use and prevent old mirror/publisher contexts from being recreated.
    It 'UnitT50_UsesOneBoundedWindowsJobWithoutCompatibilityPublishers' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:WorkflowRoot 'standard-v1-candidate-windows.yml') -Raw
        $workflow | Should -Match 'runs-on: windows-latest'
        $workflow | Should -Match '(?m)^    timeout-minutes:\s*[1-9][0-9]*\s*$'
        $workflow | Should -Match 'if:\s*always\(\)'
        $workflow | Should -Match 'SGV1_RUN_DIRECTORY'
        $workflow | Should -Match 'Remove run-owned validation directory'
        $workflow | Should -Not -Match 'repository-contract|skill-validator|skill-tools|publish-head-required-checks|ubuntu-latest|CODEX_PESTER_CGROUP_ROOT'
        Test-Path -LiteralPath (Join-Path $script:WorkflowRoot 'standard-v1-protected.yml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1') | Should -BeFalse
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
            Should -Match 'pwsh -NoLogo -NoProfile -File ./scripts/Invoke-PrePushValidation\.ps1'
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

    It 'keeps one exact protected Pester inventory across supervisor, parent, and worker execution' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:CanonicalValidatorPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-RequiredPesterTests'
        }, $true)
        $definition | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($definition.Extent.Text))

        $expected = @(
            'BootstrapTransition.Tests.ps1'
            'LocalizationWorkset.Tests.ps1'
            'ModUpdateAutomation.Tests.ps1'
            'RepositoryContract.Tests.ps1'
            'RepositoryValidation.Tests.ps1'
            'Schema15Coordination.Tests.ps1'
            'Schema15SourceAcquisition.Tests.ps1'
            'SkillContract.Tests.ps1'
            'SourcePin.Tests.ps1'
        )
        @(Get-RequiredPesterTests) | Should -Be $expected
        @(Get-RequiredPesterTests -IncludeTrustedPostPromotionTests) | Should -Be @(
            $expected
            'InstalledClosureOrdering.Tests.ps1'
        )

        $canonicalValidator = $ast.Extent.Text
        foreach ($requiredTest in $expected) {
            ([regex]::Matches($definition.Extent.Text, [regex]::Escape("'$requiredTest'"))).Count | Should -Be 1
        }
        ([regex]::Matches($canonicalValidator, 'Get-RequiredPesterTests -IncludeTrustedPostPromotionTests')).Count | Should -Be 4
        $canonicalValidator | Should -Match '\$requiredPesterTestsFunction = \(Get-Command Get-RequiredPesterTests'
        $canonicalValidator | Should -Match '__REQUIRED_PESTER_TESTS_FUNCTION__'
        $canonicalValidator | Should -Match '\.Replace\(''__REQUIRED_PESTER_TESTS_FUNCTION__'', \$requiredPesterTestsFunctionDefinition\)'
    }
}
