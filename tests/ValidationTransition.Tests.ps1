# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'SYP-280 immutable source validation contracts' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:Workflow = Get-Content (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-candidate-windows.yml') -Raw
        $script:Driver = Get-Content (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw
        $script:Pin = Get-Content (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw | ConvertFrom-Json -Depth 30
    }
    # Scenario: source checks select the merged SYP-280 runtime.
    # Purpose: Bind the complete authority inventory to the compiled reviewed tuple.
    It 'UnitT10_BindsTheReviewedAuthorityTuple' {
        $script:Pin.authority.commit | Should -BeExactly 'ff85d5f80fe795b96354e753074b5ce59ad04ecd'
        $script:Pin.authority.archiveSha256 | Should -BeExactly '3dc38613f2e2316ad8fcc79d4bf48d0b03fd8398f8dacc72d156abcbce95ea9d'
        @($script:Pin.authority.files).Count | Should -Be 32
        foreach ($entry in $script:Pin.authority.files) {
            $script:Driver | Should -Match ([regex]::Escape("'$($entry.path)' = '$($entry.sha256)'"))
        }
    }
    # Scenario: a PR changes the validator together with its source.
    # Purpose: Bind execution to the event base and protect Pester acquisition.
    It 'UnitT20_UsesTheExactProtectedBaseDriver' {
        $script:Workflow | Should -Match 'github\.event\.pull_request\.base\.sha \|\| github\.sha'
        $script:Workflow | Should -Match 'driverHead -cne \$env:EXPECTED_DRIVER_SHA'
        $script:Workflow | Should -Match "Join-Path \(Join-Path \`$env:GITHUB_WORKSPACE 'driver'\) 'scripts/Prepare-PesterRuntime.ps1'"
        $script:Workflow | Should -Match 'persist-credentials: false'
        $script:Workflow | Should -Not -Match 'pull_request_target|checks: write|statuses: write'
    }
    # Scenario: controlled acquisition precedes execution on one frozen run.
    # Purpose: Require the typed source outcome rather than ordinary Core PASS.
    It 'UnitT30_SeparatesSetupAndValidationAndRequiresTypedSourceReport' {
        foreach ($value in @('PrepareSourceTools','SourceValidation','SOURCE_TOOLS_PATH','Assert-StandardCoreSourceCheckReport')) { $script:Workflow | Should -Match $value }
        $script:Workflow | Should -Match 'ProcessExitCode \$ActualExit'
        $script:Driver | Should -Match "'-SourceValidation','-RunId',\[string\]\`$preparedSource.runId"
        $script:Driver | Should -Match 'Assert-StandardCoreFrozenFiles'
        $script:Driver | Should -Match 'Assert-StandardCoreSourceToolReceipts'
    }
    # Scenario: required contexts consume the same canonical source result.
    # Purpose: Keep the existing Ruleset context and preserve raw evidence.
    It 'UnitT40_PreservesRequiredContextAndProjectsOneSourceOutcome' {
        $script:Workflow | Should -Match '(?m)^    name: Darktide Translate Windows Latest Stable PowerShell\r?$'
        ([regex]::Matches($script:Workflow, "SOURCE_CONFORMANCE_RESULT -cne 'passed'")).Count | Should -Be 3
        $script:Workflow | Should -Match 'releaseEligible -ne \$false'
        $script:Workflow | Should -Not -Match 'https://github.com/SyuanTsai/Darktide Translate'
        $script:Workflow.IndexOf('Preserve raw source validation evidence') | Should -BeLessThan $script:Workflow.IndexOf('Remove run-owned validation directory')
    }
    # Scenario: a local branch uses the same source entry and complete history.
    # Purpose: Separate source success from release approval and consumer deployment.
    It 'UnitT50_DocumentsCanonicalSourceValidationAndFullMergeBase' {
        $wrapper = Get-Content (Join-Path $script:RepositoryRoot 'scripts/Invoke-PrePushValidation.ps1') -Raw
        $wrapper | Should -Match 'merge-base --all'
        $wrapper | Should -Not -Match 'HEAD\^'
        $wrapper | Should -Match 'Assert-StandardCoreSourceCheckReport'
        foreach ($path in @('README.md','docs/RELEASE.md','docs/ROLLBACK.md')) {
            $text = Get-Content (Join-Path $script:RepositoryRoot $path) -Raw
            foreach ($value in @('merge-base','SourceValidation','releaseEligible=false','component')) { $text | Should -Match $value }
        }
    }
    # Scenario: workflow adaptation damages an executable inline step.
    # Purpose: Parse every PowerShell block, including cleanup and result mirrors.
    It 'UnitT60_ParsesEveryWorkflowPowerShellBlock' {
        $blocks = [regex]::Matches($script:Workflow, '(?ms)^        run: \|\r?\n(?<code>.*?)(?=^      - |^  [a-z][a-z-]*:|\z)')
        $blocks.Count | Should -BeGreaterThan 8
        foreach ($block in $blocks) {
            $code = [regex]::Replace($block.Groups['code'].Value, '(?m)^          ', '')
            $tokens=$null; $errors=$null
            [void][Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
            @($errors).Count | Should -Be 0 -Because ($errors.Message -join '; ')
        }
    }
    # Scenario: the Pester adapter receives the read-only source snapshot.
    # Purpose: Verify the full test tree, exact runtime closure and case inventory.
    It 'UnitT70_RunsUnfilteredPesterWithExactRuntimeClosure' {
        $pester = Get-Content (Join-Path $script:RepositoryRoot 'scripts/Invoke-CorePester.ps1') -Raw
        foreach ($value in @('Test-CorePesterClosure','Test-CorePesterLoadedModuleIdentity','New-CorePesterCaseInventory','candidateSnapshotBefore')) { $pester | Should -Match $value }
        $pester | Should -Match '\$pesterConfig.Run.Path = \$testRoot'
        $pester | Should -Not -Match 'Run.Filter|ExcludePath|ExcludeTag|IncludeTag'
        $script:Driver | Should -Match 'Test-Repository.ps1.*ReadOnlySnapshot'
    }
}
