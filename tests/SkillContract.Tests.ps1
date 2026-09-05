# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Auto Update Darktide MOD Skill contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $skillRoot = Join-Path $repoRoot 'skills/auto-update-darktide-mod'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:skillSourcePinPath = New-TestSkillSourcePin -SkillRoot $skillRoot -OutputPath (Join-Path $TestDrive 'skill-source-pin.json')
    }

    # Scenario: A new run loads the packaged Skill entrypoint.
    # Purpose: Ensure discovery is precise and every normative reference is explicitly routed.
    It 'UnitT10_RoutesSchema14BaseAndSchema15ExtensionReferences' {
        $skillPath = Join-Path $skillRoot 'SKILL.md'
        Test-Path -LiteralPath $skillPath | Should -Be $true
        $skill = Get-Content -LiteralPath $skillPath -Raw

        $skill | Should -Match '(?m)^name: auto-update-darktide-mod$'
        $skill | Should -Match 'references/package-binding\.md'
        $skill | Should -Match 'assets/workflow-schema-14\.md\.gz'
        $skill | Should -Match 'assets/review-baseline\.md\.gz'
        $skill | Should -Match 'references/schema-15\.md'
        $skill | Should -Match 'scripts/Expand-Schema14Reference\.ps1'
        $skill | Should -Match 'scripts/Test-ReferenceIntegrity\.ps1'
    }

    # Scenario: The Skill entrypoint is evaluated by the repository quality gate.
    # Purpose: Keep discovery metadata concise and preserve progressive disclosure as the workflow grows.
    It 'UnitT12_KeepsDiscoveryMetadataAndTopLevelRoutingConcise' {
        $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
        $description = [regex]::Match($skill, '(?m)^description: (?<value>.+)$').Groups['value'].Value
        $topLevelSections = [regex]::Matches($skill, '(?m)^## [^#].+$')

        $description.Length | Should -BeLessOrEqual 300
        $topLevelSections.Count | Should -BeLessOrEqual 5
    }

    # Scenario: The original Workflow and Review Baseline are packaged from a fixed source commit.
    # Purpose: Detect any silent truncation or content drift in the converted Skill references.
    It 'UnitT20_VerifiesByteExactSchema14ReferenceProvenance' {
        $validatorPath = Join-Path $skillRoot 'scripts/Test-ReferenceIntegrity.ps1'
        Test-Path -LiteralPath $validatorPath | Should -Be $true

        $result = & $validatorPath -PassThru
        $result.result | Should -Be 'passed'
        $result.workflow.sha256 | Should -Be '931a38d48d3f7d23b435108fc990e395f853604cd3aafac7068c0438f9c48549'
        $result.reviewBaseline.sha256 | Should -Be 'd8bcaedb66f3aa6e40ad271dbf07a7a738db37bcc071c19c8eef512bb1183d26'
        $result.schema15.sha256 | Should -Be '4cb3fa95c205b28e3c33bc1bf4eb763842ccc350335a7b65deda647bc932e6c4'
        $result.schema15.path | Should -Be 'skills/auto-update-darktide-mod/references/schema-15.md'
        $result.workflow.path | Should -Be 'skills/auto-update-darktide-mod/assets/workflow-schema-14.md.gz'
        $result.reviewBaseline.path | Should -Be 'skills/auto-update-darktide-mod/assets/review-baseline.md.gz'
        $result.workflow.packagedPath | Should -Be 'assets/workflow-schema-14.md.gz'
        $result.reviewBaseline.packagedPath | Should -Be 'assets/review-baseline.md.gz'
        $result.workflow.packageSha256 | Should -Match '^[0-9a-f]{64}$'
        $result.reviewBaseline.packageSha256 | Should -Match '^[0-9a-f]{64}$'
        $result.workflow.gitBlobOid | Should -Be '48d1ace4f2c6095a7df2ab45af6ce03c57aa2ab1'
        $result.reviewBaseline.gitBlobOid | Should -Be 'ac411332ec53e9524d687a87f0694214e858ad43'
        $result.workflow.sourceGitBlobOid | Should -Be '40752444d26a4ce39c4f32201076b1c84ad1db31'
        $result.reviewBaseline.sourceGitBlobOid | Should -Be 'e1b94428c041238e3aff8cf02408b3de1387ee15'
    }

    # Scenario: Authoring provenance names a source blob that does not match the expanded bytes.
    # Purpose: Prevent the integrity command from passing while merely echoing a false source Git OID.
    It 'UnitT22_RejectsMismatchedSourceGitBlobProvenance' {
        $fixtureRoot = Join-Path $TestDrive 'tampered-source-provenance'
        Copy-Item -LiteralPath $skillRoot -Destination $fixtureRoot -Recurse
        $fixtureProvenancePath = Join-Path $fixtureRoot 'references/source-provenance.json'
        $fixtureProvenance = Get-Content -LiteralPath $fixtureProvenancePath -Raw | ConvertFrom-Json
        $fixtureProvenance.documents.workflow.sourceGitBlobOid = '0000000000000000000000000000000000000000'
        $fixtureProvenance | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $fixtureProvenancePath -NoNewline

        $fixtureValidator = Join-Path $fixtureRoot 'scripts/Test-ReferenceIntegrity.ps1'
        { & $fixtureValidator -PassThru } | Should -Throw '*source Git blob OID mismatch*'
    }

    # Scenario: The installed Schema 15 extension bytes drift from their local provenance record.
    # Purpose: Prevent new automatic-source runs from starting under an unverified extension contract.
    It 'UnitT23_RejectsTamperedSchema15ExtensionBytes' {
        $fixtureRoot = Join-Path $TestDrive 'tampered-schema-15'
        Copy-Item -LiteralPath $skillRoot -Destination $fixtureRoot -Recurse
        Add-Content -LiteralPath (Join-Path $fixtureRoot 'references/schema-15.md') -Value "`ntampered"

        { & (Join-Path $fixtureRoot 'scripts/Test-ReferenceIntegrity.ps1') -PassThru } |
            Should -Throw '*Schema 15 reference size mismatch*'
    }

    # Scenario: Packaged Schema 14 authoring provenance comes from the target MOD repository, while a run must pin this Skill repository.
    # Purpose: Prevent the old document-source commit from being recorded as the immutable darktide-translate Skill commit.
    It 'UnitT24_SeparatesAuthoringProvenanceFromTheRuntimeSkillSourcePin' {
        $validatorPath = Join-Path $skillRoot 'scripts/Test-ReferenceIntegrity.ps1'
        $result = & $validatorPath -PassThru
        $bound = & $validatorPath -SkillSourcePinPath $script:skillSourcePinPath -PassThru
        $runner = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/mod-update.ps1') -Raw
        $candidateValidator = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/Test-ModUpdateCandidate.ps1') -Raw

        $result.authoringSourceCommit | Should -Be 'f2912faf7a52304198aa0ffc096eb12a436bbb45'
        @($result.PSObject.Properties.Name) | Should -Not -Contain 'sourceCommit'
        $bound.skillSourcePin.resolvedCommit | Should -Be '1111111111111111111111111111111111111111'
        $bound.skillSourcePin.fileCount | Should -BeGreaterThan 10
        $runner | Should -Match '\$SkillSourcePinPath'
        $runner | Should -Not -Match '\$plannedOwner\.workflowCommitOid\s*=\s*\$integrity\.sourceCommit'
        $runner | Should -Not -Match 'workflowCommitOid\s*=\s*\$integrity\.sourceCommit'
        $candidateValidator | Should -Match 'Legacy Schema 14 authoring reference tuple changed'
        $candidateValidator | Should -Match 'authoringSourceCommit'
    }

    # Scenario: A run loads each normative Schema 14 document only when its stage needs it.
    # Purpose: Prove both compressed packages reconstruct byte-exact originals before an agent reads them.
    It 'UnitT25_ExpandsVerifiedSchema14DocumentsOnDemand' {
        $expanderPath = Join-Path $skillRoot 'scripts/Expand-Schema14Reference.ps1'
        Test-Path -LiteralPath $expanderPath | Should -Be $true

        $workflow = & $expanderPath -Document Workflow -OutputDirectory $TestDrive -PassThru
        $workflow.result | Should -Be 'passed'
        $workflow.document | Should -Be 'Workflow'
        $workflow.sha256 | Should -Be '931a38d48d3f7d23b435108fc990e395f853604cd3aafac7068c0438f9c48549'
        Test-Path -LiteralPath $workflow.path -PathType Leaf | Should -Be $true
        (Get-Item -LiteralPath $workflow.path).Length | Should -Be 74587

        $baseline = & $expanderPath -Document ReviewBaseline -OutputDirectory $TestDrive -PassThru
        $baseline.result | Should -Be 'passed'
        $baseline.document | Should -Be 'ReviewBaseline'
        $baseline.sha256 | Should -Be 'd8bcaedb66f3aa6e40ad271dbf07a7a738db37bcc071c19c8eef512bb1183d26'
        Test-Path -LiteralPath $baseline.path -PathType Leaf | Should -Be $true
        (Get-Item -LiteralPath $baseline.path).Length | Should -Be 20507
    }

    # Scenario: A packaged reference directory or an external source-pin parent is replaced by a junction.
    # Purpose: Reject every reparse component before reading integrity-critical reference or pin bytes.
    It 'UnitT26_RejectsReparseParentsAtReferenceAndSourcePinReadBoundaries' {
        $fixtureRoot = Join-Path $TestDrive 'reparse-reference-skill'
        Copy-Item -LiteralPath $skillRoot -Destination $fixtureRoot -Recurse
        $outsideAssets = Join-Path $TestDrive 'reparse-reference-assets'
        Move-Item -LiteralPath (Join-Path $fixtureRoot 'assets') -Destination $outsideAssets
        New-Item -ItemType Junction -Path (Join-Path $fixtureRoot 'assets') -Target $outsideAssets | Out-Null
        { & (Join-Path $fixtureRoot 'scripts/Test-ReferenceIntegrity.ps1') -PassThru } |
            Should -Throw '*reparse*'

        $outsidePin = Join-Path $TestDrive 'reparse-pin-outside'
        $linkedPin = Join-Path $TestDrive 'reparse-pin-link'
        New-Item -ItemType Directory -Path $outsidePin -Force | Out-Null
        Copy-Item -LiteralPath $script:skillSourcePinPath -Destination (Join-Path $outsidePin 'skill-source-pin.json')
        New-Item -ItemType Junction -Path $linkedPin -Target $outsidePin | Out-Null
        { & (Join-Path $skillRoot 'scripts/Test-ReferenceIntegrity.ps1') `
                -SkillSourcePinPath (Join-Path $linkedPin 'skill-source-pin.json') -PassThru } |
            Should -Throw '*reparse*'
    }

    # Scenario: A temporary materialization path already contains the requested document.
    # Purpose: Preserve the no-overwrite boundary for evidence-bearing normative documents.
    It 'UnitT27_RefusesToOverwriteAnExistingExpandedDocument' {
        $expanderPath = Join-Path $skillRoot 'scripts/Expand-Schema14Reference.ps1'
        $outputDirectory = Join-Path $TestDrive 'no-overwrite'
        New-Item -ItemType Directory -Path $outputDirectory | Out-Null
        $first = & $expanderPath -Document Workflow -OutputDirectory $outputDirectory -PassThru
        Test-Path -LiteralPath $first.path -PathType Leaf | Should -Be $true

        { & $expanderPath -Document Workflow -OutputDirectory $outputDirectory -PassThru } |
            Should -Throw
    }

    # Scenario: A caller selects the installed Skill directory as the expansion destination.
    # Purpose: Enforce the documented boundary that generated documents never modify the Skill source.
    It 'UnitT28_RefusesToExpandInsideTheSkillSource' {
        $fixtureRoot = Join-Path $TestDrive 'in-skill-output'
        Copy-Item -LiteralPath $skillRoot -Destination $fixtureRoot -Recurse
        $fixtureExpander = Join-Path $fixtureRoot 'scripts/Expand-Schema14Reference.ps1'

        { & $fixtureExpander -Document Workflow -OutputDirectory $fixtureRoot -PassThru } |
            Should -Throw '*outside the Skill source*'
    }

    # Scenario: A completed run is resumed with a runner file whose bytes no longer match its immutable source pin.
    # Purpose: Reject runtime package drift even when the changed file is the stage runner itself.
    It 'UnitT29_RejectsRunnerFileDriftFromTheImmutableSourcePin' {
        $fixtureRoot = Join-Path $TestDrive 'runner-drift-skill'
        Copy-Item -LiteralPath $skillRoot -Destination $fixtureRoot -Recurse
        $fixturePinPath = New-TestSkillSourcePin -SkillRoot $fixtureRoot -OutputPath (Join-Path $TestDrive 'runner-drift-pin.json')
        Add-Content -LiteralPath (Join-Path $fixtureRoot 'scripts/mod-update.ps1') -Value "`n# runtime drift"

        { & (Join-Path $fixtureRoot 'scripts/Test-ReferenceIntegrity.ps1') `
                -SkillSourcePinPath $fixturePinPath -PassThru } |
            Should -Throw '*Installed Skill file differs from its source pin*mod-update.ps1*'
    }

    # Scenario: The Skill runs outside the original MOD repository prompt location.
    # Purpose: Preserve immutable source pinning without requiring AI Prompt files in the target repository.
    It 'UnitT30_MapsOriginalWorkflowLocationsToTheInstalledSkillSource' {
        $bindingPath = Join-Path $skillRoot 'references/package-binding.md'
        Test-Path -LiteralPath $bindingPath | Should -Be $true
        $binding = Get-Content -LiteralPath $bindingPath -Raw

        $binding | Should -Match 'darktide-translate'
        $binding | Should -Match 'workflow_commit_oid'
        $binding | Should -Match 'workflow-schema-14\.md\.gz'
        $binding | Should -Match 'review-baseline\.md\.gz'
        $binding | Should -Match 'Expand-Schema14Reference\.ps1'
        $binding | Should -Match 'target MOD repository'
        $binding | Should -Match 'packagedGitBlobOid'
        $binding | Should -Match 'sourceGitBlobOid'
        $binding | Should -Match 'repository-relative path'
    }

    # Scenario: The Skill appears in Codex UI and may be selected automatically for matching maintenance work.
    # Purpose: Keep UI metadata consistent with the Skill ID and implicit invocation policy.
    It 'UnitT40_ProvidesConsistentOpenAiMetadata' {
        $metadataPath = Join-Path $skillRoot 'agents/openai.yaml'
        Test-Path -LiteralPath $metadataPath | Should -Be $true
        $metadata = Get-Content -LiteralPath $metadataPath -Raw

        $metadata | Should -Match 'display_name: "Auto Update Darktide MOD"'
        $metadata | Should -Match '\$auto-update-darktide-mod'
        $metadata | Should -Not -Match 'allow_implicit_invocation: false'
    }
}
