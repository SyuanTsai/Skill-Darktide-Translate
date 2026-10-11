# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force
}

Describe 'Core Pester progress' {
    # Scenario: Pester displays a parameterized template at case start and its expanded name at completion.
    # Purpose: Keep the live completed count aligned with the authoritative final case count without a fake module.
    It 'UnitT10_counts_parameterized_case_completion_with_the_shared_progress_gate' {
        $start = ConvertFrom-CorePesterProgressLine -Line '  [|] Case <Value>...' -ActiveCaseStarts 0
        $start.IsRecognized | Should -BeTrue
        $start.Phase | Should -Be 'case-start'
        $start.ActiveCaseStarts | Should -Be 1
        $start.CompletedDelta | Should -Be 0

        $completion = ConvertFrom-CorePesterProgressLine -Line '  [+] Case alpha' -ActiveCaseStarts $start.ActiveCaseStarts
        $completion.IsRecognized | Should -BeTrue
        $completion.Phase | Should -Be 'case-end'
        $completion.ActiveCaseStarts | Should -Be 0
        $completion.CompletedDelta | Should -Be 1

        $longExpandedName = 'Long case ' + ('x' * 260)
        $longStart = ConvertFrom-CorePesterProgressLine -Line "  [|] $longExpandedName..." -ActiveCaseStarts 0
        $longEnd = ConvertFrom-CorePesterProgressLine -Line "  [+] $longExpandedName" -ActiveCaseStarts $longStart.ActiveCaseStarts
        $longEnd.CompletedDelta | Should -Be 1
        $longEnd.Line | Should -Be "  [+] $longExpandedName"

        $unpairedCompletion = ConvertFrom-CorePesterProgressLine -Line '  [+] no matching start' -ActiveCaseStarts 0
        $unpairedCompletion.CompletedDelta | Should -Be 0
        $unrelated = ConvertFrom-CorePesterProgressLine -Line 'diagnostic detail' -ActiveCaseStarts 0
        $unrelated.IsRecognized | Should -BeFalse
    }
    # Scenario: an actual isolated Pester 6.2.0 child discovers one data-driven case and one skipped case.
    # Purpose: Verify real source extents, the full unfiltered tests root, retained long names, and the run-owned ledger binding.
    It 'InterT11_writes_complete_actual_Pester_case_inventory_before_six_field_success' {
        $driveCapturePath = [Environment]::GetEnvironmentVariable('SYP_CORE_PESTER_TESTDRIVE_CAPTURE', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($driveCapturePath)) {
            [IO.File]::WriteAllText($driveCapturePath, $TestDrive, [Text.UTF8Encoding]::new($false))
        }
        $fixtureRoot = Join-Path $TestDrive 'actual-case-inventory'
        $driverRunId = [guid]::NewGuid().ToString('N')
        $coreRunId = [guid]::NewGuid().ToString('N')
        $runOwnedRoot = Join-Path $fixtureRoot 'run-owned'
        $coreArtifactsRoot = Join-Path $runOwnedRoot 'artifacts'
        $runRoot = Join-Path $coreArtifactsRoot "runs/$coreRunId"
        $candidateRoot = Join-Path $runRoot 'candidate'
        $testRoot = Join-Path $candidateRoot 'tests'
        $authorityRoot = Join-Path $runOwnedRoot ".core-v2-adapter-$driverRunId/authority"
        [void](New-Item -ItemType Directory -Path $testRoot, $authorityRoot -Force)
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $authorityRoot) 'standard-core-adapter-v2.json'), '{}', [Text.UTF8Encoding]::new($false))
        $longCaseName = 'Skipped long case ' + ('y' * 260)
        $fixtureSource = @"
Describe 'actual inventory' {
    It 'Dynamic <Name>' -ForEach @(@{ Name = 'alpha' }) { 1 | Should -Be 1 }
    It '$longCaseName' -Skip { }
}
"@
        [IO.File]::WriteAllText((Join-Path $testRoot 'fixture.Tests.ps1'), $fixtureSource, [Text.UTF8Encoding]::new($false))

        $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $runtimeRoot = Split-Path -Parent $pwsh
        $moduleRoot = Join-Path $runtimeRoot 'Modules'
        $pesterModuleRoot = Join-Path $moduleRoot 'Pester/6.2.0'
        Test-Path -LiteralPath (Join-Path $pesterModuleRoot 'Pester.psd1') -PathType Leaf | Should -BeTrue
        $runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-CorePester.ps1'
        $bootstrap = Join-Path $fixtureRoot 'Invoke-ActualCorePesterFixture.ps1'
        [IO.File]::WriteAllText($bootstrap, @'
param(
    [Parameter(Mandatory = $true)][string] $Runner,
    [Parameter(Mandatory = $true)][string] $OuterRunId,
    [Parameter(Mandatory = $true)][string] $ModuleSearchPath
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = $ModuleSearchPath
& $Runner -CandidateAuthorityAdapterRunId $OuterRunId
$wrapperExitCode = [int]$LASTEXITCODE
[Console]::Error.WriteLine("actual wrapper exit propagation: $wrapperExitCode")
exit $wrapperExitCode
'@, [Text.UTF8Encoding]::new($false))

        $startInfo = [Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $bootstrap,
            '-Runner', $runner, '-OuterRunId', $driverRunId, '-ModuleSearchPath', $moduleRoot)) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        $startInfo.WorkingDirectory = $candidateRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['PSModulePath'] = $moduleRoot
        $startInfo.Environment['STANDARD_VALIDATION_CORE_RUN_ID'] = $coreRunId
        $startInfo.Environment['STANDARD_VALIDATION_CORE_CHECK_ID'] = 'repository-pester'
        $releasePath = Join-Path $candidateRoot ("b-{0}.sig" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($releasePath, ('release' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $startInfo.Environment['STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH'] = $releasePath
        $startInfo.Environment['STANDARD_VALIDATION_BOOTSTRAP_COMMAND'] = $pwsh
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
                throw "Actual Core Pester fixture exceeded its 30-second bound (child pid $($process.Id))."
            }
            $childPid = $process.Id
            $exitCode = $process.ExitCode
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
        }
        finally { $process.Dispose() }

        $exitCode | Should -Be 0 -Because ("child pid {0}`nstderr: {1}`nstdout: {2}" -f $childPid, $stderr, $stdout)
        $reportLines = @(($stdout.Trim()) -split '\r?\n')
        $reportLines.Count | Should -Be 1
        $summary = $reportLines[0] | ConvertFrom-Json
        @($summary.PSObject.Properties.Name).Count | Should -Be 6
        $summary.report | Should -Be 'standard-core-pester-result-v1'
        $summary.total | Should -Be 2
        $summary.passed | Should -Be 1
        $summary.skipped | Should -Be 1
        $summary.failed | Should -Be 0

        $ledgerMatch = [regex]::Match($stderr, 'Pester case inventory ledger: path="([^"]+)" sha256=([0-9a-f]{64}) discovered=2 executed=2 complete=True')
        $ledgerMatch.Success | Should -BeTrue -Because ("child pid {0}`nstderr: {1}" -f $childPid, $stderr)
        $ledgerPath = $ledgerMatch.Groups[1].Value
        $ledgerPath | Should -Be (Join-Path $runRoot 'repository-pester-case-inventory-v1.json')
        (Split-Path -Parent $ledgerPath) | Should -Be $runRoot
        $ledgerPath.StartsWith(($candidateRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
        (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $ledgerMatch.Groups[2].Value
        $ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
        $ledger.runPath | Should -Be $testRoot
        $ledger.runScope | Should -Be 'complete-unfiltered-tests-tree'
        $ledger.complete | Should -BeTrue
        $ledger.caseDiscoveryCount | Should -Be 2
        $ledger.caseExecutionCount | Should -Be 2
        @($ledger.errors).Count | Should -Be 0
        @($ledger.discoveryCases | Where-Object { $_.expandedPath -like '*Dynamic alpha*' -and $_.result -eq 'Passed' }).Count | Should -Be 1
        @($ledger.executionCases | Where-Object { $_.result -eq 'Skipped' -and $_.expandedPath.EndsWith($longCaseName, [StringComparison]::Ordinal) }).Count | Should -Be 1
        @($ledger.discoveryCases | Where-Object { $_.expandedPath.Length -gt 200 }).Count | Should -Be 1
        @($ledger.discoveryCases | Select-Object -ExpandProperty identity -Unique).Count | Should -Be 2
        @($ledger.discoveryCases | Where-Object { $_.sourceFile -cne 'fixture.Tests.ps1' -or $_.sourceStartOffset -lt 0 -or $_.sourceStartLine -le 0 }).Count | Should -Be 0
        @($ledger.testFileInventory).Count | Should -Be 1
        @($ledger.containerFileInventory).Count | Should -Be 1
        @($ledger.discoveredCaseFileInventory).Count | Should -Be 1

        $failedDriverRunId = [guid]::NewGuid().ToString('N')
        $failedCoreRunId = [guid]::NewGuid().ToString('N')
        $failedRunRoot = Join-Path $coreArtifactsRoot "runs/$failedCoreRunId"
        $failedCandidateRoot = Join-Path $failedRunRoot 'candidate'
        $failedTestRoot = Join-Path $failedCandidateRoot 'tests'
        $failedAuthorityRoot = Join-Path $runOwnedRoot ".core-v2-adapter-$failedDriverRunId/authority"
        [void](New-Item -ItemType Directory -Path $failedTestRoot, $failedAuthorityRoot -Force)
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $failedAuthorityRoot) 'standard-core-adapter-v2.json'), '{}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $failedTestRoot 'Broken.Tests.ps1'), "Describe 'broken syntax' { It 'cannot discover' {`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $failedTestRoot 'BlockFailure.Tests.ps1'), "Describe 'failed block' { BeforeAll { throw 'intentional test block failure' }; It 'does not pass' { 1 | Should -Be 1 } }`n", [Text.UTF8Encoding]::new($false))
        $failedStartInfo = [Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $bootstrap,
            '-Runner', $runner, '-OuterRunId', $failedDriverRunId, '-ModuleSearchPath', $moduleRoot)) {
            [void]$failedStartInfo.ArgumentList.Add($argument)
        }
        $failedStartInfo.WorkingDirectory = $failedCandidateRoot
        $failedStartInfo.UseShellExecute = $false
        $failedStartInfo.CreateNoWindow = $true
        $failedStartInfo.RedirectStandardOutput = $true
        $failedStartInfo.RedirectStandardError = $true
        $failedStartInfo.Environment['PSModulePath'] = $moduleRoot
        $failedStartInfo.Environment['STANDARD_VALIDATION_CORE_RUN_ID'] = $failedCoreRunId
        $failedStartInfo.Environment['STANDARD_VALIDATION_CORE_CHECK_ID'] = 'repository-pester'
        $failedReleasePath = Join-Path $failedCandidateRoot ("b-{0}.sig" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($failedReleasePath, ('release' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $failedStartInfo.Environment['STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH'] = $failedReleasePath
        $failedStartInfo.Environment['STANDARD_VALIDATION_BOOTSTRAP_COMMAND'] = $pwsh
        $failedProcess = [Diagnostics.Process]::new()
        $failedProcess.StartInfo = $failedStartInfo
        try {
            [void]$failedProcess.Start()
            $failedStdoutTask = $failedProcess.StandardOutput.ReadToEndAsync()
            $failedStderrTask = $failedProcess.StandardError.ReadToEndAsync()
            if (-not $failedProcess.WaitForExit(30000)) {
                $failedProcess.Kill($true)
                [void]$failedProcess.WaitForExit(5000)
                throw "Actual failing Pester fixture exceeded its 30-second bound (child pid $($failedProcess.Id))."
            }
            $failedChildPid = $failedProcess.Id
            $failedExitCode = $failedProcess.ExitCode
            $failedStdout = $failedStdoutTask.GetAwaiter().GetResult()
            $failedStderr = $failedStderrTask.GetAwaiter().GetResult()
        }
        finally { $failedProcess.Dispose() }
        $failedExitCode | Should -Be 1 -Because ("child pid {0}`nstderr: {1}`nstdout: {2}" -f $failedChildPid, $failedStderr, $failedStdout)
        $failedStderr | Should -Match 'actual wrapper exit propagation: 1'
        $failedStdout | Should -BeNullOrEmpty -Because 'the wrapper must not emit a success-shaped machine report when case inventory gates fail'
        $failedStderr | Should -Match 'Core Pester acceptance failed; no success report was emitted\.'
        $failedLedgerMatch = [regex]::Match($failedStderr, 'Pester case inventory ledger: path="([^"]+)" sha256=([0-9a-f]{64}) discovered=\d+ executed=\d+ complete=False')
        $failedLedgerMatch.Success | Should -BeTrue -Because ("child pid {0}`nstderr: {1}" -f $failedChildPid, $failedStderr)
        $failedLedgerPath = $failedLedgerMatch.Groups[1].Value
        $failedLedgerPath | Should -Be (Join-Path $failedRunRoot 'repository-pester-case-inventory-v1.json')
        (Get-FileHash -LiteralPath $failedLedgerPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $failedLedgerMatch.Groups[2].Value
        $failedLedger = Get-Content -LiteralPath $failedLedgerPath -Raw | ConvertFrom-Json
        $failedLedger.complete | Should -BeFalse
        $failedLedger.failedBlockCount | Should -BeGreaterThan 0
        $failedLedger.failedContainerCount | Should -BeGreaterThan 0
        $failedLedger.errors | Should -Contain 'Pester reported a failed block.'
        $failedLedger.errors | Should -Contain 'Pester reported a failed or undiscovered container.'
    }
}
