# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20

        $tokens = $null
        $parseErrors = $null
        $validatorAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:Validator, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'Validate.ps1 must parse before the SkillSpector probe is built.' }
        $probeFunctions = $validatorAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                @('Get-RequiredProperty', 'Assert-SkillSpectorReport') -contains $node.Name
        }, $true)
        if ($probeFunctions.Count -ne 2) { throw 'The SkillSpector completeness probe could not find its validator functions.' }
        $probeSource = ($probeFunctions | Sort-Object { $_.Extent.StartOffset } |
            ForEach-Object { $_.Extent.Text }) -join "`n"
        $probeSource += "`nExport-ModuleMember -Function Assert-SkillSpectorReport"
        $script:SkillSpectorProbeSource = $probeSource
    }

    It 'binds the immutable candidate before any external authority or tool acquisition' {
        $candidateIndex = $script:Validator.IndexOf('status --porcelain=v1')
        $authorityIndex = $script:Validator.IndexOf('Invoke-WebRequest -Uri $adapter.authority.archiveUrl')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $candidateIndex | Should -BeGreaterThan -1
        $authorityIndex | Should -BeGreaterThan $candidateIndex
        $resolverIndex | Should -BeGreaterThan $authorityIndex
    }

    It 'verifies bundle and authority file identities before invoking the central resolver' {
        $archiveHashIndex = $script:Validator.IndexOf('$archiveHash -cne')
        $fileHashIndex = $script:Validator.IndexOf('$fileHash -cne')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $archiveHashIndex | Should -BeGreaterThan -1
        $fileHashIndex | Should -BeGreaterThan $archiveHashIndex
        $resolverIndex | Should -BeGreaterThan $fileHashIndex
    }

    It 'rejects ambiguous JSON evidence and repository-local artifact destinations' {
        $script:Validator | Should -Match 'Assert-NoDuplicateJsonProperties'
        $script:Validator | Should -Match 'not valid unambiguous UTF-8 JSON'
        $script:Validator | Should -Match 'Artifacts root must be outside the candidate repository'
        $script:Validator | Should -Match "Assert-PathWithinRoot.*-Context 'Conformance output'"
    }

    It 'normalizes the event base to one distinct immutable ancestor' {
        $script:Validator | Should -Match 'rev-parse --verify --end-of-options'
        $script:Validator | Should -Match 'merge-base --is-ancestor'
        $script:Validator | Should -Match 'Base commit must be a distinct ancestor'
        $script:Validator | Should -Match 'baseCommit = \$resolvedBaseCommit'
    }

    It 'scans the complete candidate tree when comparison base is absent' {
        # Scenario: A push or manual run has no trusted event base.
        # Purpose: Check every committed candidate path instead of only HEAD's parent.
        $script:Validator | Should -Match 'emptyTreeObject = ''4b825dc642cb6eb9a060e54bf8d69288fbee4904'''
        $script:Validator | Should -Match ([regex]::Escape("'diff'") + '.*' + [regex]::Escape("'--check'") + '.*' + [regex]::Escape('$emptyTreeObject') + '.*' + [regex]::Escape("'HEAD'"))
        $script:Validator | Should -Not -Match 'diff-tree.*--root.*HEAD'
    }

    It 'rejects reparse-backed resolved tool paths before execution' {
        $script:Validator | Should -Match 'Assert-NoReparseAncestors'
        $script:Validator | Should -Match 'Assert-NoReparseAncestors -Path \$path -Context "\$Context installed file"'
        $script:Validator | Should -Match 'is backed by a reparse point'
    }

    It 'binds safe Unix virtual-environment symlinks without allowing traversal' {
        $script:Validator | Should -Match 'function Get-InstalledSafeUnixSymlinkEntry'
        $script:Validator | Should -Match 'function Get-InstalledClosureSymlinkIdentitySha256'
        $script:Validator | Should -Match 'symbolic-link target escapes the install root'
        $script:Validator | Should -Match 'Get-InstalledSafeUnixSymlinkEntry -Item \$item'
        $script:Validator | Should -Match 'symbolicLinkTarget='
    }

    It 'fails closed for explicitly supplied blank Linux read-only paths' {
        $script:Validator | Should -Match '\[IO\.Path\]::GetFullPath\(\[string\]\$readOnlyPath\)'
        $script:Validator | Should -Not -Match 'IsNullOrWhiteSpace\(\$readOnlyPathText\)\) \{ continue \}'
    }

    It 'keeps reparse accounting explicit in the descriptor-relative writable-root scan' {
        $script:Validator | Should -Match '\[switch\] \$AllowReparseEntries'
        $script:Validator | Should -Match 'S_IFLNK'
        $script:Validator | Should -Match 'Writable root contains a reparse entry'
    }

    It 'counts but never traverses explicitly allowed writable-root reparse entries' {
        $usageStart = $script:Validator.IndexOf('function Get-LinuxWritableRootUsage', [StringComparison]::Ordinal)
        $usageEnd = $script:Validator.IndexOf('function Assert-LinuxWritableRootUsage', $usageStart, [StringComparison]::Ordinal)
        $usageFunction = $script:Validator.Substring($usageStart, $usageEnd - $usageStart)

        $usageFunction | Should -Match '\[switch\] \$AllowReparseEntries'
        $usageFunction | Should -Match '-MaximumEntries\s+100000'
        $usageFunction | Should -Match '-AllowReparseEntries\s+\(\[bool\]\$AllowReparseEntries\)'
        $script:Validator | Should -Match 'if \(fileType == S_IFLNK\) \{[\s\S]*?if \(allowReparseEntries\) \{ continue; \}'
    }

    # Scenario: A hostile tree swaps or inserts a symlink while writable-root inspection is running.
    # Purpose: Keep traversal descriptor-relative and reject reparse entries before following them.
    It 'UnitT90_UsesDescriptorRelativeNoFollowWritableRootTraversal' {
        $usageStart = $script:Validator.IndexOf('function Get-LinuxWritableRootUsage', [StringComparison]::Ordinal)
        $usageEnd = $script:Validator.IndexOf('function Assert-LinuxWritableRootUsage', $usageStart, [StringComparison]::Ordinal)
        $usageFunction = $script:Validator.Substring($usageStart, $usageEnd - $usageStart)

        $script:Validator | Should -Match 'openat'
        $script:Validator | Should -Match 'O_NOFOLLOW'
        $script:Validator | Should -Match 'AT_SYMLINK_NOFOLLOW'
        $usageFunction | Should -Not -Match 'EnumerateFileSystemInfos|Get-ChildItem'
    }

    It 'enforces writable-root growth during every protected Pester shard' {
        $runspaceStart = $script:Validator.IndexOf('function Invoke-ProtectedPesterRunspace', [StringComparison]::Ordinal)
        $runspaceEnd = $script:Validator.IndexOf('if ($ProtectedPesterServerProxy)', $runspaceStart, [StringComparison]::Ordinal)
        $runspaceFunction = $script:Validator.Substring($runspaceStart, $runspaceEnd - $runspaceStart)

        $runspaceFunction | Should -Match '\[int64\] \$WritableRootBaselineBytes'
        $runspaceFunction | Should -Match '(?s)Assert-LinuxAggregateResourceUsage.*?Assert-LinuxWritableRootUsage'
        $runspaceFunction | Should -Match '-BaselineBytes \$WritableRootBaselineBytes'
        $runspaceFunction | Should -Match '(?s)\$output = @\(\$powerShell\.EndInvoke\(\$asyncResult\)\).*?Assert-LinuxWritableRootUsage'

        $supervisorStart = $script:Validator.IndexOf('function Invoke-ProtectedPesterSupervisor', [StringComparison]::Ordinal)
        $supervisorEnd = $script:Validator.IndexOf('if ($ProtectedPesterSupervisor)', $supervisorStart, [StringComparison]::Ordinal)
        $supervisorFunction = $script:Validator.Substring($supervisorStart, $supervisorEnd - $supervisorStart)
        $supervisorFunction | Should -Match '(?s)\$linuxWritableRootBaselineBytes = \[int64\]0.*?foreach \(\$requiredPesterTest'
        $supervisorFunction | Should -Match '-WritableRootBaselineBytes \$linuxWritableRootBaselineBytes'
    }

    It 'sizes the private Linux etc projection for hosted runner images' {
        $script:Validator | Should -Match 'size=268435456,nodev,nosuid,noexec tmpfs "\$target"'
    }

    It 'uses the portable setpriv syntax for clearing ambient capabilities' {
        $script:Validator | Should -Match ([regex]::Escape('--ambient-caps=-all'))
        $script:Validator | Should -Not -Match ([regex]::Escape('--ambient-clear'))
    }

    It 'skips unreadable optional Linux module search paths without weakening required paths' {
        $script:Validator | Should -Match 'modulePathExists = Test-Path -LiteralPath \$modulePath -PathType Container -ErrorAction Stop'
        $script:Validator | Should -Match 'catch \[UnauthorizedAccessException\]'
        $script:Validator | Should -Match 'Inherited PSModulePath entries are optional'
    }

    It 'verifies host runtimes by absolute path and hash while keeping package files run-owned' {
        $script:Validator | Should -Match 'function Assert-ExternalReceiptFile'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ExternalReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'nodePath'"))
        $script:Validator | Should -Match 'receipt path must be absolute'
        $script:Validator | Should -Match 'runtime file changed after resolution'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'entryPointPath'"))
    }

    It 'freezes all four formal tools and imports the central security gate before scanning' {
        @($script:Adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
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

    It 'discovers every formal package invocation from catalog source inventory' {
        $script:Validator | Should -Match '\$skillIds\s*=\s*@\(\$integrityReport\.skills'
        $script:Validator | Should -Match 'Assert-SkillSpectorReport'
        $script:Validator | Should -Match 'ExpectedInventoryPaths'
        $script:Validator | Should -Match 'foreach \(\$skillId in \$skillIds\)'
        $script:Validator | Should -Match "validate', 'structure', '--allow-dirs=agents'"
        $script:Validator | Should -Match "'check', '--strict', '--allow-dirs=agents'"
        $script:Validator | Should -Match ([regex]::Escape("'check', `$skillRoot, '--format', 'sarif'"))
    }

    # Scenario: A SkillSpector report fails one completeness gate or contains hostile status text.
    # Purpose: Emit one bounded, sanitized diagnostic while preserving fail-closed rejection.
    It 'UnitT30_ReportsSanitizedSkillSpectorCompletenessFailures' {
        $completeness = [pscustomobject]@{
            execution_successful = $true
            is_complete = $true
            status = 'complete'
            coverage_percent = 100
            ledger_exceptions = @()
            scope_exclusions = @()
            limitations = @()
        }
        $report = [pscustomobject]@{
            execution_successful = $false
            analysis_completeness = $completeness
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @()
                } $report
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'execution_successful'
            $failure.Message | Should -Match 'did not prove complete static analysis'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: The report status contains an attacker-controlled long value and marker.
    # Purpose: Keep diagnostics bounded and prevent untrusted report strings from reaching output.
    It 'UnitT31_RedactsAndBoundsHostileCompletenessStrings' {
        $hostileStatus = 'partial;SECRET_MARKER=' + ('x' * 4096)
        $report = [pscustomobject]@{
            execution_successful = $true
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $true
                status = $hostileStatus
                coverage_percent = 100
                ledger_exceptions = @()
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @()
                } $report
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $diagnostic = $failure.Message
            $diagnostic | Should -Match 'analysis_completeness.status'
            $diagnostic.Length | Should -BeLessThan 500
            $diagnostic | Should -Not -Match 'SECRET_MARKER'
            $failure.Message | Should -Match 'did not prove complete static analysis'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: A required completeness gate field is absent from the report.
    # Purpose: Identify missing gate evidence safely and continue to reject the report.
    It 'UnitT32_ReportsMissingCompletenessGateFieldsAndRejects' {
        $report = [pscustomobject]@{
            execution_successful = $true
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                status = 'complete'
                coverage_percent = 100
                ledger_exceptions = @()
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @()
                } $report
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'analysis_completeness.is_complete=missing'
            $failure.Message | Should -Match 'did not prove complete static analysis'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: SkillId contains a newline and attacker-controlled marker text.
    # Purpose: Keep both the generic rejection and diagnostic free of raw SkillId content.
    It 'UnitT33_RedactsHostileSkillIdInCompletenessFailure' {
        $hostileSkillId = "bad`nSECRET_SKILL_ID" + ('x' * 4096)
        $report = [pscustomobject]@{
            execution_successful = $false
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $true
                status = 'complete'
                coverage_percent = 100
                ledger_exceptions = @()
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport, $probeSkillId)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId $probeSkillId -ExpectedInventoryPaths @()
                } $report $hostileSkillId
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'did not prove complete static analysis'
            $failure.Message | Should -Match 'skillId=\[redacted\]'
            $failure.Message | Should -Not -Match 'SECRET_SKILL_ID'
            $failure.Message | Should -Not -Match '[\r\n]'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts a clean skill-tools SARIF report with no findings' {
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

    # Scenario: Static candidate checks remain offline while an explicitly enabled semantic scan uses its trusted profile.
    # Purpose: Prevent optional semantic scanning from weakening deterministic failure or credential isolation.
    It 'UnitT80_ModelsSemanticScanAsADeterministicFailClosedConditionalStage' {
        $script:Validator | Should -Match 'Test-SecurityRelevantSkillChange'
        $script:Validator | Should -Match '\$staticFindingCount -gt 0'
        $script:Validator | Should -Match 'Triggered SkillSpector semantic scan did not complete'
        $script:Validator | Should -Match '\[switch\] \$EnableSemanticScan'
        $script:Validator | Should -Match '\$semanticTriggered = \[bool\]\$EnableSemanticScan -and'
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
        $semanticIndex = $script:Validator.IndexOf('$semanticTriggerCandidate')
        $pesterIndex = $script:Validator.IndexOf('$pesterRunnerPath')
        $semanticIndex | Should -BeGreaterThan -1
        $pesterIndex | Should -BeGreaterThan $semanticIndex
        $candidate = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-candidate-windows.yml') -Raw
        $main = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $candidate | Should -Match '(?m)^  pull_request:\s*$'
        $candidate | Should -Match 'github\.event\.pull_request\.head\.sha'
        $main | Should -Match '(?ms)^  push:\s*\r?\n\s+branches:\s*\r?\n\s+- main'
        $main | Should -Match 'EXPECTED_HEAD_SHA: \$\{\{ github\.sha \}\}'
        foreach ($workflow in @($candidate, $main)) {
            $workflow | Should -Match 'runs-on: windows-latest'
            $workflow | Should -Match 'scripts/Validate\.ps1'
            $workflow | Should -Match 'TrustedTestCommit \$checkoutHead'
            $workflow | Should -Not -Match 'pull_request_target|checks: write|ubuntu-latest'
        }
    }

    It 'keeps required CI free of implicit LLM credentials and skipped tests' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Not -Match 'EnableSemanticScan'
        $script:Validator | Should -Match 'credential-free and deterministic'
        $script:Validator | Should -Match 'SkippedCount -ne 0'
        $script:Validator | Should -Match "SKILLSPECTOR_MAX_WORKFLOW_SECONDS.*=.*'1200'"
        $script:Validator | Should -Match 'authoritative 300-second execution limit'
        $script:Validator | Should -Match '-AdditionalEnvironmentVariables \$skillSpectorRuntimeEnvironment'
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'rawSha256'
        $repositoryValidator | Should -Match '\[string\] \$TrustedGitPath'
        $repositoryValidator | Should -Match '\[string\] \$TrustedStatPath'
        $repositoryValidator | Should -Match '\[switch\] \$NoFilters'
        $repositoryValidator | Should -Match 'NoFilters:\$NoFilters'
    }

    # Scenario: A collaborator can select a branch when requesting a manual workflow run.
    # Purpose: Keep the normal PR and main paths read-only and exclude ref-selected dispatch.
    It 'does not expose ref-selectable dispatch or a write-token publisher' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Not -Match '(?m)^\s+workflow_dispatch:'
        $workflow | Should -Not -Match 'pull_request_target|checks: write|publish-head-required-checks'
        $workflow | Should -Match '(?m)^  push:'
        $workflow | Should -Match 'ref: \$\{\{ github\.sha \}\}'
    }
}

Describe 'Installed closure path identity' {
    BeforeAll {
        $script:TrustRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:TrustValidator = Get-Content -LiteralPath (Join-Path $script:TrustRepositoryRoot 'scripts/Validate.ps1') -Raw
    }

    # Scenario: Two installed paths share an ordinal, NFC or ASCII-folded identity.
    # Purpose: Fail closed using actual production helpers, including canonically equivalent Unicode.
    It 'UnitT55_RejectsCollidingInstalledPaths_<kind>' -ForEach @(
        @{ kind = 'NFC'; first = "$([char]0xE9).txt"; second = "e$([char]0x301).txt"; message = '*Unicode-normalization-colliding*' },
        @{ kind = 'case'; first = 'A.txt'; second = 'a.txt'; message = '*ASCII-case-colliding*' },
        @{ kind = 'duplicate'; first = 'a.txt'; second = 'a.txt'; message = '*duplicate path*' }
    ) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:TrustValidator, [ref]$tokens, [ref]$errors)
        $functions = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Assert-InstalledClosureSafeRelativePath', 'Get-InstalledClosureAsciiCaseFold', 'Add-InstalledClosureEntry')
        }, $true)
        @($errors).Count | Should -Be 0
        @($functions).Count | Should -Be 3
        $module = New-Module -ScriptBlock ([scriptblock]::Create(($functions.Extent.Text -join "`n")))
        { & $module {
            param($one, $two)
            $entries = [Collections.Generic.List[object]]::new()
            $ordinal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $nfc = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $ascii = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            foreach ($path in @($one, $two)) {
                Add-InstalledClosureEntry -Entries $entries -OrdinalPaths $ordinal -NfcPaths $nfc -AsciiCasePaths $ascii -Entry @{ path = $path; sha256 = ('a' * 64) } -Context 'fixture'
            }
        } $first $second } | Should -Throw $message
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
            'Enable-LinuxWritableRootInspector',
            'Invoke-LinuxWritableRootInspection',
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
    # Purpose: Keep the exact 100000 ceiling inside the descriptor-relative native traversal.
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
}
