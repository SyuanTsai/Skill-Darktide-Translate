<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Provenance and licensing boundary

- Repository: [Skill-Darktide-Translate](https://github.com/SyuanTsai/Skill-Darktide-Translate)
- Audited baseline: [`d08261243d531a815128ffb8c5d99e1f4ea12f19`](https://github.com/SyuanTsai/Skill-Darktide-Translate/tree/d08261243d531a815128ffb8c5d99e1f4ea12f19)
- Review date: 2026-09-04

## Confirmed repository inventory

The audited tree contains the Darktide maintenance Skill, agent metadata, scripts, tests, references, catalog/version metadata, release and rollback documentation, and CI configuration. It contains no downloaded game data, Mod installation, localization package, upstream translation archive, credentials, or private company/Jira URL.

The repository-authored workflow, tools, tests, metadata, and documentation are the Apache-2.0 scope. The packaged source-derived reference documents described below are excluded from that grant.

## Standard v1 migration evidence

The SYP-158 migration separates the repository-owned source package into the canonical `skills/auto-update-darktide-mod/` layout and records it in `catalog/source.json` with source ID `darktide-translate`. The former `catalog/skills-catalog.json` is retained as the product-local `catalog/profiles.json` extension; it does not replace the source inventory or define central validation, security, lifecycle, or approval policy.

The six other `.agents/skills/*` directories are not Darktide-owned source packages. They are managed consumer projections whose exact target files, source repositories, revisions, and hashes are declared by `.codex/ai-instructions.manifest.json`. The migration preserves them and validates their manifest binding; it does not infer ownership or delete them.

`config/standard-v1.json` pins the reviewed `SyuanTsai-AI-Instructions` Standard v1 authority archive and normative files. `scripts/Validate.ps1` is the single local, pre-push, and CI validation entry point, while the existing Darktide domain regressions remain repository-test extensions within the canonical stage order.

## Compressed reference audit

The two packaged files were inspected as bytes and expanded, rather than classified by filename:

| Path | File type | Packaged SHA-256 | Content SHA-256 | Decision |
| --- | --- | --- | --- | --- |
| `assets/workflow-schema-14.md` | UTF-8 Markdown; byte-exact source copy | `931a38d48d3f7d23b435108fc990e395f853604cd3aafac7068c0438f9c48549` | `931a38d48d3f7d23b435108fc990e395f853604cd3aafac7068c0438f9c48549` | Source-derived upstream reference; not relicensed |
| `assets/review-baseline.md` | UTF-8 Markdown; byte-exact source copy | `d8bcaedb66f3aa6e40ad271dbf07a7a738db37bcc071c19c8eef512bb1183d26` | `d8bcaedb66f3aa6e40ad271dbf07a7a738db37bcc071c19c8eef512bb1183d26` | Source-derived upstream reference; not relicensed |

The repository's `references/source-provenance.json` records source repository `SyuanTsai/Warhammer-40-000-DARKTIDE-Mods`, source commit `f2912faf7a52304198aa0ffc096eb12a436bbb45`, workflow source blob `40752444d26a4ce39c4f32201076b1c84ad1db31`, review source blob `e1b94428c041238e3aff8cf02408b3de1387ee15`, and the historical ref `Codex/AI-Auto-Update-Workflow-Hash`. The source commit and both source blobs were checked directly. The historical branch ref is no longer available, so branch-level re-fetch is a documented residual; the commit/blob evidence remains available.

## Third-party and excluded material

Downloaded Mods, game data, localization, archives, upstream translations, Nexus content, external service content, trademarks, credentials, and user-provided or generated content retain their own rights. Handling them with this workflow does not automatically place them under Apache-2.0.

GitHub Actions, the skill validator, skill-tools, PowerShell, Git, and other runtime or hosted-service dependencies are not vendored or relicensed here. Their upstream terms apply. The two source-derived reference documents are not included in the Apache-2.0 decision and are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Decision and limits

Decision: apply Apache-2.0 only to the confirmed repository-authored current-tree scope, while preserving upstream rights for the two source-derived reference documents and all external/user content. This record does not grant a license to game, Mod, localization, archive, translation, service, or generated material. It is a source and evidence record, not a legal opinion; unreviewed future additions require a new provenance decision.
