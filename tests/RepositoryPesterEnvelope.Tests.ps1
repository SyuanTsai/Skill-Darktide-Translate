# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Repository Pester result envelope' {
    BeforeAll {
        $repositoryRoot = Split-Path -Parent $PSScriptRoot
        $validator = Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts/Validate.ps1') -Raw
        $runnerMatch = [regex]::Match($validator, '(?ms)^\$childRunnerText = @''\r?\n(?<body>.*?)^''@')
        if (-not $runnerMatch.Success) { throw 'Generated child runner was not found.' }

        $script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sg-pester-envelope-' + [guid]::NewGuid().ToString('N'))
        $candidateRoot = Join-Path $script:fixtureRoot 'candidate'
        $testsRoot = Join-Path $candidateRoot 'tests'
        $moduleRoot = Join-Path $script:fixtureRoot 'Pester'
        [void](New-Item -ItemType Directory -Path $testsRoot, $moduleRoot -Force)
        [IO.File]::WriteAllText((Join-Path $testsRoot 'fixture.Tests.ps1'), "It 'fixture' {}`n", [Text.UTF8Encoding]::new($false))
        $script:runnerPath = Join-Path $script:fixtureRoot 'child-runner.ps1'
        [IO.File]::WriteAllText($script:runnerPath, $runnerMatch.Groups['body'].Value, [Text.UTF8Encoding]::new($false))
        $moduleBody = @'
function Invoke-Pester {
    param($Path, $Output, [switch] $PassThru)
    switch ($env:TEST_PESTER_SCENARIO) {
        'partial-skip' { return [pscustomobject]@{ TotalCount = 3; PassedCount = 2; SkippedCount = 1; FailedCount = 0; FailedBlocksCount = 0; FailedContainersCount = 0 } }
        'zero-selected' { return [pscustomobject]@{ TotalCount = 0; PassedCount = 0; SkippedCount = 0; FailedCount = 0; FailedBlocksCount = 0; FailedContainersCount = 0 } }
        'all-skipped' { return [pscustomobject]@{ TotalCount = 2; PassedCount = 0; SkippedCount = 2; FailedCount = 0; FailedBlocksCount = 0; FailedContainersCount = 0 } }
        'failed' { return [pscustomobject]@{ TotalCount = 2; PassedCount = 1; SkippedCount = 0; FailedCount = 1; FailedBlocksCount = 0; FailedContainersCount = 0 } }
    }
    throw 'Unknown fake Pester scenario.'
}
Export-ModuleMember -Function Invoke-Pester
'@
        [IO.File]::WriteAllText((Join-Path $moduleRoot 'Pester.psm1'), $moduleBody, [Text.UTF8Encoding]::new($false))
        $script:modulePath = Join-Path $moduleRoot 'Pester.psd1'
        New-ModuleManifest -Path $script:modulePath -RootModule 'Pester.psm1' -ModuleVersion '6.2.0' -FunctionsToExport @('Invoke-Pester')
        $toolchainPath = Join-Path $script:fixtureRoot 'toolchain.json'
        [IO.File]::WriteAllText($toolchainPath, (@{ pesterModulePath = $script:modulePath; pesterModuleSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:modulePath).Hash.ToLowerInvariant(); pesterVersion = '6.2.0' } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $script:toolchainPath = $toolchainPath
        $script:toolchainSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $toolchainPath).Hash.ToLowerInvariant()
        $script:pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $script:oldCandidateRoot = $env:STANDARD_VALIDATION_CANDIDATE_ROOT
        $script:oldCandidateId = $env:STANDARD_VALIDATION_CANDIDATE_ID
        $script:oldActiveSkills = $env:STANDARD_VALIDATION_ACTIVE_SKILLS
        $script:oldScenario = $env:TEST_PESTER_SCENARIO
        $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $candidateRoot
        $env:STANDARD_VALIDATION_CANDIDATE_ID = 'fixture-candidate'
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS = 'fixture-skill'
    }

    AfterAll {
        $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $script:oldCandidateRoot
        $env:STANDARD_VALIDATION_CANDIDATE_ID = $script:oldCandidateId
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS = $script:oldActiveSkills
        $env:TEST_PESTER_SCENARIO = $script:oldScenario
        if (Test-Path -LiteralPath $script:fixtureRoot) { Remove-Item -LiteralPath $script:fixtureRoot -Recurse -Force }
    }

    # Scenario: Pester returns two passes and one skip; the child runner emits its actual typed counts.
    # Purpose: Protect the supervisor proposal contract against an omitted failed count.
    It 'InterT10_ emits exact numeric counts in one JSON envelope for a partial skip' {
        $env:TEST_PESTER_SCENARIO = 'partial-skip'
        $output = @(& $script:pwsh -NoProfile -NonInteractive -File $script:runnerPath -Mode repository-pester -ToolchainPath $script:toolchainPath -ToolchainSha256 $script:toolchainSha256)
        $LASTEXITCODE | Should -Be 0
        $output.Count | Should -Be 1
        $json = $output[0] | ConvertFrom-Json -Depth 20
        $json.testResult.status | Should -Be 'passed'
        $json.testResult.total | Should -BeOfType ([long])
        $json.testResult.passed | Should -BeOfType ([long])
        $json.testResult.skipped | Should -BeOfType ([long])
        $json.testResult.failed | Should -BeOfType ([long])
        $json.testResult.total | Should -Be 3
        $json.testResult.passed | Should -Be 2
        $json.testResult.skipped | Should -Be 1
        $json.testResult.failed | Should -Be 0
    }

    # Scenario: Pester selects no tests; the child runner must reject the result.
    # Purpose: Prevent an empty suite from qualifying as repository regression evidence.
    It 'InterT20_ rejects zero selected tests' {
        $env:TEST_PESTER_SCENARIO = 'zero-selected'
        $output = @(& $script:pwsh -NoProfile -NonInteractive -File $script:runnerPath -Mode repository-pester -ToolchainPath $script:toolchainPath -ToolchainSha256 $script:toolchainSha256 2>$null)
        $LASTEXITCODE | Should -Not -Be 0
        $output.Count | Should -Be 0
    }

    # Scenario: All discovered tests are skipped; the child runner must reject the result.
    # Purpose: Prevent a pass envelope with no executed assertions.
    It 'InterT30_ rejects an all-skipped suite' {
        $env:TEST_PESTER_SCENARIO = 'all-skipped'
        $output = @(& $script:pwsh -NoProfile -NonInteractive -File $script:runnerPath -Mode repository-pester -ToolchainPath $script:toolchainPath -ToolchainSha256 $script:toolchainSha256 2>$null)
        $LASTEXITCODE | Should -Not -Be 0
        $output.Count | Should -Be 0
    }

    # Scenario: Pester reports a failed test; the child runner must reject the result.
    # Purpose: Preserve fail-closed repository regression evidence.
    It 'InterT40_ rejects a failed suite' {
        $env:TEST_PESTER_SCENARIO = 'failed'
        $output = @(& $script:pwsh -NoProfile -NonInteractive -File $script:runnerPath -Mode repository-pester -ToolchainPath $script:toolchainPath -ToolchainSha256 $script:toolchainSha256 2>$null)
        $LASTEXITCODE | Should -Not -Be 0
        $output.Count | Should -Be 0
    }
}
