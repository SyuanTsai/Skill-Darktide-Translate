# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide consumer repository check' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryCheck = Join-Path $script:RepositoryRoot 'scripts/Test-DarktideRepository.ps1'
    }

    It 'UnitT10_DeclaresTheGeneralCheckInterfaceWithoutWindowsOnlyDependencies' {
        $source = Get-Content -LiteralPath $script:RepositoryCheck -Raw
        $source | Should -Match '\[string\]\s+\$RepositoryRoot'
        $source | Should -Match '\[switch\]\s+\$ReadOnlySnapshot'
        $source | Should -Not -Match '(?i)pwsh\.exe|icacls|kernel32|advapi32|DllImport|Add-Type'
    }

    It 'InterT20_ValidatesTheTrackedRepositoryAsAReadOnlySnapshot' {
        $before = @(git -C $script:RepositoryRoot status --porcelain=v1 --untracked-files=all)
        $output = @(& $script:RepositoryCheck -RepositoryRoot $script:RepositoryRoot -ReadOnlySnapshot)
        $LASTEXITCODE | Should -Be 0
        $evidence = $output[-1] | ConvertFrom-TestJson
        $evidence.schemaVersion | Should -Be 1
        $evidence.report | Should -Be 'darktide-repository-check-v1'
        $evidence.result | Should -Be 'passed'
        $evidence.activeSkillCount | Should -Be 1
        @($evidence.skills[0].files).Count | Should -BeGreaterThan 0
        $after = @(git -C $script:RepositoryRoot status --porcelain=v1 --untracked-files=all)
        ($after -join "`n") | Should -BeExactly ($before -join "`n")
    }

    It 'UnitT30_RejectsOutputMutationInReadOnlySnapshotMode' {
        { & $script:RepositoryCheck -RepositoryRoot $script:RepositoryRoot -ReadOnlySnapshot `
                -OutputPath (Join-Path $TestDrive 'forbidden.json') } |
            Should -Throw '*does not permit an output file*'
    }
}
