$repoRoot = Split-Path -Parent $PSScriptRoot
$skillRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod'

Describe 'Auto Update Darktide MOD Skill contract' {
    # Scenario: A new run loads the packaged Skill entrypoint.
    # Purpose: Ensure discovery is precise and every normative reference is explicitly routed.
    It 'UnitT10_RoutesSchema14ExecutionAndReviewReferences' {
        $skillPath = Join-Path $skillRoot 'SKILL.md'
        Test-Path -LiteralPath $skillPath | Should Be $true
        $skill = Get-Content -LiteralPath $skillPath -Raw

        $skill | Should Match '(?m)^name: auto-update-darktide-mod$'
        $skill | Should Match 'references/package-binding\.md'
        $skill | Should Match 'references/workflow-schema-14\.md'
        $skill | Should Match 'references/review-baseline\.md'
        $skill | Should Match 'scripts/Test-ReferenceIntegrity\.ps1'
    }

    # Scenario: The original Workflow and Review Baseline are packaged from a fixed source commit.
    # Purpose: Detect any silent truncation or content drift in the converted Skill references.
    It 'UnitT20_VerifiesByteExactSchema14ReferenceProvenance' {
        $validatorPath = Join-Path $skillRoot 'scripts/Test-ReferenceIntegrity.ps1'
        Test-Path -LiteralPath $validatorPath | Should Be $true

        $result = & $validatorPath -PassThru
        $result.result | Should Be 'passed'
        $result.workflow.sha256 | Should Be '931a38d48d3f7d23b435108fc990e395f853604cd3aafac7068c0438f9c48549'
        $result.reviewBaseline.sha256 | Should Be 'd8bcaedb66f3aa6e40ad271dbf07a7a738db37bcc071c19c8eef512bb1183d26'
    }

    # Scenario: The Skill runs outside the original MOD repository prompt location.
    # Purpose: Preserve immutable source pinning without requiring AI Prompt files in the target repository.
    It 'UnitT30_MapsOriginalWorkflowLocationsToTheInstalledSkillSource' {
        $bindingPath = Join-Path $skillRoot 'references/package-binding.md'
        Test-Path -LiteralPath $bindingPath | Should Be $true
        $binding = Get-Content -LiteralPath $bindingPath -Raw

        $binding | Should Match 'darktide-translate'
        $binding | Should Match 'workflow_commit_oid'
        $binding | Should Match 'workflow-schema-14\.md'
        $binding | Should Match 'review-baseline\.md'
        $binding | Should Match 'target MOD repository'
    }

    # Scenario: The Skill appears in Codex UI and may be selected automatically for matching maintenance work.
    # Purpose: Keep UI metadata consistent with the Skill ID and implicit invocation policy.
    It 'UnitT40_ProvidesConsistentOpenAiMetadata' {
        $metadataPath = Join-Path $skillRoot 'agents/openai.yaml'
        Test-Path -LiteralPath $metadataPath | Should Be $true
        $metadata = Get-Content -LiteralPath $metadataPath -Raw

        $metadata | Should Match 'display_name: "Auto Update Darktide MOD"'
        $metadata | Should Match '\$auto-update-darktide-mod'
        $metadata | Should Not Match 'allow_implicit_invocation: false'
    }
}
