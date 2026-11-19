<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Rollback

Rollback is source-pin based. Do not rewrite a released tag, force-update consumers under the same version, migrate active Schema 14 run state, or downgrade Schema 15 state implicitly.

## Consumer rollback

1. Stop selecting the `darktide-mod-maintenance` profile if the Skill must be disabled immediately.
2. Restore the previous complete `darktide-translate` source-pin JSON: requested ref, resolved commit, repository content SHA-256, and installed-file manifest.
3. Restore the matching installed Skill files and verify `scripts/Test-ReferenceIntegrity.ps1` from that pinned revision.
4. Re-run consumer discovery and compatibility filtering.
5. Resume an existing MOD run only with the exact Workflow/Baseline tuple recorded in that state. Schema 15 also requires its recorded extension, source request, source receipt, verified source, and localization-workset evidence tuple.
6. Remove only files managed by the newer source pin. Do not delete unrelated Skills, the `.agents/skills/*` managed projections, or target MOD run evidence.

After restoring a pin, reproduce the repository-owned checks with `pwsh -NoLogo -NoProfile -File ./scripts/Test-DarktideRepository.ps1 -RepositoryRoot .` and complete Pester discovery under `tests/`. Pull requests are validated by the pinned consumer gate on Windows, Linux, and macOS; authority upgrades change only `config/authority-pin.json`'s `commit`.

Version 0.2.x cannot resume a Schema 15 state. Restore an exact compatible 0.3.x source pin or leave the run stopped for explicit recovery. Preserve `.incoming-<run-id>` retained evidence, `verified-source`, `review-artifacts/source-receipt.json`, acquisition records, reservations, state, worktree, branch, and any pre-publication localization workset.

## Repository rollback

Create a new commit that restores the previous behavior and publish a new patch version. Never move or overwrite an existing release tag.

## K1 coordination-lease rollback

Version 0.4.0 changes shared coordination and MOD reservation leases from the legacy `.locks/<id>/` directory layout to immutable-receipt single-file leases with token-bound acquire, heartbeat, and release operations. The runtime deliberately treats an existing legacy lease directory as held with unknown ownership and fails closed; it never deletes, converts, or reuses that directory automatically.

Before rolling back or forward across this format boundary, stop every process that can use the affected Skill state. Preserve the legacy directory as evidence, verify independently that no owner is active, and have an operator move it to a separately retained migration archive outside the live `.locks` namespace. Do not rename its contents into the new lease file or synthesize a released receipt. Resume only after the live lease path is absent and all participants run the same pinned Skill version. If ownership cannot be established, leave the state stopped and retain the directory for manual recovery.

An absent shared single-file owner accompanied by a recognizable `.<owner-leaf>.publish-<guid>.tmp` in `.locks`, or an absent MOD owner accompanied by the matching owner-leaf temporary in `.locks/mod`, is not the legacy directory format. The owner-update guard reports `BLOCKED: incomplete owner publication residue exists under '<relative-lock-root>' (...)`. Keep the affected shared namespace or MOD reservation stopped and follow **Manual recovery for incomplete owner publication** in `skills/auto-update-darktide-mod/references/automation.md` before any rollback or forward retry; a temporary for a different MOD does not block this MOD.

An interrupted owner-checked directory cleanup can retain the exact sibling `<owned-directory>.codex-removal`. A same-version retry resumes that quarantine before advancing the persisted cleanup step. If both names exist, either name is not an ordinary owned directory, or deletion fails, keep the reservation cleanup-pending and follow **Manual recovery for interrupted directory cleanup** in `skills/auto-update-darktide-mod/references/automation.md`; never delete a broader claim or `In Progress` root.

## Safe fallback

If the pinned Workflow, Review Baseline, Schema 15 extension, package binding, source commit, or content hash cannot be verified, treat the Skill as unavailable for new claims. Preserve existing run state, source archives, receipts, acquisition records, reservations, worktrees, branches, PRs, and evidence until the original tuple can be restored.
