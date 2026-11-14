# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'SkillSpector stdout report capture' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $validatorPath = Join-Path $repositoryRoot 'scripts/Validate.ps1'
        $validatorSource = Get-Content -LiteralPath $validatorPath -Raw
        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseInput(
            $validatorSource, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'Validate.ps1 must parse before native output tests run.' }

        $requiredFunctions = @(
            'Test-PathEqual',
            'Test-PathWithinOrEqual',
            'Assert-NoReparseAncestors',
            'Write-ExclusiveUtf8File',
            'Read-StrictUtf8File',
            'Assert-NoDuplicateJsonProperties',
            'Read-JsonFile',
            'Read-SkillSpectorJsonReport',
            'Invoke-NativeChecked'
        )
        $functionAsts = @($validatorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $requiredFunctions -ccontains $node.Name
        }, $true))
        if ($functionAsts.Count -ne $requiredFunctions.Count) {
            throw 'The native report regression fixture could not locate every production helper.'
        }
        $moduleSource = ($functionAsts | Sort-Object { $_.Extent.StartOffset } |
            ForEach-Object { $_.Extent.Text }) -join "`n"
        $script:NativeReportModule = New-Module -ScriptBlock ([scriptblock]::Create($moduleSource))
        & $script:NativeReportModule { $script:IsWindowsHost = $false }
        $script:ValidatorSource = $validatorSource

        $fixtureScript = Join-Path $TestDrive 'native-skillspector-fixture.ps1'
        [IO.File]::WriteAllText($fixtureScript, @'
param([string] $Mode)
if ($Mode -ceq 'valid') {
    [Console]::Out.Write('{"result":"fixture"}')
    exit 0
}
if ($Mode -ceq 'invalid-json') {
    [Console]::Out.Write('not-json')
    [Console]::Error.Write('fixture invalid json stderr')
    exit 0
}
[Console]::Out.Write('{"partial":true}')
[Console]::Error.Write('fixture native failure stderr ' + ('x' * 5000))
exit 17
'@, [Text.UTF8Encoding]::new($false))
        # The forwarding command is a .cmd file on Windows and an executable sh script elsewhere.
        $fixtureCommandBase = Join-Path $TestDrive 'native-skillspector-fixture'
        $script:FixtureCommand = New-TestPowerShellScriptCommand -Path $fixtureCommandBase -ScriptPath $fixtureScript
    }

    AfterAll {
        if ($null -ne $script:NativeReportModule) {
            Remove-Module $script:NativeReportModule -Force -ErrorAction SilentlyContinue
        }
    }

    It 'UnitT10_OmitsOutputArgumentsAndRecordsTheActualScannerArguments' {
        $script:ValidatorSource | Should -Match '\$skillSpectorArguments = @\(''scan'', \$skillRoot, ''--no-llm'', ''--format'', ''json''\)'
        $script:ValidatorSource | Should -Match '\$semanticArguments = @\(''scan'', \$skillRoot, ''--format'', ''json''\)'
        $script:ValidatorSource | Should -Not -Match "@\('scan'[^\r\n]*'--output'"
        $script:ValidatorSource | Should -Match 'arguments = @\(\$skillSpectorArguments\)'
        $script:ValidatorSource | Should -Match 'arguments = @\(\$semanticArguments\)'
    }

    It 'InterT20_WritesNativeStdoutAndStderrToNewFiles' {
        # Native output roots must not have link ancestors, so use the physical TestDrive path.
        $caseRoot = Join-Path (Resolve-TestPhysicalPath -Path $TestDrive) 'valid-case'
        [void][IO.Directory]::CreateDirectory($caseRoot)
        $reportPath = Join-Path $caseRoot 'report.json'
        $stderrPath = Join-Path $caseRoot 'stderr.txt'

        & $script:NativeReportModule {
            param($command, $root, $report, $stderr)
            Invoke-NativeChecked -Command $command -Arguments @('valid') -Context 'fixture scan' `
                -DiagnosticRoot $root -ChildWritableRoot $root `
                -StandardOutputPath $report -StandardErrorPath $stderr | Out-Null
        } $script:FixtureCommand $caseRoot $reportPath $stderrPath

        [IO.File]::ReadAllText($reportPath) | Should -BeExactly '{"result":"fixture"}'
        $standardError = [IO.File]::ReadAllText($stderrPath)
        [string]::IsNullOrEmpty($standardError) | Should -BeTrue
        { & $script:NativeReportModule {
                param($command, $root, $report, $stderr)
                Invoke-NativeChecked -Command $command -Arguments @('valid') -Context 'fixture scan' `
                    -DiagnosticRoot $root -ChildWritableRoot $root `
                    -StandardOutputPath $report -StandardErrorPath $stderr
            } $script:FixtureCommand $caseRoot $reportPath $stderrPath } |
            Should -Throw '*already exists*'
    }

    It 'InterT30_IncludesBoundedNativeStderrWhenTheProcessFails' {
        # Native output roots must not have link ancestors, so use the physical TestDrive path.
        $caseRoot = Join-Path (Resolve-TestPhysicalPath -Path $TestDrive) 'failure-case'
        [void][IO.Directory]::CreateDirectory($caseRoot)
        $reportPath = Join-Path $caseRoot 'report.json'
        $stderrPath = Join-Path $caseRoot 'stderr.txt'
        $message = ''
        try {
            & $script:NativeReportModule {
                param($command, $root, $report, $stderr)
                Invoke-NativeChecked -Command $command -Arguments @('failure') -Context 'fixture scan' `
                    -DiagnosticRoot $root -ChildWritableRoot $root `
                    -StandardOutputPath $report -StandardErrorPath $stderr
            } $script:FixtureCommand $caseRoot $reportPath $stderrPath
        }
        catch { $message = $_.Exception.Message }

        $message | Should -Match 'exited with code 17'
        $message | Should -Match 'fixture native failure stderr'
        $message | Should -Match '\.\.\.\[truncated\]'
        $message.Length | Should -BeLessOrEqual 4300
    }

    It 'InterT40_IncludesBoundedStderrWhenStdoutIsInvalidJson' {
        # Native output roots must not have link ancestors, so use the physical TestDrive path.
        $caseRoot = Join-Path (Resolve-TestPhysicalPath -Path $TestDrive) 'invalid-json-case'
        [void][IO.Directory]::CreateDirectory($caseRoot)
        $reportPath = Join-Path $caseRoot 'report.json'
        $stderrPath = Join-Path $caseRoot 'stderr.txt'
        & $script:NativeReportModule {
            param($command, $root, $report, $stderr)
            Invoke-NativeChecked -Command $command -Arguments @('invalid-json') -Context 'fixture scan' `
                -DiagnosticRoot $root -ChildWritableRoot $root `
                -StandardOutputPath $report -StandardErrorPath $stderr | Out-Null
        } $script:FixtureCommand $caseRoot $reportPath $stderrPath

        { & $script:NativeReportModule {
                param($report, $stderr)
                Read-SkillSpectorJsonReport -ReportPath $report -StandardErrorPath $stderr -Context 'fixture scan'
            } $reportPath $stderrPath } |
            Should -Throw '*not valid unambiguous UTF-8 JSON*fixture invalid json stderr*'
    }
}
