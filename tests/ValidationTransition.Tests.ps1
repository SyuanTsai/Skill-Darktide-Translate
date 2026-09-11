# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Validation rebuild transition contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:TransitionValidator = Join-Path $script:RepositoryRoot 'scripts/Test-ValidationTransition.ps1'
        $script:FormalValidator = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'

        function Invoke-TestGit {
            param(
                [Parameter(Mandatory)][string] $RepositoryRoot,
                [Parameter(Mandatory)][string[]] $Arguments
            )

            $output = @(& git -C $RepositoryRoot @Arguments 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
            }
            return @($output | ForEach-Object { [string]$_ })
        }

        function Set-TestUtf8File {
            param(
                [Parameter(Mandatory)][string] $Path,
                [Parameter(Mandatory)][AllowEmptyString()][string] $Content
            )

            $parent = Split-Path -Parent $Path
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
        }

        function New-ValidationTransitionFixture {
            param([Parameter(Mandatory)][string] $Path)

            [void](New-Item -ItemType Directory -Path $Path -Force)
            [void](Invoke-TestGit -RepositoryRoot $Path -Arguments @('init', '--quiet', '--initial-branch=main'))
            [void](Invoke-TestGit -RepositoryRoot $Path -Arguments @('config', 'user.name', 'Validation Transition Test'))
            [void](Invoke-TestGit -RepositoryRoot $Path -Arguments @('config', 'user.email', 'validation-transition@example.invalid'))

            Set-TestUtf8File -Path (Join-Path $Path '.agents/skills/auto-update-darktide-mod/SKILL.md') -Content "---`nname: auto-update-darktide-mod`ndescription: fixture`n---`n"
            Set-TestUtf8File -Path (Join-Path $Path 'catalog/skills-catalog.json') -Content "{`"schemaVersion`":1,`"catalogId`":`"darktide-translate`"}`n"
            Set-TestUtf8File -Path (Join-Path $Path 'VERSION') -Content "0.3.13`n"
            Set-TestUtf8File -Path (Join-Path $Path 'scripts/Validate.ps1') -Content "throw 'legacy formal validator fixture'`n"
            Set-TestUtf8File -Path (Join-Path $Path 'scripts/Invoke-PrePushValidation.ps1') -Content "'legacy pre-push fixture'`n"
            Set-TestUtf8File -Path (Join-Path $Path 'tests/Invoke-Tests.ps1') -Content "'legacy tests fixture'`n"
            foreach ($relativePath in @(
                    'scripts/Get-SourcePin.ps1',
                    'scripts/Test-CleanRepositoryHead.ps1',
                    'scripts/Test-Repository.ps1',
                    'tests/LocalizationWorkset.Tests.ps1',
                    'tests/ModUpdateAutomation.Tests.ps1',
                    'tests/RepositoryContract.Tests.ps1',
                    'tests/RepositoryValidation.Tests.ps1',
                    'tests/Schema15Coordination.Tests.ps1',
                    'tests/Schema15SourceAcquisition.Tests.ps1',
                    'tests/SkillContract.Tests.ps1',
                    'tests/SourcePin.Tests.ps1',
                    'tests/TestSupport.ps1'
                )) {
                Set-TestUtf8File -Path (Join-Path $Path $relativePath) -Content "'preserved contract fixture'`n"
            }
            Set-TestUtf8File -Path (Join-Path $Path 'tests/BootstrapTransition.Tests.ps1') -Content "'retired fixture'`n"
            Set-TestUtf8File -Path (Join-Path $Path '.github/workflows/validate.yml') -Content "name: legacy`n"
            Set-TestUtf8File -Path (Join-Path $Path '.github/workflows/skill-validator.yml') -Content "name: legacy-quality`n"
            Set-TestUtf8File -Path (Join-Path $Path 'docs/RELEASE.md') -Content "legacy release fixture`n"
            [void](Invoke-TestGit -RepositoryRoot $Path -Arguments @('add', '--all'))
            [void](Invoke-TestGit -RepositoryRoot $Path -Arguments @('commit', '--quiet', '-m', 'baseline'))
            $baseline = @(Invoke-TestGit -RepositoryRoot $Path -Arguments @('rev-parse', 'HEAD'))[0].Trim()

            Remove-Item -LiteralPath (Join-Path $Path 'tests/BootstrapTransition.Tests.ps1') -Force
            Remove-Item -LiteralPath (Join-Path $Path '.github/workflows/validate.yml') -Force
            Remove-Item -LiteralPath (Join-Path $Path '.github/workflows/skill-validator.yml') -Force
            Set-TestUtf8File -Path (Join-Path $Path 'scripts/Test-ValidationTransition.ps1') -Content "'fixture transition entry'`n"
            Set-TestUtf8File -Path (Join-Path $Path 'scripts/Validate.ps1') -Content "& ./scripts/Test-ValidationTransition.ps1 -RequireFormalValidation`n"
            Set-TestUtf8File -Path (Join-Path $Path 'scripts/Invoke-PrePushValidation.ps1') -Content "& ./scripts/Test-ValidationTransition.ps1`n"
            Set-TestUtf8File -Path (Join-Path $Path 'tests/ValidationTransition.Tests.ps1') -Content "'fixture transition tests'`n"
            Set-TestUtf8File -Path (Join-Path $Path '.github/workflows/validation-rebuild.yml') -Content "name: Validation Rebuild`n"
            Set-TestUtf8File -Path (Join-Path $Path '.github/workflows/standard-v1-protected.yml') -Content "name: Protected Transition Policy`n"
            Set-TestUtf8File -Path (Join-Path $Path 'docs/RELEASE.md') -Content "formal release blocked while validation is rebuilt`n"
            [void](Invoke-TestGit -RepositoryRoot $Path -Arguments @('add', '--all'))
            [void](Invoke-TestGit -RepositoryRoot $Path -Arguments @('commit', '--quiet', '-m', 'transition'))
            $candidate = @(Invoke-TestGit -RepositoryRoot $Path -Arguments @('rev-parse', 'HEAD'))[0].Trim()

            return [pscustomobject]@{
                root = $Path
                baseline = $baseline
                candidate = $candidate
            }
        }
    }

    # Scenario: A cleanup candidate changes validation infrastructure while retaining the exact product tree.
    # Purpose: Distinguish a successful rebuild-maintenance check from formal Standard v1 validation.
    It 'UnitT10_ReportsBoundCandidateAndProductIdentityWithoutReleaseEligibility' {
        Test-Path -LiteralPath $script:TransitionValidator -PathType Leaf | Should -BeTrue
        $fixture = New-ValidationTransitionFixture -Path (Join-Path $TestDrive 'successful-transition')

        $result = & $script:TransitionValidator `
            -RepositoryRoot $fixture.root `
            -CandidateCommit $fixture.candidate `
            -ProductBaselineCommit $fixture.baseline `
            -PassThru

        $result.result | Should -Be 'passed'
        $result.validationStatus | Should -Be 'transition-policy-passed'
        $result.formalValidationStatus | Should -Be 'pending-rebuild'
        $result.releaseEligible | Should -BeFalse
        $result.candidateCommit | Should -Be $fixture.candidate
        $result.productBaselineCommit | Should -Be $fixture.baseline
        $result.productInventorySha256 | Should -Match '^[0-9a-f]{64}$'
        @($result.missingFormalCapabilities).Count | Should -BeGreaterThan 0
    }

    # Scenario: A caller asks the transitional formal entry to certify a release candidate.
    # Purpose: Ensure incomplete formal validation exits nonzero after emitting a machine-readable blocked state.
    It 'UnitT20_BlocksFormalValidationWithAnExplicitMachineReadableState' {
        Test-Path -LiteralPath $script:TransitionValidator -PathType Leaf | Should -BeTrue
        $fixture = New-ValidationTransitionFixture -Path (Join-Path $TestDrive 'formal-block')
        $pwshPath = (Get-Process -Id $PID).Path
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
                '-NoProfile', '-File', $script:TransitionValidator,
                '-RepositoryRoot', $fixture.root,
                '-CandidateCommit', $fixture.candidate,
                '-ProductBaselineCommit', $fixture.baseline,
                '-RequireFormalValidation'
            )) {
            $startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            $process.Start() | Should -BeTrue
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()

            $process.ExitCode | Should -Not -Be 0
            $state = $stdout | ConvertFrom-Json
            $state.validationStatus | Should -Be 'transition-policy-passed'
            $state.formalValidationStatus | Should -Be 'pending-rebuild'
            $state.releaseEligible | Should -BeFalse
            $stderr | Should -Match 'Formal Standard v1 validation is pending rebuild'
        }
        finally {
            $process.Dispose()
        }
    }

    # Scenario: The preserved repository contract is evaluated during the rebuild period.
    # Purpose: Keep package integrity coverage while making its limited, release-blocked scope machine-readable.
    It 'UnitT25_ReportsTheRepositoryContractAsRebuildMaintenanceOnly' {
        $repositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $json = & $repositoryValidator -RepositoryRoot $script:RepositoryRoot -ValidationTransition -NoFilters |
            Select-Object -Last 1
        $result = $json | ConvertFrom-Json

        $result.result | Should -Be 'passed'
        $result.validationMode | Should -Be 'validation-rebuild-maintenance'
        $result.formalValidationStatus | Should -Be 'pending-rebuild'
        $result.releaseEligible | Should -BeFalse
        $result.activeSkillCount | Should -Be 1
    }

    # Scenario: A cleanup candidate changes one tracked Skill byte after the preserved baseline.
    # Purpose: Prevent validation cleanup from silently changing product content or package identity.
    It 'InterT10_RejectsAnyProductBlobModeOrPathDriftFromTheBaseline' {
        Test-Path -LiteralPath $script:TransitionValidator -PathType Leaf | Should -BeTrue
        $fixture = New-ValidationTransitionFixture -Path (Join-Path $TestDrive 'product-drift')
        Set-TestUtf8File -Path (Join-Path $fixture.root '.agents/skills/auto-update-darktide-mod/SKILL.md') -Content "changed product`n"
        [void](Invoke-TestGit -RepositoryRoot $fixture.root -Arguments @('add', '--all'))
        [void](Invoke-TestGit -RepositoryRoot $fixture.root -Arguments @('commit', '--quiet', '-m', 'product drift'))
        $driftedCandidate = @(Invoke-TestGit -RepositoryRoot $fixture.root -Arguments @('rev-parse', 'HEAD'))[0].Trim()

        { & $script:TransitionValidator `
                -RepositoryRoot $fixture.root `
                -CandidateCommit $driftedCandidate `
                -ProductBaselineCommit $fixture.baseline `
                -PassThru } |
            Should -Throw '*Product inventory differs*'
    }

    # Scenario: The cleanup replaces the old supervisor with one small formal blocking launcher.
    # Purpose: Ensure proxy, runspace, Pester-supervisor, and bootstrap executor paths are actually retired.
    It 'UnitT30_UsesAThinFormalLauncherWithoutRetiredExecutorSymbols' {
        $formalValidator = Get-Content -LiteralPath $script:FormalValidator -Raw

        $formalValidator | Should -Match 'Test-ValidationTransition\.ps1'
        $formalValidator | Should -Match 'RequireFormalValidation'
        $formalValidator | Should -Not -Match 'Invoke-ProtectedPester(ServerProxy|Runspace|Supervisor)'
        $formalValidator | Should -Not -Match 'BootstrapTransition'
        (Get-Content -LiteralPath $script:FormalValidator).Count | Should -BeLessThan 80
    }

    # Scenario: A maintenance candidate deletes one existing domain regression suite while leaving product blobs unchanged.
    # Purpose: Keep the fixed product and repository test inventory present until an independently trusted controller replaces it.
    It 'UnitT35_RejectsDeletionOfAPreservedDomainRegressionSuite' {
        $fixture = New-ValidationTransitionFixture -Path (Join-Path $TestDrive 'missing-domain-suite')
        Remove-Item -LiteralPath (Join-Path $fixture.root 'tests/SkillContract.Tests.ps1') -Force
        [void](Invoke-TestGit -RepositoryRoot $fixture.root -Arguments @('add', '--all'))
        [void](Invoke-TestGit -RepositoryRoot $fixture.root -Arguments @('commit', '--quiet', '-m', 'delete domain suite'))
        $candidate = @(Invoke-TestGit -RepositoryRoot $fixture.root -Arguments @('rev-parse', 'HEAD'))[0].Trim()

        { & $script:TransitionValidator `
                -RepositoryRoot $fixture.root `
                -CandidateCommit $candidate `
                -ProductBaselineCommit $fixture.baseline `
                -PassThru } |
            Should -Throw "*tests/SkillContract.Tests.ps1*tracked regular blob*"
    }

    # Scenario: Rebuild maintenance runs on pull requests and main without publishing old formal context names.
    # Purpose: Make the temporary governance mapping explicit and avoid dangling or duplicate required checks.
    It 'UnitT40_UsesOnlyExplicitRebuildWorkflowContexts' {
        $workflowRoot = Join-Path $script:RepositoryRoot '.github/workflows'
        Test-Path -LiteralPath (Join-Path $workflowRoot 'validation-rebuild.yml') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $workflowRoot 'validate.yml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $workflowRoot 'skill-validator.yml') | Should -BeFalse
        $workflow = Get-Content -LiteralPath (Join-Path $workflowRoot 'validation-rebuild.yml') -Raw

        $workflow | Should -Match 'rebuild-repository-contract'
        $workflow | Should -Match 'rebuild-skill-validator'
        $workflow | Should -Match 'rebuild-skill-tools'
        $workflow | Should -Match 'scripts/Invoke-PrePushValidation\.ps1'
        $workflow | Should -Not -Match '(?m)^\s{2}(repository-contract|skill-validator|skill-tools):\s*$'
    }

    # Scenario: Old tests assert internal functions and layouts that no longer exist after cleanup.
    # Purpose: Retire source-shape assertions while keeping their security requirements in the rebuild checklist.
    It 'UnitT50_RemovesTheBootstrapSupervisorSourceShapeSuite' {
        Test-Path -LiteralPath (Join-Path $PSScriptRoot 'BootstrapTransition.Tests.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $PSScriptRoot 'validate-windows-powershell.ps1') | Should -BeFalse
    }
}
