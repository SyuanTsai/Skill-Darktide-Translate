# Skill Darktide Translate

Independent Agent Skill source for safe Warhammer 40,000 DARKTIDE MOD archive updates and `zh-tw` source synchronization.

- Stable source ID: `darktide-translate`
- Catalog: `catalog/skills-catalog.json`
- Current repository version: `0.2.0`
- Jira delivery items: `SYP-92` packaging and `SYP-88` deterministic automation under `SYP-86`

## Skill

| Skill | Profile | Purpose | Capability gate |
| --- | --- | --- | --- |
| `auto-update-darktide-mod` | `darktide-mod-maintenance` | Execute or resume the Schema 14 archive, localization, Git evidence, Candidate Gate, PR, Review, and finalization workflow. | Windows, PowerShell 7, Git, and either a configured GitHub connector or authenticated `gh` |

The profile is opt-in because the workflow can mutate isolated branches, publish PRs, and retain per-MOD reservations. Normal user authorization remains required for external writes and security overrides.

## Repository layout

```text
.agents/skills/auto-update-darktide-mod/
  SKILL.md
  agents/openai.yaml
  assets/
  references/
  scripts/mod-update.ps1
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

Release and immutable pin rules are in `docs/RELEASE.md`. Consumers roll back by restoring an earlier tag, resolved commit, and deterministic content hash as described in `docs/ROLLBACK.md`. Existing MOD runs never auto-migrate to a newer Workflow revision.

The real Reconnect trial, immutable Git evidence, Gate hashes, Review result, and measured 9-minute-18-second wall-clock run are recorded in [`docs/SYP-88-E2E.md`](docs/SYP-88-E2E.md).

## Scope

This repository independently owns the packaged Skill, its Schema 14 Workflow and Review references, deterministic stage runner, Candidate Gate, metadata, validation, and release contract. It is not added to the AI-Instructions Catalog, Lock, bootstrap, or fan-out; consumers install and pin it independently.
