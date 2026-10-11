# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'SourceValidation tracked-only package snapshot' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
    }
    BeforeEach {
        $script:SnapshotRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:SnapshotRoot)
        foreach ($directory in @('catalog', 'config', 'skills')) {
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $directory) -Destination $script:SnapshotRoot -Recurse
        }
        $script:PackageRoot = Join-Path $script:SnapshotRoot 'skills/auto-update-darktide-mod'
    }

    # Scenario: The central runner supplies a verified tracked-only snapshot without Git metadata.
    # Purpose: Validate every package byte while leaving Git/index/mode acquisition binding with the runner.
    It 'UnitT10_ValidatesEverySnapshotFileWithoutReadingGit' {
        $report = & $script:ValidatorPath -RepositoryRoot $script:SnapshotRoot -ReadOnlySnapshot -TrustedGitPath (Join-Path $TestDrive 'unavailable-git.exe') |
            Select-Object -Last 1 | ConvertFrom-Json -Depth 30
        $report.result | Should -BeExactly 'passed'
        $report.activeSkillCount | Should -Be 1
        @($report.skills[0].files).Count | Should -Be @(Get-ChildItem -LiteralPath $script:PackageRoot -Recurse -File).Count
        foreach ($file in @($report.skills[0].files)) {
            $actual = (Get-FileHash -LiteralPath (Join-Path $script:PackageRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant()
            $file.sha256 | Should -BeExactly $actual
            $file.rawSha256 | Should -BeExactly $actual
            @($file.PSObject.Properties.Name) | Should -Not -Contain 'mode'
        }
        Test-Path -LiteralPath (Join-Path $script:SnapshotRoot '.git') | Should -BeFalse
    }

    # Scenario: One verified package byte changes between two diagnostic snapshots.
    # Purpose: Make the complete raw-byte identity sensitive to changes rather than Git normalization.
    It 'UnitT20_ChangesTheSnapshotIdentityWhenPackageBytesChange' {
        $before = & $script:ValidatorPath -RepositoryRoot $script:SnapshotRoot -ReadOnlySnapshot | Select-Object -Last 1 | ConvertFrom-Json
        [IO.File]::AppendAllText((Join-Path $script:PackageRoot 'references/automation.md'), "`nSnapshot mutation fixture.`n")
        $after = & $script:ValidatorPath -RepositoryRoot $script:SnapshotRoot -ReadOnlySnapshot | Select-Object -Last 1 | ConvertFrom-Json
        $after.skills[0].contentSha256 | Should -Not -Be $before.skills[0].contentSha256
    }

    # Scenario: A candidate includes a package directory omitted from its source inventory.
    # Purpose: Preserve exact active-package coverage in the snapshot adapter.
    It 'UnitT30_RejectsAnUnlistedSnapshotPackage' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:SnapshotRoot 'skills/unlisted'))
        { & $script:ValidatorPath -RepositoryRoot $script:SnapshotRoot -ReadOnlySnapshot } |
            Should -Throw '*inventory does not exactly match*'
    }

    # Scenario: A package entry points outside the immutable snapshot.
    # Purpose: Preserve the existing reparse boundary rather than hashing an external target.
    It 'InterT40_RejectsAReparseEntryInsideTheSnapshot' {
        $outside = Join-Path $TestDrive 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        $kind = if ([OperatingSystem]::IsWindows()) { 'Junction' } else { 'SymbolicLink' }
        [void](New-Item -ItemType $kind -Path (Join-Path $script:PackageRoot 'external') -Target $outside)
        { & $script:ValidatorPath -RepositoryRoot $script:SnapshotRoot -ReadOnlySnapshot } | Should -Throw '*reparse*'
    }
}
