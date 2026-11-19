<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Skill Darktide Translate

Independent, Windows-only Agent Skill source for safe Warhammer 40,000 DARKTIDE MOD archive updates and `zh-tw` source synchronization.

Local development, installation, execution, testing, validation, and CI acceptance require a Windows host; Linux, macOS, and WSL are unsupported.

- Stable source ID: `darktide-translate`
- Source inventory: `catalog/source.json`
- Profile catalog extension: `catalog/profiles.json`
- Current repository version: `0.4.1`
- Delivery tracking is maintained outside this public source and does not change the repository licensing boundary.

## Skill

| Skill | Profile | Purpose | Capability gate |
| --- | --- | --- | --- |
| `auto-update-darktide-mod` | `darktide-mod-maintenance` | Execute or resume manual Schema 14 runs or receipt-bound Schema 15 Nexus Main-file, natural zh-tw maintenance, Git evidence, Candidate Gate, PR, Review, and state-driven merge finalization. | Windows, PowerShell 7, Git, and either a configured GitHub connector or authenticated `gh` |

The profile is opt-in because the workflow can mutate isolated branches, publish PRs, and retain per-MOD reservations. Normal user authorization remains required for external writes and security overrides.

## Repository layout

```text
skills/auto-update-darktide-mod/
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
  scripts/PathSafety.psm1
  scripts/LuaLocalizationScanner.psm1
  scripts/New-LocalizationWorkset.ps1
  scripts/Apply-LocalizationWorkset.ps1
  scripts/Test-LocalizationWorksetReceipt.ps1
  scripts/Finalize-LocalizationWorksetEvidence.ps1
  scripts/Finalize-ModUpdateMerge.ps1
  scripts/Test-ModUpdateCandidate.ps1
  scripts/Expand-Schema14Reference.ps1
  scripts/Test-ReferenceIntegrity.ps1
catalog/source.json
catalog/profiles.json
config/authority-pin.json
config/consumer-gate.json
scripts/Invoke-PinnedAuthority.ps1
scripts/Test-DarktideRepository.ps1
scripts/Test-CleanRepositoryHead.ps1
scripts/New-SkillSourcePin.ps1
docs/RELEASE.md
docs/ROLLBACK.md
tests/
.github/workflows/consumer-gate.yml
.github/workflows/consumer-gate-transition.yml
VERSION
```

## Validation

Run from the repository root:

Repository contract tests require Pester 5 or later. Run the repository-owned checks directly when reproducing a consumer-gate result locally:

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/Test-DarktideRepository.ps1 -RepositoryRoot .
Invoke-Pester -Path ./tests
```

Pull requests are validated by `.github/workflows/consumer-gate.yml` on Windows, Linux, and macOS. The `pull_request_target` workflow uses the immutable authority selected by `config/authority-pin.json`; the dedicated App publishes `repository-contract`, `skill-validator`, and `skill-tools` to the pull-request head. Repository-specific checks are `scripts/Test-DarktideRepository.ps1` and complete Pester discovery under `tests/`, as declared in `config/consumer-gate.json`. Routine authority upgrades change only the pin's `commit`.

The transition workflow is single-use conversion scaffolding and is removed in the follow-up cleanup pull request. Repository files describe the gate but do not by themselves prove that remote App, event-policy, environment, or ruleset enforcement is enabled.

## Versioning and rollback

Release and immutable pin rules are in `docs/RELEASE.md`. From a source checkout, generate the complete consumer pin without changing the repository:

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/New-SkillSourcePin.ps1 -Ref HEAD -OutputPath ../darktide-source-pin.json
```

The JSON includes the requested ref, resolved commit, deterministic repository content hash, version, Skill path, and installed Skill per-file blob/SHA-256 manifest. Existing Schema 14 states remain immutable, and Schema 15 states never downgrade or migrate implicitly.

### Historical trial evidence

These dated reports describe their recorded versions and are retained in Git history; current operations follow the packaged Schema 14/15 instructions.

- [AutoMark (2026-08-30)](https://github.com/SyuanTsai/Skill-Darktide-Translate/blob/4bd1bbc34981ee6a3f9d84cf0cb8214f74c97b02/docs/AUTOMARK-REAL-MOD-TRIAL-2026-08-30.md)
- [BetterMelk (2026-08-30)](https://github.com/SyuanTsai/Skill-Darktide-Translate/blob/4bd1bbc34981ee6a3f9d84cf0cb8214f74c97b02/docs/BETTERMELK-REAL-MOD-TRIAL-2026-08-30.md)
- [BornReady (2026-08-30)](https://github.com/SyuanTsai/Skill-Darktide-Translate/blob/4bd1bbc34981ee6a3f9d84cf0cb8214f74c97b02/docs/BORNREADY-REAL-MOD-TRIAL-2026-08-30.md)
- [Reconnect (2026-08-22)](https://github.com/SyuanTsai/Skill-Darktide-Translate/blob/4bd1bbc34981ee6a3f9d84cf0cb8214f74c97b02/docs/darktide-mod-e2e.md)

## License and contribution boundary

The Apache-2.0 license in [LICENSE](LICENSE) applies to the repository-authored Skill instructions under `skills/`, agent metadata, scripts, tests, catalog and version metadata, documentation, and workflow configuration that this repository created. The two source-derived normative reference documents under `skills/auto-update-darktide-mod/assets/` are expressly excluded from that grant; their provenance and treatment are recorded in [PROVENANCE.md](PROVENANCE.md).

Downloaded Mods, game data, localization files, archives, upstream translations, Nexus or other external-service content, trademarks, credentials, user-provided inputs, and generated outputs are outside this repository's Apache-2.0 scope. Processing or transforming such material with this workflow does not automatically relicense it.

The repository does not vendor third-party source code. CI and developer dependencies are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and their upstream terms remain applicable. Contributors must have the right to submit their contribution; unless a separate written agreement says otherwise, an intentional contribution to the repository-authored scope is submitted under Apache-2.0 and must preserve existing notices.

## Scope

This repository independently owns the packaged Skill, its Schema 14 Workflow and Review base, Schema 15 normative extension, source receipt boundary, deterministic localization worksets, stage runner, Candidate Gate, metadata, validation, and release contract. It is not added to the AI-Instructions Catalog, Lock, bootstrap, or fan-out; consumers install and pin it independently.
