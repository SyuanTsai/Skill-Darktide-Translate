# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Repository test environment' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ModulePath = Join-Path $script:RepositoryRoot 'scripts/TestEnvironment.psm1'
        $script:PreflightPath = Join-Path $script:RepositoryRoot 'scripts/Test-TestEnvironment.ps1'
        $script:InstallerPath = Join-Path $script:RepositoryRoot 'scripts/Install-TestEnvironment.ps1'
        Import-Module $script:ModulePath -Force

        function New-TestPesterManifest {
            param([string] $Root, [string] $Version)
            $moduleRoot = Join-Path $Root "Pester/$Version"
            New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
            $manifest = Join-Path $moduleRoot 'Pester.psd1'
            [IO.File]::WriteAllText($manifest, "@{ ModuleVersion = '$Version'; RootModule = 'Pester.psm1' }`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $moduleRoot 'Pester.psm1'), "# fixture`n", [Text.UTF8Encoding]::new($false))
            $manifest
        }
    }

    # Scenario: The current shell is Windows PowerShell or older than the CI minimum.
    # Purpose: Block unsupported runtimes while showing both expected and actual values.
    It 'UnitT10_BlocksAnUnsupportedPowerShellRuntime_<edition>_<version>' -ForEach @(
        @{ edition = 'Desktop'; version = '5.1.22621.2506' },
        @{ edition = 'Core'; version = '7.5.9' }
    ) {
        $check = Test-TestEnvironmentPowerShell -Edition $edition -Version ([version]$version) -MinimumVersion ([version]'7.6.6')
        $check.status | Should -Be 'blocked'
        $check.expected | Should -Match '7\.6\.6'
        $check.actual | Should -Match ([regex]::Escape($version))
    }

    # Scenario: The current PowerShell is newer than the configured minimum.
    # Purpose: Preserve the latest-stable policy by accepting future stable versions.
    It 'UnitT11_AcceptsANewerPowerShellRuntime' {
        $check = Test-TestEnvironmentPowerShell -Edition Core -Version ([version]'7.7.0') -MinimumVersion ([version]'7.6.6')
        $check.status | Should -Be 'pass'
    }

    # Scenario: Explicit Pester manifests are older, newer, or receipt-tampered.
    # Purpose: Require the minimum version and verify receipt-bound manifest integrity.
    It 'UnitT20_ValidatesPesterVersionAndReceiptHash' {
        $old = New-TestPesterManifest -Root (Join-Path $TestDrive 'old') -Version '6.1.0'
        (Test-TestEnvironmentPester -ManifestPath $old -MinimumVersion ([version]'6.2.0')).status | Should -Be 'blocked'
        $new = New-TestPesterManifest -Root (Join-Path $TestDrive 'new') -Version '6.3.0'
        (Test-TestEnvironmentPester -ManifestPath $new -MinimumVersion ([version]'6.2.0')).status | Should -Be 'pass'
        $wrongHash = '0' * 64
        (Test-TestEnvironmentPester -ManifestPath $new -MinimumVersion ([version]'6.2.0') -ExpectedSha256 $wrongHash).status |
            Should -Be 'blocked'
    }

    # Scenario: The effective execution policy prevents ordinary script execution.
    # Purpose: Direct users to the standard runtime without normalizing policy bypasses.
    It 'UnitT30_BlocksRestrictedExecutionPolicyWithoutBypassAdvice' {
        $check = Test-TestEnvironmentExecutionPolicy -ExecutionPolicy Restricted -IsWindows $true
        $check.status | Should -Be 'blocked'
        $check.remediation | Should -Match '不要用 -ExecutionPolicy Bypass'
        $check.remediation | Should -Not -Match '(?i)建議.+-ExecutionPolicy\s+Bypass'
    }

    # Scenario: Git rejects the repository because ownership is untrusted.
    # Purpose: Surface the precise safe.directory remediation as a user decision.
    It 'UnitT40_ReportsDubiousOwnershipWithSafeDirectoryAdvice' {
        $check = Test-TestEnvironmentGitResult -RepositoryRoot 'C:\repo' -ExitCode 128 -Output 'fatal: detected dubious ownership in repository'
        $check.status | Should -Be 'blocked'
        $check.remediation | Should -Match 'git config --global --add safe\.directory'
    }

    # Scenario: Skill files move between clean, untracked, unstaged, staged, and out-of-package states.
    # Purpose: Mirror the InterT20 Git-index prerequisite without rejecting unrelated changes.
    It 'InterT50_ValidatesTheSkillPackageAgainstTheGitIndex' {
        $root = Join-Path $TestDrive 'repository'
        $skill = Join-Path $root 'skills/auto-update-darktide-mod'
        New-Item -ItemType Directory -Path $skill -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $skill 'SKILL.md'), "fixture`n", [Text.UTF8Encoding]::new($false))
        & git -C $root init --quiet
        & git -C $root config user.name fixture
        & git -C $root config user.email fixture@example.invalid
        & git -C $root add -- skills
        & git -C $root commit --quiet -m fixture

        (Test-TestEnvironmentSkillPackageIndex -RepositoryRoot $root).status | Should -Be 'pass'
        [IO.File]::WriteAllText((Join-Path $skill 'new.txt'), "new`n", [Text.UTF8Encoding]::new($false))
        $untracked = Test-TestEnvironmentSkillPackageIndex -RepositoryRoot $root
        $untracked.status | Should -Be 'blocked'
        $untracked.actual | Should -Match 'new\.txt'
        Remove-Item -LiteralPath (Join-Path $skill 'new.txt')

        [IO.File]::AppendAllText((Join-Path $skill 'SKILL.md'), "changed`n", [Text.UTF8Encoding]::new($false))
        (Test-TestEnvironmentSkillPackageIndex -RepositoryRoot $root).status | Should -Be 'blocked'
        & git -C $root add -- skills/auto-update-darktide-mod/SKILL.md
        (Test-TestEnvironmentSkillPackageIndex -RepositoryRoot $root).status | Should -Be 'pass'
        [IO.File]::WriteAllText((Join-Path $root 'outside.txt'), "outside`n", [Text.UTF8Encoding]::new($false))
        (Test-TestEnvironmentSkillPackageIndex -RepositoryRoot $root).status | Should -Be 'pass'
    }

    # Scenario: The orchestrator receives a preflight failure before importing Pester.
    # Purpose: Ensure a missing explicit manifest exits nonzero without starting Pester.
    It 'InterT60_StopsInvokeTestsBeforePesterWhenPreflightIsBlocked' {
        $missing = Join-Path $TestDrive 'missing/Pester.psd1'
        $powerShell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $output = @(& $powerShell -NoProfile -File (Join-Path $script:RepositoryRoot 'tests/Invoke-Tests.ps1') -PesterManifestPath $missing 2>&1)
        $LASTEXITCODE | Should -Be 2
        ($output -join "`n") | Should -Match 'pester-module'
    }

    # Scenario: The preflight reports a blocked check whose remediation contains Traditional Chinese text.
    # Purpose: Ensure Invoke-Tests decodes the preflight output as UTF-8 instead of the console code page, so the JSON stays parseable.
    It 'InterT61_PreservesNonAsciiPreflightTextInInvokeTests' {
        $missing = Join-Path $TestDrive 'missing/Pester.psd1'
        $powerShell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $expected = (Test-TestEnvironmentPester -ManifestPath $missing -MinimumVersion ([version]'6.2.0')).remediation
        $expected | Should -Match '[^\x00-\x7F]'
        $invokeTests = Join-Path $script:RepositoryRoot 'tests/Invoke-Tests.ps1'
        $stderrPath = Join-Path $TestDrive 'invoke-tests.stderr.txt'
        if ($IsWindows) {
            # A zh-TW console code page (950) previously turned the UTF-8 preflight JSON into invalid text.
            $command = 'chcp 950 >nul & "{0}" -NoProfile -File "{1}" -PesterManifestPath "{2}" 2>"{3}"' -f $powerShell, $invokeTests, $missing, $stderrPath
            & cmd.exe /d /c $command | Out-Null
            $exitCode = $LASTEXITCODE
            $stderr = [IO.File]::ReadAllText($stderrPath, [Text.Encoding]::GetEncoding(950))
        }
        else {
            $process = Start-Process -FilePath $powerShell -ArgumentList @('-NoProfile', '-File', $invokeTests, '-PesterManifestPath', $missing) `
                -RedirectStandardError $stderrPath -RedirectStandardOutput (Join-Path $TestDrive 'invoke-tests.stdout.txt') -NoNewWindow -Wait -PassThru
            $exitCode = $process.ExitCode
            $stderr = [IO.File]::ReadAllText($stderrPath)
        }
        $exitCode | Should -Be 2
        $stderr | Should -BeLikeExactly "*remediation=$expected*"
    }

    # Scenario: The preflight runs inside a console that uses the zh-TW code page 950.
    # Purpose: Ensure the preflight never changes the shared console code page and its JSON line stays pure ASCII.
    It 'InterT62_LeavesTheConsoleCodePageUnchangedAndEmitsAsciiJson' {
        $powerShell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $stdoutPath = Join-Path $TestDrive 'preflight.stdout.txt'
        if ($IsWindows) {
            $command = 'chcp 950 >nul & "{0}" -NoProfile -File "{1}" -PesterManifestPath "{2}" >"{3}" 2>nul & chcp' -f $powerShell, $script:PreflightPath, (Join-Path $TestDrive 'missing/Pester.psd1'), $stdoutPath
            $after = (& cmd.exe /d /c $command) -join "`n"
            $after | Should -Match '\b950\b'
        }
        else {
            & $powerShell -NoProfile -File $script:PreflightPath -PesterManifestPath (Join-Path $TestDrive 'missing/Pester.psd1') > $stdoutPath 2>$null
        }
        $bytes = [IO.File]::ReadAllBytes($stdoutPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $report = ([Text.Encoding]::ASCII.GetString($bytes).Trim() -split "`r?`n")[-1] | ConvertFrom-Json
        $report.result | Should -BeExactly 'BLOCKED'
        $report.checks.remediation | Should -Contain (Test-TestEnvironmentPester -ManifestPath (Join-Path $TestDrive 'missing/Pester.psd1') -MinimumVersion ([version]'6.2.0')).remediation
    }

    # Scenario: The preflight is started by Windows PowerShell 5.1 without an explicit RepositoryRoot, as in the Codex sandbox.
    # Purpose: Ensure the script parses and resolves its own root under 5.1, then reports the runtime as BLOCKED instead of crashing.
    It 'InterT63_ReportsWindowsPowerShellAsBlockedWithoutCrashing' {
        if (-not $IsWindows) {
            # Windows PowerShell 5.1 exists only on Windows; on other platforms the pwsh runtime path is covered by UnitT10/UnitT11.
            $true | Should -BeTrue
            return
        }
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $output = @(& $windowsPowerShell -NoProfile -ExecutionPolicy RemoteSigned -File $script:PreflightPath 2>$null)
        $LASTEXITCODE | Should -Be 2
        $report = $output[-1] | ConvertFrom-Json
        $runtime = @($report.checks | Where-Object id -eq 'powershell-runtime')[0]
        $runtime.status | Should -BeExactly 'blocked'
        $runtime.actual | Should -Match '^Desktop 5\.1'
        $report.environment.powerShell.edition | Should -BeExactly 'Desktop'
    }

    # Scenario: A locally supplied minimal Pester nupkg has a valid or invalid expected digest.
    # Purpose: Install atomically, record evidence, and leave no partial version on hash failure.
    It 'InterT70_InstallsAnOfflinePesterPackageAtomically' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $source = Join-Path $TestDrive 'package-source'
        New-Item -ItemType Directory -Path $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'Pester.psd1'), "@{ ModuleVersion = '6.3.0'; RootModule = 'Pester.psm1' }`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $source 'Pester.psm1'), "# fixture`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $source 'Pester.nuspec'), '<package />', [Text.UTF8Encoding]::new($false))
        $package = Join-Path $TestDrive 'Pester.6.3.0.nupkg'
        [IO.Compression.ZipFile]::CreateFromDirectory($source, $package)
        $sha = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
        $toolRoot = Join-Path $TestDrive 'tools-good'
        & $script:InstallerPath -ToolRoot $toolRoot -Component Pester -OfflinePackagePath $package -ExpectedSha256 $sha
        Test-Path (Join-Path $toolRoot 'modules/Pester/6.3.0/Pester.psd1') | Should -BeTrue
        (Get-Content -Raw (Join-Path $toolRoot 'install-receipt.json') | ConvertFrom-Json).pester.version | Should -Be '6.3.0'

        $badRoot = Join-Path $TestDrive 'tools-bad'
        { & $script:InstallerPath -ToolRoot $badRoot -Component Pester -OfflinePackagePath $package -ExpectedSha256 ('0' * 64) } |
            Should -Throw
        Test-Path (Join-Path $badRoot 'modules/Pester/6.3.0') | Should -BeFalse
    }

    # Scenario: Repository-local minima are compared with the pinned central authority values.
    # Purpose: Detect drift; offline validation fixes the values sourced from setup-agent-environment.policy.json and validation-toolchain.json at authority pin 5119a93417dc976feedca18cfd2e23044a8ca2e7.
    It 'UnitT80_PinsTheOfflineCentralToolchainMinimums' {
        $config = Get-Content -Raw (Join-Path $script:RepositoryRoot 'config/test-environment.json') | ConvertFrom-Json
        $config.powerShell.minimumVersion | Should -Be '7.6.6'
        $config.pester.minimumVersion | Should -Be '6.2.0'
    }
}
