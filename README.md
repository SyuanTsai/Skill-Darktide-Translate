<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Skill Darktide Translate

Independent Agent Skill source for safe Warhammer 40,000 DARKTIDE MOD archive updates and `zh-tw` source synchronization.

- Stable source ID: `darktide-translate`
- Catalog: `catalog/skills-catalog.json`
- Current repository version: `0.3.13`
- Delivery tracking is maintained outside this public source and does not change the repository licensing boundary.

## Skill

| Skill | Profile | Purpose | Capability gate |
| --- | --- | --- | --- |
| `auto-update-darktide-mod` | `darktide-mod-maintenance` | Execute or resume manual Schema 14 runs or receipt-bound Schema 15 Nexus Main-file, natural zh-tw maintenance, Git evidence, Candidate Gate, PR, Review, and state-driven merge finalization. | Windows, PowerShell 7, Git, and either a configured GitHub connector or authenticated `gh` |

The profile is opt-in because the workflow can mutate isolated branches, publish PRs, and retain per-MOD reservations. Normal user authorization remains required for external writes and security overrides.

## Repository layout

```text
.agents/skills/auto-update-darktide-mod/
  SKILL.md
  agents/openai.yaml
  assets/
  references/schema-15.md
  references/schema-15-provenance.json
  references/translation-quality.md
  scripts/mod-update.ps1
  scripts/Receive-NexusMainFile.ps1
  scripts/Test-SourceReceipt.ps1
  scripts/Invoke-ModUpdateQueue.ps1
  scripts/SharedCoordinationLock.psm1
  scripts/LuaLocalizationScanner.psm1
  scripts/New-LocalizationWorkset.ps1
  scripts/Apply-LocalizationWorkset.ps1
  scripts/Test-LocalizationWorksetReceipt.ps1
  scripts/Finalize-LocalizationWorksetEvidence.ps1
  scripts/Finalize-ModUpdateMerge.ps1
  scripts/Test-ModUpdateCandidate.ps1
  scripts/Expand-Schema14Reference.ps1
  scripts/Test-ReferenceIntegrity.ps1
catalog/skills-catalog.json
docs/RELEASE.md
docs/ROLLBACK.md
scripts/Get-SourcePin.ps1
scripts/Invoke-PrePushValidation.ps1
scripts/Test-CleanRepositoryHead.ps1
tests/
.github/workflows/
VERSION
```

## Validation

Run from the repository root:

Repository contract tests require Pester 5 or later.
Commit the intended snapshot, ensure the working tree and index are clean, then run the same gate used by GitHub before pushing:

```powershell
pwsh -File ./scripts/Invoke-PrePushValidation.ps1
```

The gate binds tests, packaged-reference integrity, and the reproducible source pin to one unchanged HEAD. Run the component commands directly only when diagnosing a failed gate.

GitHub Actions also runs strict `skill-validator` and `skill-tools` Quality Gates using versions resolved once per workflow run and reported in logs and the job summary.

## Versioning and rollback

Release and immutable pin rules are in `docs/RELEASE.md`. Consumers start and roll back runs with the complete JSON emitted by `scripts/Get-SourcePin.ps1`, including the tag/ref, resolved commit, deterministic content hash, and installed Skill file manifest, as described in `docs/ROLLBACK.md`. Existing Schema 14 states remain immutable, and Schema 15 states never downgrade or migrate implicitly.

The real Reconnect trial, immutable Git evidence, Gate hashes, Review result, and measured wall-clock run are recorded in the versioned end-to-end evidence document.

## License and contribution boundary

The Apache-2.0 license in [LICENSE](LICENSE) applies to the repository-authored Skill instructions, agent metadata, scripts, tests, catalog and version metadata, documentation, and workflow configuration that this repository created. The two compressed reference archives under `assets/` are source-derived upstream material and are expressly excluded from that grant; their provenance and treatment are recorded in [PROVENANCE.md](PROVENANCE.md).

Downloaded Mods, game data, localization files, archives, upstream translations, Nexus or other external-service content, trademarks, credentials, user-provided inputs, and generated outputs are outside this repository's Apache-2.0 scope. Processing or transforming such material with this workflow does not automatically relicense it.

The repository does not vendor third-party source code. CI and developer dependencies are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and their upstream terms remain applicable. Contributors must have the right to submit their contribution; unless a separate written agreement says otherwise, an intentional contribution to the repository-authored scope is submitted under Apache-2.0 and must preserve existing notices.

## Scope

This repository independently owns the packaged Skill, its Schema 14 Workflow and Review base, Schema 15 normative extension, source receipt boundary, deterministic localization worksets, stage runner, Candidate Gate, metadata, validation, and release contract. It is not added to the AI-Instructions Catalog, Lock, bootstrap, or fan-out; consumers install and pin it independently.
