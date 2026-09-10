# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide bootstrap transition' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:Supervisor = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:ProtectedWorkflow = Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Layout = Get-TestRepositoryLayout -RepositoryRoot $script:RepositoryRoot

        function New-ValidatorGitSnapshot {
            param([Parameter(Mandatory = $true)][string] $Destination)

            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $script:RepositoryRoot -Force |
                    Where-Object { $_.Name -cne '.git' })) {
                Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
            }
            & git -C $Destination init --quiet --initial-branch=main
            if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the validator Git snapshot.' }
            & git -C $Destination config user.name 'Protected Validator Snapshot'
            & git -C $Destination config user.email 'protected-validator@example.invalid'
            & git -C $Destination add --all
            & git -C $Destination commit --quiet -m 'protected validator snapshot'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to commit the validator Git snapshot.' }
            return $Destination
        }

        $script:ValidatorRepositoryRoot = New-ValidatorGitSnapshot `
            -Destination (Join-Path $TestDrive 'validator-repository-snapshot')
    }

    It 'UnitT10_ValidatesExactlyOneBoundedRepositoryLayout' {
        # Scenario: The protected suite runs against either the current legacy tree or a Standard v1 migration candidate.
        # Purpose: Keep both accepted structures explicit while requiring the matching validator mode.
        if ($script:Layout.Name -ceq 'legacy') {
            $reportPath = Join-Path $TestDrive 'bootstrap-repository-report.json'
            $output = @(& $script:RepositoryValidator `
                    -RepositoryRoot $script:ValidatorRepositoryRoot `
                    -BootstrapTransition `
                    -OutputPath $reportPath)
            $result = ($output | Select-Object -Last 1) | ConvertFrom-Json

            $result.result | Should -Be 'passed'
            $result.validationMode | Should -Be 'bootstrap-transition'
            $result.skillsRoot | Should -Be '.agents/skills'
            $result.activeSkillCount | Should -Be 1
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
        }
        else {
            $reportPath = Join-Path $TestDrive 'standard-v1-repository-report.json'
            $output = @(& $script:RepositoryValidator `
                    -RepositoryRoot $script:ValidatorRepositoryRoot `
                    -OutputPath $reportPath)
            $result = ($output | Select-Object -Last 1) | ConvertFrom-Json

            $result.result | Should -Be 'passed'
            $result.sourceId | Should -Be 'darktide-translate'
            $result.skillsRoot | Should -Be 'skills'
            $result.activeSkillCount | Should -Be 1
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
        }
    }

    It 'UnitT20_RejectsAnUnauthorizedValidatorMode' {
        # Scenario: A caller selects a validator mode that does not belong to the repository's bounded layout.
        # Purpose: Prevent legacy authorization from being reused after Standard v1 promotion and prevent normal validation from bypassing legacy transition authorization.
        if ($script:Layout.Name -ceq 'legacy') {
            { & $script:RepositoryValidator -RepositoryRoot $script:ValidatorRepositoryRoot } |
                Should -Throw '*Standard v1*'
        }
        else {
            { & $script:RepositoryValidator -RepositoryRoot $script:ValidatorRepositoryRoot -BootstrapTransition } |
                Should -Throw '*catalog/skills-catalog.json fixture*'
        }
    }

    It 'UnitT25_RejectsMixedMissingAndUnauthorizedLayouts' {
        # Scenario: A migration candidate has both layout markers, only part of a layout, or an unrelated source root.
        # Purpose: Prove the protected test resolver does not widen the migration path to arbitrary directories or silently accept missing configuration.
        $mixedRoot = Join-Path $TestDrive 'mixed-layout'
        New-Item -ItemType Directory -Path (Join-Path $mixedRoot 'catalog'), (Join-Path $mixedRoot 'config'),
            (Join-Path $mixedRoot '.agents/skills/auto-update-darktide-mod'), (Join-Path $mixedRoot 'skills/auto-update-darktide-mod') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mixedRoot 'catalog/skills-catalog.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $mixedRoot 'catalog/source.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $mixedRoot 'config/standard-v1.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $mixedRoot } |
            Should -Throw '*mixed*'

        $incompleteRoot = Join-Path $TestDrive 'incomplete-layout'
        New-Item -ItemType Directory -Path (Join-Path $incompleteRoot 'catalog') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $incompleteRoot 'catalog/source.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $incompleteRoot } |
            Should -Throw '*incomplete or unauthorized*'

        $unauthorizedRoot = Join-Path $TestDrive 'unauthorized-layout'
        New-Item -ItemType Directory -Path (Join-Path $unauthorizedRoot 'catalog'), (Join-Path $unauthorizedRoot 'extensions/skills/auto-update-darktide-mod') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $unauthorizedRoot 'catalog/source.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $unauthorizedRoot } |
            Should -Throw '*incomplete or unauthorized*'

        if ($script:Layout.Name -ceq 'standard-v1') {
            $missingConfigRoot = New-ValidatorGitSnapshot `
                -Destination (Join-Path $TestDrive 'standard-v1-missing-config')
            Remove-Item -LiteralPath (Join-Path $missingConfigRoot 'config/standard-v1.json') -Force
            { & $script:RepositoryValidator -RepositoryRoot $missingConfigRoot } |
                Should -Throw '*standard-v1.json*'

            $mixedCandidateRoot = New-ValidatorGitSnapshot `
                -Destination (Join-Path $TestDrive 'standard-v1-mixed-candidate')
            Set-Content -LiteralPath (Join-Path $mixedCandidateRoot 'catalog/skills-catalog.json') -Value '{}'
            { & $script:RepositoryValidator -RepositoryRoot $mixedCandidateRoot } |
                Should -Throw '*must not coexist*'
        }
    }

    It 'UnitT30_SelectsBootstrapOnlyWhenTheCandidateHasNotMigratedToStandardV1' {
        # Scenario: The protected workflow sees either the current bootstrap layout or the migrated layout.
        # Purpose: Keep transition success explicit and prevent a mixed or post-migration tree from taking the legacy path.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match '\[switch\] \$BootstrapTransition'
        $workflow | Should -Match 'BootstrapTransition'
        $workflow | Should -Match 'config/standard-v1\.json'
        $workflow | Should -Match 'catalog/skills-catalog\.json'
    }

    It 'UnitT40_UsesAnOSNativeWindowsProcessSnapshotForCleanup' {
        # Scenario: The host denies WMI process enumeration even though native process controls are available.
        # Purpose: Keep process-tree cleanup bound to an OS-native snapshot instead of weakening identity or cleanup assertions.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'CreateToolhelp32Snapshot'
        $supervisor | Should -Match 'Process32FirstW'
        $supervisor | Should -Match 'Process32NextW'
        $supervisor | Should -Not -Match 'Get-CimInstance\s+-ClassName\s+Win32_Process'
    }

    It 'UnitT50_BindsBootstrapToTheExpectedChangedPathSetAndBaseCommit' {
        # Scenario: A bootstrap candidate could otherwise select the legacy path while changing arbitrary repository content.
        # Purpose: Require an immutable base comparison and a narrow transition-only changed-path contract.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'Bootstrap transition requires a distinct base commit'
        $supervisor | Should -Match 'Bootstrap transition changed-path allowlist'
        $supervisor | Should -Match '\.github/workflows/standard-v1-protected\.yml'
        $supervisor | Should -Match 'scripts/Test-Repository\.ps1'
        $supervisor | Should -Match 'scripts/Validate\.ps1'
        $supervisor | Should -Match 'tests/validate-windows-powershell\.ps1'
        $supervisor | Should -Match 'Bootstrap transition bounded cancellation probe'
    }

    It 'UnitT60_UsesAWindowsLowIntegrityBoundaryForCandidateWrites' {
        # Scenario: The candidate runs under the same runner account as the trusted supervisor.
        # Purpose: Require a mandatory-integrity boundary so candidate code cannot write up into supervisor-owned roots.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'S-1-16-4096'
        $supervisor | Should -Match 'TokenIntegrityLevel'
        $supervisor | Should -Match 'SetTokenInformation'
        $supervisor | Should -Match 'SetLowIntegrityKernelObject'
        $supervisor | Should -Match 'CreateRestrictedToken'
        $supervisor | Should -Match 'Set-WindowsLowIntegrityDirectory'
        $supervisor | Should -Match "'/setintegritylevel'"
    }

    It 'UnitT70_PinsTheTrustedPesterRegressionInventory' {
        # Scenario: Candidate code removes a protected regression file before the isolated run.
        # Purpose: Require the base-owned supervisor to invoke a fixed, non-empty test inventory.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match "'BootstrapTransition\.Tests\.ps1'"
        $supervisor | Should -Match "'RepositoryValidation\.Tests\.ps1'"
        $supervisor | Should -Match '\$requiredPesterPaths'
        $supervisor | Should -Match 'Invoke-Pester -Path \$requiredPesterPaths'
        $supervisor | Should -Not -Match '\$requiredPesterTests = @\(\)'
    }

    It 'UnitT80_ProjectsLinuxEtcWithoutArchiveOwnershipCopy' {
        # Scenario: A user namespace cannot read every host /etc file or preserve host-root ownership.
        # Purpose: Build a private readable projection without mutating the host bind or aborting on archive metadata.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'system_root.*=.*"/etc"'
        $supervisor | Should -Match '-type f -readable'
        $supervisor | Should -Match '/bin/cat -- "\$source"'
        $supervisor | Should -Not -Match '/bin/cp -a'
    }

    It 'UnitT90SeparatesChildOutputAndTrustedPesterContent' {
        # Scenario: Low-integrity children must write only to a labeled output root, while tests come from trusted Git bytes.
        # Purpose: Keep scanner receipts and Pester content outside candidate-writable paths and out of the worker's authority.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match "'low-integrity-output'"
        $supervisor | Should -Match '''-PesterChildWritableRoot'', \$childOutputRoot'
        $supervisor | Should -Match '-ChildWritableRoot \$ChildWritableRoot'
        $supervisor | Should -Match 'Expand-TrustedGitArchive'
        $supervisor | Should -Match 'Assert-TrustedGitTreeFile'
        $supervisor | Should -Match '\$trustedPesterCommit'
        $supervisor | Should -Match '(?s)Expand-TrustedGitArchive.*?-Revision \$trustedPesterCommit.*?-PathSpec @\(''tests''\).*?-Context ''Trusted base Pester tests'''
        $supervisor | Should -Match '(?s)\$candidateMirrorTestsRoot.*?Remove-Item'
        $supervisor | Should -Match '\$readOnlyPaths = @\('
        $supervisor | Should -Match 'Invoke-ProtectedPesterRunspace'
        $supervisor | Should -Match 'CreateOutOfProcessRunspace'
        $supervisor | Should -Match 'AddScript\(\$workerScriptText\)'
        $supervisor | Should -Match 'InvocationStateInfo\.State'
        $supervisor | Should -Match 'Assert-LinuxAggregateResourceUsage'
        $supervisor | Should -Match 'Get-LinuxAggregateClockTicksPerSecond'
        $supervisor | Should -Match 'Get-LinuxCgroupCpuUsage'
        $supervisor | Should -Match '\$fields\[13\].*\$fields\[14\]'
        $supervisor | Should -Match 'CODEX_PESTER_CGROUP_ROOT'
        $supervisor | Should -Match 'Get-LinuxPesterCgroupRoot'
        $supervisor | Should -Match '/proc/\$PID/cgroup'
        $supervisor | Should -Match 'New-LinuxPesterCgroup'
        $supervisor | Should -Match 'memory\.max'
        $supervisor | Should -Match 'cpu\.stat'
        $supervisor | Should -Match 'usage_usec'
        $supervisor | Should -Match 'cgroup\.procs'
        $supervisor | Should -Match 'cgroup\.events'
        $supervisor | Should -Match 'populated'
        $supervisor | Should -Match 'Start-Sleep -Milliseconds 25'
        $supervisor | Should -Match 'linuxPesterCgroupCleanupException'
        $supervisor | Should -Match 'Add-LinuxProcessTreeToCgroup'
        $workflow | Should -Match 'Delegate Linux cgroup v2 subtree'
        $workflow | Should -Match 'CODEX_PESTER_CGROUP_ROOT'
        $workflow | Should -Match 'CODEX_PESTER_VALIDATOR_CGROUP'
        $workflow | Should -Match 'root_subtree_control'
        $workflow | Should -Match '\+cpu \+memory'
        $workflow | Should -Match 'cgroup\.subtree_control'
        $workflow | Should -Match 'cgroup\.threads'
        $workflow | Should -Match 'cgroup_parent/cgroup\.procs'
        $workflow | Should -Match 'sudo -n chown'
        $workflow | Should -Match 'trusted-validator'
        $workflow | Should -Match 'Remove delegated Linux cgroup subtree'
        $supervisor | Should -Match 'Start-WindowsSuspendedProcess'
        $supervisor | Should -Match '\.CopyToAsync\('
        $supervisor | Should -Match '--kill-child'
        $supervisor | Should -Match '--as=2147483648'
        $supervisor | Should -Match '--cpu=300'
        $supervisor | Should -Match '\[switch\] \$ProtectedPesterServerProxy'
        $supervisor | Should -Match '\$PesterProxyReadOnlyPathsJson'
        $supervisor | Should -Match 'EnvironmentVariables\.Remove\(\$gateEnvironmentName\)'
        $supervisor | Should -Match '\[ ! -e "\$target" \]'
        $supervisor | Should -Match 'exec "\$chroot_path"'
        $supervisor | Should -Match 'exec chroot "\$sandbox_root"'
        $supervisor | Should -Match 'SGV1-Pester-Result:'
        $supervisor | Should -Match 'Invoke-TrustedPowerShellProcess'
        $supervisor | Should -Match 'Invoke-ProtectedPesterSupervisor'
        $supervisor | Should -Match '\$trustedPesterSupervisorMarker'
        $supervisor | Should -Match '\$completionMarker = \(\[Console\]::In\.ReadToEnd\(\)\)'
        $supervisor | Should -Match 'trusted-parent-post-exit'
        $supervisor | Should -Match '\$completionAttestationNonce'
        $supervisor | Should -Not -Match '\$workerMarkerVariableName'
        $supervisor | Should -Not -Match '\$workerResultLines'
        $supervisor | Should -Not -Match '-StandardInput \$pesterWorkerMarker'
        $supervisor | Should -Not -Match '\$pesterSupervisorPath\s*='
    }
}
