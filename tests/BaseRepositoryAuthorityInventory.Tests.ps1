# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Base-owned repository authority inventory compatibility' {
    BeforeAll {
        $root=Split-Path -Parent $PSScriptRoot
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Test-Repository.ps1'),[ref]$tokens,[ref]$errors)
        if ($errors.Count) {throw 'Repository validator parse failed.'}
        $shape=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-ExactPropertySet'},$true)
        . ([scriptblock]::Create($shape.Extent.Text))
        $selected=@($ast.EndBlock.Statements | Where-Object {
            ($_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$requiredAuthorityPaths') -or
            ($_ -is [Management.Automation.Language.IfStatementAst] -and ($_.Extent.Text.StartsWith("if (`$adapter.authority.commit -ceq '8aabd226") -or $_.Extent.Text.StartsWith('if ($adapter.authority.files -isnot'))) -or
            ($_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Extent.Text.StartsWith('foreach ($file in @($adapter.authority.files))'))
        })
        if ($selected.Count -ne 4) {throw 'Inventory guard statements must be unambiguous.'}
        $script:Inventory=[scriptblock]::Create(($selected.Extent.Text -join "`n"))
        $driver=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Validate.ps1'),[ref]$tokens,[ref]$errors)
        $fixed=$driver.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-RequiredPesterTests'},$true)
        . ([scriptblock]::Create($fixed.Extent.Text))
        $script:Adapters=@{
            old=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/ApprovedA403Adapter.json') -Raw | ConvertFrom-Json)
            new=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/Reviewed8aAdapter.json') -Raw | ConvertFrom-Json)
        }
    }

    # Scenario: Trusted repository inventory sees either exact version and its expected closure.
    # Purpose: Remove the demonstrated26-member rejection while preserving14-member baseline.
    It 'UnitT10_AcceptsVersionBoundInventory_<Version>' -TestCases @(@{Version='old'},@{Version='new'}) {
        param($Version)
        @(Get-RequiredPesterTests -IncludeTrustedPostPromotionTests) | Should -Contain 'BaseRepositoryAuthorityInventory.Tests.ps1'
        $adapter=$script:Adapters[$Version]
        $authorityPaths=@()
        . $script:Inventory
        $authorityPaths.Count | Should -Be $adapter.authority.files.Count
    }

    # Scenario: Caller changes the inventory count, version, membership or uniqueness.
    # Purpose: Reject open-ended version adoption and preserve existing exact path gates.
    It 'UnitT20_RejectsInventorySubstitution_<Kind>' -TestCases @(
        @{Kind='old-with26'},@{Kind='new-with14'},@{Kind='unknown-version'},@{Kind='wrong-path'},@{Kind='duplicate'}
    ) {
        param($Kind)
        $adapter=$script:Adapters.new | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        switch($Kind) {
            'old-with26' {$adapter.authority.commit=$script:Adapters.old.authority.commit}
            'new-with14' {$adapter.authority.files=$script:Adapters.old.authority.files}
            'unknown-version' {$adapter.authority.commit='0'*40}
            'wrong-path' {$adapter.authority.files[0].path='scripts/unreviewed.ps1'}
            'duplicate' {$adapter.authority.files[1]=$adapter.authority.files[0]}
        }
        $authorityPaths=@()
        { . $script:Inventory } | Should -Throw
    }
}
