# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Atomic caller-specified validation output' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:OutputRoot = Join-Path $TestDrive 'validation-output'
        New-Item -ItemType Directory -Path $script:OutputRoot -Force | Out-Null

        function Invoke-RepositoryValidatorProcess {
            param([Parameter(Mandatory = $true)][string] $OutputPath)

            $pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = [IO.Path]::GetFullPath([string]$pwsh.Source)
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @(
                    '-NoLogo',
                    '-NoProfile',
                    '-NonInteractive',
                    '-File', $script:RepositoryValidator,
                    '-RepositoryRoot', $script:RepositoryRoot,
                    '-OutputPath', $OutputPath)) {
                [void]$startInfo.ArgumentList.Add([string]$argument)
            }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { throw 'Could not start the repository validator child process.' }
            return $process
        }

        function Complete-RepositoryValidatorProcess {
            param([Parameter(Mandatory = $true)][Diagnostics.Process] $Process)

            # Drain both redirected streams asynchronously before waiting. A
            # synchronous WaitForExit followed by ReadToEnd can deadlock when a
            # validator or a diagnostic component fills either pipe.
            $stdoutTask = $Process.StandardOutput.ReadToEndAsync()
            $stderrTask = $Process.StandardError.ReadToEndAsync()
            if (-not $Process.WaitForExit(120000)) {
                try { $Process.Kill($true) } catch { }
                throw 'Repository validator child process exceeded the bounded test timeout.'
            }
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            [pscustomobject]@{
                ExitCode = $Process.ExitCode
                StdOut = $stdout
                StdErr = $stderr
            }
            $Process.Dispose()
        }
    }

    # Scenario: A previous validation result already occupies the requested output path.
    # Purpose: Preserve prior evidence and fail closed instead of replacing it.
    It 'UnitT10_RejectsAnExistingOutputWithoutChangingItsBytes' {
        $outputPath = Join-Path $script:OutputRoot 'existing.json'
        $original = '{"sentinel":"do-not-overwrite"}' + [Environment]::NewLine
        [IO.File]::WriteAllText($outputPath, $original, [Text.UTF8Encoding]::new($false))

        { & $script:RepositoryValidator -RepositoryRoot $script:RepositoryRoot -OutputPath $outputPath } |
            Should -Throw
        [IO.File]::ReadAllText($outputPath, [Text.UTF8Encoding]::new($false)) | Should -Be $original
    }

    # Scenario: Two independent validation processes select the same new output path at the same time.
    # Purpose: Prove exclusive creation gives exactly one writer and leaves one complete parseable JSON result.
    It 'InterT20_AllowsExactlyOneConcurrentWriterAndLeavesCompleteJson' {
        $outputPath = Join-Path $script:OutputRoot 'concurrent.json'
        $first = Invoke-RepositoryValidatorProcess -OutputPath $outputPath
        $second = Invoke-RepositoryValidatorProcess -OutputPath $outputPath
        $firstResult = Complete-RepositoryValidatorProcess -Process $first
        $secondResult = Complete-RepositoryValidatorProcess -Process $second
        $results = @($firstResult, $secondResult)

        @($results | Where-Object ExitCode -eq 0).Count | Should -Be 1
        @($results | Where-Object ExitCode -ne 0).Count | Should -Be 1
        Test-Path -LiteralPath $outputPath -PathType Leaf | Should -BeTrue
        $outputBytes = [IO.File]::ReadAllBytes($outputPath)
        $outputBytes.Length | Should -BeGreaterThan 0
        ([Text.UTF8Encoding]::new($false, $true).GetString($outputBytes) | ConvertFrom-Json).result | Should -Be 'passed'
        $outputBytes[0] | Should -Not -Be 0xEF
    }
}
