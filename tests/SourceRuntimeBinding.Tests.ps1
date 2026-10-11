# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Canonical source runtime binding' {
    BeforeAll {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Validate.ps1'),[ref]$tokens,[ref]$errors)
        $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-ResolvedPowerShellPath'},$false)
        $script:RuntimeModule=New-Module -ScriptBlock ([scriptblock]::Create($function.Extent.Text))
    }
    # Scenario: a verified private runtime starts validation while PATH contains another pwsh.
    # Purpose: Use the actual host executable rather than silently switching runtimes.
    It 'UnitT10_UsesTheActualHostExecutableDespiteAmbientPath' {
        $before=$env:PATH
        try {
            $env:PATH=Join-Path $TestDrive 'missing-ambient-pwsh'
            $actual=& $script:RuntimeModule { Get-ResolvedPowerShellPath }
            $actual | Should -BeExactly ([IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName))
        } finally { $env:PATH=$before }
    }
}
