# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
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

    It 'does not resolve an omitted Linux read-only path as an empty filesystem path' {
        $script:Validator | Should -Match '\$readOnlyPathText = \[string\]\$readOnlyPath'
        $script:Validator | Should -Match 'IsNullOrWhiteSpace\(\$readOnlyPathText\)\) \{ continue \}'
        $script:Validator | Should -Match 'GetFullPath\(\$readOnlyPathText\)'
    }

    It 'accounts for safe Unix symlinks in the bounded Linux writable-root scan' {
        $script:Validator | Should -Match 'Get-InstalledSafeUnixSymlinkEntry -Item \$entry -Root \$rootPath -Context \$Context'
        $script:Validator | Should -Match '(?s)if \(\(\$entry\.Attributes.*?ReparsePoint.*?\) -ne 0\).*?Get-InstalledSafeUnixSymlinkEntry.*?continue'
    }

    It 'counts safe Unix symlink payloads toward bounded writable-root usage' {
        $usageStart = $script:Validator.IndexOf('function Get-LinuxWritableRootUsage', [StringComparison]::Ordinal)
        $usageEnd = $script:Validator.IndexOf('function Assert-LinuxWritableRootUsage', $usageStart, [StringComparison]::Ordinal)
        $usageFunction = $script:Validator.Substring($usageStart, $usageEnd - $usageStart)

        $usageFunction | Should -Match '\$symlinkEntry = Get-InstalledSafeUnixSymlinkEntry'
        $usageFunction | Should -Match '\$entryCount\+\+'
        $usageFunction | Should -Match '\$symlinkBytes = \[int64\]\$symlinkEntry\.storageBytes'
        $usageFunction | Should -Match '\$bytes \+= \$symlinkBytes'
        $usageFunction | Should -Match 'writable-entry-count limit of 100000'
        $script:Validator | Should -Match '\$storageBytes = \[Text\.Encoding\]::UTF8\.GetByteCount\(\$target\)'
    }

    # Scenario: A real directory is encountered during bounded writable-root inspection.
    # Purpose: Preserve count-and-limit ordering before traversal; native behavior is tested below.
    It 'UnitT90_CountsDirectoriesBeforeTraversingBoundedWritableRoots' {
        $usageStart = $script:Validator.IndexOf('function Get-LinuxWritableRootUsage', [StringComparison]::Ordinal)
        $usageEnd = $script:Validator.IndexOf('function Assert-LinuxWritableRootUsage', $usageStart, [StringComparison]::Ordinal)
        $usageFunction = $script:Validator.Substring($usageStart, $usageEnd - $usageStart)

        $usageFunction | Should -Match '(?s)if \(\$entry -is \[IO\.DirectoryInfo\]\) \{.*?\$entryCount\+\+.*?writable-entry-count limit of 100000.*?\$pending\.Push\(\[IO\.DirectoryInfo\]\$entry\)'
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
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Match 'github\.run_attempt'
        $workflow | Should -Match 'github\.event\.pull_request\.head\.sha'
        $workflow | Should -Match 'pull_request_target:'
        $workflow | Should -Match 'ref: \$\{\{ github\.event_name == .pull_request_target. && github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}'
        $workflow | Should -Match 'Materialize protected validation supervisor'
        $workflow | Should -Match 'Materialize protected Windows compatibility contract'
        $workflow | Should -Match 'TRUSTED_WINDOWS_CONTRACT'
        $workflow | Should -Match 'TRUSTED_SUPERVISOR_COMMIT: \$\{\{ github\.sha \}\}'
        $workflow | Should -Match 'TRUSTED_DEFAULT_BRANCH: \$\{\{ github\.event\.repository\.default_branch \}\}'
        $workflow | Should -Match "GITHUB_EVENT_NAME -eq 'workflow_dispatch'"
        $workflow | Should -Match 'refs/remotes/origin'
        $workflow | Should -Match 'Enable unprivileged Linux user namespaces'
        $workflow | Should -Match 'kernel\.unprivileged_userns_clone=1'
        $workflow | Should -Match 'kernel\.apparmor_restrict_unprivileged_userns=0'
        $workflow | Should -Match 'unshare --user --map-root-user --pid --fork --kill-child=SIGKILL -- true'
        $workflow | Should -Match 'publish-head-required-checks'
        $workflow | Should -Match "github\.event_name != 'workflow_dispatch'"
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

    # Scenario: A collaborator can choose a branch when manually dispatching a workflow.
    # Purpose: A branch-owned definition must never gain this publisher's checks permission.
    It 'does not expose ref-selectable dispatch on the privileged workflow' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $workflow | Should -Not -Match '(?m)^\s+workflow_dispatch:'
        $workflow | Should -Match '(?m)^  pull_request_target:'
        $workflow | Should -Match 'baseCandidate.*not.*distinct ancestor'
        $workflow | Should -Match "github\.event_name == 'push'.*github\.sha"
    }
}

Describe 'Protected workflow trust binding' {
    BeforeAll {
        $script:TrustRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:TrustWorkflow = Get-Content -LiteralPath (Join-Path $script:TrustRepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        $script:TrustValidator = Get-Content -LiteralPath (Join-Path $script:TrustRepositoryRoot 'scripts/Validate.ps1') -Raw

        function Get-TestWorkflowStep {
            param([string] $Name)
            $pattern = '(?ms)^      - name: ' + [regex]::Escape($Name) + '\r?\n(?:(?!^      - name: ).)*?        run: \|\r?\n(?<body>(?:          [^\r\n]*\r?\n|\r?\n)+)'
            $match = [regex]::Match($script:TrustWorkflow, $pattern)
            if (-not $match.Success) { throw "Workflow step not found: $Name" }
            return [regex]::Replace($match.Groups['body'].Value, '(?m)^          ', '')
        }

        function Invoke-TestManualTrust {
            param([string] $BaseMode = 'blank', [string] $EventName = 'workflow_dispatch', [switch] $RemoveProof)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $repo = Join-Path $root 'repo'
            $temp = Join-Path $root 'runner'
            [void](New-Item -ItemType Directory -Path $repo, $temp, (Join-Path $repo 'scripts'), (Join-Path $repo 'tests') -Force)
            $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
            function Invoke-FixtureGit {
                param([string[]] $GitArgs)
                $output = @(& $git -C $repo -c user.name=Example -c user.email=example@example.test -c commit.gpgsign=false @GitArgs 2>&1)
                if ($LASTEXITCODE -ne 0) { throw "Git fixture failed: $output" }
                return ($output -join "`n").Trim()
            }
            $start = $script:TrustValidator.IndexOf('$trustedPesterCommit =', [StringComparison]::Ordinal)
            $end = $script:TrustValidator.IndexOf('$pesterMirrorRoot =', $start, [StringComparison]::Ordinal)
            if ($start -lt 0 -or $end -le $start) { throw 'Production Pester trust-selection block not found.' }
            $selection = $script:TrustValidator.Substring($start, $end - $start)
            $spy = @'
param($RepositoryRoot, $ArtifactsRoot, $BaseCommit, $TrustedTestCommit, $ExpectedGoRuntimeVersion, $OutputPath)
$isGitHubActions = $true
$candidateCommit = (& git -C $RepositoryRoot rev-parse HEAD) -join ''
'@ + "`n" + $selection + @'

$marker = (& git -C $RepositoryRoot show "${trustedPesterCommit}:tests/marker.txt") -join ''
if ($LASTEXITCODE -ne 0) { throw 'Selected trusted test commit is not readable.' }
[pscustomobject]@{ base = $BaseCommit; trusted = $trustedPesterCommit; marker = $marker } |
    ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding utf8
'@
            [IO.File]::WriteAllText((Join-Path $repo 'scripts/Validate.ps1'), $spy)
            [IO.File]::WriteAllText((Join-Path $repo 'scripts/Test-Repository.ps1'), '# trusted fixture')
            [IO.File]::WriteAllText((Join-Path $repo 'tests/marker.txt'), 'common')
            [void](Invoke-FixtureGit @('init', '-q', '-b', 'main'))
            [void](Invoke-FixtureGit @('add', '.'))
            [void](Invoke-FixtureGit @('commit', '-qm', 'common'))
            $common = Invoke-FixtureGit @('rev-parse', 'HEAD')
            [void](Invoke-FixtureGit @('checkout', '-qb', 'candidate'))
            [IO.File]::WriteAllText((Join-Path $repo 'tests/marker.txt'), 'candidate-untrusted')
            [void](Invoke-FixtureGit @('commit', '-qam', 'candidate'))
            $candidate = Invoke-FixtureGit @('rev-parse', 'HEAD')
            [void](Invoke-FixtureGit @('checkout', '-q', 'main'))
            [IO.File]::WriteAllText((Join-Path $repo 'tests/marker.txt'), 'default-trusted')
            [void](Invoke-FixtureGit @('commit', '-qam', 'trusted'))
            $trusted = Invoke-FixtureGit @('rev-parse', 'HEAD')
            [void](Invoke-FixtureGit @('update-ref', 'refs/remotes/origin/main', $trusted))
            [void](Invoke-FixtureGit @('checkout', '-q', 'candidate'))
            $names = @('RUNNER_TEMP', 'GITHUB_ENV', 'GITHUB_EVENT_NAME', 'GITHUB_SHA', 'TRUSTED_SUPERVISOR_COMMIT', 'TRUSTED_DEFAULT_BRANCH', 'TRUSTED_SUPERVISOR_ROOT', 'TRUSTED_SUPERVISOR_SHA', 'PULL_REQUEST_BASE_SHA', 'PUSH_BEFORE_SHA', 'STANDARD_GO_RUNTIME_VERSION')
            $saved = @{}
            foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
            $savedNativeDirectory = [Environment]::CurrentDirectory
            Push-Location $repo
            try {
                # GitHub launches pwsh with its native cwd equal to the checkout.
                # Match that for the real ProcessStartInfo cat-file invocation.
                [Environment]::CurrentDirectory = $repo
                $env:RUNNER_TEMP = $temp
                $env:GITHUB_ENV = Join-Path $temp 'github-env'
                $env:GITHUB_EVENT_NAME = $EventName
                $env:GITHUB_SHA = if ($EventName -eq 'workflow_dispatch') { $candidate } else { $common }
                $env:TRUSTED_SUPERVISOR_COMMIT = if ($EventName -eq 'workflow_dispatch') { $candidate } else { $common }
                $env:TRUSTED_DEFAULT_BRANCH = 'main'
                $env:TRUSTED_SUPERVISOR_SHA = ''
                $env:PUSH_BEFORE_SHA = ''
                $env:STANDARD_GO_RUNTIME_VERSION = '1.2.3'
                $env:PULL_REQUEST_BASE_SHA = switch ($BaseMode) {
                    'matching' { $trusted }; 'candidate' { $candidate }; 'malformed' { 'not-a-sha' }; 'common' { $common }; default { '' }
                }
                & ([scriptblock]::Create((Get-TestWorkflowStep 'Materialize protected validation supervisor')))
                foreach ($line in (Get-Content -LiteralPath $env:GITHUB_ENV)) {
                    $parts = $line.Split('=', 2)
                    [Environment]::SetEnvironmentVariable($parts[0], $parts[1])
                }
                if ($RemoveProof) { $env:TRUSTED_SUPERVISOR_SHA = '' }
                $canonical = Get-TestWorkflowStep 'Run canonical Standard v1 validation'
                $selectionStart = $canonical.IndexOf('$repositoryRoot =', [StringComparison]::Ordinal)
                if ($selectionStart -lt 0) { throw 'Canonical parameter-selection boundary not found.' }
                # This portable regression executes the real Git/parameter path;
                # Linux cgroup admission is validated by the protected Linux job.
                & ([scriptblock]::Create($canonical.Substring($selectionStart)))
                $result = Get-Content -LiteralPath (Join-Path $temp 'darktide-translate-conformance-report.json') -Raw | ConvertFrom-Json
                return [pscustomobject]@{ Result = $result; Trusted = $trusted; Common = $common }
            }
            finally {
                [Environment]::CurrentDirectory = $savedNativeDirectory
                Pop-Location
                foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
            }
        }
    }

    # Scenario: A manual candidate diverges from the current default branch and omits the optional base.
    # Purpose: Candidate-owned tests cannot replace the supervisor's trusted regression archive.
    It 'InterT10_BindsBlankManualBaseToResolvedDefaultTests' {
        $probe = Invoke-TestManualTrust
        $probe.Result.trusted | Should -BeExactly $probe.Trusted
        $probe.Result.marker | Should -BeExactly 'default-trusted'
        $probe.Result.base | Should -BeNullOrEmpty
    }

    # Scenario: A caller supplies the same resolved default SHA despite divergent candidate history.
    # Purpose: Keep trusted-test identity separate from optional ancestor-only diff comparison.
    It 'InterT20_AcceptsMatchingManualBaseWithoutCandidateFallback' {
        $probe = Invoke-TestManualTrust -BaseMode matching
        $probe.Result.trusted | Should -BeExactly $probe.Trusted
        $probe.Result.base | Should -BeNullOrEmpty
    }

    # Scenario: A manual caller names a candidate or malformed SHA instead of the trusted default.
    # Purpose: Reject arbitrary test provenance instead of silently falling back to candidate tests.
    It 'InterT30_RejectsConflictingManualBase_<mode>' -ForEach @(@{ mode = 'candidate' }, @{ mode = 'malformed' }) {
        { Invoke-TestManualTrust -BaseMode $mode } | Should -Throw '*manual base*trusted supervisor*'
    }

    # Scenario: Materializer proof is missing before canonical invocation.
    # Purpose: An absent trust identity must fail closed before expensive validation.
    It 'InterT40_RejectsMissingSupervisorIdentity' {
        { Invoke-TestManualTrust -RemoveProof } | Should -Throw '*supervisor*SHA*'
    }

    # Scenario: A PR event supplies its immutable common ancestor as the supervisor and comparison base.
    # Purpose: Preserve the established PR archive and changed-path binding.
    It 'InterT50_PreservesPullRequestTrustedBase' {
        $probe = Invoke-TestManualTrust -BaseMode common -EventName pull_request_target
        $probe.Result.trusted | Should -BeExactly $probe.Common
        $probe.Result.base | Should -BeExactly $probe.Common
        $probe.Result.marker | Should -BeExactly 'common'
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

    # Scenario: An existing summary is rewritten or removed after the trusted preflight emitted its evidence.
    # Purpose: Exercise the real exporter against a tampered regular file, not a regex approximation.
    It 'InterT60_AuthenticatesDiagnosticsBeforeExport_<mode>' -ForEach @(
        @{ mode = 'valid' }, @{ mode = 'tampered' }, @{ mode = 'missing-proof' },
        @{ mode = 'deleted' }, @{ mode = 'pre-summary-failure' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $run = Join-Path $root 'sgv1-fixture'
        [void](New-Item -ItemType Directory -Path $run -Force)
        $names = @('RUNNER_TEMP', 'GITHUB_OUTPUT', 'EVIDENCE_BASE64_LENGTH', 'EXPECTED_DIAGNOSTICS_SHA256')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:RUNNER_TEMP = $root
            $env:GITHUB_OUTPUT = Join-Path $root 'trusted-output'
            $env:EVIDENCE_BASE64_LENGTH = '0'
            $env:EXPECTED_DIAGNOSTICS_SHA256 = ''
            $securityPreflightSummaryPath = Join-Path $run 'security-preflight-summary.json'
            $securityBlockers = @()
            $sanitizedSecurityFindings = @()
            $runId = 'fixture'
            $start = $script:TrustValidator.IndexOf('$securityPreflightSummary =', [StringComparison]::Ordinal)
            $end = $script:TrustValidator.IndexOf('if ($securityBlockers.Count -gt 0)', $start, [StringComparison]::Ordinal)
            & ([scriptblock]::Create($script:TrustValidator.Substring($start, $end - $start)))
            if (Test-Path -LiteralPath $env:GITHUB_OUTPUT) {
                $line = Get-Content -LiteralPath $env:GITHUB_OUTPUT | Where-Object { $_ -like 'standard_v1_diagnostics_sha256=*' }
                $env:EXPECTED_DIAGNOSTICS_SHA256 = ([string]$line).Split('=', 2)[1]
            }
            if ($mode -eq 'tampered') {
                $code = "[IO.File]::WriteAllText('" + $securityPreflightSummaryPath.Replace("'", "''") + "', 'forged summary'); exit 1"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
                & (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) -NoProfile -EncodedCommand $encoded
                $LASTEXITCODE | Should -Be 1
            }
            if ($mode -in @('deleted', 'pre-summary-failure')) {
                [IO.File]::Delete($securityPreflightSummaryPath)
            }
            if ($mode -in @('missing-proof', 'pre-summary-failure')) { $env:EXPECTED_DIAGNOSTICS_SHA256 = '' }
            $env:GITHUB_OUTPUT = Join-Path $root 'export-output'
            $exportPath = Join-Path $root 'export.ps1'
            [IO.File]::WriteAllText($exportPath, '$ErrorActionPreference = ''Stop''' + [Environment]::NewLine +
                (Get-TestWorkflowStep 'Export bounded validation diagnostics for clean upload'), [Text.UTF8Encoding]::new($false))
            # Run the real workflow step in a separate pwsh so its exit 0 cannot
            # terminate the test harness or bypass subsequent assertions.
            $exportOutput = @(& (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) -NoProfile -NonInteractive -File $exportPath 2>&1)
            $exportExitCode = $LASTEXITCODE
            if ($mode -in @('valid', 'pre-summary-failure')) {
                $exportExitCode | Should -Be 0
                if ($mode -eq 'valid') { $env:EXPECTED_DIAGNOSTICS_SHA256 | Should -Match '^[0-9a-f]{64}$' }
                $lines = Get-Content -LiteralPath $env:GITHUB_OUTPUT
                ($lines | Where-Object { $_ -like 'diagnostics_sha256=*' }) | Should -BeExactly "diagnostics_sha256=$env:EXPECTED_DIAGNOSTICS_SHA256"
                if ($mode -eq 'pre-summary-failure') {
                    ($lines | Where-Object { $_ -like 'diagnostics_base64=*' }) | Should -BeExactly 'diagnostics_base64='
                }
            }
            else {
                $exportExitCode | Should -Not -Be 0
                ($exportOutput -join [Environment]::NewLine) | Should -Match 'diagnostics'
                Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
            }
        }
        finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
}

Describe 'Bounded writable-root enumeration behavior' {
    BeforeAll {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Validate.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) { throw 'Validator must parse before behavioral testing.' }
        # Test seam exists before the fix so Red measures eager consumption, not a missing symbol.
        function Get-LinuxWritableDirectoryEnumerator {
            param([IO.DirectoryInfo] $Directory)
            return ,$Directory.EnumerateFileSystemInfos().GetEnumerator()
        }
        foreach ($name in @('Get-LinuxWritableDirectoryEnumerator', 'Get-LinuxWritableRootUsage')) {
            $definition = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
            if ($null -ne $definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
            elseif ($name -ceq 'Get-LinuxWritableRootUsage') { throw 'Missing production usage function.' }
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
        $script:CursorState = [pscustomobject]@{
            Pulls = 0; Maximum = 100002; Disposed = 0; Entry = (Get-Item -LiteralPath $file)
        }
        $script:UsageCursor = [pscustomobject]@{ State = $script:CursorState }
        $script:UsageCursor | Add-Member ScriptMethod MoveNext {
            $this.State.Pulls++
            return $this.State.Pulls -le $this.State.Maximum
        }
        $script:UsageCursor | Add-Member ScriptProperty Current { $this.State.Entry }
        $script:UsageCursor | Add-Member ScriptMethod Dispose { $this.State.Disposed++ }
    }
    AfterEach { $script:IsLinuxHost = $script:PreviousLinuxHost }

    # Scenario: A finite source has more entries than the production limit.
    # Purpose: Abort at entry100001 without requesting the remaining source and release the enumerator.
    It 'UnitT10_StopsEnumerationAtTheFirstExcessEntry' {
        Mock Get-LinuxWritableDirectoryEnumerator { return ,$script:UsageCursor }
        Mock Get-ChildItem {
            for ($i = 0; $i -lt $script:CursorState.Maximum; $i++) {
                $script:CursorState.Pulls++
                $script:CursorState.Entry
            }
        }
        { Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Bounded fixture' } | Should -Throw '*limit*'
        $script:CursorState.Pulls | Should -Be 100001
        $script:CursorState.Disposed | Should -Be 1
    }

    # Scenario: A finite source contains exactly the allowed100000 regular files.
    # Purpose: Preserve the inclusive limit and return contract without weakening the overflow case.
    It 'UnitT20_AcceptsTheExactEntryLimit' {
        $script:CursorState.Maximum = 100000
        Mock Get-LinuxWritableDirectoryEnumerator { return ,$script:UsageCursor }
        Mock Get-ChildItem {
            for ($i = 0; $i -lt $script:CursorState.Maximum; $i++) {
                $script:CursorState.Pulls++
                $script:CursorState.Entry
            }
        }
        $usage = Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Exact fixture'
        $usage.fileCount | Should -Be 100000
        $usage.bytes | Should -Be 0
    }

    # Scenario: A real directory contains an ordinary file, hidden-name file and nested directory/file.
    # Purpose: Exercise native enumeration and verify that directories count while file bytes remain exact.
    It 'InterT30_CountsRealFilesDirectoriesAndHiddenEntries' {
        [IO.File]::WriteAllText((Join-Path $script:UsageRoot '.hidden'), 'ab')
        $subdir = Join-Path $script:UsageRoot 'nested'
        [void](New-Item -ItemType Directory -Path $subdir)
        [IO.File]::WriteAllText((Join-Path $subdir 'payload'), 'xyz')
        $usage = Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Real fixture'
        $usage.fileCount | Should -Be 4
        $usage.bytes | Should -Be 5
    }

    # Scenario: The enumeration source raises an IO error while advancing.
    # Purpose: Preserve fail-closed propagation and dispose the native enumeration resource.
    It 'UnitT40_DisposesEnumeratorWhenMoveNextFails' {
        $script:UsageCursor | Add-Member ScriptMethod MoveNext { throw [IO.IOException]::new('fixture enumeration failure') } -Force
        Mock Get-LinuxWritableDirectoryEnumerator { return ,$script:UsageCursor }
        Mock Get-ChildItem { throw [IO.IOException]::new('fixture enumeration failure') }
        { Get-LinuxWritableRootUsage -Root $script:UsageRoot -Context 'Error fixture' } | Should -Throw '*fixture enumeration failure*'
        $script:CursorState.Disposed | Should -Be 1
    }
}
