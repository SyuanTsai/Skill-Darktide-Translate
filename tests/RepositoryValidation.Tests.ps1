# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Repository clean-head validation' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:StateValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-CleanRepositoryHead.ps1'

        function New-TestGitRepository {
            param([Parameter(Mandatory)][string] $Path)

            [void](New-Item -ItemType Directory -Path $Path -Force)
            & git -C $Path init --quiet --initial-branch=main
            if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the test repository.' }
            & git -C $Path config user.name 'Repository Validation Test'
            & git -C $Path config user.email 'repository-validation@example.invalid'
            Set-Content -LiteralPath (Join-Path $Path 'tracked.txt') -Value 'committed'
            & git -C $Path add -- tracked.txt
            & git -C $Path commit --quiet -m 'test fixture'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to commit the test repository fixture.' }
        }
    }

    It 'UnitT10_AcceptsOnlyACleanRepositoryAndReturnsItsExactHead' {
        Test-Path -LiteralPath $script:StateValidatorPath | Should -BeTrue
        $fixtureRoot = Join-Path $TestDrive 'clean'
        New-TestGitRepository -Path $fixtureRoot

        $result = & $script:StateValidatorPath -RepositoryRoot $fixtureRoot -PassThru
        $expectedHead = (& git -C $fixtureRoot rev-parse --verify 'HEAD^{commit}').Trim()

        $result.result | Should -Be 'passed'
        $result.repositoryRoot | Should -Be ([IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixtureRoot).Path))
        $result.headOid | Should -Be $expectedHead
    }

    It 'UnitT20_RejectsTrackedAndUntrackedChangesBeforeValidation_<Case>' -ForEach @(
        @{ Case = 'tracked'; Mutate = { param($root) Set-Content -LiteralPath (Join-Path $root 'tracked.txt') -Value 'changed' } }
        @{ Case = 'untracked'; Mutate = { param($root) Set-Content -LiteralPath (Join-Path $root 'untracked.txt') -Value 'new' } }
    ) {
        $fixtureRoot = Join-Path $TestDrive $Case
        New-TestGitRepository -Path $fixtureRoot
        & $Mutate $fixtureRoot

        { & $script:StateValidatorPath -RepositoryRoot $fixtureRoot -PassThru } |
            Should -Throw '*working tree and index must be clean*'
    }

    It 'UnitT30_RejectsAHeadThatChangedAfterValidationStarted' {
        $fixtureRoot = Join-Path $TestDrive 'head-drift'
        New-TestGitRepository -Path $fixtureRoot

        { & $script:StateValidatorPath -RepositoryRoot $fixtureRoot `
                -ExpectedHeadOid '0000000000000000000000000000000000000000' -PassThru } |
            Should -Throw '*HEAD changed during pre-push validation*'
    }
}
