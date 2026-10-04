# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide bootstrap transition' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:Supervisor = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:ValidationWorkflow = Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-candidate-windows.yml'
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
            # The protected runner's run-owned TEMP can put fixture Git objects beyond MAX_PATH.
            & git -C $Destination config core.longpaths true
            if ($LASTEXITCODE -ne 0) { throw 'Failed to enable long paths for the validator Git snapshot.' }
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

    It 'UnitT30_KeepsBootstrapModeOutOfTheNormalWindowsWorkflow' {
        # Scenario: The repository retains a local bootstrap validator while normal CI uses the Standard v1 route.
        # Purpose: Prevent CI from re-entering the retired protected workflow or legacy validation mode.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ValidationWorkflow -Raw

        $supervisor | Should -Match '\[switch\] \$BootstrapTransition'
        $workflow | Should -Match 'scripts/Validate\.ps1'
        $workflow | Should -Not -Match 'BootstrapTransition|pull_request_target|ubuntu-latest|checks: write'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1') | Should -BeFalse
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

    It 'InterT45_BoundsRealTrustedPesterChildOutputAndPreservesExitStatus' {
        # Scenario: The trusted Pester transport receives a verbose or failing real child.
        # Purpose: Keep each captured stream bounded while preserving the child's exit.
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $definitions = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Get-WindowsSuspendedProcessBoundaryType', 'Invoke-TrustedPowerShellProcess')
        }, $false))
        $definitions.Count | Should -Be 2
        $transport = @($definitions | Where-Object Name -eq 'Invoke-TrustedPowerShellProcess')[0]
        $transport.Extent.Text | Should -Match 'ReadBoundedAsync'
        $transport.Extent.Text | Should -Not -Match 'ReadToEndAsync'
        foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

        $powerShellPath = [string](Join-Path $PSHOME 'pwsh.exe')
        $normal = Invoke-TrustedPowerShellProcess -Command $powerShellPath `
            -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("normal")') `
            -WorkingDirectory $TestDrive -Context 'bounded child'
        $normal | Should -Be 'normal'
        { Invoke-TrustedPowerShellProcess -Command $powerShellPath `
            -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write(''x'' * 4194305)') `
            -WorkingDirectory $TestDrive -Context 'oversized child' } |
            Should -Throw '*bounded trusted-process output limit*'
        { Invoke-TrustedPowerShellProcess -Command $powerShellPath `
            -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 7') `
            -WorkingDirectory $TestDrive -Context 'failed child' } |
            Should -Throw '*exited with code 7*'
    }

    It 'UnitT50_BindsBootstrapToTheExpectedChangedPathSetAndBaseCommit' {
        # Scenario: A bootstrap candidate could otherwise select the legacy path while changing arbitrary repository content.
        # Purpose: Require an immutable base comparison and a narrow transition-only changed-path contract.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'Bootstrap transition requires a distinct base commit'
        $supervisor | Should -Match 'Bootstrap transition changed-path allowlist'
        $supervisor | Should -Match '\.github/workflows/standard-v1-candidate-windows\.yml'
        $supervisor | Should -Match 'scripts/Install-LatestPowerShell\.ps1'
        $supervisor | Should -Match 'scripts/PowerShellRelease\.psm1'
        $supervisor | Should -Match 'scripts/Test-Repository\.ps1'
        $supervisor | Should -Match 'scripts/Validate\.ps1'
        $supervisor | Should -Match '\$retiredPathList'
        $supervisor | Should -Match 'if \(\$status -ceq ''D''\)'
        $supervisor | Should -Match 'Bootstrap retirement requires'
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
        $supervisor | Should -Match '\$pesterConfiguration = New-PesterConfiguration'
        $supervisor | Should -Match '\$pesterConfiguration\.Run\.Path = \$requiredPesterPaths'
        $supervisor | Should -Match 'Invoke-Pester -Configuration \$pesterConfiguration'
        $supervisor | Should -Match 'FailedTests='
        $supervisor | Should -Not -Match '\$requiredPesterTests = @\(\)'
        $supervisor | Should -Match '(?s)Trusted base Pester tests.*?\$requiredPesterTests = @\(\$requiredPesterTests \| Where-Object'
        $supervisor | Should -Match 'Join-Path \$trustedPesterTestsRoot \$_'
        $supervisor | Should -Match 'Join-Path \$TestsRoot \$_'
        $supervisor | Should -Match 'Join-Path \$testsRoot \$_'
    }

    It 'UnitT90SeparatesChildOutputAndTrustedPesterContent' {
        # Scenario: Low-integrity children must write only to a labeled output root, while tests come from trusted Git bytes.
        # Purpose: Keep scanner receipts and Pester content outside candidate-writable paths and out of the worker's authority.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $supervisor | Should -Match "'low-integrity-output'"
        $supervisor | Should -Match '''-PesterChildWritableRoot'', \$childOutputRoot'
        $supervisor | Should -Match '-ChildWritableRoot \$ChildWritableRoot'
        $supervisor | Should -Match 'Expand-TrustedGitArchive'
        $supervisor | Should -Match 'Assert-TrustedGitTreeFile'
        $supervisor | Should -Match '\$trustedPesterCommit'
        $supervisor | Should -Match '(?s)Expand-TrustedGitArchive.*?-Revision \$trustedPesterCommit.*?-PathSpec @\(''tests''\).*?-Context ''Trusted base Pester tests'''
        $supervisor | Should -Match '(?s)\$candidateMirrorTestsRoot.*?Remove-Item'
        $supervisor | Should -Match 'function Invoke-ProtectedPesterServerProxy'
        $supervisor | Should -Match 'New-ContainedProcessEnvironment -DiagnosticRoot \$childWritableRootPath'
        $supervisor | Should -Match 'New-WindowsKillOnCloseJob -Context ''Protected Pester server proxy'''
        $supervisor | Should -Match 'Assign-WindowsProcessToJob -JobHandle \$jobHandle -Process \$child'
        $supervisor | Should -Match '-UseRestrictedToken \$true'
        $supervisor | Should -Match '''-ProtectedPesterServerProxy'''
        $supervisor | Should -Match 'Invoke-ProtectedPesterRunspace'
        $supervisor | Should -Match '\[string\[\]\] \$TestNames'
        $supervisor | Should -Match "AddParameter\('TestNames'"
        $supervisor | Should -Match '\[string\] \$PesterTrustedTestCommit'
        $supervisor | Should -Match "AddParameter\('TrustedTestCommit'"
        $supervisor | Should -Match "BootstrapTransition\.Tests\.ps1"
        $supervisor | Should -Match 'foreach \(\$requiredPesterTest in \$requiredPesterTests\)'
        $supervisor | Should -Match '\$requiredPesterTestsFunction = \(Get-Command Get-RequiredPesterTests'
        $supervisor | Should -Match '__REQUIRED_PESTER_TESTS_FUNCTION__'
        $supervisor | Should -Match '\.Replace\(''__REQUIRED_PESTER_TESTS_FUNCTION__'', \$requiredPesterTestsFunctionDefinition\)'
        $supervisor | Should -Match '\$aggregateTotalCount'
        $supervisor | Should -Match 'per-candidate 300-second CPU'
        $supervisor | Should -Match 'TimeoutMilliseconds 1800000'
        $supervisor | Should -Match 'CreateOutOfProcessRunspace'
        $supervisor | Should -Match 'AddScript\(\$workerScriptText\)'
        $supervisor | Should -Match 'InvocationStateInfo\.State'
        $supervisor | Should -Match '\$powerShell\.Stop\(\)'
        $supervisor | Should -Match '\$runspace\.Close\(\)'
        $supervisor | Should -Match 'serverProcessInstance\.Process\.WaitForExit\(5000\)'
        $supervisor | Should -Match 'Start-WindowsSuspendedProcess'
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

    It 'UnitT92_BoundsOnlyTheMeasuredSlowPesterShardWithExtraWallTime' {
        # Scenario: ModUpdateAutomation and Schema15SourceAcquisition are measured 300-second-plus wall-clock shards; all other immutable files retain the default.
        # Purpose: Give only those two explicit trusted files enough wall time without widening the 300-second CPU or default shard boundary.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $tokens = $null
        $errors = $null
        $supervisorAst = [Management.Automation.Language.Parser]::ParseInput($supervisor, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $timeoutFunction = @($supervisorAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-ProtectedPesterShardTimeoutMilliseconds'
        }, $true))
        $requiredTestsFunction = @($supervisorAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-RequiredPesterTests'
        }, $true))

        $timeoutFunction.Count | Should -Be 1
        $requiredTestsFunction.Count | Should -Be 1
        if ($timeoutFunction.Count -ne 1 -or $requiredTestsFunction.Count -ne 1) { return }

        $moduleSource = $requiredTestsFunction[0].Extent.Text + [Environment]::NewLine + $timeoutFunction[0].Extent.Text
        $timeoutModule = New-Module -ScriptBlock ([scriptblock]::Create($moduleSource))
        $requiredTests = @(& $timeoutModule { Get-RequiredPesterTests })
        $postPromotionTests = @(& $timeoutModule { Get-RequiredPesterTests -IncludeTrustedPostPromotionTests })
        $expectedRequiredTests = @(
            'BootstrapTransition.Tests.ps1'
            'LocalizationWorkset.Tests.ps1'
            'ModUpdateAutomation.Tests.ps1'
            'RepositoryContract.Tests.ps1'
            'RepositoryValidation.Tests.ps1'
            'Schema15Coordination.Tests.ps1'
            'Schema15SourceAcquisition.Tests.ps1'
            'SkillContract.Tests.ps1'
            'SourcePin.Tests.ps1'
        )
        $requiredTests.Count | Should -Be 9
        ($requiredTests -join "`n") | Should -BeExactly ($expectedRequiredTests -join "`n")
        $postPromotionTests.Count | Should -Be 10
        ($postPromotionTests[0..8] -join "`n") | Should -BeExactly ($expectedRequiredTests -join "`n")
        $postPromotionTests[9] | Should -BeExactly 'InstalledClosureOrdering.Tests.ps1'
        $supervisor | Should -Not -Match '(?s)\$requiredPesterTests\s*=\s*@\(\s*''BootstrapTransition\.Tests\.ps1'''
        foreach ($testName in $requiredTests) {
            $actualTimeout = & $timeoutModule {
                param($name)
                Get-ProtectedPesterShardTimeoutMilliseconds -TestName $name
            } $testName
            $expectedTimeout = if ($testName -ceq 'ModUpdateAutomation.Tests.ps1' -or
                $testName -ceq 'Schema15SourceAcquisition.Tests.ps1') { 600000 } else { 300000 }
            $actualTimeout | Should -Be $expectedTimeout
        }
        (& $timeoutModule { Get-ProtectedPesterShardTimeoutMilliseconds -TestName 'InstalledClosureOrdering.Tests.ps1' }) |
            Should -Be 300000
        { & $timeoutModule { Get-ProtectedPesterShardTimeoutMilliseconds -TestName 'CandidateControlled.Tests.ps1' } } |
            Should -Throw '*outside the immutable required inventory*'
        $supervisor | Should -Match '\$shardTimeoutMilliseconds\s*=\s*Get-ProtectedPesterShardTimeoutMilliseconds'
        $supervisor | Should -Match '-TimeoutMilliseconds\s+\$shardTimeoutMilliseconds'
        $supervisor | Should -Match 'per-candidate 300-second CPU'
    }

    It 'UnitT100_BindsReplacementObjectDiscoveryToTheCandidateWorktree' {
        # Scenario: Git does not trust the runner checkout through ambient global configuration.
        # Purpose: Make the replacement-object preflight use the same explicit repository trust boundary as every later Git read.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ValidationWorkflow -Raw

        $supervisor | Should -Match '(?s)function Assert-NoGitReplacementObjects.*?safe\.directory=\$RepositoryRoot.*?core\.worktree=\$RepositoryRoot.*?rev-parse --git-path refs/replace'
        $workflow | Should -Match '(?s)\$gitArguments\s*=\s*@\(.*?safe\.directory=\$repositoryRoot.*?rev-parse HEAD.*?checkoutHead -cne \$env:EXPECTED_HEAD_SHA.*?merge-base \$env:BASE_SHA \$checkoutHead'

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:Supervisor,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Assert-NoGitReplacementObjects'
            }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))

        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
        $emptyGitConfig = Join-Path $TestDrive 'empty-git-config'
        New-Item -ItemType File -Path $emptyGitConfig -Force | Out-Null
        $savedAssumeDifferentOwner = $env:GIT_TEST_ASSUME_DIFFERENT_OWNER
        $savedGlobalConfig = $env:GIT_CONFIG_GLOBAL
        $savedSystemConfig = $env:GIT_CONFIG_SYSTEM
        $savedNoSystemConfig = $env:GIT_CONFIG_NOSYSTEM
        try {
            $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = '1'
            $env:GIT_CONFIG_GLOBAL = $emptyGitConfig
            $env:GIT_CONFIG_SYSTEM = $emptyGitConfig
            $env:GIT_CONFIG_NOSYSTEM = '1'

            & $gitPath -C $script:ValidatorRepositoryRoot rev-parse --git-path refs/replace 2>$null | Out-Null
            $LASTEXITCODE | Should -Not -Be 0

            {
                & $guardModule {
                    param($ResolvedGitPath, $RepositoryRoot)
                    Assert-NoGitReplacementObjects `
                        -GitPath $ResolvedGitPath `
                        -RepositoryRoot $RepositoryRoot `
                        -Context 'Unit test candidate'
                } $gitPath $script:ValidatorRepositoryRoot
            } | Should -Not -Throw
        }
        finally {
            $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = $savedAssumeDifferentOwner
            $env:GIT_CONFIG_GLOBAL = $savedGlobalConfig
            $env:GIT_CONFIG_SYSTEM = $savedSystemConfig
            $env:GIT_CONFIG_NOSYSTEM = $savedNoSystemConfig
            Remove-Module $guardModule -Force
        }
    }



}
