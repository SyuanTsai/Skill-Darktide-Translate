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

Version 0.2.x cannot resume a Schema 15 state. Restore an exact compatible 0.3.x source pin or leave the run stopped for explicit recovery. Preserve `.incoming-<run-id>` retained evidence, `verified-source`, `review-artifacts/source-receipt.json`, acquisition records, reservations, state, worktree, branch, and any pre-publication localization workset.

## Repository rollback

Create a new commit that restores the previous behavior and publish a new patch version. Never move or overwrite an existing release tag.

## Safe fallback

If the pinned Workflow, Review Baseline, Schema 15 extension, package binding, source commit, or content hash cannot be verified, treat the Skill as unavailable for new claims. Preserve existing run state, source archives, receipts, acquisition records, reservations, worktrees, branches, PRs, and evidence until the original tuple can be restored.
