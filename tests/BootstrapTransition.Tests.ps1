# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide bootstrap transition' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:Supervisor = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:ProtectedWorkflow = Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Layout = Get-TestRepositoryLayout -RepositoryRoot $script:RepositoryRoot

        function New-ValidatorGitSnapshot {
            param([Parameter(Mandatory = $true)][string] $Destination)

            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $script:RepositoryRoot -Force |
                    Where-Object { $_.Name -cne '.git' })) {
                Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
            }
            & git -C $Destination init --quiet --initial-branch=main
            if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the validator Git snapshot.' }
            & git -C $Destination config user.name 'Protected Validator Snapshot'
            & git -C $Destination config user.email 'protected-validator@example.invalid'
            & git -C $Destination add --all
            & git -C $Destination commit --quiet -m 'protected validator snapshot'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to commit the validator Git snapshot.' }
            return $Destination
        }

        $script:ValidatorRepositoryRoot = New-ValidatorGitSnapshot `
            -Destination (Join-Path $TestDrive 'validator-repository-snapshot')
    }

    It 'UnitT10_ValidatesExactlyOneBoundedRepositoryLayout' {
        # Scenario: The protected suite runs against either the current legacy tree or a Standard v1 migration candidate.
        # Purpose: Keep both accepted structures explicit while requiring the matching validator mode.
        if ($script:Layout.Name -ceq 'legacy') {
            $reportPath = Join-Path $TestDrive 'bootstrap-repository-report.json'
            $output = @(& $script:RepositoryValidator `
                    -RepositoryRoot $script:ValidatorRepositoryRoot `
                    -BootstrapTransition `
                    -OutputPath $reportPath)
            $result = ($output | Select-Object -Last 1) | ConvertFrom-Json

            $result.result | Should -Be 'passed'
            $result.validationMode | Should -Be 'bootstrap-transition'
            $result.skillsRoot | Should -Be '.agents/skills'
            $result.activeSkillCount | Should -Be 1
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
        }
        else {
            $reportPath = Join-Path $TestDrive 'standard-v1-repository-report.json'
            $output = @(& $script:RepositoryValidator `
                    -RepositoryRoot $script:ValidatorRepositoryRoot `
                    -OutputPath $reportPath)
            $result = ($output | Select-Object -Last 1) | ConvertFrom-Json

            $result.result | Should -Be 'passed'
            $result.sourceId | Should -Be 'darktide-translate'
            $result.skillsRoot | Should -Be 'skills'
            $result.activeSkillCount | Should -Be 1
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
        }
    }

    It 'UnitT20_RejectsAnUnauthorizedValidatorMode' {
        # Scenario: A caller selects a validator mode that does not belong to the repository's bounded layout.
        # Purpose: Prevent legacy authorization from being reused after Standard v1 promotion and prevent normal validation from bypassing legacy transition authorization.
        if ($script:Layout.Name -ceq 'legacy') {
            { & $script:RepositoryValidator -RepositoryRoot $script:ValidatorRepositoryRoot } |
                Should -Throw '*Standard v1*'
        }
        else {
            { & $script:RepositoryValidator -RepositoryRoot $script:ValidatorRepositoryRoot -BootstrapTransition } |
                Should -Throw '*catalog/skills-catalog.json fixture*'
        }
    }

    It 'UnitT25_RejectsMixedMissingAndUnauthorizedLayouts' {
        # Scenario: A migration candidate has both layout markers, only part of a layout, or an unrelated source root.
        # Purpose: Prove the protected test resolver does not widen the migration path to arbitrary directories or silently accept missing configuration.
        $mixedRoot = Join-Path $TestDrive 'mixed-layout'
        New-Item -ItemType Directory -Path (Join-Path $mixedRoot 'catalog'), (Join-Path $mixedRoot 'config'),
            (Join-Path $mixedRoot '.agents/skills/auto-update-darktide-mod'), (Join-Path $mixedRoot 'skills/auto-update-darktide-mod') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mixedRoot 'catalog/skills-catalog.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $mixedRoot 'catalog/source.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $mixedRoot 'config/standard-v1.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $mixedRoot } |
            Should -Throw '*mixed*'

        $incompleteRoot = Join-Path $TestDrive 'incomplete-layout'
        New-Item -ItemType Directory -Path (Join-Path $incompleteRoot 'catalog') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $incompleteRoot 'catalog/source.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $incompleteRoot } |
            Should -Throw '*incomplete or unauthorized*'

        $unauthorizedRoot = Join-Path $TestDrive 'unauthorized-layout'
        New-Item -ItemType Directory -Path (Join-Path $unauthorizedRoot 'catalog'), (Join-Path $unauthorizedRoot 'extensions/skills/auto-update-darktide-mod') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $unauthorizedRoot 'catalog/source.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $unauthorizedRoot } |
            Should -Throw '*incomplete or unauthorized*'

        if ($script:Layout.Name -ceq 'standard-v1') {
            $missingConfigRoot = New-ValidatorGitSnapshot `
                -Destination (Join-Path $TestDrive 'standard-v1-missing-config')
            Remove-Item -LiteralPath (Join-Path $missingConfigRoot 'config/standard-v1.json') -Force
            { & $script:RepositoryValidator -RepositoryRoot $missingConfigRoot } |
                Should -Throw '*standard-v1.json*'

            $mixedCandidateRoot = New-ValidatorGitSnapshot `
                -Destination (Join-Path $TestDrive 'standard-v1-mixed-candidate')
            Set-Content -LiteralPath (Join-Path $mixedCandidateRoot 'catalog/skills-catalog.json') -Value '{}'
            { & $script:RepositoryValidator -RepositoryRoot $mixedCandidateRoot } |
                Should -Throw '*must not coexist*'
        }
    }

    It 'UnitT30_SelectsBootstrapOnlyWhenTheCandidateHasNotMigratedToStandardV1' {
        # Scenario: The protected workflow sees either the current bootstrap layout or the migrated layout.
        # Purpose: Keep transition success explicit and prevent a mixed or post-migration tree from taking the legacy path.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match '\[switch\] \$BootstrapTransition'
        $workflow | Should -Match 'BootstrapTransition'
        $workflow | Should -Match 'config/standard-v1\.json'
        $workflow | Should -Match 'catalog/skills-catalog\.json'
    }

    It 'UnitT40_UsesAnOSNativeWindowsProcessSnapshotForCleanup' {
        # Scenario: The host denies WMI process enumeration even though native process controls are available.
        # Purpose: Keep process-tree cleanup bound to an OS-native snapshot instead of weakening identity or cleanup assertions.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'CreateToolhelp32Snapshot'
        $supervisor | Should -Match 'Process32FirstW'
        $supervisor | Should -Match 'Process32NextW'
        $supervisor | Should -Not -Match 'Get-CimInstance\s+-ClassName\s+Win32_Process'
    }

    It 'UnitT50_BindsBootstrapToTheExpectedChangedPathSetAndBaseCommit' {
        # Scenario: A bootstrap candidate could otherwise select the legacy path while changing arbitrary repository content.
        # Purpose: Require an immutable base comparison and a narrow transition-only changed-path contract.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'Bootstrap transition requires a distinct base commit'
        $supervisor | Should -Match 'Bootstrap transition changed-path allowlist'
        $supervisor | Should -Match '\.github/workflows/standard-v1-protected\.yml'
        $supervisor | Should -Match 'scripts/Test-Repository\.ps1'
        $supervisor | Should -Match 'scripts/Validate\.ps1'
        $supervisor | Should -Match 'tests/validate-windows-powershell\.ps1'
        $supervisor | Should -Match 'Bootstrap transition bounded cancellation probe'
    }

    It 'UnitT52_AllowsExactBootstrapMaintenancePathsWithoutRequiringAnchorEdits' {
        # Scenario: A reviewed maintenance PR changes exactly one trusted test while every anchor remains a regular blob in both commits.
        # Purpose: Permit the fixed twelve-suite and TestSupport foundation without widening bootstrap to catalog, config, or Skill content.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-BootstrapTransitionChangedPaths'
        }, $true))
        $functionAst.Count | Should -Be 1
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst[0].Extent.Text))

        $gitPath = [IO.Path]::GetFullPath([string](Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path)
        $maintenancePaths = @(
            'tests/BootstrapTransition.Tests.ps1', 'tests/CanonicalValidation.Tests.ps1',
            'tests/LocalizationWorkset.Tests.ps1', 'tests/ModUpdateAutomation.Tests.ps1',
            'tests/RepositoryContract.Tests.ps1', 'tests/RepositoryValidation.Tests.ps1',
            'tests/Schema15Coordination.Tests.ps1', 'tests/Schema15SourceAcquisition.Tests.ps1',
            'tests/SkillContract.Tests.ps1', 'tests/SourcePin.Tests.ps1',
            'tests/StandardV1Conformance.Tests.ps1', 'tests/Test-Repository.Tests.ps1',
            'tests/TestSupport.ps1'
        )
        try {
            foreach ($maintenancePath in $maintenancePaths) {
                $fixture = Join-Path $TestDrive ("bootstrap-maintenance-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fixture -Force | Out-Null
                foreach ($anchor in @(
                    '.github/workflows/standard-v1-protected.yml', 'scripts/Test-Repository.ps1',
                    'scripts/Validate.ps1', 'tests/validate-windows-powershell.ps1'
                )) {
                    $anchorPath = Join-Path $fixture $anchor
                    New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                    [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
                }
                $path = Join-Path $fixture $maintenancePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [IO.File]::WriteAllText($path, 'base test', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture init --quiet --initial-branch=main
                & $gitPath -C $fixture config user.name 'Bootstrap fixture'
                & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
                & $gitPath -C $fixture add --all
                & $gitPath -C $fixture commit --quiet -m base
                $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                [IO.File]::WriteAllText($path, 'maintenance update', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture add -- $maintenancePath
                & $gitPath -C $fixture commit --quiet -m maintenance
                $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                {
                    & $guardModule {
                        param($GitPath, $RepositoryRoot, $BaseCommit, $CandidateCommit)
                        Assert-BootstrapTransitionChangedPaths -GitPath $GitPath -RepositoryRoot $RepositoryRoot -BaseCommit $BaseCommit -CandidateCommit $CandidateCommit
                    } $gitPath $fixture $baseCommit $candidateCommit
                } | Should -Not -Throw
            }
        }
        finally {
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT54_RejectsBootstrapPathsAndStatusesOutsideTheExactContract' {
        # Scenario: A bootstrap range contains a catalog, Skill, or unknown path change, a deletion, or a rename.
        # Purpose: Keep maintenance within the exact allowed paths and A/M statuses.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-BootstrapTransitionChangedPaths'
        }, $true))
        $functionAst.Count | Should -Be 1
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst[0].Extent.Text))
        $gitPath = [IO.Path]::GetFullPath([string](Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path)
        try {
            foreach ($case in @(
                [pscustomobject]@{ Name = 'catalog'; Path = 'catalog/source.json'; Action = 'modify' },
                [pscustomobject]@{ Name = 'skill'; Path = 'skills/auto-update-darktide-mod/SKILL.md'; Action = 'modify' },
                [pscustomobject]@{ Name = 'unknown'; Path = 'docs/unrelated.md'; Action = 'modify' },
                [pscustomobject]@{ Name = 'delete'; Path = 'tests/TestSupport.ps1'; Action = 'delete' },
                [pscustomobject]@{ Name = 'rename'; Path = 'tests/TestSupport.ps1'; Action = 'rename' }
            )) {
                $fixture = Join-Path $TestDrive ("bootstrap-reject-$($case.Name)-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fixture -Force | Out-Null
                foreach ($anchor in @(
                    '.github/workflows/standard-v1-protected.yml', 'scripts/Test-Repository.ps1',
                    'scripts/Validate.ps1', 'tests/validate-windows-powershell.ps1'
                )) {
                    $anchorPath = Join-Path $fixture $anchor
                    New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                    [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
                }
                $casePath = Join-Path $fixture $case.Path
                New-Item -ItemType Directory -Path (Split-Path -Parent $casePath) -Force | Out-Null
                [IO.File]::WriteAllText($casePath, 'base payload', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture init --quiet --initial-branch=main
                & $gitPath -C $fixture config user.name 'Bootstrap fixture'
                & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
                & $gitPath -C $fixture add --all
                & $gitPath -C $fixture commit --quiet -m base
                $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                switch ($case.Action) {
                    'modify' { [IO.File]::WriteAllText($casePath, 'changed payload', [Text.UTF8Encoding]::new($false)) }
                    'delete' { Remove-Item -LiteralPath $casePath -Force }
                    'rename' { Move-Item -LiteralPath $casePath -Destination ($casePath + '.renamed') }
                }
                & $gitPath -C $fixture add --all
                & $gitPath -C $fixture commit --quiet -m $case.Name
                $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
                {
                    & $guardModule {
                        param($GitPath, $RepositoryRoot, $BaseCommit, $CandidateCommit)
                        Assert-BootstrapTransitionChangedPaths -GitPath $GitPath -RepositoryRoot $RepositoryRoot -BaseCommit $BaseCommit -CandidateCommit $CandidateCommit
                    } $gitPath $fixture $baseCommit $candidateCommit
                } | Should -Throw
            }
        }
        finally {
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT56_RequiresEveryBootstrapAnchorToBeARegularTrackedBlobAtBothRangeEnds' {
        # Scenario: A maintenance-only diff retains an absent, directory, or symbolic-link anchor at both range ends; a separate legacy-shaped range restores a missing base anchor while changing all four anchors.
        # Purpose: Keep all four trust anchors as tracked regular blobs at both endpoints of maintenance and legacy four-anchor updates.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-BootstrapTransitionChangedPaths'
        }, $true))
        $functionAst.Count | Should -Be 1
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst[0].Extent.Text))
        $gitPath = [IO.Path]::GetFullPath([string](Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path)
        $anchors = @(
            '.github/workflows/standard-v1-protected.yml', 'scripts/Test-Repository.ps1',
            'scripts/Validate.ps1', 'tests/validate-windows-powershell.ps1'
        )
        $invokeGuard = {
            param($GitPath, $GuardModule, $Fixture, $BaseCommit, $CandidateCommit)
            & $GuardModule {
                param($InnerGitPath, $RepositoryRoot, $InnerBaseCommit, $InnerCandidateCommit)
                Assert-BootstrapTransitionChangedPaths -GitPath $InnerGitPath -RepositoryRoot $RepositoryRoot -BaseCommit $InnerBaseCommit -CandidateCommit $InnerCandidateCommit
            } $GitPath $Fixture $BaseCommit $CandidateCommit
        }
        try {
            foreach ($case in @('missing', 'tree', 'symlink')) {
                $fixture = Join-Path $TestDrive ("bootstrap-anchor-$case-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fixture -Force | Out-Null
                foreach ($anchor in $anchors) {
                    $anchorPath = Join-Path $fixture $anchor
                    New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                    [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
                }
                $supportPath = Join-Path $fixture 'tests/TestSupport.ps1'
                [IO.File]::WriteAllText($supportPath, 'base support', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture init --quiet --initial-branch=main
                & $gitPath -C $fixture config user.name 'Bootstrap fixture'
                & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
                $anchorPath = Join-Path $fixture 'scripts/Validate.ps1'
                $symlinkObjectId = ''
                switch ($case) {
                    'missing' { Remove-Item -LiteralPath $anchorPath -Force }
                    'tree' {
                        Remove-Item -LiteralPath $anchorPath -Force
                        New-Item -ItemType Directory -Path $anchorPath -Force | Out-Null
                        [IO.File]::WriteAllText((Join-Path $anchorPath 'nested.ps1'), 'nested', [Text.UTF8Encoding]::new($false))
                    }
                    'symlink' {
                        $symlinkObjectId = ('symlink-target' | & $gitPath -C $fixture hash-object -w --stdin).Trim()
                    }
                }
                & $gitPath -C $fixture add --all
                if ($case -ceq 'symlink') {
                    & $gitPath -C $fixture update-index --add --cacheinfo "120000,$symlinkObjectId,scripts/Validate.ps1"
                }
                & $gitPath -C $fixture commit --quiet -m "base-$case"
                $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                [IO.File]::WriteAllText($supportPath, 'maintenance support', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture add -- 'tests/TestSupport.ps1'
                & $gitPath -C $fixture commit --quiet -m "maintenance-$case"
                $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
                $failure = $null
                try {
                    & $invokeGuard $gitPath $guardModule $fixture $baseCommit $candidateCommit
                }
                catch {
                    $failure = $_
                }
                $failure | Should -Not -BeNullOrEmpty
                $failure.Exception.Message | Should -Match 'tracked regular trust anchor'
            }

            $fixture = Join-Path $TestDrive ('bootstrap-anchor-base-missing-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            foreach ($anchor in $anchors) {
                $anchorPath = Join-Path $fixture $anchor
                New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
            }
            $supportPath = Join-Path $fixture 'tests/TestSupport.ps1'
            [IO.File]::WriteAllText($supportPath, 'base support', [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath (Join-Path $fixture 'scripts/Validate.ps1') -Force
            & $gitPath -C $fixture init --quiet --initial-branch=main
            & $gitPath -C $fixture config user.name 'Bootstrap fixture'
            & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m base-missing-anchor
            $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            foreach ($anchor in $anchors) {
                $anchorPath = Join-Path $fixture $anchor
                New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                [IO.File]::WriteAllText($anchorPath, "candidate $anchor", [Text.UTF8Encoding]::new($false))
            }
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m candidate-restores-anchor
            $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            $failure = $null
            try {
                & $invokeGuard $gitPath $guardModule $fixture $baseCommit $candidateCommit
            }
            catch {
                $failure = $_
            }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -Match 'tracked regular trust anchor'

            $fixture = Join-Path $TestDrive ('bootstrap-anchor-legacy-success-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            foreach ($anchor in $anchors) {
                $anchorPath = Join-Path $fixture $anchor
                New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
            }
            & $gitPath -C $fixture init --quiet --initial-branch=main
            & $gitPath -C $fixture config user.name 'Bootstrap fixture'
            & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m base
            $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            foreach ($anchor in $anchors) {
                [IO.File]::WriteAllText((Join-Path $fixture $anchor), "candidate $anchor", [Text.UTF8Encoding]::new($false))
            }
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m candidate-all-anchors
            $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            {
                & $invokeGuard $gitPath $guardModule $fixture $baseCommit $candidateCommit
            } | Should -Not -Throw
        }
        finally {
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT58_BindsTheCanonicalEvidenceDigestInsideTheNamedExportStep' {
        # Scenario: Workflow text omits, changes, or places the canonical evidence digest outside its clean export step.
        # Purpose: Bind the exported evidence bytes to the canonical-validation digest at the only step allowed to publish them.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1'),
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $assertTrueAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-True'
        }, $true))
        $bindingAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-WorkflowEvidenceDigestBinding'
        }, $true))
        $assertTrueAst.Count | Should -Be 1
        $bindingAst.Count | Should -Be 1
        $contractSource = @($assertTrueAst[0].Extent.Text, $bindingAst[0].Extent.Text) -join [Environment]::NewLine
        $contractModule = New-Module -ScriptBlock ([scriptblock]::Create($contractSource))
        try {
            $validWorkflow = @'
steps:
  - name: Export canonical evidence for clean upload
    id: export-evidence
    if: ${{ success() }}
    shell: pwsh
    env:
      EXPECTED_EVIDENCE_SHA256: ${{ steps.canonical-validation.outputs.standard_v1_evidence_sha256 }}
    run: echo export
'@
            {
                & $contractModule { param($Workflow) Assert-WorkflowEvidenceDigestBinding -Workflow $Workflow } $validWorkflow
            } | Should -Not -Throw
            foreach ($invalidWorkflow in @(
                ($validWorkflow -replace '(?m)^\s*EXPECTED_EVIDENCE_SHA256:.*\r?\n', ''),
                ($validWorkflow -replace 'steps\.canonical-validation\.outputs\.standard_v1_evidence_sha256', 'steps.other.outputs.evidence_sha256'),
@'
steps:
  - name: Verify canonical validation evidence
    env:
      EXPECTED_EVIDENCE_SHA256: ${{ steps.canonical-validation.outputs.standard_v1_evidence_sha256 }}
    run: echo verify
  - name: Export canonical evidence for clean upload
    id: export-evidence
    if: ${{ success() }}
    shell: pwsh
    run: echo export
'@
            )) {
                {
                    & $contractModule { param($Workflow) Assert-WorkflowEvidenceDigestBinding -Workflow $Workflow } $invalidWorkflow
                } | Should -Throw
            }
        }
        finally {
            Remove-Module $contractModule -Force
        }
    }

    It 'UnitT59_ValidatesTheCanonicalDigestBeforeExportingEvidence' {
        # Scenario: A normal JSON evidence file is exported with the correct, wrong, absent, and malformed canonical digest values.
        # Purpose: Bind both exported values to the exact bytes and canonical digest emitted by validation.
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw
        $stepMatch = [regex]::Match(
            $workflow,
            '(?ms)^ {6}- name: Export canonical evidence for clean upload\r?\n(?<step>.*?)(?=^ {6}- name:|\z)'
        )
        $stepMatch.Success | Should -BeTrue
        $runMatch = [regex]::Match(
            $stepMatch.Groups['step'].Value,
            '(?ms)^ {8}run:\s*\|\r?\n(?<script>(?:^ {10}.*(?:\r?\n|$))+)'
        )
        $runMatch.Success | Should -BeTrue
        $exportScript = [regex]::Replace($runMatch.Groups['script'].Value, '(?m)^ {10}', '')
        $exportBlock = [scriptblock]::Create($exportScript)

        $evidencePath = Join-Path $TestDrive 'darktide-translate-conformance-report.json'
        $githubOutputPath = Join-Path $TestDrive 'github-output.txt'
        $evidenceBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"result":"passed"}')
        [IO.File]::WriteAllBytes($evidencePath, $evidenceBytes)
        [IO.File]::WriteAllText($githubOutputPath, '', [Text.UTF8Encoding]::new($false))
        $expectedDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $evidencePath).Hash.ToLowerInvariant()
        $wrongDigest = if ($expectedDigest -ceq ('0' * 64)) { '1' * 64 } else { '0' * 64 }

        $savedRunnerTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP', [EnvironmentVariableTarget]::Process)
        $savedGithubOutput = [Environment]::GetEnvironmentVariable('GITHUB_OUTPUT', [EnvironmentVariableTarget]::Process)
        $savedExpectedDigest = [Environment]::GetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $TestDrive, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $githubOutputPath, [EnvironmentVariableTarget]::Process)

            [Environment]::SetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', $expectedDigest, [EnvironmentVariableTarget]::Process)
            { & $exportBlock } | Should -Not -Throw
            $exportOutput = Get-Content -LiteralPath $githubOutputPath -Raw
            $base64Matches = @([regex]::Matches($exportOutput, '(?m)^evidence_base64=(?<value>[A-Za-z0-9+/=]*)\r?$'))
            $digestMatches = @([regex]::Matches($exportOutput, '(?m)^evidence_sha256=(?<value>[0-9a-f]{64})\r?$'))
            $base64Matches.Count | Should -Be 1
            $digestMatches.Count | Should -Be 1
            $decodedEvidenceBytes = [Convert]::FromBase64String($base64Matches[0].Groups['value'].Value)
            [BitConverter]::ToString($decodedEvidenceBytes) | Should -Be ([BitConverter]::ToString($evidenceBytes))
            $digestMatches[0].Groups['value'].Value | Should -Be $expectedDigest

            foreach ($invalidCase in @(
                [pscustomobject]@{ Digest = $wrongDigest; ExpectedMessage = 'Canonical evidence digest does not match the canonical validation output.' },
                [pscustomobject]@{ Digest = $null; ExpectedMessage = 'Canonical validation did not emit one lowercase evidence SHA-256 output.' },
                [pscustomobject]@{ Digest = 'not-a-sha256'; ExpectedMessage = 'Canonical validation did not emit one lowercase evidence SHA-256 output.' }
            )) {
                [IO.File]::WriteAllText($githubOutputPath, '', [Text.UTF8Encoding]::new($false))
                [Environment]::SetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', $invalidCase.Digest, [EnvironmentVariableTarget]::Process)
                $failure = $null
                try {
                    & $exportBlock
                }
                catch {
                    $failure = $_
                }
                $failure | Should -Not -BeNullOrEmpty
                $failure.Exception.Message | Should -Be $invalidCase.ExpectedMessage
                (Get-Item -LiteralPath $githubOutputPath -Force).Length | Should -Be 0
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $savedRunnerTemp, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $savedGithubOutput, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', $savedExpectedDigest, [EnvironmentVariableTarget]::Process)
        }
    }

    It 'UnitT60_UsesAWindowsLowIntegrityBoundaryForCandidateWrites' {
        # Scenario: The candidate runs under the same runner account as the trusted supervisor.
        # Purpose: Require a mandatory-integrity boundary so candidate code cannot write up into supervisor-owned roots.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'S-1-16-4096'
        $supervisor | Should -Match 'TokenIntegrityLevel'
        $supervisor | Should -Match 'SetTokenInformation'
        $supervisor | Should -Match 'SetLowIntegrityKernelObject'
        $supervisor | Should -Match 'CreateRestrictedToken'
        $supervisor | Should -Match 'Set-WindowsLowIntegrityDirectory'
        $supervisor | Should -Match "'/setintegritylevel'"
    }

    It 'UnitT70_PinsTheTrustedPesterRegressionInventory' {
        # Scenario: Candidate code removes a protected regression file before the isolated run.
        # Purpose: Require the base-owned supervisor to invoke a fixed, non-empty test inventory.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match "'BootstrapTransition\.Tests\.ps1'"
        $supervisor | Should -Match "'RepositoryValidation\.Tests\.ps1'"
        $supervisor | Should -Match '\$requiredPesterPaths'
        $supervisor | Should -Match '\$pesterConfiguration = New-PesterConfiguration'
        $supervisor | Should -Match '\$pesterConfiguration\.Run\.Path = \$requiredPesterPaths'
        $supervisor | Should -Match '\$pesterConfiguration\.Run\.PassThru = \$true'
        $supervisor | Should -Match '\$pesterConfiguration\.TestRegistry\.Enabled = \$false'
        $supervisor | Should -Match 'Invoke-Pester -Configuration \$pesterConfiguration'
        $supervisor | Should -Not -Match '\$requiredPesterTests = @\(\)'
    }

    It 'UnitT80_ProjectsLinuxEtcWithoutArchiveOwnershipCopy' {
        # Scenario: A user namespace cannot read every host /etc file or preserve host-root ownership.
        # Purpose: Build a private readable projection without mutating the host bind or aborting on archive metadata.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'system_root.*=.*"/etc"'
        $supervisor | Should -Match '-type f -readable'
        $supervisor | Should -Match '/bin/cat -- "\$source"'
        $supervisor | Should -Not -Match '/bin/cp -a'
    }

    It 'UnitT90SeparatesChildOutputAndTrustedPesterContent' {
        # Scenario: Low-integrity children must write only to a labeled output root, while tests come from trusted Git bytes.
        # Purpose: Keep scanner receipts and Pester content outside candidate-writable paths and out of the worker's authority.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match "'low-integrity-output'"
        $supervisor | Should -Match '''-PesterChildWritableRoot'', \$childOutputRoot'
        $supervisor | Should -Match '-ChildWritableRoot \$ChildWritableRoot'
        $supervisor | Should -Match 'Expand-TrustedGitArchive'
        $supervisor | Should -Match 'Assert-TrustedGitTreeFile'
        $supervisor | Should -Match '\$trustedPesterCommit'
        $supervisor | Should -Match '(?s)Expand-TrustedGitArchive.*?-Revision \$trustedPesterCommit.*?-PathSpec @\(''tests''\).*?-Context ''Trusted base Pester tests'''
        $supervisor | Should -Match '(?s)\$candidateMirrorTestsRoot.*?Remove-Item'
        $supervisor | Should -Match '\$readOnlyPaths = @\('
        $supervisor | Should -Match 'Invoke-ProtectedPesterRunspace'
        $supervisor | Should -Match 'CreateOutOfProcessRunspace'
        $supervisor | Should -Match 'AddScript\(\$workerScriptText\)'
        $supervisor | Should -Match 'InvocationStateInfo\.State'
        $supervisor | Should -Match 'Assert-LinuxAggregateResourceUsage'
        $supervisor | Should -Match 'Get-LinuxAggregateClockTicksPerSecond'
        $supervisor | Should -Match 'Get-LinuxCgroupCpuUsage'
        $supervisor | Should -Match '\$fields\[13\].*\$fields\[14\]'
        $supervisor | Should -Match 'CODEX_PESTER_CGROUP_ROOT'
        $supervisor | Should -Match 'Get-LinuxPesterCgroupRoot'
        $supervisor | Should -Match '/proc/\$PID/cgroup'
        $supervisor | Should -Match 'New-LinuxPesterCgroup'
        $supervisor | Should -Match 'memory\.max'
        $supervisor | Should -Match 'cpu\.stat'
        $supervisor | Should -Match 'usage_usec'
        $supervisor | Should -Match 'cgroup\.procs'
        $supervisor | Should -Match 'cgroup\.events'
        $supervisor | Should -Match 'populated'
        $supervisor | Should -Match 'Start-Sleep -Milliseconds 25'
        $supervisor | Should -Match 'linuxPesterCgroupCleanupException'
        $supervisor | Should -Match 'Add-LinuxProcessTreeToCgroup'
        $workflow | Should -Match 'Delegate Linux cgroup v2 subtree'
        $workflow | Should -Match 'CODEX_PESTER_CGROUP_ROOT'
        $workflow | Should -Match 'CODEX_PESTER_VALIDATOR_CGROUP'
        $workflow | Should -Match 'root_subtree_control'
        $workflow | Should -Match '\+cpu \+memory'
        $workflow | Should -Match 'cgroup\.subtree_control'
        $workflow | Should -Match 'cgroup\.threads'
        $workflow | Should -Match 'cgroup_parent/cgroup\.procs'
        $workflow | Should -Match 'sudo -n chown'
        $workflow | Should -Match 'trusted-validator'
        $workflow | Should -Match 'Remove delegated Linux cgroup subtree'
        $supervisor | Should -Match 'Start-WindowsSuspendedProcess'
        $supervisor | Should -Match '\.CopyToAsync\('
        $supervisor | Should -Match '--kill-child'
        $supervisor | Should -Match '--as=2147483648'
        $supervisor | Should -Match '--cpu=300'
        $supervisor | Should -Match '\[switch\] \$ProtectedPesterServerProxy'
        $supervisor | Should -Match '\$PesterProxyReadOnlyPathsJson'
        $supervisor | Should -Match 'EnvironmentVariables\.Remove\(\$gateEnvironmentName\)'
        $supervisor | Should -Match '\[ ! -e "\$target" \]'
        $supervisor | Should -Match 'exec "\$chroot_path"'
        $supervisor | Should -Match 'exec chroot "\$sandbox_root"'
        $supervisor | Should -Match 'SGV1-Pester-Result:'
        $supervisor | Should -Match 'Invoke-TrustedPowerShellProcess'
        $supervisor | Should -Match 'Invoke-ProtectedPesterSupervisor'
        $supervisor | Should -Match '\$trustedPesterSupervisorMarker'
        $supervisor | Should -Match '\$completionMarker = \(\[Console\]::In\.ReadToEnd\(\)\)'
        $supervisor | Should -Match 'trusted-parent-post-exit'
        $supervisor | Should -Match '\$completionAttestationNonce'
        $supervisor | Should -Not -Match '\$workerMarkerVariableName'
        $supervisor | Should -Not -Match '\$workerResultLines'
        $supervisor | Should -Not -Match '-StandardInput \$pesterWorkerMarker'
        $supervisor | Should -Not -Match '\$pesterSupervisorPath\s*='
    }

    It 'UnitT100_BindsReplacementObjectDiscoveryToTheCandidateWorktree' {
        # Scenario: Git does not trust the runner checkout through ambient global configuration.
        # Purpose: Make the replacement-object preflight use the same explicit repository trust boundary as every later Git read.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match '(?s)function Assert-NoGitReplacementObjects.*?safe\.directory=\$RepositoryRoot.*?core\.worktree=\$RepositoryRoot.*?rev-parse --git-path refs/replace'
        $workflow | Should -Match '(?s)\$gitPath\s*=.*?\$gitArguments\s*=\s*@\(.*?safe\.directory=\$repositoryRoot.*?core\.worktree=\$repositoryRoot.*?rev-parse HEAD.*?merge-base --is-ancestor'

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:Supervisor,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Assert-NoGitReplacementObjects'
            }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))

        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
        $emptyGitConfig = Join-Path $TestDrive 'empty-git-config'
        New-Item -ItemType File -Path $emptyGitConfig -Force | Out-Null
        $savedAssumeDifferentOwner = $env:GIT_TEST_ASSUME_DIFFERENT_OWNER
        $savedGlobalConfig = $env:GIT_CONFIG_GLOBAL
        $savedSystemConfig = $env:GIT_CONFIG_SYSTEM
        $savedNoSystemConfig = $env:GIT_CONFIG_NOSYSTEM
        try {
            $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = '1'
            $env:GIT_CONFIG_GLOBAL = $emptyGitConfig
            $env:GIT_CONFIG_SYSTEM = $emptyGitConfig
            $env:GIT_CONFIG_NOSYSTEM = '1'

            & $gitPath -C $script:ValidatorRepositoryRoot rev-parse --git-path refs/replace 2>$null | Out-Null
            $LASTEXITCODE | Should -Not -Be 0

            {
                & $guardModule {
                    param($ResolvedGitPath, $RepositoryRoot)
                    Assert-NoGitReplacementObjects `
                        -GitPath $ResolvedGitPath `
                        -RepositoryRoot $RepositoryRoot `
                        -Context 'Unit test candidate'
                } $gitPath $script:ValidatorRepositoryRoot
            } | Should -Not -Throw
        }
        finally {
            $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = $savedAssumeDifferentOwner
            $env:GIT_CONFIG_GLOBAL = $savedGlobalConfig
            $env:GIT_CONFIG_SYSTEM = $savedSystemConfig
            $env:GIT_CONFIG_NOSYSTEM = $savedNoSystemConfig
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT110_RejectsNonUtf8PowerShellSourceBytes' {
        # Scenario: Windows PowerShell 5.1 parses trusted local source fixtures encoded as UTF-8 with or without a BOM, while UTF-16 and UTF-32 source is rejected.
        # Purpose: Prevent host ANSI source interpretation from accepting malformed candidate PowerShell while preserving non-ASCII UTF-8 code.
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $workflow | Should -Match '\[IO\.File\]::ReadAllBytes\(\$candidatePath\)'
        $workflow | Should -Not -Match '\$candidateSource\s*=\s*\[IO\.File\]::ReadAllText\('
        $workflow | Should -Match '(?s)\$candidateBytes\[0\] -eq 0xEF.*?\$candidateBytes\[1\] -eq 0xBB.*?\$candidateBytes\[2\] -eq 0xBF'
        $workflow | Should -Match '(?s)\[Text\.UTF8Encoding\]::new\(\$false, \$true\)\.GetString\(.*?\$candidateBytes.*?\$candidateOffset.*?\$candidateBytes\.Length - \$candidateOffset'

        $compatibilityTokens = $null
        $compatibilityParseErrors = $null
        $compatibilityAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1'),
            [ref]$compatibilityTokens,
            [ref]$compatibilityParseErrors
        )
        @($compatibilityParseErrors).Count | Should -Be 0
        $sourceParserAst = $compatibilityAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Assert-StrictUtf8PowerShellFile'
            }, $true)
        $sourceParserAst | Should -Not -BeNullOrEmpty

        $fixtureRoot = Join-Path $TestDrive 'windows-powershell-utf8-fixtures'
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        $plainPath = Join-Path $fixtureRoot 'plain-utf8.ps1'
        $bomPath = Join-Path $fixtureRoot 'bom-utf8.ps1'
        $utf16Path = Join-Path $fixtureRoot 'utf16.ps1'
        $utf32Path = Join-Path $fixtureRoot 'utf32.ps1'
        $malformedPath = Join-Path $fixtureRoot 'malformed-utf8.ps1'
        $fixtureSource = "`$message = '" + [string][char]0x6E2C + [char]0x8A66 + "'"
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $utf16 = [Text.Encoding]::Unicode
        $utf32 = [Text.UTF32Encoding]::new($false, $true)
        [IO.File]::WriteAllBytes($plainPath, $utf8.GetBytes($fixtureSource))
        [IO.File]::WriteAllBytes($bomPath, ([byte[]]@(0xEF, 0xBB, 0xBF) + $utf8.GetBytes($fixtureSource)))
        [IO.File]::WriteAllBytes($utf16Path, ($utf16.GetPreamble() + $utf16.GetBytes($fixtureSource)))
        [IO.File]::WriteAllBytes($utf32Path, ($utf32.GetPreamble() + $utf32.GetBytes($fixtureSource)))
        [IO.File]::WriteAllBytes($malformedPath, $utf8.GetBytes('if ('))

        $sourceParserModule = New-Module -ScriptBlock ([scriptblock]::Create($sourceParserAst.Extent.Text))
        try {
            foreach ($validPath in @($plainPath, $bomPath)) {
                {
                    & $sourceParserModule {
                        param($Path)
                        Assert-StrictUtf8PowerShellFile -Path $Path
                    } $validPath
                } | Should -Not -Throw
            }
            foreach ($invalidPath in @($utf16Path, $utf32Path, $malformedPath)) {
                {
                    & $sourceParserModule {
                        param($Path)
                        Assert-StrictUtf8PowerShellFile -Path $Path
                    } $invalidPath
                } | Should -Throw
            }
        }
        finally {
            Remove-Module $sourceParserModule -Force
        }

        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
            $systemRoot | Should -Not -BeNullOrEmpty
            $windowsPowerShellPath = [IO.Path]::GetFullPath((Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
            Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf | Should -BeTrue
            $runnerPath = Join-Path $fixtureRoot 'parse-fixtures.ps1'
            $runnerSource = @(
                'param([string] $PlainPath, [string] $BomPath, [string] $Utf16Path, [string] $Utf32Path, [string] $MalformedPath)'
                '$ErrorActionPreference = ''Stop'''
                $sourceParserAst.Extent.Text
                'Assert-StrictUtf8PowerShellFile -Path $PlainPath'
                'Assert-StrictUtf8PowerShellFile -Path $BomPath'
                'foreach ($invalidPath in @($Utf16Path, $Utf32Path, $MalformedPath)) { try { Assert-StrictUtf8PowerShellFile -Path $invalidPath; throw "Expected strict UTF-8 parsing to reject $invalidPath." } catch { if ($_.Exception.Message -like "Expected strict UTF-8 parsing*") { throw } } }'
            ) -join [Environment]::NewLine
            [IO.File]::WriteAllText($runnerPath, $runnerSource, [Text.UTF8Encoding]::new($false))
            & $windowsPowerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runnerPath $plainPath $bomPath $utf16Path $utf32Path $malformedPath
            $LASTEXITCODE | Should -Be 0
        }

        foreach ($validatorPath in @($script:Supervisor, $script:RepositoryValidator)) {
            $validatorSource = Get-Content -LiteralPath $validatorPath -Raw
            $validatorSource | Should -Match 'Read-StrictUtf8File -Path'
            $validatorSource | Should -Not -Match '\[IO\.File\]::ReadAllText\([^\r\n]+\[Text\.UTF8Encoding\]::new\(\$false,\s*\$true\)\)'
            $tokens = $null
            $parseErrors = $null
            $validatorAst = [Management.Automation.Language.Parser]::ParseFile(
                $validatorPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            @($parseErrors).Count | Should -Be 0
            $readerAst = $validatorAst.Find({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -eq 'Read-StrictUtf8File'
                }, $true)
            $readerAst | Should -Not -BeNullOrEmpty
            $readerAst.Extent.Text | Should -Match '\[IO\.File\]::ReadAllBytes\(\$Path\)'
            $readerAst.Extent.Text | Should -Match '(?s)\$bytes\[0\] -eq 0xEF.*?\$bytes\[1\] -eq 0xBB.*?\$bytes\[2\] -eq 0xBF'
            $readerAst.Extent.Text | Should -Match '\[Text\.UTF8Encoding\]::new\(\$false, \$true\)\.GetString\('

            $readerModule = New-Module -ScriptBlock ([scriptblock]::Create($readerAst.Extent.Text))
            try {
                $validatorName = [IO.Path]::GetFileNameWithoutExtension($validatorPath)
                $invalidPath = Join-Path $TestDrive "$validatorName-utf16.txt"
                $plainPath = Join-Path $TestDrive "$validatorName-utf8.txt"
                $bomPath = Join-Path $TestDrive "$validatorName-utf8-bom.txt"
                [IO.File]::WriteAllBytes($invalidPath, [byte[]]@(0xFF, 0xFE, 0x23, 0x00))
                [IO.File]::WriteAllBytes($plainPath, [byte[]]@(0x23, 0x20, 0x6F, 0x6B))
                [IO.File]::WriteAllBytes($bomPath, [byte[]]@(0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x6F, 0x6B))

                { & $readerModule { param($Path) Read-StrictUtf8File -Path $Path } $invalidPath } |
                    Should -Throw
                (& $readerModule { param($Path) Read-StrictUtf8File -Path $Path } $plainPath) |
                    Should -Be '# ok'
                (& $readerModule { param($Path) Read-StrictUtf8File -Path $Path } $bomPath) |
                    Should -Be '# ok'
            }
            finally {
                Remove-Module $readerModule -Force
            }
        }

        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        { $strictUtf8.GetString([byte[]]@(0xFF, 0xFE, 0x23, 0x00), 0, 4) } |
            Should -Throw
        { $strictUtf8.GetString([byte[]]@(0xFE, 0xFF, 0x00, 0x23), 0, 4) } |
            Should -Throw
        { $strictUtf8.GetString([byte[]]@(0xFF, 0xFE, 0x00, 0x00, 0x23, 0x00, 0x00, 0x00), 0, 8) } |
            Should -Throw
        { $strictUtf8.GetString([byte[]]@(0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x23), 0, 8) } |
            Should -Throw
        $strictUtf8.GetString([byte[]]@(0x23, 0x20, 0x6F, 0x6B), 0, 4) |
            Should -Be '# ok'
        $strictUtf8.GetString([byte[]]@(0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x6F, 0x6B), 3, 4) |
            Should -Be '# ok'
    }

}
