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
        $adapter.authority.commit | Should -Be 'ead467c3488c103546f316d137196b447a1ff58a'
        $adapter.authority.archiveUrl | Should -Be 'https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/ead467c3488c103546f316d137196b447a1ff58a'
        $adapter.authority.archiveSha256 | Should -Be 'ab304bc6caabe4bb9b605f403c852650e19e25f72999010db61bbad695e1c60b'

        $expected = [ordered]@{
            'docs/standards/README.md' = '8aef64a9e69848c82d0ceba43f14c2876e3816cbc4761bac26a35e6f62aaf884'
            'docs/standards/managed-skill-lifecycle.md' = '4e3f8595072d663f51d18aa28f42293fda5456362b49c0ea3f0157ae3dcf56dd'
            'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json' = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863'
            'docs/standards/schemas/openai-agent-metadata.schema.json' = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a'
            'docs/standards/schemas/source-inventory-v2.schema.json' = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e'
            'docs/standards/schemas/validation-security-gate-v1.schema.json' = 'b924b28a791f4d6eedcc0aa1c01fb62687ec863c0c17048093bfdd99aaa55b74'
            'docs/standards/skill-repository-review-matrix.md' = 'db0f898b2e59e0600abe3ec93684e561db339c82547d9035b18285f0285672ab'
            'docs/standards/skill-repository-standard.md' = '1815569ebfc727bdc8ce1d906ecd63769fb2cf323d526074aa687ffe6b12b2c3'
            'docs/standards/upstream-interoperability.md' = '8e48cc4831d151ffa4665433d79ad88e8871cb1d694861908dd0206406dcefe5'
            'docs/standards/validation-security-gate.json' = '1ab4c1208885a3aeb74654d8133426367134446e2b7519f06e63de3a53b16067'
            'docs/standards/validation-toolchain.json' = '001054854960563201d969a826db990f01ab93a2e87120ccc5ee42be8f8417d7'
            'scripts/Invoke-StandardAuthorityGate.ps1' = 'b4972681e79f788485e3925b737a7b0faac38a63c617450472758f2cc33798ef'
            'scripts/Resolve-PythonWheelClosure.py' = '4d6325bc7d425e6fe2ef474d7f78fe8966b44ec5e1acee86f2417dc740d1fcea'
            'scripts/Resolve-StandardValidationTool.ps1' = 'c0d68b227fc04e19d710a89c4559fe45e0cc979eead846006261dc2dc5bfa14f'
            'docs/standards/skillspector-approved-sources.json' = 'baaaf2a66e98f2c28a48fddd04051f09cf5498ef6c7978cbf45f5d415b69a330'
            'docs/standards/schemas/skillspector-approved-sources-v1.schema.json' = '20fa8516c9dcb7c9ae15f4682092dc583411db3149fac2641fef7b5182c3d12b'
            'docs/standards/static-parser-host-ownership.json' = '994acd989327d094d22ce2c68ca20eceec609f4e494f4e5d252cfcdef742de2c'
            'scripts/platform-runtime.psd1' = '7f112390d2995a105b9e9a916876df1779485dec6df21d7516243e2dcd1c4dca'
            'scripts/platform-runtime.psm1' = 'ad051b2794ce4dc10108404201735d02f7b032ed0e633c5f22f73c884fb10370'
            'scripts/installer-safe-mutation.psm1' = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293'
            'scripts/WindowsDacl.psm1' = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6'
            'scripts/platform/PlatformNative.cs' = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514'
            'scripts/platform/UnixNative.cs' = '996a8e4cc1c795f4732a9d7368e597b838c801d0710e32629cafcbba89f8c004'
            'scripts/platform/WindowsNative.cs' = '6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433'
            'scripts/platform/WindowsInstallerMutation.cs' = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218'
            'scripts/platform/OwnedProcess.cs' = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58'
            'scripts/platform/UnixProcess.cs' = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1'
            'scripts/platform/WindowsProcess.cs' = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6'
            'scripts/platform/Unix.psm1' = 'ec3b3bb0b39e1ce84d4c8f60a78c44fb40cb9d58c13ed88a6b9d9db978fcc147'
            'scripts/platform/RuntimePreparation.psm1' = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077'
            'scripts/platform/Windows.psm1' = '9b7442178083a9b165ed3bf53367d5c3ce1b1f09d56f0f6efe964b524e17be0b'
            'scripts/platform/Linux.psm1' = '52c261d577ee7b3946771d1112030996896fdd119e06ac3849e430a3d56fb38c'
            'scripts/platform/MacOS.psm1' = '8f25edfbee5ab36b5e1c42eb55c6dbab44db0bc29896c180612b1248920c7c47'
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

    # Scenario: A pull request or main push enters the read-only Windows route for its event commit.
    # Purpose: Keep candidate tests and evidence bound to the exact event SHA without granting write access.
    It 'UnitT31_BindsPullRequestAndMainPushToTheExactReadOnlyHead' {
        $path = Join-Path $script:WorkflowRoot 'standard-v1-candidate-windows.yml'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $workflow = Get-Content -LiteralPath $path -Raw
        $workflow | Should -Match '(?ms)^on:\s*\r?\n  pull_request:\s*\r?\n  push:\s*\r?\n    branches:\s*\r?\n      - main(?:\r?\n|$)'
        $workflow | Should -Match '(?m)^permissions:\s*\r?\n  contents: read\s*$'
        $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
        $workflow | Should -Match 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020'
        $workflow | Should -Match "node-version: '24'"
        $workflow | Should -Match 'Require npm 11 lockfile semantics'
        $workflow | Should -Match ([regex]::Escape('^11\.[0-9]+\.[0-9]+$'))
        $workflow.IndexOf('Require npm 11 lockfile semantics') | Should -BeLessThan $workflow.IndexOf('Validate exact commit with verified PowerShell')
        $workflow | Should -Match "runnerNpmPrefix -ceq 'C:\\npm\\prefix'"
        $workflow | Should -Match 'SetEnvironmentVariable\(''NPM_CONFIG_PREFIX'', \$null, ''Process''\)'
        $workflow | Should -Match 'Unexpected npm prefix in the candidate runner environment'
        $workflow | Should -Match 'github\.event\.pull_request\.head\.sha'
        $workflow | Should -Match 'github\.event\.pull_request\.head\.sha \|\| github\.sha'
        $workflow | Should -Match 'ref: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}'
        $workflow | Should -Match 'persist-credentials: false'
        $workflow | Should -Match 'checkoutHead -cne \$env:EXPECTED_HEAD_SHA'
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Match 'TrustedTestCommit \$checkoutHead'
        $workflow | Should -Match 'report\.candidate\.commit -cne \$checkoutHead'
        ([regex]::Matches($workflow, 'scripts/Validate\.ps1')).Count | Should -Be 1
        $workflow | Should -Not -Match 'pull_request_target|workflow_dispatch|checks: write|status: write|CODEX_PESTER_CGROUP_ROOT'
    }

    # Scenario: the central authority script is dot-sourced through its current function-only interface.
    # Purpose: avoid forwarding the resolver-only Go runtime parameter to the authority gate.
    It 'UnitT32_LoadsAuthorityFunctionsThroughTheCurrentInterface' {
        $validator = Get-Content -LiteralPath $script:CanonicalValidatorPath -Raw
        $validator | Should -Match '(?m)^\. \$authorityGatePath -DefineFunctionsOnly$'
        $validator | Should -Not -Match '(?m)^\. \$authorityGatePath .*ExpectedGoRuntimeVersion'
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

    # Scenario: The validation job selects current stable Go and the Microsoft stable PowerShell release.
    # Purpose: Bind tool execution to verified stable versions, archive digest, and executable receipt evidence.
    It 'UnitT40_UsesVerifiedLatestStableToolchains' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:WorkflowRoot 'standard-v1-candidate-windows.yml') -Raw
        $workflow | Should -Match 'runs-on: windows-latest'
        $workflow | Should -Match 'actions/setup-go@[0-9a-f]{40}'
        $workflow | Should -Match "go-version: 'stable'"
        $workflow | Should -Match 'check-latest: true'
        $workflow | Should -Not -Match "go-version: '[0-9]+\.[0-9]+\.[0-9]+'"
        $workflow | Should -Match 'Install-LatestPowerShell\.ps1'
        $workflow | Should -Match 'PowerShellRelease\.psm1'
        $workflow | Should -Match 'sha256:'
        $workflow | Should -Match '\$powerShellReceipt\.publishedDigest'
        $workflow | Should -Match '\$powerShellReceipt\.observedSha256'
        $workflow | Should -Match '\$powerShellReceipt\.executableVersion'
        $workflow | Should -Match '\$powerShellReceipt\.executablePath'
        $workflow | Should -Match '\$powerShellPath\.StartsWith\(\$installRootFullPath'
        $workflow | Should -Match '& \$powerShellPath -NoLogo -NoProfile -NonInteractive'
        $workflow | Should -Match '\$powerShellReceipt\.version'
        $workflow | Should -Match '\[regex\]::Match\('
        $workflow | Should -Match "Groups\['version'\]\.Value"
        $workflow | Should -Match 'ExpectedGoRuntimeVersion \$expectedGoRuntimeVersion'
        $workflow | Should -Not -Match 'PSVersionTable\.PSVersion\.Major -lt 7|& pwsh\s'
        $installer = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Install-LatestPowerShell.ps1') -Raw
        $installer | Should -Match 'https://aka\.ms/powershell-release\?tag=stable'
        $installer | Should -Match 'BaseResponse\.RequestMessage\.RequestUri'
        $installer | Should -Match 'Get-VerifiedPowerShellStableTagFromUri'
        $installer | Should -Match 'Assert-PowerShellReleaseTagMatchesStableChannel'
        $installer | Should -Match 'releases/tags/\$stableTag'
    }

    # Scenario: The latest-only route finishes under a finite job deadline and removes its run-owned files.
    # Purpose: Prevent unbounded runner use and prevent old mirror/publisher contexts from being recreated.
    It 'UnitT50_UsesOneBoundedWindowsJobWithoutCompatibilityPublishers' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:WorkflowRoot 'standard-v1-candidate-windows.yml') -Raw
        $workflow | Should -Match 'runs-on: windows-latest'
        $workflow | Should -Match '(?m)^    timeout-minutes:\s*[1-9][0-9]*\s*$'
        $workflow | Should -Match 'if:\s*always\(\)'
        $workflow | Should -Match 'SGV1_RUN_DIRECTORY'
        $workflow | Should -Match "\$directoryName = 'sv'"
        $workflow | Should -Match "\$directoryName -cne 'sv'"
        $workflow | Should -Match 'beta_claude_tag_slack_channel_bundle_target_create_param\.py'
        $workflow | Should -Match '\$longestSkillSpectorPath\.Length -ge 248'
        $workflow | Should -Match 'Remove run-owned validation directory'
        $workflow | Should -Not -Match 'repository-contract|skill-validator|skill-tools|publish-head-required-checks|CANONICAL_RESULT|ubuntu-latest|CODEX_PESTER_CGROUP_ROOT|actions/upload-artifact|GITHUB_STEP_SUMMARY'
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
            'SkillSpectorOutput.Tests.ps1'
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
