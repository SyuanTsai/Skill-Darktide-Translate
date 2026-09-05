# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20
    }

    It 'binds the immutable candidate before any external authority or tool acquisition' {
        $candidateIndex = $script:Validator.IndexOf('status --porcelain=v1')
        $authorityIndex = $script:Validator.IndexOf('Invoke-WebRequest -Uri $adapter.authority.archiveUrl')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $candidateIndex | Should -BeGreaterThan -1
        $authorityIndex | Should -BeGreaterThan $candidateIndex
        $resolverIndex | Should -BeGreaterThan $authorityIndex
    }

    It 'verifies bundle and authority file identities before invoking the central resolver' {
        $archiveHashIndex = $script:Validator.IndexOf('$archiveHash -cne')
        $fileHashIndex = $script:Validator.IndexOf('$fileHash -cne')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $archiveHashIndex | Should -BeGreaterThan -1
        $fileHashIndex | Should -BeGreaterThan $archiveHashIndex
        $resolverIndex | Should -BeGreaterThan $fileHashIndex
    }

    It 'rejects ambiguous JSON evidence and repository-local artifact destinations' {
        $script:Validator | Should -Match 'Assert-NoDuplicateJsonProperties'
        $script:Validator | Should -Match 'not valid unambiguous UTF-8 JSON'
        $script:Validator | Should -Match 'Artifacts root must be outside the candidate repository'
        $script:Validator | Should -Match "Assert-PathWithinRoot.*-Context 'Conformance output'"
    }

    It 'normalizes the event base to one distinct immutable ancestor' {
        $script:Validator | Should -Match 'rev-parse --verify --end-of-options'
        $script:Validator | Should -Match 'merge-base --is-ancestor'
        $script:Validator | Should -Match 'Base commit must be a distinct ancestor'
        $script:Validator | Should -Match 'baseCommit = \$resolvedBaseCommit'
    }

    It 'rejects reparse-backed resolved tool paths before execution' {
        $script:Validator | Should -Match 'Assert-NoReparseAncestors'
        $script:Validator | Should -Match 'Assert-NoReparseAncestors -Path \$path -Context "\$Context installed file"'
        $script:Validator | Should -Match 'is backed by a reparse point'
    }

    It 'verifies host runtimes by absolute path and hash while keeping package files run-owned' {
        $script:Validator | Should -Match 'function Assert-ExternalReceiptFile'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ExternalReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'nodePath'"))
        $script:Validator | Should -Match 'receipt path must be absolute'
        $script:Validator | Should -Match 'runtime file changed after resolution'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'entryPointPath'"))
    }

    It 'freezes all four formal tools and imports the central security gate before scanning' {
        @($script:Adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        $script:Validator | Should -Match '\.\s+\$authorityGatePath -DefineFunctionsOnly'
        $script:Validator | Should -Match 'Assert-AuthorityValidationSecurityGate'
        $script:Validator | Should -Not -Match 'adapter\.security|blockSeverities|security\.(suppressions|exceptions)'
        $script:Validator | Should -Match "'skillspector' = 'NVIDIA/SkillSpector'"
        $script:Validator | Should -Match "'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'"
        $script:Validator | Should -Match "'skill-tools' = 'npm:skill-tools'"
        $script:Validator | Should -Match "'pester' = 'PowerShellGallery:Pester'"

        $freezeIndex = $script:Validator.IndexOf('foreach ($toolName in $expectedSources.Keys)')
        $packageIndex = $script:Validator.IndexOf('skill-validator package validation for')
        $staticIndex = $script:Validator.IndexOf("'--no-llm'")
        $repositoryIndex = $script:Validator.IndexOf('$repositoryReportPath')
        $staticIndex | Should -BeGreaterThan $freezeIndex
        $packageIndex | Should -BeGreaterThan $freezeIndex
        $staticIndex | Should -BeGreaterThan $packageIndex
        $repositoryIndex | Should -BeGreaterThan $staticIndex
    }

    It 'discovers every formal package invocation from catalog source inventory' {
        $script:Validator | Should -Match '\$skillIds\s*=\s*@\(\$integrityReport\.skills'
        $script:Validator | Should -Match 'Assert-SkillSpectorReport'
        $script:Validator | Should -Match 'ExpectedInventoryPaths'
        $script:Validator | Should -Match 'foreach \(\$skillId in \$skillIds\)'
        $script:Validator | Should -Match "validate', 'structure', '--allow-dirs=agents'"
        $script:Validator | Should -Match ([regex]::Escape("'check', `$skillRoot, '--format', 'sarif'"))
    }

    It 'accepts a clean skill-tools SARIF report with no findings' {
        $start = $script:Validator.IndexOf('function Assert-SkillToolsReport')
        $end = $script:Validator.IndexOf('function Assert-PathWithinRoot')
        $start | Should -BeGreaterThan -1
        $end | Should -BeGreaterThan $start
        $skillToolsValidator = $script:Validator.Substring($start, $end - $start)
        $skillToolsValidator | Should -Match '\$driverName -cne ''skill-tools'''
        $skillToolsValidator | Should -Match '\$rules -isnot \[array\]'
        $skillToolsValidator | Should -Match '\$results -isnot \[array\]'
        $skillToolsValidator | Should -Not -Match '\$rules\)\.Count -le 0'
        $skillToolsValidator | Should -Not -Match '\$results\)\.Count -le 0'
        $skillToolsValidator | Should -Match 'skill-tools SARIF contains a malformed or error-level result'
    }

    It 'keeps reports in the run artifacts root and records review boundaries' {
        $script:Validator | Should -Match ([regex]::Escape("Join-Path `$runRoot 'conformance-report.json'"))
        $script:Validator | Should -Match 'canonicalGate = \[ordered\]@'
        $script:Validator | Should -Match "policyPath = 'docs/standards/validation-security-gate.json'"
        $script:Validator | Should -Match "aiReview = 'required-before-release'"
        $script:Validator | Should -Match "humanApproval = 'required-before-release'"
        $script:Validator | Should -Match "postInstallVerification = 'required-after-install'"
        $script:Validator | Should -Match "deviations = 'None'"
    }

    It 'models semantic scan as a deterministic fail-closed conditional stage' {
        $script:Validator | Should -Match 'Test-SecurityRelevantSkillChange'
        $script:Validator | Should -Match '\$staticFindingCount -gt 0'
        $script:Validator | Should -Match 'Triggered SkillSpector semantic scan did not complete'
        $script:Validator | Should -Not -Match 'semantic.*continue|continue.*semantic'
    }
}
