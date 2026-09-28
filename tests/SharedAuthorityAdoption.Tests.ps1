# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Shared authority adoption guards' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $tokens = $null
        $parseErrors = $null
        $script:ValidatorAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'scripts/Validate.ps1'), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -ne 0) { throw 'Canonical validator has parse errors.' }
        $guard = $script:ValidatorAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-ApprovedAuthorityAdapter'
        }, $true)
        if ($null -eq $guard) { throw 'The canonical driver does not implement the shared authority guard.' }
        . ([scriptblock]::Create($guard.Extent.Text))
        $script:ApprovedAdapter = Get-Content -LiteralPath (Join-Path $repoRoot 'config/standard-v1.json') -Raw | ConvertFrom-Json -Depth 40
        $script:ResolverInstallCommand = $script:ValidatorAst.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.Extent.Text -match '^& \$resolverPath .* -ToolName \$toolName -Install '
        }, $true)
        $archiveAssignment = $script:ValidatorAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$archiveHash'
        }
        $archiveGuard = $script:ValidatorAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if ($archiveHash -cne')
        }
        if (@($archiveAssignment).Count -ne 1 -or @($archiveGuard).Count -ne 1) { throw 'Archive verification must be unambiguous.' }
        $script:ArchiveVerification = [scriptblock]::Create($archiveAssignment.Extent.Text + "`n" + $archiveGuard.Extent.Text)
    }

    # Scenario: The current source adapter presents the exact immutable 8a identity and full closure.
    # Purpose: Execute the production guard without Git, network, acquisition, or candidate code.
    It 'UnitT10_AcceptsTheExactSharedAuthoritySnapshot' {
        $script:ApprovedAdapter.authority.commit | Should -Be '8aabd22694a05771f98639f6d726cc9a620eb94b'
        @($script:ApprovedAdapter.authority.files).Count | Should -Be 26
        { Assert-ApprovedAuthorityAdapter -Adapter $script:ApprovedAdapter } | Should -Not -Throw
    }

    # Scenario: A caller changes one binding field while retaining all other approved values.
    # Purpose: Prevent old authority, substituted archives, and mutable URLs from entering acquisition.
    It 'UnitT20_RejectsAChangedAuthorityBinding_<Field>' -TestCases @(
        @{ Field = 'commit'; Value = 'a403abdf038a3346d775431a6908a71cc3d35a5b' }
        @{ Field = 'archiveSha256'; Value = ('0' * 64) }
        @{ Field = 'archiveUrl'; Value = 'https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/main' }
        @{ Field = 'repository'; Value = 'https://example.test/authority.git' }
    ) {
        param($Field, $Value)
        $copy = $script:ApprovedAdapter | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $copy.authority.$Field = $Value
        { Assert-ApprovedAuthorityAdapter -Adapter $copy } | Should -Throw
    }

    # Scenario: A resolver, helper, runner, or contract entry claims a forged member hash.
    # Purpose: Ensure config cannot redefine trusted shared runtime bytes.
    It 'UnitT30_RejectsAChangedRuntimeMember_<Path>' -TestCases @(
        @{ Path = 'scripts/Resolve-PythonWheelClosure.py' }
        @{ Path = 'scripts/Resolve-StandardValidationTool.ps1' }
        @{ Path = 'scripts/Invoke-StandardValidation.ps1' }
        @{ Path = 'docs/standards/standard-validation-contract-v1.json' }
    ) {
        param($Path)
        $copy = $script:ApprovedAdapter | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $entry = @($copy.authority.files | Where-Object path -CEQ $Path)
        $entry.Count | Should -Be 1
        $entry[0].sha256 = '0' * 64
        { Assert-ApprovedAuthorityAdapter -Adapter $copy } | Should -Throw
    }

    # Scenario: An adapter drops or duplicates an authority member.
    # Purpose: Reject incomplete or ambiguous runtime closure before any tool is acquired.
    It 'UnitT40_RejectsAnIncompleteOrDuplicateClosure_<Kind>' -TestCases @(
        @{ Kind = 'missing' }
        @{ Kind = 'duplicate' }
    ) {
        param($Kind)
        $copy = $script:ApprovedAdapter | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        if ($Kind -ceq 'missing') { $copy.authority.files = @($copy.authority.files | Select-Object -Skip 1) }
        else { $copy.authority.files[1] = $copy.authority.files[0] }
        { Assert-ApprovedAuthorityAdapter -Adapter $copy } | Should -Throw
    }

    # Scenario: Acquisition runs with the default budget or a distinct caller-supplied budget.
    # Purpose: Execute the actual resolver call with a probe to prove acquisition limits reach the resolver.
    It 'UnitT50_ForwardsTheIndependentAcquisitionBudget_<Budget>' -TestCases @(
        @{ Budget = 900 }
        @{ Budget = 37 }
    ) {
        param($Budget)
        $parameter = $script:ValidatorAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'AcquisitionTimeoutSeconds' }
        @($parameter).Count | Should -Be 1
        $parameter.DefaultValue.SafeGetValue() | Should -Be 900
        function Test-ResolverProbe {
            param($PolicyPath, $ToolName, [switch]$Install, $InstallRoot, $ExpectedGoRuntimeVersion, $AcquisitionTimeoutSeconds, $OutputPath)
            $script:ObservedAcquisitionBudget = $AcquisitionTimeoutSeconds
            $script:ObservedToolName = $ToolName
        }
        $resolverPath = 'Test-ResolverProbe'
        $policyPath = 'policy-probe'
        $toolName = 'skillspector'
        $installRoot = 'install-probe'
        $ExpectedGoRuntimeVersion = '1.26.0'
        $AcquisitionTimeoutSeconds = $Budget
        $receiptPath = 'receipt-probe'
        $script:ObservedAcquisitionBudget = $null
        . ([scriptblock]::Create($script:ResolverInstallCommand.Extent.Text))
        $script:ObservedAcquisitionBudget | Should -Be $Budget
        $script:ObservedToolName | Should -Be 'skillspector'
    }

    # Scenario: The archive bytes either match their declared hash or are substituted before extraction.
    # Purpose: Execute the actual hash computation and rejection from the production driver without extraction or network.
    It 'UnitT60_RejectsSubstitutedArchiveBytesBeforeExtraction' {
        $archivePath = Join-Path $TestDrive 'archive-probe.zip'
        [IO.File]::WriteAllBytes($archivePath, [byte[]]@(1, 2, 3, 4))
        $adapter = [pscustomobject]@{ authority = [pscustomobject]@{ archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() } }
        { . $script:ArchiveVerification } | Should -Not -Throw
        [IO.File]::WriteAllBytes($archivePath, [byte[]]@(1, 2, 3, 5))
        { . $script:ArchiveVerification } | Should -Throw '*Authority archive SHA-256 does not match*'
    }

    # Scenario: The verified authority supplies an entry-point contract that can block this consumer.
    # Purpose: Run the shared gate before acquiring tools, with the real repository and canonical path.
    It 'UnitT70_EnforcesTheSharedEntryPointContractBeforeToolAcquisition' {
        $command = $script:ValidatorAst.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Assert-AuthorityConsumerEntryPointContract'
        }, $true)
        $command | Should -Not -BeNullOrEmpty
        $command.Extent.StartOffset | Should -BeLessThan $script:ResolverInstallCommand.Extent.StartOffset
        function Assert-AuthorityConsumerEntryPointContract {
            param($RepositoryRoot, $CanonicalValidatorPath, $Policy)
            $script:ObservedRepositoryRoot = $RepositoryRoot
            $script:ObservedCanonicalPath = $CanonicalValidatorPath
            $script:ObservedPolicy = $Policy
            throw 'entry-point-probe-blocked'
        }
        $repoRoot = 'candidate-probe'
        $validationSecurityGate = [pscustomobject]@{ identity = 'verified-authority-policy' }
        { . ([scriptblock]::Create($command.Extent.Text)) } | Should -Throw '*entry-point-probe-blocked*'
        $script:ObservedRepositoryRoot | Should -Be $repoRoot
        $script:ObservedCanonicalPath | Should -Be 'scripts/Validate.ps1'
        $script:ObservedPolicy.identity | Should -Be 'verified-authority-policy'
    }
}
