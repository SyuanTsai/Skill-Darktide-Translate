# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Consumer repository-check evidence output' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $fixtureScript = Join-Path $TestDrive 'consumer-check-fixture.ps1'
        [IO.File]::WriteAllText($fixtureScript, @'
param([string] $Mode)
if ($Mode -ceq 'valid') {
    [Console]::Out.Write('{"schemaVersion":1,"result":"passed"}')
    exit 0
}
if ($Mode -ceq 'invalid-json') {
    [Console]::Out.Write('not-json')
    [Console]::Error.Write('fixture invalid json stderr')
    exit 0
}
[Console]::Out.Write('{"result":"failed"}')
[Console]::Error.Write('fixture repository check failure')
exit 17
'@, [Text.UTF8Encoding]::new($false))
        $script:FixtureCommand = New-TestPowerShellScriptCommand `
            -Path (Join-Path $TestDrive 'consumer-check-fixture') `
            -ScriptPath $fixtureScript

        function Invoke-EvidenceFixture {
            param([Parameter(Mandatory)][string] $Mode)

            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $script:FixtureCommand
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            [void]$start.ArgumentList.Add($Mode)
            $process = [Diagnostics.Process]::new()
            try {
                $process.StartInfo = $start
                [void]$process.Start()
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    StandardOutput = $stdout.GetAwaiter().GetResult()
                    StandardError = $stderr.GetAwaiter().GetResult()
                }
            }
            finally {
                $process.Dispose()
            }
        }
    }

    It 'InterT20_CapturesOneValidJsonEvidenceDocument' {
        $actual = Invoke-EvidenceFixture -Mode valid
        $actual.ExitCode | Should -Be 0
        $evidence = $actual.StandardOutput | ConvertFrom-TestJson
        $evidence.schemaVersion | Should -Be 1
        $evidence.result | Should -Be 'passed'
        [string]::IsNullOrEmpty($actual.StandardError) | Should -BeTrue
    }

    It 'InterT30_PreservesFailureExitAndDiagnosticStreams' {
        $actual = Invoke-EvidenceFixture -Mode failure
        $actual.ExitCode | Should -Be 17
        $actual.StandardOutput | Should -BeExactly '{"result":"failed"}'
        $actual.StandardError | Should -BeExactly 'fixture repository check failure'
    }

    It 'InterT40_RejectsSuccessfulOutputThatIsNotJsonEvidence' {
        $actual = Invoke-EvidenceFixture -Mode invalid-json
        $actual.ExitCode | Should -Be 0
        { $actual.StandardOutput | ConvertFrom-TestJson } | Should -Throw
        $actual.StandardError | Should -BeExactly 'fixture invalid json stderr'
    }
}
