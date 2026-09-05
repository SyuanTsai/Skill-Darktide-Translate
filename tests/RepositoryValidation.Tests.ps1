# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Repository pre-push validation' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:stateValidatorPath = Join-Path $script:repoRoot 'scripts/Test-CleanRepositoryHead.ps1'
        $script:prePushPath = Join-Path $script:repoRoot 'scripts/Invoke-PrePushValidation.ps1'

        function New-TestGitRepository {
            param([string] $Path)

            New-Item -ItemType Directory -Path $Path -Force | Out-Null
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
        Test-Path -LiteralPath $script:stateValidatorPath | Should -Be $true
        $fixtureRoot = Join-Path $TestDrive 'clean'
        New-TestGitRepository -Path $fixtureRoot

        $result = & $script:stateValidatorPath -RepositoryRoot $fixtureRoot -PassThru
        $expectedHead = (& git -C $fixtureRoot rev-parse --verify 'HEAD^{commit}').Trim()

        $result.result | Should -Be 'passed'
        $result.repositoryRoot | Should -Be (Resolve-Path -LiteralPath $fixtureRoot).Path
        $result.headOid | Should -Be $expectedHead
    }

    It 'UnitT20_RejectsTrackedAndUntrackedChangesBeforeValidation' -ForEach @(
        @{ Case = 'tracked'; Mutate = { param($root) Set-Content -LiteralPath (Join-Path $root 'tracked.txt') -Value 'changed' } }
        @{ Case = 'untracked'; Mutate = { param($root) Set-Content -LiteralPath (Join-Path $root 'untracked.txt') -Value 'new' } }
    ) {
        $fixtureRoot = Join-Path $TestDrive $Case
        New-TestGitRepository -Path $fixtureRoot
        & $Mutate $fixtureRoot

        { & $script:stateValidatorPath -RepositoryRoot $fixtureRoot -PassThru } |
            Should -Throw '*working tree and index must be clean*'
    }

    It 'UnitT30_RejectsAHeadThatChangedAfterValidationStarted' {
        $fixtureRoot = Join-Path $TestDrive 'head-drift'
        New-TestGitRepository -Path $fixtureRoot

        { & $script:stateValidatorPath -RepositoryRoot $fixtureRoot `
                -ExpectedHeadOid '0000000000000000000000000000000000000000' -PassThru } |
            Should -Throw '*HEAD changed during pre-push validation*'
    }

    It 'UnitT40_UsesOnePrePushEntrypointForTheLocalAndCiContract' {
        Test-Path -LiteralPath $script:prePushPath | Should -Be $true
        $prePush = Get-Content -LiteralPath $script:prePushPath -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/validate.yml') -Raw

        $prePush | Should -Match 'scripts/Validate\.ps1'
        $prePush | Should -Match 'ArtifactsRoot'
        $prePush | Should -Match 'BaseCommit'
        $prePush | Should -Not -Match 'tests/Invoke-Tests\.ps1'
        $prePush | Should -Not -Match 'Test-ReferenceIntegrity\.ps1'
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Not -Match 'run: \./tests/Invoke-Tests\.ps1'
    }

    It 'UnitT50_RunsEachPullRequestHeadOnceAndRevalidatesMainAfterMerge' {
        foreach ($workflowName in @('validate.yml')) {
            $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot ".github/workflows/$workflowName") -Raw

            $workflow | Should -Match '(?m)^  push:\r?$'
            $workflow | Should -Match '(?m)^  pull_request:'
        }
    }
}
