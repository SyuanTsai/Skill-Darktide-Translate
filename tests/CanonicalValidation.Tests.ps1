# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Layout = Get-TestRepositoryLayout -RepositoryRoot $script:RepositoryRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = if ($script:Layout.Name -ceq 'standard-v1') {
            Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
                ConvertFrom-Json -Depth 20
        }
        else { $null }
    }

    # Scenario: The validator receives a candidate and then resolves authority and tools.
    # Purpose: Bind the candidate before any external input can influence validation.
    It 'UnitT10_BindsImmutableCandidateBeforeExternalAcquisition' {
        $candidateIndex = $script:Validator.IndexOf('status --porcelain=v1')
        $authorityIndex = $script:Validator.IndexOf('Invoke-WebRequest -Uri $adapter.authority.archiveUrl')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $candidateIndex | Should -BeGreaterThan -1
        $authorityIndex | Should -BeGreaterThan $candidateIndex
        $resolverIndex | Should -BeGreaterThan $authorityIndex
    }

    # Scenario: An authority archive and its required files precede central resolver execution.
    # Purpose: Reject unverified authority material before it can supply validation logic.
    It 'UnitT15_VerifiesAuthorityBundleBeforeResolverInvocation' {
        $archiveHashIndex = $script:Validator.IndexOf('$archiveHash -cne')
        $fileHashIndex = $script:Validator.IndexOf('$fileHash -cne')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $archiveHashIndex | Should -BeGreaterThan -1
        $fileHashIndex | Should -BeGreaterThan $archiveHashIndex
        $resolverIndex | Should -BeGreaterThan $fileHashIndex
    }

    # Scenario: Candidate evidence has duplicate JSON fields or an artifact path inside the candidate tree.
    # Purpose: Keep evidence unambiguous and outside candidate-controlled storage.
    It 'UnitT20_RejectsAmbiguousEvidenceAndCandidateArtifacts' {
        $script:Validator | Should -Match 'Assert-NoDuplicateJsonProperties'
        $script:Validator | Should -Match 'not valid unambiguous UTF-8 JSON'
        $script:Validator | Should -Match 'Artifacts root must be outside the candidate repository'
        $script:Validator | Should -Match "Assert-PathWithinRoot.*-Context 'Conformance output'"
    }

    # Scenario: An event provides a base revision for candidate comparison.
    # Purpose: Require one verified ancestor rather than an ambiguous or self-referential base.
    It 'UnitT25_NormalizesAnImmutableDistinctEventBase' {
        $script:Validator | Should -Match 'rev-parse --verify --end-of-options'
        $script:Validator | Should -Match 'merge-base --is-ancestor'
        $script:Validator | Should -Match 'Base commit must be a distinct ancestor'
        $script:Validator | Should -Match 'baseCommit = \$resolvedBaseCommit'
    }

    # Scenario: A push or manual run has no trusted event base.
    # Purpose: Check every committed candidate path instead of only HEAD's parent.
    It 'UnitT30_ScansTheCompleteCandidateWithoutAnEventBase' {
        # Scenario: A push or manual run has no trusted event base.
        # Purpose: Check every committed candidate path instead of only HEAD's parent.
        $script:Validator | Should -Match 'emptyTreeObject = ''4b825dc642cb6eb9a060e54bf8d69288fbee4904'''
        $script:Validator | Should -Match ([regex]::Escape("'diff'") + '.*' + [regex]::Escape("'--check'") + '.*' + [regex]::Escape('$emptyTreeObject') + '.*' + [regex]::Escape("'HEAD'"))
        $script:Validator | Should -Not -Match 'diff-tree.*--root.*HEAD'
    }

    # Scenario: A resolved package tool path traverses a reparse point.
    # Purpose: Prevent execution through a path whose identity can change outside the trusted tree.
    It 'UnitT31_RejectsReparseBackedResolvedToolPaths' {
        $script:Validator | Should -Match 'Assert-NoReparseAncestors'
        $script:Validator | Should -Match 'Assert-NoReparseAncestors -Path \$path -Context "\$Context installed file"'
        $script:Validator | Should -Match 'is backed by a reparse point'
    }

    # Scenario: A host runtime receipt names a runtime and package files are materialized for one run.
    # Purpose: Bind runtimes by absolute path and hash while preserving run-owned package boundaries.
    It 'UnitT32_VerifiesHostRuntimeReceiptsAndRunOwnedPackageFiles' {
        $script:Validator | Should -Match 'function Assert-ExternalReceiptFile'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ExternalReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'nodePath'"))
        $script:Validator | Should -Match 'receipt path must be absolute'
        $script:Validator | Should -Match 'runtime file changed after resolution'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'entryPointPath'"))
    }

    # Scenario: The canonical adapter schedules required package and static checks.
    # Purpose: Run the required skill-tools package check before Static Scan.
    It 'UnitT33_CompletesSkillToolsPackageCheckBeforeStaticScanning' {
        # Scenario: The canonical adapter schedules the required formal tools.
        # Purpose: Enforce authority section 8.3 package validation before Static Scan.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $calls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-NativeChecked'
        }, $true))
        $packageCheck = @($calls | Where-Object { $_.Extent.Text.Contains('$skillToolsEntryPoint') -and $_.Extent.Text.Contains("'check'") })
        $staticScan = @($calls | Where-Object { $_.Extent.Text.Contains("'--no-llm'") })
        $packageCheck.Count | Should -Be 1
        $staticScan.Count | Should -Be 1
        $packageCheck[0].Extent.StartOffset | Should -BeLessThan $staticScan[0].Extent.StartOffset
    }

    # Scenario: The complete protected Pester group needs a bounded deadline and cleanup grace.
    # Purpose: Allow measured work while retaining finite containment and cleanup limits.
    It 'UnitT34_BoundsTheCompletePesterRunAndAllowsSupervisorCleanup' {
        # Scenario: The complete required suite includes a measured 242-second end-to-end case.
        # Purpose: Allow the measured full suite while retaining a finite deadline and cleanup grace.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $calls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true))
        $inner = @($calls | Where-Object { $_.GetCommandName() -ceq 'Invoke-ProtectedPesterRunspace' })
        $outer = @($calls | Where-Object {
            $_.GetCommandName() -ceq 'Invoke-TrustedPowerShellProcess' -and
            $_.Extent.Text.Contains("-Context 'Trusted Pester supervisor'")
        })
        $inner.Count | Should -Be 1
        $outer.Count | Should -Be 1
        $timeouts = @($inner[0], $outer[0] | ForEach-Object {
            $elements = $_.CommandElements
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and
                    $elements[$i].ParameterName -ceq 'TimeoutMilliseconds') {
                    $elements[$i + 1] | Should -BeOfType ([Management.Automation.Language.ConstantExpressionAst])
                    [int]$elements[$i + 1].Value
                }
            }
        })
        $timeouts.Count | Should -Be 2
        $timeouts[0] | Should -BeGreaterOrEqual 600000
        $timeouts[0] | Should -BeLessOrEqual 900000
        ($timeouts[1] - $timeouts[0]) | Should -BeGreaterOrEqual 30000
        ($timeouts[1] - $timeouts[0]) | Should -BeLessOrEqual 60000
    }

    # Scenario: Integrity evidence distinguishes Git-normalized bytes from bytes read by package tools.
    # Purpose: Bind the central envelope to raw input bytes without dropping script resources.
    It 'UnitT35_BindsPackageToolInputsToRawIntegrityHashes' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        $definition = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'New-PackageValidationInputEnvelope'
        }, $true))
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))
        $files = @(
            [pscustomobject]@{ path = 'SKILL.md'; sha256 = ('0' * 64); rawSha256 = ('1' * 64) },
            [pscustomobject]@{ path = 'scripts/run.ps1'; sha256 = ('2' * 64); rawSha256 = ('3' * 64) }
        )
        foreach ($toolName in @('skill-validator', 'skill-tools')) {
            $envelope = New-PackageValidationInputEnvelope -ToolName $toolName -SkillRoot $TestDrive -IntegrityFiles $files
            $envelope.toolName | Should -Be $toolName
            $envelope.coverageMode | Should -Be 'authority-input-inventory'
            $envelope.root | Should -Be $TestDrive
            @($envelope.files.path) | Should -Be @('SKILL.md', 'scripts/run.ps1')
            @($envelope.files.sha256) | Should -Be @(('1' * 64), ('3' * 64))
            @($envelope.files[0].PSObject.Properties.Name) | Should -Be @('path', 'sha256')
        }
    }

    # Scenario: A syntactically clean native report is rejected by the approved central report contract.
    # Purpose: Propagate central rejection and pass the independently known token-path sets to that contract.
    It 'UnitT36_DelegatesBothNativeReportShapesToTheCentralContract' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        $definitions = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -cin @('Assert-SkillValidatorReport', 'Get-RequiredProperty', 'Test-PathEqual')
        }, $true))
        . ([scriptblock]::Create(($definitions.Extent.Text -join "`n")))
        $script:DelegatedPackageReport = $null
        function Assert-AuthoritySkillValidatorReport {
            param($Report, $ExpectedFixtureRoot, $ExpectedInventoryPaths, $ExpectedTokenPaths, $ExpectedOtherTokenPaths)
            $script:DelegatedPackageReport = $PSBoundParameters
            throw 'Central package report contract rejected missing metadata evidence.'
        }
        $paths = @(
            'SKILL.md', 'assets/review-baseline.md', 'assets/workflow-schema-14.md',
            'references/automation.md', 'references/package-binding.md', 'references/schema-15.md',
            'references/schema-15-provenance.json', 'references/source-provenance.json', 'references/translation-quality.md',
            'agents/openai.yaml', 'scripts/run.ps1'
        )
        foreach ($category in @('structure', 'metadata')) {
            $report = [pscustomobject]@{
                skill_dir = $TestDrive; passed = $true; errors = 0; warnings = 0
                results = @([pscustomobject]@{ level = 'pass'; category = $category; message = 'A clean report entry.' })
            }
            { Assert-SkillValidatorReport -Report $report -SkillRoot $TestDrive -ExpectedInventoryPaths $paths -SkillId 'auto-update-darktide-mod' } |
                Should -Throw '*Central package report contract rejected missing metadata evidence*'
            $script:DelegatedPackageReport.Report | Should -Be $report
            $script:DelegatedPackageReport.ExpectedFixtureRoot | Should -Be $TestDrive
            @($script:DelegatedPackageReport.ExpectedInventoryPaths) | Should -Be $paths
            @($script:DelegatedPackageReport.ExpectedTokenPaths) | Should -Be $paths[0..8]
            @($script:DelegatedPackageReport.ExpectedOtherTokenPaths) | Should -Be @('agents/openai.yaml')
        }
    }

    # Scenario: Each native package check can observe all package files between entry and exit.
    # Purpose: Require raw input verification on both sides of all three checks and retain run-owned evidence.
    It 'UnitT37_VerifiesInputsBeforeAndAfterEveryNativePackageCheck' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ValidatorPath, [ref]$tokens, [ref]$parseErrors)
        $calls = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true))
        $inputChecks = @($calls | Where-Object { $_.GetCommandName() -ceq 'Assert-AuthorityToolInputInventory' })
        $inputChecks.Count | Should -Be 6
        $packageCalls = @($calls | Where-Object {
            $_.GetCommandName() -ceq 'Invoke-NativeChecked' -and
            ($_.Extent.Text.Contains('-Command $skillValidatorPath') -or $_.Extent.Text.Contains("-Command `$skillToolsNodePath -Arguments @(`$skillToolsEntryPoint, 'check'"))
        })
        $packageCalls.Count | Should -Be 3
        foreach ($call in $packageCalls) {
            $before = @($inputChecks | Where-Object { $_.Extent.EndOffset -lt $call.Extent.StartOffset } | Select-Object -Last 1)
            $after = @($inputChecks | Where-Object { $_.Extent.StartOffset -gt $call.Extent.EndOffset } | Select-Object -First 1)
            $before.Count | Should -Be 1
            $after.Count | Should -Be 1
            $before[0].Parent.Extent.Text | Should -Match 'Out-Null'
            $after[0].Parent.Extent.Text | Should -Match 'Out-Null'
            $expectedTool = if ($call.Extent.Text.Contains('-Command $skillValidatorPath')) { 'skill-validator' } else { 'skill-tools' }
            $before[0].Extent.Text | Should -Match ([regex]::Escape("-ExpectedToolName '$expectedTool'"))
            $after[0].Extent.Text | Should -Match ([regex]::Escape("-ExpectedToolName '$expectedTool'"))
        }
        $script:Validator | Should -Match 'skill-validator-coverage-\$skillId.json'
        $script:Validator | Should -Match 'skill-tools-coverage-\$skillId.json'
        $script:Validator | Should -Match 'coverageReport = \[IO.Path\]::GetFileName\(\$validatorCoveragePath\)'
        $script:Validator | Should -Match 'coverageReport = \[IO.Path\]::GetFileName\(\$toolsCoveragePath\)'
    }

    # Scenario: The validator resolves its formal tools before any package or static scan.
    # Purpose: Require one centrally governed security gate and immutable tool sources.
    It 'UnitT40_FreezesFormalToolsAndImportsCentralSecurityGate' {
        if ($script:Layout.Name -ceq 'standard-v1') {
            @($script:Adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        }
        else {
            $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
            $repositoryValidator | Should -Match 'Bootstrap transition is valid only before the Standard v1 source inventory, adapter, or skills/ root is promoted.'
        }
        $script:Validator | Should -Match '\.\s+\$authorityGatePath -DefineFunctionsOnly'
        $script:Validator | Should -Match 'Assert-AuthorityValidationSecurityGate'
        $script:Validator | Should -Not -Match 'adapter\.security|blockSeverities|security\.(suppressions|exceptions)'
        $script:Validator | Should -Match "'skillspector' = 'NVIDIA/SkillSpector'"
        $script:Validator | Should -Match "'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'"
        $script:Validator | Should -Match "'skill-tools' = 'npm:skill-tools'"
        $script:Validator | Should -Match "'pester' = 'PowerShellGallery:Pester'"
        $script:Validator | Should -Match '\$resolverPath\s+-PolicyPath \$policyPath\s+-ToolName \$toolName\s+-Install\s+-InstallRoot \$installRoot\s+-ExpectedGoRuntimeVersion \$ExpectedGoRuntimeVersion'

        $freezeIndex = $script:Validator.IndexOf('foreach ($toolName in $expectedSources.Keys)')
        $packageIndex = $script:Validator.IndexOf('skill-validator package validation for')
        $staticIndex = $script:Validator.IndexOf("'--no-llm'")
        $repositoryIndex = $script:Validator.IndexOf('$repositoryReportPath')
        $staticIndex | Should -BeGreaterThan $freezeIndex
        $packageIndex | Should -BeGreaterThan $freezeIndex
        $staticIndex | Should -BeGreaterThan $packageIndex
        $repositoryIndex | Should -BeGreaterThan $staticIndex
    }

    # Scenario: The source inventory lists the Skill packages that require formal validation.
    # Purpose: Drive each native package check from the authoritative inventory.
    It 'UnitT45_DiscoversFormalPackageInvocationsFromSourceInventory' {
        $script:Validator | Should -Match '\$skillIds\s*=\s*@\(\$integrityReport\.skills'
        $script:Validator | Should -Match 'Assert-SkillSpectorReport'
        $script:Validator | Should -Match 'ExpectedInventoryPaths'
        $script:Validator | Should -Match 'foreach \(\$skillId in \$skillIds\)'
        $script:Validator | Should -Match "validate', 'structure', '--allow-dirs=agents'"
        $script:Validator | Should -Match "'check', '--strict', '--allow-dirs=agents'"
        $script:Validator | Should -Match ([regex]::Escape("'check', `$skillRoot, '--format', 'sarif'"))
    }

    # Scenario: skill-tools returns a syntactically valid SARIF report without findings.
    # Purpose: Accept the clean report shape while rejecting malformed or error-level results.
    It 'UnitT50_AcceptsCleanSkillToolsSarif' {
        $start = $script:Validator.IndexOf('function Assert-SkillToolsReport')
        $end = $script:Validator.IndexOf('function Assert-PathWithinRoot')
        $start | Should -BeGreaterThan -1
        $end | Should -BeGreaterThan $start
        $skillToolsValidator = $script:Validator.Substring($start, $end - $start)
        $skillToolsValidator | Should -Match '\$driverName -cne ''skill-tools'''
        $skillToolsValidator | Should -Match '\$rules -isnot \[array\]'
        $skillToolsValidator | Should -Match '\$results -isnot \[array\]'
        $skillToolsValidator | Should -Not -Match '\$rules\)\.Count -le 0'
        $skillToolsValidator | Should -Not -Match '\$results\)\.Count -le 0'
        $skillToolsValidator | Should -Match 'skill-tools SARIF contains a malformed or error-level result'
    }

    # Scenario: Canonical validation emits run-owned evidence after the security preflight.
    # Purpose: Keep candidate-controlled paths out of evidence and retain every required review boundary.
    It 'UnitT70_KeepsReportsInTheRunArtifactsRootAndRecordsReviewBoundaries' {
        $script:Validator | Should -Match ([regex]::Escape("Join-Path `$runRoot 'conformance-report.json'"))
        $script:Validator | Should -Match 'canonicalGate = \[ordered\]@'
        $script:Validator | Should -Match 'executionBoundary = \[ordered\]@'
        $script:Validator | Should -Match 'assertionInventory = \[ordered\]@'
        $script:Validator | Should -Match 'security-preflight\.json'
        $script:Validator | Should -Match 'security-preflight-summary\.json'
        $script:Validator | Should -Match 'Get-SanitizedSecurityFindingValue'
        $script:Validator | Should -Match 'Select-Object -First 64'
        $script:Validator | Should -Match "policyPath = 'docs/standards/validation-security-gate.json'"
        $script:Validator | Should -Match "aiReview = 'required-before-release'"
        $script:Validator | Should -Match "humanApproval = 'required-before-release'"
        $script:Validator | Should -Match "postInstallVerification = 'required-after-install'"
        $script:Validator | Should -Match "deviations = 'None'"
    }

    # Scenario: A central semantic trigger is true after all protected repository tests complete.
    # Purpose: Prevent a local switch or early scan from bypassing the canonical stage-6 security gate.
    It 'UnitT80_ModelsSemanticScanAsADeterministicFailClosedConditionalStage' {
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:ValidatorPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $semanticAssignments = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -ceq '$semanticTriggered'
                }, $true))
        $semanticAssignments.Count | Should -Be 1
        $semanticAssignments[0].Right.Extent.Text.Trim() | Should -Be '$semanticTriggerCandidate'
        $script:Validator | Should -Not -Match '\[switch\]\s+\$EnableSemanticScan'

        $script:Validator | Should -Match 'Test-SecurityRelevantSkillChange'
        $script:Validator | Should -Match '\$staticFindingCount -gt 0'
        $script:Validator | Should -Match 'Triggered SkillSpector semantic scan did not complete'
        $script:Validator | Should -Match 'repository-validation-post-pester'
        $script:Validator | Should -Match 'Invoke-ProtectedPesterRunspace'
        $script:Validator | Should -Match 'CreateOutOfProcessRunspace'
        $script:Validator | Should -Match '\$trustedPesterSupervisorMarker'
        $script:Validator | Should -Match '\$completionAttestationNonce'
        $script:Validator | Should -Match "completionAttestation = 'trusted-parent-post-exit'"
        $script:Validator | Should -Not -Match 'NamedPipeServerStream|NamedPipeClientStream|CompletionPipeName|CompletionToken|workerResultMarker'
        $script:Validator | Should -Match "ValidateSet\('Offline', 'TrustedSemantic'\)"
        $script:Validator | Should -Match '-NetworkProfile Offline'
        $script:Validator | Should -Match '-NetworkProfile TrustedSemantic'
        $script:Validator | Should -Match 'IsolateRunnerCommandFiles'
        $script:Validator | Should -Match 'TerminateProcessTree'
        $script:Validator | Should -Match 'ProtectRunnerCommandFiles'
        $script:Validator | Should -Match 'function New-ContainedProcessEnvironment'
        $script:Validator | Should -Match 'function Protect-ProcessCredentialEnvironment'
        $script:Validator | Should -Match 'SemanticCredentialNames'
        $script:Validator | Should -Match 'AdditionalEnvironmentVariables'
        $script:Validator | Should -Match 'EnvironmentVariables\.Clear\(\)'
        $script:Validator | Should -Match 'ACTIONS_RUNTIME_TOKEN'
        $script:Validator | Should -Match 'Assert-RunnerCommandFilesUnchanged'
        $script:Validator | Should -Match 'standard_v1_evidence_sha256'
        $script:Validator | Should -Not -Match 'pesterResultPath'
        $script:Validator | Should -Not -Match ([regex]::Escape("'-OutputPath', `$pesterResultPath"))
        $script:Validator | Should -Match 'postPesterCandidateCommit'
        $script:Validator | Should -Match 'postPesterTree'
        $script:Validator | Should -Match 'prePesterGitIndexSha256'
        $script:Validator | Should -Match 'Get-RepositoryRawSnapshot'
        $script:Validator | Should -Match 'Assert-RepositoryRawSnapshotUnchanged'
        $script:Validator | Should -Match 'postPesterRepositoryRawSnapshot'
        $script:Validator | Should -Match 'SkillSpector semantic scanner'
        $script:Validator | Should -Match 'Assert-ReceiptFile -Receipt \$receipts\.skillspector'
        $script:Validator | Should -Match 'Assert-ReceiptInstalledClosure'
        $script:Validator | Should -Match 'installedClosureSha256'
        $script:Validator | Should -Match 'installed closure contains a reparse-backed entry'
        $script:Validator | Should -Match 'Get-ChildItem -LiteralPath \$root -Recurse -Force'
        $script:Validator | Should -Match 'GIT_CONFIG_NOSYSTEM'
        $script:Validator | Should -Match 'core\.hooksPath'
        $script:Validator | Should -Match '\$repositoryValidatorPath'
        $script:Validator | Should -Match 'pesterRunnerPath'
        $script:Validator | Should -Match 'Invoke-TrustedPowerShellProcess -Command \$powerShellPath'
        $script:Validator | Should -Match "'-NoProfile'"
        $script:Validator | Should -Match "'route'"
        $script:Validator | Should -Match 'skill-tools route did not return exactly one result'
        $script:Validator | Should -Match '\$routeResults = @\(Read-JsonFile'
        $script:Validator | Should -Not -Match '\$routeResults -isnot \[array\]'
        $script:Validator | Should -Not -Match 'semantic.*continue|continue.*semantic'
        $postPesterInventoryIndex = $script:Validator.IndexOf('$postPesterRepositoryRawSnapshot')
        $semanticScanIndex = $script:Validator.IndexOf('Post-Pester SkillSpector semantic scan')
        $postPesterInventoryIndex | Should -BeGreaterThan -1
        $semanticAssignments[0].Extent.StartOffset | Should -BeGreaterThan $postPesterInventoryIndex
        $semanticScanIndex | Should -BeGreaterThan $postPesterInventoryIndex
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Match 'github\.run_attempt'
        $workflow | Should -Match 'github\.event\.pull_request\.head\.sha'
        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Match 'ref: \$\{\{ github\.event_name == .pull_request_target. && github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}'
        $workflow | Should -Match 'Materialize protected validation supervisor'
        $workflow | Should -Match 'Materialize protected Windows compatibility contract'
        $workflow | Should -Match 'TRUSTED_WINDOWS_CONTRACT'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_COMMIT: \$\{\{ github\.sha \}\}'
        $workflow | Should -Match 'publish-head-required-checks'
        $workflow | Should -Match 'HEAD_SHA'
        $workflow | Should -Match 'Darktide Translate Standard v1'
        $workflow | Should -Not -Match "github\.event_name == 'pull_request'"
        $workflow | Should -Not -Match 'TRUSTED_VALIDATE_BLOB|TRUSTED_REPOSITORY_VALIDATOR_BLOB'
        $workflow | Should -Match '\$actualBlob = .*rev-parse \$revision'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_ROOT'
        $workflow | Should -Match '\$trustedValidator = Join-Path \$env:TRUSTED_SUPERVISOR_ROOT'
        $workflow | Should -Match 'id: canonical-validation'
        $workflow | Should -Match 'Verify canonical validation evidence'
        $workflow | Should -Match 'standard_v1_evidence_sha256'
        $workflow | Should -Not -Match '(?m)^\s*& \.\/scripts\/Validate\.ps1'
    }

    # Scenario: Required CI invokes protected validation without implicit LLM credentials or skipped tests.
    # Purpose: Keep required verification deterministic and credential-free.
    It 'UnitT85_RejectsImplicitCredentialsAndSkippedRequiredTests' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Not -Match 'EnableSemanticScan'
        $script:Validator | Should -Match 'Protect-ProcessCredentialEnvironment -SemanticCredentialNames'
        $script:Validator | Should -Match 'SkippedCount -ne 0'
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'rawSha256'
        $repositoryValidator | Should -Match '\[string\] \$TrustedGitPath'
        $repositoryValidator | Should -Match '\[string\] \$TrustedStatPath'
        $repositoryValidator | Should -Match '\[switch\] \$NoFilters'
        $repositoryValidator | Should -Match 'NoFilters:\$NoFilters'
    }

    # Scenario: The protected Pester worker receives the canonical test list from its trusted supervisor definition.
    # Purpose: Require all Standard-v1 conformance and repository-contract suites without trusting candidate-supplied JSON.
    It 'UnitT90_UsesOneTrustedTwelveSuitePesterInventory' {
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:ValidatorPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $inventoryFunction = @($validatorAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Get-RequiredPesterTests'
                }, $true))
        $inventoryFunction.Count | Should -Be 1
        $inventoryModule = New-Module -ScriptBlock ([scriptblock]::Create($inventoryFunction[0].Extent.Text))
        try {
            $requiredTests = @(& $inventoryModule { Get-RequiredPesterTests })
            $requiredTests | Should -Be @(
                'BootstrapTransition.Tests.ps1',
                'CanonicalValidation.Tests.ps1',
                'LocalizationWorkset.Tests.ps1',
                'ModUpdateAutomation.Tests.ps1',
                'RepositoryContract.Tests.ps1',
                'RepositoryValidation.Tests.ps1',
                'Schema15Coordination.Tests.ps1',
                'Schema15SourceAcquisition.Tests.ps1',
                'SkillContract.Tests.ps1',
                'SourcePin.Tests.ps1',
                'StandardV1Conformance.Tests.ps1',
                'Test-Repository.Tests.ps1'
            )
        }
        finally {
            Remove-Module $inventoryModule -Force
        }

        $script:Validator | Should -Match '\$requiredPesterTestsFunction\s*=\s*\(Get-Command Get-RequiredPesterTests'
        $script:Validator | Should -Match '\$requiredPesterTestsFunction'
        $script:Validator | Should -Match '\$requiredPesterTests\s*=\s*@\(Get-RequiredPesterTests\)'
    }

    # Scenario: The active layout runs its native pre-push wrapper through controlled local stubs.
    # Purpose: Verify Bootstrap sequencing and failure handling while preserving Standard v1 credential-name forwarding.
    It 'UnitT95_ExecutesLayoutSpecificPrePushWrapperContract' {
        if ($script:Layout.Name -ceq 'legacy') {
            $fixtureRoot = Join-Path $TestDrive 'legacy-pre-push-wrapper-fixture'
            $scriptsRoot = Join-Path $fixtureRoot 'scripts'
            $testsRoot = Join-Path $fixtureRoot 'tests'
            $skillScriptsRoot = Join-Path $fixtureRoot '.agents/skills/auto-update-darktide-mod/scripts'
            New-Item -ItemType Directory -Path $scriptsRoot, $testsRoot, $skillScriptsRoot -Force | Out-Null
            $wrapperPath = Join-Path $scriptsRoot 'Invoke-PrePushValidation.ps1'
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-PrePushValidation.ps1') -Destination $wrapperPath
            $eventLogPath = Join-Path $fixtureRoot 'invocation-order.log'
            $eventLogLiteral = $eventLogPath.Replace("'", "''")
            $headOid = 'a' * 40

            [IO.File]::WriteAllText((Join-Path $scriptsRoot 'Test-CleanRepositoryHead.ps1'), @"
param([string] `$RepositoryRoot, [string] `$ExpectedHeadOid, [switch] `$PassThru)
`$event = if ([string]::IsNullOrWhiteSpace(`$ExpectedHeadOid)) { 'clean:initial' } else { "clean:final:`$ExpectedHeadOid" }
Add-Content -LiteralPath '$eventLogLiteral' -Value `$event
[pscustomobject]@{ headOid = '$headOid' }
"@, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $testsRoot 'Invoke-Tests.ps1'), @"
Add-Content -LiteralPath '$eventLogLiteral' -Value 'tests'
[pscustomobject]@{ result = 'passed'; testCount = 12; passedCount = 12 }
"@, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $skillScriptsRoot 'Test-ReferenceIntegrity.ps1'), @"
param([switch] `$PassThru)
Add-Content -LiteralPath '$eventLogLiteral' -Value 'reference-integrity'
[pscustomobject]@{ result = 'passed' }
"@, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $scriptsRoot 'Get-SourcePin.ps1'), @"
param([string] `$Ref)
Add-Content -LiteralPath '$eventLogLiteral' -Value "source-pin:`$Ref"
[ordered]@{ sourceId = 'darktide-translate'; resolvedCommit = '$headOid'; contentSha256 = ('b' * 64); resolvedVersion = '1.2.3' } | ConvertTo-Json -Compress
"@, [Text.UTF8Encoding]::new($false))

            $result = & $wrapperPath -PassThru
            $result.result | Should -Be 'passed'
            $result.headOid | Should -Be $headOid
            $result.testCount | Should -Be 12
            @([IO.File]::ReadAllLines($eventLogPath)) | Should -Be @(
                'clean:initial', 'tests', 'reference-integrity', "source-pin:$headOid", "clean:final:$headOid"
            )

            [IO.File]::WriteAllText((Join-Path $testsRoot 'Invoke-Tests.ps1'), @"
Add-Content -LiteralPath '$eventLogLiteral' -Value 'tests:failed'
[pscustomobject]@{ result = 'failed'; testCount = 12; passedCount = 11 }
"@, [Text.UTF8Encoding]::new($false))
            { & $wrapperPath } | Should -Throw '*Repository tests did not return one passing summary.*'
            return
        }
        $fixtureRoot = Join-Path $TestDrive 'pre-push-semantic-credential-fixture'
        $scriptsRoot = Join-Path $fixtureRoot 'scripts'
        New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
        $wrapperPath = Join-Path $scriptsRoot 'Invoke-PrePushValidation.ps1'
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-PrePushValidation.ps1') -Destination $wrapperPath
        $stubPath = Join-Path $scriptsRoot 'Validate.ps1'
        $stubSource = @'
param(
    [string] $RepositoryRoot,
    [string] $ArtifactsRoot,
    [string] $BaseCommit,
    [string[]] $SemanticCredentialNames
)
[pscustomobject][ordered]@{
    baseCommit = $BaseCommit
    semanticCredentialNames = @($SemanticCredentialNames)
} | ConvertTo-Json -Compress
exit 0
'@
        [IO.File]::WriteAllText($stubPath, $stubSource, [Text.UTF8Encoding]::new($false))

        $safeNames = @('TEST_SEMANTIC_PROVIDER', 'TEST_SEMANTIC_AUXILIARY')
        $result = & $wrapperPath -ArtifactsRoot $TestDrive -BaseCommit ('a' * 40) -SemanticCredentialNames $safeNames -PassThru
        $result.baseCommit | Should -Be ('a' * 40)
        @($result.semanticCredentialNames) | Should -Be $safeNames

        [IO.File]::WriteAllText($stubPath, 'exit 1', [Text.UTF8Encoding]::new($false))
        { & $wrapperPath -ArtifactsRoot $TestDrive -BaseCommit ('b' * 40) -SemanticCredentialNames $safeNames } |
            Should -Throw '*Canonical Standard v1 validation failed*'
    }
}
