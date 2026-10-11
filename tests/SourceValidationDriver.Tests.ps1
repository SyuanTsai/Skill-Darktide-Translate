# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Explicit Darktide source validation requests' {
    BeforeAll {
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Validate.ps1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'The canonical driver must parse.' }
        $script:RequestFunction = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-SourceValidationRequest'
        }, $false) | Select-Object -First 1
        function Invoke-SourceRequestFixture {
            param([System.Collections.IDictionary] $Bound)
            if ($null -eq $script:RequestFunction) { throw 'The explicit SourceValidation request guard is missing.' }
            $nativeBinding = @'
function Invoke-NativelyBoundSourceGuard {
    [CmdletBinding()]
    param([switch] $PrepareSourceTools, [switch] $SourceValidation, [string] $SourceToolsPath, [string] $ExpectedGoRuntimeVersion)
    Assert-SourceValidationRequest -BoundParameters $PSBoundParameters
}

'@
            $module = New-Module -ScriptBlock ([scriptblock]::Create($script:RequestFunction.Extent.Text + "`n" + $nativeBinding))
            & $module { param($value) Invoke-NativelyBoundSourceGuard @value } $Bound
        }
    }
    # Scenario: A caller requests one explicit setup or one frozen source validation.
    # Purpose: Keep acquisition separate from execution rather than silently falling back to ordinary Core.
    It 'UnitT10_AcceptsSeparateSetupAndSourceRequests' {
        { Invoke-SourceRequestFixture @{ PrepareSourceTools=$true; SourceToolsPath='toolset.json'; ExpectedGoRuntimeVersion='1.27.2' } } | Should -Not -Throw
        { Invoke-SourceRequestFixture @{ SourceValidation=$true; SourceToolsPath='toolset.json' } } | Should -Not -Throw
    }
    # Scenario: A caller invokes the canonical entry without requesting the source gate.
    # Purpose: Prevent an ordinary Core PASS from becoming a required source check.
    It 'UnitT20_RejectsARequestWithoutTheExplicitSourcePurpose' {
        { Invoke-SourceRequestFixture @{} } | Should -Throw '*requires exactly one explicit source purpose*'
    }
    # Scenario: A caller combines acquisition and execution or omits their frozen receipt path.
    # Purpose: Fail closed before downloading or running tools on an ambiguous request.
    It 'UnitT30_RejectsCombinedPurposesAndMissingToolsets' {
        { Invoke-SourceRequestFixture @{ PrepareSourceTools=$true; SourceValidation=$true; SourceToolsPath='toolset.json' } } | Should -Throw '*separate*'
        { Invoke-SourceRequestFixture @{ SourceValidation=$true } } | Should -Throw '*SourceToolsPath*'
    }
    # Scenario: A validation request attempts to resolve a new Go runtime during execution.
    # Purpose: Preserve the frozen setup toolchain and forbid acquisition during validation.
    It 'UnitT40_RejectsRuntimeResolutionDuringSourceValidation' {
        { Invoke-SourceRequestFixture @{ SourceValidation=$true; SourceToolsPath='toolset.json'; ExpectedGoRuntimeVersion='1.27.2' } } |
            Should -Throw '*setup*'
    }
}

Describe 'Reviewed source authority binding' {
    BeforeAll {
        $script:Root = Split-Path -Parent $PSScriptRoot
        $tokens=$null; $errors=$null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'scripts/Validate.ps1'),[ref]$tokens,[ref]$errors)
        $definitions = $ast.FindAll({param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -cin @('Assert-ExactPropertySet','Get-ApprovedSourceAuthorityPin','Assert-AuthorityConfig')
        }, $false)
        $constants = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -cmatch '^\$script:(SourceAuthority|AuthorityRepository)' }).Extent.Text -join "`n"
        $script:AuthorityModule = New-Module -ScriptBlock ([scriptblock]::Create($constants + "`n" + ($definitions.Extent.Text -join "`n")))
        function New-AuthorityConfig { Get-Content (Join-Path $script:Root 'config/standard-v1.json') -Raw | ConvertFrom-Json -Depth 50 }
        function Assert-TestAuthority { param($Config) & $script:AuthorityModule {param($value) Assert-AuthorityConfig -Config $value} $Config }
    }
    # Scenario: the approved complete tuple is presented to the source driver.
    # Purpose: Accept only the reviewed archive and runtime inventory.
    It 'UnitT50_AcceptsTheCompleteReviewedAuthority' {
        { Assert-TestAuthority (New-AuthorityConfig) } | Should -Not -Throw
    }
    # Scenario: a changed commit, archive or required-file digest is substituted.
    # Purpose: Reject each partial authority update before any acquisition.
    It 'UnitT60_RejectsPartialAuthorityUpdates' {
        foreach ($property in @('commit','archiveSha256','archiveUrl')) {
            $config=New-AuthorityConfig; $config.authority.$property='substituted'
            { Assert-TestAuthority $config } | Should -Throw
        }
        $config=New-AuthorityConfig; $config.authority.files[0].sha256='a' * 64
        { Assert-TestAuthority $config } | Should -Throw
    }
    # Scenario: JSON scalars are replaced by type-coercible strings or arrays.
    # Purpose: Preserve exact schema types at the trusted authority boundary.
    It 'UnitT70_RejectsCoercibleAuthorityTypes' {
        $config=New-AuthorityConfig; $config.schemaVersion='1'
        { Assert-TestAuthority $config } | Should -Throw
        $config=New-AuthorityConfig; $config.authority.files[0].sha256=@($config.authority.files[0].sha256)
        { Assert-TestAuthority $config } | Should -Throw
    }
    # Scenario: one required file is duplicated while another is omitted.
    # Purpose: Require the complete unique inventory rather than a matching count.
    It 'UnitT80_RejectsDuplicateRequiredFiles' {
        $config=New-AuthorityConfig; $config.authority.files[1]=$config.authority.files[0]
        { Assert-TestAuthority $config } | Should -Throw
    }
}
