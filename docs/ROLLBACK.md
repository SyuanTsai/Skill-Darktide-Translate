# Rollback

Rollback is source-pin based. Do not rewrite a released tag, force-update consumers under the same version, or migrate active Schema 14 run state implicitly.

## Consumer rollback

1. Stop selecting the `darktide-mod-maintenance` profile if the Skill must be disabled immediately.
2. Restore the previous `darktide-translate` requested ref, resolved commit, and repository content SHA-256.
3. Restore the matching installed Skill files and verify `scripts/Test-ReferenceIntegrity.ps1` from that pinned revision.
4. Re-run consumer discovery and compatibility filtering.
5. Resume an existing MOD run only with the Workflow/Baseline tuple already recorded in that run's state; otherwise leave it waiting for explicit recovery.
6. Remove only files managed by the newer source pin. Do not delete unrelated Skills or target MOD run evidence.

## Repository rollback

Create a new commit that restores the previous behavior and publish a new patch version. Never move or overwrite an existing release tag.

## Safe fallback

If the pinned Workflow, Review Baseline, package binding, source commit, or content hash cannot be verified, treat the Skill as unavailable for new claims. Preserve existing run state, source archives, reservations, worktrees, branches, PRs, and evidence until the original tuple can be restored.
