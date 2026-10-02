# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Darktide Translate Standard v1 conformance' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:SourcePath = Join-Path $script:RepositoryRoot 'catalog/source.json'
        $script:AdapterPath = Join-Path $script:RepositoryRoot 'config/standard-v1.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
    }

    It 'uses the canonical schema v2 source inventory and source root' {
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -PathType Container | Should -BeTrue
        $source = Get-Content -LiteralPath $script:SourcePath -Raw | ConvertFrom-Json -Depth 20
        @($source.PSObject.Properties.Name) | Should -Be @('schemaVersion','sourceId','repository','skillsRoot','skills')
        $source.schemaVersion | Should -Be 2
        $source.sourceId | Should -Be 'darktide-translate'
        $source.repository | Should -Be 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
        $source.skillsRoot | Should -Be 'skills'
        @($source.skills) | Should -Be @('auto-update-darktide-mod')
        $projectionRoot = Join-Path $script:RepositoryRoot '.agents/skills'
        if (Test-Path -LiteralPath $projectionRoot) {
            $manifestPath = Join-Path $script:RepositoryRoot '.codex/ai-instructions.manifest.json'
            Test-Path -LiteralPath $manifestPath -PathType Leaf | Should -BeTrue
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 30
            @($manifest.files | Where-Object { $_.artifactType -eq 'skill' }).Count | Should -BeGreaterThan 0
            @($manifest.files | Where-Object { $_.targetPath -like '.agents/skills/*' }).Count | Should -BeGreaterThan 0
        }
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.agents/skills/auto-update-darktide-mod') | Should -BeFalse
    }

    It 'binds one immutable central authority snapshot without a local security policy' {
        $adapter = Get-Content -LiteralPath $script:AdapterPath -Raw | ConvertFrom-Json -Depth 20
        $adapter.schemaVersion | Should -Be 1
        $adapter.standardVersion | Should -Be 'v1'
        $adapter.authority.repository | Should -Be 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $adapter.authority.commit | Should -Match '^[0-9a-f]{40}$'
        $adapter.authority.archiveSha256 | Should -Match '^[0-9a-f]{64}$'
        @($adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/skill-repository-standard.md'
        @($adapter.authority.files.path) | Should -Contain 'docs/standards/validation-security-gate.json'
        @($adapter.authority.files.path) | Should -Contain 'scripts/Resolve-StandardValidationTool.ps1'
        $adapter.deviations | Should -Be 'None'
    }

    It 'exposes the canonical validator and central tool integration' {
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $validator | Should -Match 'Test-Repository\.ps1'
        $validator | Should -Match 'skillspector'
        $validator | Should -Match 'skill-validator'
        $validator | Should -Match 'skill-tools'
        $validator | Should -Match 'Invoke-Pester'
        $validator | Should -Match '\[string\] \$BaseCommit'
        $validator | Should -Match 'repositoryValidatorBytes'
        $validator | Should -Match 'postPesterRepositoryValidatorScript'
        $validator | Should -Match '\[scriptblock\]::Create'
        $validator | Should -Match 'rev-parse --git-common-dir'
        $validator | Should -Match 'Git common metadata directory'
        $validator | Should -Not -Match 'postPesterRepositoryValidatorPath'
    }

    # Scenario: The canonical validator is invoked directly on a non-Windows host.
    # Purpose: Stop before legacy Linux isolation setup, which is outside the supported R4 execution path.
    It 'UnitT50_RejectsUnsupportedHostsBeforeLegacyLinuxSetup' {
        $validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $hostDetection = $validator.IndexOf('$script:IsWindowsHost =', [StringComparison]::Ordinal)
        $linuxSetup = $validator.IndexOf('$script:IsLinuxHost =', [StringComparison]::Ordinal)
        $guard = [regex]::Match($validator,
            "(?s)if \(-not \`$script:IsWindowsHost\) \{\s*throw 'Standard v1 validation requires Windows with PowerShell 7\.'\s*\}")

        $hostDetection | Should -BeGreaterOrEqual 0
        $guard.Success | Should -BeTrue
        $guard.Index | Should -BeGreaterThan $hostDetection
        $guard.Index | Should -BeLessThan $linuxSetup

        $guardBlock = [scriptblock]::Create($guard.Value)
        $previousHostFlag = Get-Variable -Name IsWindowsHost -Scope Script -ErrorAction SilentlyContinue
        try {
            $script:IsWindowsHost = $false
            { & $guardBlock } | Should -Throw -ExpectedMessage 'Standard v1 validation requires Windows with PowerShell 7.'
            $script:IsWindowsHost = $true
            { & $guardBlock } | Should -Not -Throw
        }
        finally {
            if ($null -ne $previousHostFlag) { $script:IsWindowsHost = $previousHostFlag.Value }
            else { Remove-Variable -Name IsWindowsHost -Scope Script -ErrorAction SilentlyContinue }
        }
    }

    It 'routes PR and main CI through the same canonical validator on Windows' {
        $candidate = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-candidate-windows.yml') -Raw
        $main = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
        foreach ($workflow in @($candidate, $main)) {
            $workflow | Should -Match 'scripts/Validate\.ps1'
            $workflow | Should -Match 'runs-on: windows-latest'
            $workflow | Should -Match 'shell: pwsh'
            $workflow | Should -Match 'persist-credentials: false'
            $workflow | Should -Match 'actions/checkout@[0-9a-f]{40}'
            $workflow | Should -Match 'actions/setup-go@[0-9a-f]{40}'
            $workflow | Should -Match 'TrustedTestCommit \$checkoutHead'
            $workflow | Should -Not -Match 'pull_request_target|checks: write|ubuntu-latest'
        }
        $candidate | Should -Match '(?m)^  pull_request:\s*$'
        $main | Should -Match '(?ms)^  push:\s*\r?\n\s+branches:\s*\r?\n\s+- main'
        $main | Should -Not -Match 'publish-head-required-checks|canonical-validation|repository-contract-windows-powershell'
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/skill-validator.yml') | Should -BeFalse
    }
}
