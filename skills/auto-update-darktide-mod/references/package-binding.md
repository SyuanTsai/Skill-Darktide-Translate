<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Skill package binding

Read this file before the packaged Schema 14 Workflow. It changes only how the Workflow and Review Baseline are located after conversion from the original `AI Prompt` files into an independently versioned Skill source. Every other Workflow and Baseline requirement remains normative.

## Stable Skill source

- Source ID: `darktide-translate`
- Repository: `https://github.com/SyuanTsai/Skill-Darktide-Translate.git`
- Skill ID: `auto-update-darktide-mod`
- Skill path: `skills/auto-update-darktide-mod`

A new run requires the consumer's immutable source-pin JSON from `scripts/Get-SourcePin.ps1`: requested tag or ref, resolved 40-character source commit, deterministic repository content SHA-256, and the per-file blob/SHA-256 manifest for the installed Skill. Pass that external evidence as `-SkillSourcePinPath`. If `Test-ReferenceIntegrity.ps1 -SkillSourcePinPath ...` cannot tie every installed Skill file to that tuple, do not acquire or claim; stop as `waiting-user`. The runner copies the verified pin to `review-artifacts/skill-source-pin.json`. Resuming a run uses only that run-owned copy and rejects a different supplied pin. It validates the complete installed package before acquiring the state writer lease and again before any completed-stage receipt reuse; drift never migrates or rewrites the recorded pin.

## Original-to-package path mapping

| Original Workflow path | Packaged path | Materialized filename |
| --- | --- | --- |
| `AI Prompt/AI-Auto-Update-MOD-Workflow.md` | `skills/auto-update-darktide-mod/assets/workflow-schema-14.md` | `workflow-schema-14.md` |
| `AI Prompt/AI-Auto-Update-MOD-Review-Baseline.md` | `skills/auto-update-darktide-mod/assets/review-baseline.md` | `review-baseline.md` |

The original commands that use `git show <workflow-commit>:AI Prompt/...` mean: read the byte-exact content materialized from the mapped package at the same resolved `darktide-translate` source commit. Check out that source commit, run `scripts/Test-ReferenceIntegrity.ps1`, and use `scripts/Expand-Schema14Reference.ps1` with `-Document Workflow` or `-Document ReviewBaseline`. Materialize into a fresh temporary directory outside both repositories; the script refuses to replace an existing output file.

The packaged files are byte-exact source-derived copies kept under `assets/` so SkillSpector can inspect the normative material without an opaque archive gap. Their sizes, Git blob OIDs, and SHA-256 values remain identical to the original Schema 14 documents. A content-addressed installation may use its installed package only when the consumer manifest proves the same resolved source commit and repository content hash.

Never look for these packaged references in the target MOD repository. The target MOD repository remains the location for queue/state/worktree/Git evidence and MOD changes; the Skill source is the location for Workflow and Review policy.

## Vendored platform runtime binding

The Skill vendors the complete registry-bound platform runtime used by `scripts/PathSafety.psm1`. Agents do not invoke its internal files as independent entrypoints: the verifier hashes the inventory, loads the manifest-bound root module, and revalidates every source file with identity checks. The files remain explicit here so their roles and discovery path are part of the package contract.

| Vendored path | Role |
| --- | --- |
| `scripts/platform-runtime/Resolve-StandardValidationTool.ps1` | Resolves and verifies the pinned validation tools used by runtime preparation. |
| `scripts/platform-runtime/WindowsDacl.psm1` | Normalizes and verifies Windows DACL policy. |
| `scripts/platform-runtime/installer-safe-mutation.psm1` | Provides handle-bound installer mutation primitives. |
| `scripts/platform-runtime/platform-runtime.psd1` | Declares the platform runtime manifest, exports, file inventory, and hashes. |
| `scripts/platform-runtime/platform-runtime.psm1` | Loads the verified native sources and dispatches the public platform API. |
| `scripts/platform-runtime/platform/Linux.psm1` | Adapts the shared Unix implementation and preparation flow for Linux. |
| `scripts/platform-runtime/platform/MacOS.psm1` | Adapts the shared Unix implementation and preparation flow for macOS. |
| `scripts/platform-runtime/platform/Unix.psm1` | Implements the shared Unix publication, removal, permission, and process operations. |
| `scripts/platform-runtime/platform/Windows.psm1` | Implements the Windows platform adapter and preparation flow. |
| `scripts/platform-runtime/platform/RuntimePreparation.psm1` | Prepares verified PowerShell and Pester runtimes in private roots. |
| `scripts/platform-runtime/platform/PlatformNative.cs` | Defines common runtime identity, path, hashing, and platform primitives. |
| `scripts/platform-runtime/platform/OwnedProcess.cs` | Defines the cross-platform owned-process lease and cleanup contract. |
| `scripts/platform-runtime/platform/UnixNative.cs` | Implements Unix handle, identity, lock, publication, and permission primitives. |
| `scripts/platform-runtime/platform/UnixProcess.cs` | Implements Unix owned-process control and process-group cleanup. |
| `scripts/platform-runtime/platform/WindowsInstallerMutation.cs` | Implements handle-bound Windows installer mutations. |
| `scripts/platform-runtime/platform/WindowsNative.cs` | Implements Windows handle, identity, lock, publication, and permission primitives. |
| `scripts/platform-runtime/platform/WindowsProcess.cs` | Implements Windows owned-process and job-object control. |

## Schema 15 extension binding

New automatic-source runs also bind `references/schema-15.md`. It is a repository-native normative extension derived from the byte-exact Schema 14 Workflow and Review Baseline, not a replacement source document. `references/schema-15-provenance.json` records its exact size, SHA-256, repository-local contract identity, and the Schema 14 Workflow/Baseline hashes it extends. `scripts/Test-ReferenceIntegrity.ps1` verifies all three references together before acquisition or claim.

A Schema 15 state records `workflowSchemaVersion = 15`, `schema15Path`, `schema15BlobOid`, and `schema15Sha256` in addition to the existing Workflow and Review Baseline tuple. Schema 14 states do not gain these fields and are never migrated implicitly.

## Translation-quality extension binding

Schema 14 and Schema 15 translation decisions also bind `references/translation-quality.md` through the complete run-local Skill source pin. Read it after the packaged Workflow and with the packaged Review Baseline. It is a repository-native normative refinement of semantic translation quality: English/in-game meaning authority, independent zh-tw wording, curated existing-translation preservation, and functional rather than word-for-word completeness. It does not alter archive/source identity, deterministic target classification, byte authorization, Lua structure, security, Git evidence, Candidate Gate, publication, or merge-finalization boundaries.

## Coordination-format extension binding

Schema 14 and Schema 15 runs also bind `references/coordination-format.md` through the complete run-local Skill source pin. Read it immediately after the packaged Workflow. It is the repository-native normative contract for the persistent single-file shared coordination leases and canonical-MOD reservation introduced in version 0.4.0. It overrides only Schema 14 §3.2's `.locks` layout, §3.3's lock storage and transitions, §3.4's lock scanning/recovery/tombstones, §5.1's coordination format, and §13 steps 7–9's reservation-release format. The remaining Workflow requirements, including evidence archival followed by owner-checked claim/run cleanup, remain normative.

## State and evidence mapping

For new packaged runs:

- `workflow_ref` records the requested immutable Skill source ref or tag.
- `workflow_commit_oid` records the resolved `darktide-translate` source commit.
- `workflow_path` records `skills/auto-update-darktide-mod/assets/workflow-schema-14.md`.
- `workflow_sha256` records the Workflow content SHA-256; `workflow_package_sha256` records the packaged file SHA-256.
- `reference_sources[]` records the Workflow, Review Baseline, this package binding, `SKILL.md`, translation-quality refinement, and Schema 15 extension when applicable, including repository-relative path, resolved source commit, packaged blob, size, and SHA-256. Converted documents also retain expanded sizes and SHA-256 values. The blob values come from the verified runtime pin and are recomputed from the installed bytes, so commit, path, and blob form one directly reproducible tuple.
- For converted documents, `packagedGitBlobOid` names the packaged source-derived blob while `sourceGitBlobOid` retains the original authoring blob. The integrity command recomputes both OIDs from their respective bytes. Never substitute `sourceGitBlobOid` into runtime `reference_sources[].gitBlobOid` unless the package bytes are proven identical.
- The consumer source pin's repository URL and content SHA-256 are retained with the run evidence so a future verifier can reconstruct the package.
- A Schema 15 run additionally records the repository-relative extension path, Git blob OID, SHA-256, source receipt, and source request hash.

The `f2912...` commit in `source-provenance.json` belongs to the original Warhammer document repository and proves which Schema 14 documents were converted. `Test-ReferenceIntegrity.ps1` reports it only as `authoringSourceCommit`. It must never populate `workflow_commit_oid`; it is not a replacement for the current run's immutable `darktide-translate` Skill source pin.

## Precedence

For package-location questions, this binding overrides the original `AI Prompt` paths and workflow-branch lookup commands. `references/coordination-format.md` controls only the Schema 14 lock/reservation-format clauses enumerated in its scope and above. `references/translation-quality.md` controls semantic translation authority, curated unchanged-source preservation, functional completeness, and the corresponding Review Finding threshold for both schemas. `references/schema-15.md` controls automatic acquisition, receipt-bound claim, status distinctions, localization workset, and workset lifecycle for new Schema 15 states. These extensions preserve every Workflow requirement outside their explicit scopes, including content scope, safety checks, Git normalization, C0/C1/C2/C3/F evidence, Candidate Gate, append-only refresh, main-advance handling, evidence archival, and owner-checked claim/run cleanup.
