<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Skill Darktide Translate

## Overview

**What it is:** An Agent Skill that safely updates Warhammer 40,000: Darktide MODs from Nexus Mods archives and keeps Taiwan Traditional Chinese (`zh-tw`) localization in sync. It supports maintenance of the [public Darktide MOD collection](https://github.com/SyuanTsai/Warhammer-40-000-DARKTIDE-Mods).

**Problem it solves:** Manually replacing a MOD can silently drop or damage existing translations. The workflow preserves reliable translations when the source is unchanged, records Git evidence, and requires the Candidate Gate to pass before opening or updating a pull request (PR). A local review checks the published candidate.

**Key Skills**

| Skill | What it does |
| --- | --- |
| [`auto-update-darktide-mod`](skills/auto-update-darktide-mod/SKILL.md) | Updates MODs from verified Nexus Main files or supplied ZIPs, preserves active `zh-tw`, and records Schema 14 or 15 Git evidence. Supports acquiring sources, claiming or resuming updates, handling review feedback, and finalizing merges. |

**Requirements:** Windows only. Requires PowerShell 7, Git, and either a configured GitHub connector or an authenticated `gh`. The `darktide-mod-maintenance` profile is opt-in.

**Quick start:**

1. In your [SyuanTsai-AI-Instructions](https://github.com/SyuanTsai/SyuanTsai-AI-Instructions) setup, install this repository as an independent Skill source and pin it using the [source pin procedure](#versioning-and-rollback).
2. Enable the [`darktide-mod-maintenance` profile](catalog/profiles.json).
3. Invoke [`auto-update-darktide-mod`](skills/auto-update-darktide-mod/SKILL.md) and follow its instructions for a Nexus Main file or a supplied ZIP.

**License and attribution:** [Apache-2.0](LICENSE) covers repository-authored material. See [PROVENANCE.md](PROVENANCE.md) for excluded material and [NOTICE](NOTICE) for attribution.

## 概覽

**這是什麼：** 這個 Agent Skill 從 Nexus Mods 的壓縮檔安全更新《Warhammer 40,000: Darktide》的 MOD，並同步臺灣繁體中文（`zh-tw`）在地化內容。它可用於維護[公開的 Darktide MOD 合集](https://github.com/SyuanTsai/Warhammer-40-000-DARKTIDE-Mods)。

**解決的問題：** 手動替換 MOD 時，既有翻譯可能在未察覺的情況下遺失或損毀。這套流程會在來源未變更時保留可靠的翻譯、記錄 Git 證據，並要求通過 Candidate Gate 後才能建立或更新 Pull Request（PR）。發布後會在本機審查候選版本。

**主要 Skills**

| Skill | 功能 |
| --- | --- |
| [`auto-update-darktide-mod`](skills/auto-update-darktide-mod/SKILL.md) | 使用經驗證的 Nexus Main 檔案或使用者提供的 ZIP 更新 MOD，保留使用中的 `zh-tw`，並記錄 Schema 14 或 15 的 Git 證據。支援取得來源、認領或繼續更新、處理審查回饋，以及完成合併後的收尾作業。 |

**環境需求：** 僅支援 Windows。需要 PowerShell 7、Git，以及已設定的 GitHub connector 或已完成身分驗證的 `gh`。必須手動啟用 `darktide-mod-maintenance` 設定檔。

**快速開始：**

1. 在 [SyuanTsai-AI-Instructions](https://github.com/SyuanTsai/SyuanTsai-AI-Instructions) 的設定中，將此儲存庫安裝為獨立的 Skill 來源，並依照[來源版本固定程序](#versioning-and-rollback)固定版本。
2. 啟用 [`darktide-mod-maintenance` 設定檔](catalog/profiles.json)。
3. 呼叫 [`auto-update-darktide-mod`](skills/auto-update-darktide-mod/SKILL.md)，依指示使用 Nexus Main 檔案或使用者提供的 ZIP。

**授權與署名：** [Apache-2.0](LICENSE) 適用於此儲存庫自行撰寫的內容。授權範圍以外的內容請見 [PROVENANCE.md](PROVENANCE.md)，署名資訊請見 [NOTICE](NOTICE)。

---

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
