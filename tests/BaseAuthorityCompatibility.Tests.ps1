# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Base-compatible exact authority registry' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $tokens=$null; $errors=$null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Validate.ps1'),[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw 'Candidate parser failed.' }
        $guard = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-PredecessorApprovedSnapshot'},$true)
        . ([scriptblock]::Create($guard.Extent.Text))
        $inventory=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-RequiredPesterTests'},$true)
        . ([scriptblock]::Create($inventory.Extent.Text))
        $script:Dispatch = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith("if (`$approvedAuthorityCommit -ceq '8aabd226")},$true))
        if ($script:Dispatch.Count -ne 1) { throw 'Candidate dispatch is ambiguous.' }
        $script:Adapters = @{
            old=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/ApprovedA403Adapter.json') -Raw | ConvertFrom-Json)
            new=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/Reviewed8aAdapter.json') -Raw | ConvertFrom-Json)
        }
    }

    # Scenario: Either complete immutable tuple is presented to the actual proposed driver guard.
    # Purpose: Preserve the current14-member baseline while verifying the exact26-member future binding.
    It 'UnitT10_AcceptsOnlyTheCompleteTuple_<Version>' -TestCases @(@{Version='old';Count=14},@{Version='new';Count=26}) {
        param($Version,$Count)
        $selected = Assert-PredecessorApprovedSnapshot -Adapter $script:Adapters[$Version]
        $selected.files.Count | Should -Be $Count
        $selected.commit | Should -BeExactly $script:Adapters[$Version].authority.commit
    }

    # Scenario: One of the identity, archive or closure fields is substituted for either admitted version.
    # Purpose: Keep the reviewed set closed and reject omissions, forged members and duplicates.
    It 'UnitT20_RejectsTheSubstitution_<Version>_<Kind>' -TestCases @(
        foreach ($version in @('old','new')) {
            foreach ($kind in @('commit','url','archive','member','missing','duplicate')) { @{Version=$version;Kind=$kind} }
        }
    ) {
        param($Version,$Kind)
        $copy = $script:Adapters[$Version] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        switch ($Kind) {
            'commit' {$copy.authority.commit='0'*40}
            'url' {$copy.authority.archiveUrl='https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/main'}
            'archive' {$copy.authority.archiveSha256='0'*64}
            'member' {$copy.authority.files[0].sha256='0'*64}
            'missing' {$copy.authority.files=@($copy.authority.files | Select-Object -Skip 1)}
            'duplicate' {$copy.authority.files[1]=$copy.authority.files[0]}
        }
        { Assert-PredecessorApprovedSnapshot -Adapter $copy } | Should -Throw
    }

    # Scenario: The actual proposed dispatch chooses legacy or current resolver arguments.
    # Purpose: Avoid passing a new unsupported argument to legacy code and forward900/37 only for8a.
    It 'UnitT30_UsesTheCompatibleResolverCall_<Version>_<Budget>' -TestCases @(
        @{Version='old';Budget=37;Expected=$null},@{Version='new';Budget=900;Expected=900},@{Version='new';Budget=37;Expected=37}
    ) {
        param($Version,$Budget,$Expected)
        function Test-ResolverProbe {
            [CmdletBinding()]
            param($PolicyPath,$ToolName,[switch]$Install,$InstallRoot,$ExpectedGoRuntimeVersion,$OutputPath,[int]$AcquisitionTimeoutSeconds)
            $script:Observed = if ($PSBoundParameters.ContainsKey('AcquisitionTimeoutSeconds')) {$AcquisitionTimeoutSeconds} else {$null}
        }
        $approvedAuthorityCommit=$script:Adapters[$Version].authority.commit
        $AcquisitionTimeoutSeconds=$Budget; $resolverPath='Test-ResolverProbe'; $policyPath='policy'
        $toolName='skillspector'; $installRoot='tools'; $ExpectedGoRuntimeVersion='1.26.0'; $receiptPath='receipt'
        $script:Observed=-1
        . ([scriptblock]::Create($script:Dispatch[0].Extent.Text))
        $script:Observed | Should -Be $Expected
    }

    # Scenario: Trusted fixtures remain immutable when the current consumer is repinned to8a.
    # Purpose: Bind the current exact tuple and require both fixed compatibility test files.
    It 'UnitT40_BindsCurrentConsumerAndIncludesBothTrustedCompatibilityFiles' {
        $script:Adapters.old.authority.commit | Should -BeExactly 'a403abdf038a3346d775431a6908a71cc3d35a5b'
        $script:Adapters.old.authority.archiveSha256 | Should -BeExactly '17154929fadfa63487263db1efcb78f4948195af9c11c25a66432eff3411b2d3'
        $script:Adapters.old.authority.files.Count | Should -Be 14
        $current=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/standard-v1.json') -Raw | ConvertFrom-Json
        $selected=Assert-PredecessorApprovedSnapshot -Adapter $current
        $selected.commit | Should -BeExactly $current.authority.commit
        $fixed=@(Get-RequiredPesterTests -IncludeTrustedPostPromotionTests)
        $fixed | Should -Contain 'BaseAuthorityCompatibility.Tests.ps1'
        $fixed | Should -Contain 'BaseRepositoryAuthorityInventory.Tests.ps1'
    }
}
