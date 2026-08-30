# Skill Darktide Translate

Independent Agent Skill source for safe Warhammer 40,000 DARKTIDE MOD archive updates and `zh-tw` source synchronization.

- Stable source ID: `darktide-translate`
- Catalog: `catalog/skills-catalog.json`
- Current repository version: `0.3.8`
- Jira delivery items: `SYP-112` checkpoint reasons, `SYP-113` immutable source metadata, `SYP-114` shared coordination locks, `SYP-115` reservation heartbeat/lifecycle, `SYP-116` runner observability/Windows byte preservation, `SYP-117` deterministic partial commit recovery, and `SYP-118` resume-time Skill pin validation, building on `SYP-91`, `SYP-92`, and `SYP-88`

## Skill

| Skill | Profile | Purpose | Capability gate |
| --- | --- | --- | --- |
| `auto-update-darktide-mod` | `darktide-mod-maintenance` | Execute or resume manual Schema 14 runs or receipt-bound Schema 15 Nexus Main-file, localization-workset, Git evidence, Candidate Gate, PR, Review, and finalization runs. | Windows, PowerShell 7, Git, and either a configured GitHub connector or authenticated `gh` |

The profile is opt-in because the workflow can mutate isolated branches, publish PRs, and retain per-MOD reservations. Normal user authorization remains required for external writes and security overrides.

## Repository layout

```text
.agents/skills/auto-update-darktide-mod/
  SKILL.md
  agents/openai.yaml
  assets/
  references/schema-15.md
  references/schema-15-provenance.json
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
  scripts/Test-ModUpdateCandidate.ps1
  scripts/Expand-Schema14Reference.ps1
  scripts/Test-ReferenceIntegrity.ps1
catalog/skills-catalog.json
docs/RELEASE.md
docs/ROLLBACK.md
scripts/Get-SourcePin.ps1
tests/
.github/workflows/
VERSION
```

## Validation

Run from the repository root:

Repository contract tests require Pester 5 or later.

```powershell
pwsh -File ./tests/Invoke-Tests.ps1
pwsh -File ./.agents/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1
pwsh -File ./scripts/Get-SourcePin.ps1 -Ref HEAD
```

GitHub Actions also runs strict `skill-validator` and `skill-tools` Quality Gates using versions resolved once per workflow run and reported in logs and the job summary.

## Versioning and rollback

Release and immutable pin rules are in `docs/RELEASE.md`. Consumers start and roll back runs with the complete JSON emitted by `scripts/Get-SourcePin.ps1`, including the tag/ref, resolved commit, deterministic content hash, and installed Skill file manifest, as described in `docs/ROLLBACK.md`. Existing Schema 14 states remain immutable, and Schema 15 states never downgrade or migrate implicitly.

The real Reconnect trial, immutable Git evidence, Gate hashes, Review result, and measured 9-minute-18-second wall-clock run are recorded in [`docs/SYP-88-E2E.md`](docs/SYP-88-E2E.md).

## Scope

This repository independently owns the packaged Skill, its Schema 14 Workflow and Review base, Schema 15 normative extension, source receipt boundary, deterministic localization worksets, stage runner, Candidate Gate, metadata, validation, and release contract. It is not added to the AI-Instructions Catalog, Lock, bootstrap, or fan-out; consumers install and pin it independently.
