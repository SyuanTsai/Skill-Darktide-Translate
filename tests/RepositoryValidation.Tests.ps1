# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Repository pre-push validation' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:stateValidatorPath = Join-Path $script:repoRoot 'scripts/Test-CleanRepositoryHead.ps1'
        $script:prePushPath = Join-Path $script:repoRoot 'scripts/Invoke-PrePushValidation.ps1'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:layout = Get-TestRepositoryLayout -RepositoryRoot $script:repoRoot

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

    # Scenario: The Standard v1 source tree is validated through its documented entry points.
    # Purpose: Keep the normal CI route and local pre-push wrapper bound to the canonical validator.
    It 'UnitT40_UsesTheValidationEntrypointForTheCurrentLifecycle' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot $script:layout.WorkflowPath) -Raw

        Test-Path -LiteralPath $script:prePushPath | Should -BeTrue
        $prePush = Get-Content -LiteralPath $script:prePushPath -Raw
        $prePush | Should -Match 'scripts/Validate\.ps1'
        $prePush | Should -Match 'ArtifactsRoot'
        $prePush | Should -Match 'BaseCommit'
        $prePush | Should -Not -Match 'tests/Invoke-Tests\.ps1'
        $prePush | Should -Not -Match 'Test-ReferenceIntegrity\.ps1'
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Not -Match 'run: \./tests/Invoke-Tests\.ps1'
    }

    # Scenario: A pull request or main push enters the one ordinary Windows validation route.
    # Purpose: Prevent the retired protected publisher and parallel compatibility graph from remaining live.
    It 'UnitT50_UsesOnlyPullRequestAndMainPushEvents' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot $script:layout.WorkflowPath) -Raw
        $workflow | Should -Match '(?m)^  push:\r?$'
        $workflow | Should -Match '(?ms)^  push:\r?\n    branches:\r?\n      - main(?:\r?\n|$)'
        $workflow | Should -Match '(?m)^  pull_request:\s*$'
        $workflow | Should -Not -Match 'pull_request_target|workflow_dispatch|checks: write'
        $workflow | Should -Match 'Install-LatestPowerShell\.ps1'
        Test-Path -LiteralPath (Join-Path $script:repoRoot '.github/workflows/standard-v1-protected.yml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:repoRoot 'tests/validate-windows-powershell.ps1') | Should -BeFalse
    }

    # Scenario: A normal pull request or main push needs one Windows validator running the resolved stable PowerShell release.
    # Purpose: Reject the current PATH-selected major-only candidate job and prevent the retired protected publisher from staying live.
    It 'UnitT60_UsesOneWindowsLatestStablePowerShellWorkflow' {
        $workflowPath = Join-Path $script:repoRoot '.github/workflows/standard-v1-candidate-windows.yml'
        $workflow = Get-Content -LiteralPath $workflowPath -Raw
        $workflow | Should -Match '(?m)^  pull_request:\s*$'
        $workflow | Should -Match '(?ms)^  push:\r?\n    branches:\r?\n      - main(?:\r?\n|$)'
        $workflow | Should -Match '(?m)^\s+timeout-minutes:\s*[1-9][0-9]*\s*$'
        $workflow | Should -Match 'runs-on: windows-latest'
        $workflow | Should -Match 'contents: read'
        $workflow | Should -Match 'persist-credentials: false'
        $workflow | Should -Match 'Install-LatestPowerShell\.ps1'
        $workflow | Should -Match 'PowerShellRelease\.psm1'
        $installer = Get-Content -LiteralPath (Join-Path $script:repoRoot 'scripts/Install-LatestPowerShell.ps1') -Raw
        $installer | Should -Match 'https://aka\.ms/powershell-release\?tag=stable'
        $installer | Should -Match 'BaseResponse\.RequestMessage\.RequestUri'
        $installer | Should -Match 'Get-VerifiedPowerShellStableTagFromUri'
        $installer | Should -Match 'Assert-PowerShellReleaseTagMatchesStableChannel'
        $installer | Should -Match 'releases/tags/\$stableTag'
        $workflow | Should -Match 'sha256:'
        $workflow | Should -Match '\$powerShellReceipt\.executablePath'
        $workflow | Should -Match '\$powerShellReceipt\.version'
        $workflow | Should -Not -Match 'actions/upload-artifact|GITHUB_STEP_SUMMARY'
        $workflow | Should -Match 'if:\s*always\(\)'
        $workflow | Should -Match 'TrustedTestCommit \$checkoutHead'
        $workflow | Should -Match 'report\.candidate\.commit -cne \$checkoutHead'
        $workflow | Should -Not -Match 'PSVersionTable\.PSVersion\.Major -lt 7|& pwsh\s'
        $workflow | Should -Not -Match 'pull_request_target|checks: write|ubuntu-latest|CODEX_PESTER_CGROUP_ROOT|CANONICAL_RESULT|repository-contract \(Windows PowerShell 5\.1\)'
        Test-Path -LiteralPath (Join-Path $script:repoRoot '.github/workflows/standard-v1-protected.yml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:repoRoot 'tests/validate-windows-powershell.ps1') | Should -BeFalse

        $workflowFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:repoRoot '.github/workflows') -File |
            Where-Object { $_.Extension -in @('.yml', '.yaml') })
        @($workflowFiles | Where-Object Name -eq 'standard-v1-candidate-windows.yml').Count | Should -Be 1
        @($workflowFiles | Where-Object Name -eq 'standard-v1-protected.yml').Count | Should -Be 0
    }
}

Describe 'Latest stable PowerShell release evidence' {
    BeforeAll {
        $script:releaseModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/PowerShellRelease.psm1'
        if (Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf) {
            Import-Module $script:releaseModulePath -Force
        }

        function New-LatestPowerShellReleaseFixture {
            param(
                [string] $Digest = ('sha256:' + ('a' * 64)),
                [long] $Size = 9
            )
            [pscustomobject]@{
                tag_name = 'v7.6.6'
                draft = $false
                prerelease = $false
                assets = @(
                    [pscustomobject]@{
                        id = 766
                        name = 'PowerShell-7.6.6-win-x64.zip'
                        state = 'uploaded'
                        size = $Size
                        digest = $Digest
                        browser_download_url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
                    }
                )
            }
        }
    }

    # Scenario: The Microsoft stable channel resolves to one stable Windows x64 release archive.
    # Purpose: Bind the selected runtime to the official redirect tag, exact asset identity, and published SHA-256 digest.
    It 'UnitT70_AcceptsOneStableDigestBoundX64Archive' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $asset = Get-VerifiedPowerShellReleaseAsset -Release (New-LatestPowerShellReleaseFixture)

        $asset.version | Should -BeExactly '7.6.6'
        $asset.tag | Should -BeExactly 'v7.6.6'
        $asset.name | Should -BeExactly 'PowerShell-7.6.6-win-x64.zip'
        $asset.digest | Should -BeExactly ('sha256:' + ('a' * 64))
        $asset.browserDownloadUrl | Should -BeExactly 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
    }

    # Scenario: Microsoft’s stable alias resolves to the canonical GitHub tag whose metadata is fetched.
    # Purpose: Prevent a moving latest-release endpoint from selecting a channel that differs from Microsoft stable.
    It 'UnitT65_BindsReleaseMetadataToTheExactStableChannelRedirect' {
        $stableUri = [uri]'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6'
        $tag = Get-VerifiedPowerShellStableTagFromUri -ResolvedReleaseUri $stableUri
        $tag | Should -BeExactly 'v7.6.6'

        $release = New-LatestPowerShellReleaseFixture
        (Assert-PowerShellReleaseTagMatchesStableChannel -ExpectedTag $tag -Release $release) | Should -BeExactly $tag

        $mismatchedRelease = New-LatestPowerShellReleaseFixture
        $mismatchedRelease.tag_name = 'v7.6.5'
        { Assert-PowerShellReleaseTagMatchesStableChannel -ExpectedTag $tag -Release $mismatchedRelease } | Should -Throw

        foreach ($invalidUri in @(
            [uri]'https://aka.ms/powershell-release?tag=stable',
            [uri]'https://github.com.evil.example/PowerShell/PowerShell/releases/tag/v7.6.6',
            [uri]'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6?channel=stable',
            [uri]'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6-rc.1'
        )) {
            { Get-VerifiedPowerShellStableTagFromUri -ResolvedReleaseUri $invalidUri } | Should -Throw
        }
    }

    # Scenario: Release metadata is draft, prerelease, or uses a malformed/non-stable tag.
    # Purpose: Fail closed instead of resolving a preview or ambiguous PowerShell version.
    It 'UnitT80_RejectsDraftPrereleaseAndMalformedReleaseTags' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $draft = New-LatestPowerShellReleaseFixture
        $draft.draft = $true
        { Get-VerifiedPowerShellReleaseAsset -Release $draft } | Should -Throw

        $preview = New-LatestPowerShellReleaseFixture
        $preview.prerelease = $true
        { Get-VerifiedPowerShellReleaseAsset -Release $preview } | Should -Throw

        $malformed = New-LatestPowerShellReleaseFixture
        $malformed.tag_name = 'v7.6.6-rc.1'
        { Get-VerifiedPowerShellReleaseAsset -Release $malformed } | Should -Throw
    }

    # Scenario: The endpoint omits required archive evidence or contains duplicate candidates.
    # Purpose: Reject missing digests, zero-length assets, and ambiguous archive selection.
    It 'UnitT90_RejectsMissingDuplicateAndMalformedArchiveMetadata' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $missingDigest = New-LatestPowerShellReleaseFixture
        $missingDigest.assets[0].digest = $null
        { Get-VerifiedPowerShellReleaseAsset -Release $missingDigest } | Should -Throw

        $emptyAsset = New-LatestPowerShellReleaseFixture -Size 0
        { Get-VerifiedPowerShellReleaseAsset -Release $emptyAsset } | Should -Throw

        $duplicate = New-LatestPowerShellReleaseFixture
        $duplicate.assets = @($duplicate.assets[0], $duplicate.assets[0])
        { Get-VerifiedPowerShellReleaseAsset -Release $duplicate } | Should -Throw
    }

    # Scenario: Downloaded archive bytes or the executable's reported version disagree with release metadata.
    # Purpose: Reject tampering and ensure the validator starts only the release selected by Microsoft's stable alias.
    It 'UnitT100_RejectsMismatchedArchiveBytesAndRuntimeVersion' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $archivePath = Join-Path $TestDrive 'PowerShell-7.6.6-win-x64.zip'
        $archiveBytes = [Text.UTF8Encoding]::new($false).GetBytes('archive fixture')
        [IO.File]::WriteAllBytes($archivePath, $archiveBytes)
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
        $release = New-LatestPowerShellReleaseFixture -Digest "sha256:$hash" -Size $archiveBytes.Length
        $asset = Get-VerifiedPowerShellReleaseAsset -Release $release

        (Assert-VerifiedPowerShellArchive -Asset $asset -Path $archivePath) | Should -BeExactly $hash
        { Assert-PowerShellRuntimeVersion -Tag $asset.tag -ActualVersion '7.6.5' } | Should -Throw

        [IO.File]::WriteAllText($archivePath, 'tampered archive', [Text.UTF8Encoding]::new($false))
        { Assert-VerifiedPowerShellArchive -Asset $asset -Path $archivePath } | Should -Throw
    }
}
