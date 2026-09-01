# Skill package binding

Read this file before the packaged Schema 14 Workflow. It changes only how the Workflow and Review Baseline are located after conversion from the original `AI Prompt` files into an independently versioned Skill source. Every other Workflow and Baseline requirement remains normative.

## Stable Skill source

- Source ID: `darktide-translate`
- Repository: `https://github.com/SyuanTsai/Skill-Darktide-Translate.git`
- Skill ID: `auto-update-darktide-mod`
- Skill path: `.agents/skills/auto-update-darktide-mod`

A new run requires the consumer's immutable source-pin JSON from `scripts/Get-SourcePin.ps1`: requested tag or ref, resolved 40-character source commit, deterministic repository content SHA-256, and the per-file blob/SHA-256 manifest for the installed Skill. Pass that external evidence as `-SkillSourcePinPath`. If `Test-ReferenceIntegrity.ps1 -SkillSourcePinPath ...` cannot tie every installed Skill file to that tuple, do not acquire or claim; stop as `waiting-user`. The runner copies the verified pin to `review-artifacts/skill-source-pin.json`. Resuming a run uses only that run-owned copy and rejects a different supplied pin. It validates the complete installed package before acquiring the state writer lease and again before any completed-stage receipt reuse; drift never migrates or rewrites the recorded pin.

## Original-to-package path mapping

| Original Workflow path | Compressed packaged path | Expanded filename |
| --- | --- | --- |
| `AI Prompt/AI-Auto-Update-MOD-Workflow.md` | `.agents/skills/auto-update-darktide-mod/assets/workflow-schema-14.md.gz` | `workflow-schema-14.md` |
| `AI Prompt/AI-Auto-Update-MOD-Review-Baseline.md` | `.agents/skills/auto-update-darktide-mod/assets/review-baseline.md.gz` | `review-baseline.md` |

The original commands that use `git show <workflow-commit>:AI Prompt/...` mean: read the byte-exact content expanded from the mapped package at the same resolved `darktide-translate` source commit. Check out that source commit, run `scripts/Test-ReferenceIntegrity.ps1`, and use `scripts/Expand-Schema14Reference.ps1` with `-Document Workflow` or `-Document ReviewBaseline`. Expand into a fresh temporary directory outside both repositories; the script refuses to replace an existing output file.

The compressed files are transport containers that keep automatic Skill discovery within its progressive-disclosure budget. Their expanded bytes, sizes, and SHA-256 values remain identical to the original Schema 14 documents. A content-addressed installation may use its installed package only when the consumer manifest proves the same resolved source commit and repository content hash.

Never look for these packaged references in the target MOD repository. The target MOD repository remains the location for queue/state/worktree/Git evidence and MOD changes; the Skill source is the location for Workflow and Review policy.

## Schema 15 extension binding

New automatic-source runs also bind `references/schema-15.md`. It is a repository-native normative extension derived from the byte-exact Schema 14 Workflow and Review Baseline, not a replacement compressed document. `references/schema-15-provenance.json` records its exact size, SHA-256, SYP-91 identity, and the Schema 14 Workflow/Baseline hashes it extends. `scripts/Test-ReferenceIntegrity.ps1` verifies all three references together before acquisition or claim.

A Schema 15 state records `workflowSchemaVersion = 15`, `schema15Path`, `schema15BlobOid`, and `schema15Sha256` in addition to the existing Workflow and Review Baseline tuple. Schema 14 states do not gain these fields and are never migrated implicitly.

## Translation-quality extension binding

Schema 14 and Schema 15 translation decisions also bind `references/translation-quality.md` through the complete run-local Skill source pin. Read it after the packaged Workflow and with the packaged Review Baseline. It is a repository-native normative refinement of semantic translation quality: English/in-game meaning authority, independent zh-tw wording, curated existing-translation preservation, and functional rather than word-for-word completeness. It does not alter archive/source identity, deterministic target classification, byte authorization, Lua structure, security, Git evidence, Candidate Gate, publication, or merge-finalization boundaries.

## State and evidence mapping

For new packaged runs:

- `workflow_ref` records the requested immutable Skill source ref or tag.
- `workflow_commit_oid` records the resolved `darktide-translate` source commit.
- `workflow_path` records `.agents/skills/auto-update-darktide-mod/assets/workflow-schema-14.md.gz`.
- `workflow_sha256` records the expanded Workflow content SHA-256; `workflow_package_sha256` records the compressed container SHA-256.
- `reference_sources[]` records the Workflow, Review Baseline, this package binding, `SKILL.md`, translation-quality refinement, and Schema 15 extension when applicable, including repository-relative path, resolved source commit, packaged blob, size, and SHA-256. Converted documents also retain expanded sizes and SHA-256 values. The blob values come from the verified runtime pin and are recomputed from the installed bytes, so commit, path, and blob form one directly reproducible tuple.
- For converted documents, `packagedGitBlobOid` names that packaged gzip blob while `sourceGitBlobOid` retains the original uncompressed authoring blob. The integrity command recomputes both OIDs from their respective bytes. Never substitute `sourceGitBlobOid` into runtime `reference_sources[].gitBlobOid`.
- The consumer source pin's repository URL and content SHA-256 are retained with the run evidence so a future verifier can reconstruct the package.
- A Schema 15 run additionally records the repository-relative extension path, Git blob OID, SHA-256, source receipt, and source request hash.

The `f2912...` commit in `source-provenance.json` belongs to the original Warhammer document repository and proves which Schema 14 documents were converted. `Test-ReferenceIntegrity.ps1` reports it only as `authoringSourceCommit`. It must never populate `workflow_commit_oid`; it is not a replacement for the current run's immutable `darktide-translate` Skill source pin.

## Precedence

For package-location questions, this binding overrides the original `AI Prompt` paths and workflow-branch lookup commands. `references/translation-quality.md` controls semantic translation authority, curated unchanged-source preservation, functional completeness, and the corresponding Review Finding threshold for both schemas. `references/schema-15.md` controls automatic acquisition, receipt-bound claim, status distinctions, localization workset, and workset lifecycle for new Schema 15 states. These extensions preserve content scope, safety checks, Git normalization, C0/C1/C2/C3/F evidence, Candidate Gate, append-only refresh, main-advance handling, and finalization requirements.
