Describe 'Auto Update Darktide MOD Skill contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $skillRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod'
    }

    # Scenario: A new run loads the packaged Skill entrypoint.
    # Purpose: Ensure discovery is precise and every normative reference is explicitly routed.
    It 'UnitT10_RoutesSchema14ExecutionAndReviewReferences' {
        $skillPath = Join-Path $skillRoot 'SKILL.md'
        Test-Path -LiteralPath $skillPath | Should -Be $true
        $skill = Get-Content -LiteralPath $skillPath -Raw

        $skill | Should -Match '(?m)^name: auto-update-darktide-mod$'
        $skill | Should -Match 'references/package-binding\.md'
        $skill | Should -Match 'assets/workflow-schema-14\.md\.gz'
        $skill | Should -Match 'assets/review-baseline\.md\.gz'
        $skill | Should -Match 'scripts/Expand-Schema14Reference\.ps1'
        $skill | Should -Match 'scripts/Test-ReferenceIntegrity\.ps1'
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
        $result.workflow.path | Should -Be 'assets/workflow-schema-14.md.gz'
        $result.reviewBaseline.path | Should -Be 'assets/review-baseline.md.gz'
        $result.workflow.packageSha256 | Should -Match '^[0-9a-f]{64}$'
        $result.reviewBaseline.packageSha256 | Should -Match '^[0-9a-f]{64}$'
        $result.workflow.gitBlobOid | Should -Be '48d1ace4f2c6095a7df2ab45af6ce03c57aa2ab1'
        $result.reviewBaseline.gitBlobOid | Should -Be 'ac411332ec53e9524d687a87f0694214e858ad43'
        $result.workflow.sourceGitBlobOid | Should -Be '40752444d26a4ce39c4f32201076b1c84ad1db31'
        $result.reviewBaseline.sourceGitBlobOid | Should -Be 'e1b94428c041238e3aff8cf02408b3de1387ee15'
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
