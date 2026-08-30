# Release and source pin contract

## Versioning

This repository is versioned independently from the target DARKTIDE MOD repository and from AI-Instructions consumers. Use SemVer-compatible tags (`vMAJOR.MINOR.PATCH`) and keep `VERSION` equal to the tag without the leading `v`.

## Release checklist

1. Run `pwsh -File ./tests/Invoke-Tests.ps1`.
2. Run `pwsh -File ./.agents/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1`.
3. Run `pwsh -File ./scripts/Get-SourcePin.ps1 -Ref HEAD` and retain the complete JSON: resolved commit, content SHA-256, Skill path, and per-file blob/SHA-256 manifest.
4. Confirm the catalog exposes only `auto-update-darktide-mod` through the opt-in `darktide-mod-maintenance` profile.
5. Confirm Schema 15 acquisition and multi-process tests cover known unsupported extensions before download, signature detection, partial downloads, URL sanitization, receipt verification, same-run claim, loader preflight, queue deduplication, the concurrency ceiling, distinct-MOD isolation, competing generations, stale-owner recovery, and old-token rejection.
6. Confirm localization-workset tests cover deterministic classification (including missing zh-tw and direct `Localize(...)` source fallback), byte spans, AI-only edit authorization, pure-loader exclusion, independent receipt-plan recomputation, idempotence, and Candidate Gate rejection outside approved edits.
7. Confirm the GitHub `Validate` and `Skill Quality Gate` workflows pass on the exact PR head.
8. Merge the approved release commit to `main`.
9. Create an annotated tag matching `VERSION`, resolve it to an immutable commit, and regenerate the source content hash.
10. Consumers retain that source-pin JSON outside the installed Skill and target repository, verify it with `Test-ReferenceIntegrity.ps1 -SkillSourcePinPath`, and pass it to every new `mod-update.ps1` run. The runner archives a run-owned copy.

A live Nexus smoke test is optional and must never persist API keys, ephemeral download URLs, cookies, authorization headers, or signed URL query strings. Synthetic tests remain the mandatory deterministic release gate.

## Compatibility-sensitive contracts

- Stable source ID: `darktide-translate`
- Skill ID and path: `auto-update-darktide-mod` at `.agents/skills/auto-update-darktide-mod`
- Profile ID: `darktide-mod-maintenance`
- Schema 14 state semantics and C0/C1/C2/C3/F evidence boundaries
- Schema 15 state semantics, source request/receipt tuple, per-MOD reservation, bounded concurrency, and `review-artifacts/localization-workset.json` lifecycle
- Pre-0.3 Schema 14 states without a runtime source-pin path remain verifiable through their recorded legacy authoring tuple; no in-place state migration is permitted
- Package path mapping in `references/package-binding.md`
- Workflow, Review Baseline, and Schema 15 extension byte provenance

Do not move a released tag or use a mutable branch as the consumer's only pin.

Version `0.3.0` is the minor release that introduces Schema 15. A Schema 14 manual run remains on Schema 14 even when executed by 0.3.x.

Version `0.3.1` is the compatible hardening release for structured C2/C3 reasons, the complete Schema 14/15 Nexus source tuple and metadata preview, short shared coordination locks, and token-guarded reservation heartbeat/lifecycle recovery. It does not migrate existing run state implicitly.

Version `0.3.2` adds pre-C1 canonical metadata and raw-install validation, staged checkpoint allowlists, immutable index-blob readback, and whitespace checks, immutable partial-checkpoint recovery evidence, failed/waiting attempt history, exact-byte bounded-parallel Git evidence with independently reconstructible receipts and coordinator changed-path contracts, F-bound metadata preview verification, changed-risky-payload approval artifacts with an independent pre-commit recheck, ZIP reparse/special-entry and file/ancestor collision rejection, remote PR evidence-summary validation, Review completion bound to an immutable feedback-snapshot SHA with bounded inline-thread capture, full immutable-evidence Review completion revalidation, and resume-time validation of the installed Skill package against each run-local pin. Existing runs are never migrated to a newer pin.

Version `0.3.3` fixes Schema 14 no-plan localization under strict mode and scopes README source-tuple validation to the current Nexus MOD section, so repositories can retain canonical metadata for multiple MODs without cross-section conflicts.

Version `0.3.4` preserves existing state contracts while completing same-run recovery hardening, clarifying the exact Schema 15 browser incoming path, distinguishing valid Unix regular-file execute modes from overlapping Windows ZIP external attributes, allowing bounded aggregate runs to stop at `localized`, resuming aggregate runs past idempotent stages after approved localization input, fixing repository-root workset finalization, and documenting the required Agent-prepared README/formal-hash handoff before evidence commits. Existing runs remain pinned to their recorded package and are never migrated implicitly.

Version `0.3.5` preserves existing state contracts while classifying a missing first-time README/formal-hash input as a resumable `waiting-input` metadata-preparation handoff before C1 and preserving JSON `null` tree OIDs in localization-not-applicable C2/C3 KEEP contracts. The runner returns missing metadata paths and the immutable source-tuple receipt instead of recording a failed build-commits attempt, while the independent Candidate Gate can now byte-for-byte reconstruct no-localization checkpoint reasons. Existing runs remain pinned to their recorded package and are never migrated implicitly.

Version `0.3.6` preserves no-plan compatibility for Schema 14 MODs without a registered localization source, but suspends with `waiting-input` and `localization_plan_required` when an installed `.mod` descriptor registers `mod_localization` and no explicit plan was supplied. It also excludes a no-zh-tw unit from manual translation when its complete source expression is exactly a direct `Localize(...)` call, while composed expressions remain translation targets. This prevents active Traditional Chinese maintenance from being silently classified as `none` or generating redundant overrides for game-localized strings; the same run resumes after the Agent supplies an explicit `zh-tw` or reviewed `none` plan. Existing runs remain pinned to their recorded package and are never migrated implicitly.
