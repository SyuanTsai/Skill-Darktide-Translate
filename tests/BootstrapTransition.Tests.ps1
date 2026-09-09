# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide bootstrap transition' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:Supervisor = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:ProtectedWorkflow = Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml'
    }

    It 'UnitT10_ValidatesTheCurrentLegacyLayoutOnlyThroughAnExplicitTransition' {
        # Scenario: The bootstrap commit still uses the current source catalog and .agents/skills package root.
        # Purpose: Prove the trusted repository validator has an explicit, bounded transition path before Standard v1 promotion.
        $reportPath = Join-Path $TestDrive 'bootstrap-repository-report.json'
        $output = @(& $script:RepositoryValidator `
                -RepositoryRoot $script:RepositoryRoot `
                -BootstrapTransition `
                -OutputPath $reportPath)
        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json

        $result.result | Should -Be 'passed'
        $result.validationMode | Should -Be 'bootstrap-transition'
        $result.skillsRoot | Should -Be '.agents/skills'
        $result.activeSkillCount | Should -Be 1
        Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
    }

    It 'UnitT20_DoesNotPromoteTheLegacyLayoutWithoutTheTransitionFlag' {
        # Scenario: A caller omits the explicit transition authorization.
        # Purpose: Prevent a missing Standard v1 adapter from silently becoming a successful validation mode.
        { & $script:RepositoryValidator -RepositoryRoot $script:RepositoryRoot } |
            Should -Throw '*Standard v1*'
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
}
