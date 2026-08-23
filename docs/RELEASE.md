# Release and source pin contract

## Versioning

This repository is versioned independently from the target DARKTIDE MOD repository and from AI-Instructions consumers. Use SemVer-compatible tags (`vMAJOR.MINOR.PATCH`) and keep `VERSION` equal to the tag without the leading `v`.

## Release checklist

1. Run `pwsh -File ./tests/Invoke-Tests.ps1`.
2. Run `pwsh -File ./.agents/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1`.
3. Run `pwsh -File ./scripts/Get-SourcePin.ps1 -Ref HEAD` and retain the resolved commit and content SHA-256.
4. Confirm the catalog exposes only `auto-update-darktide-mod` through the opt-in `darktide-mod-maintenance` profile.
5. Confirm Schema 15 acquisition tests cover known unsupported extensions before download, signature detection, partial downloads, URL sanitization, receipt verification, same-run claim, loader preflight, queue deduplication, and the concurrency ceiling.
6. Confirm localization-workset tests cover deterministic classification, byte spans, AI-only edit authorization, loader exclusion, idempotence, and Candidate Gate rejection outside approved edits.
7. Confirm the GitHub `Validate` and `Skill Quality Gate` workflows pass on the exact PR head.
8. Merge the approved release commit to `main`.
9. Create an annotated tag matching `VERSION`, resolve it to an immutable commit, and regenerate the source content hash.
10. Consumers pin the requested tag, resolved commit, repository content SHA-256, and installed Skill reference hashes.

A live Nexus smoke test is optional and must never persist API keys, ephemeral download URLs, cookies, authorization headers, or signed URL query strings. Synthetic tests remain the mandatory deterministic release gate.

## Compatibility-sensitive contracts

- Stable source ID: `darktide-translate`
- Skill ID and path: `auto-update-darktide-mod` at `.agents/skills/auto-update-darktide-mod`
- Profile ID: `darktide-mod-maintenance`
- Schema 14 state semantics and C0/C1/C2/C3/F evidence boundaries
- Schema 15 state semantics, source request/receipt tuple, per-MOD reservation, bounded concurrency, and `review-artifacts/localization-workset.json` lifecycle
- Package path mapping in `references/package-binding.md`
- Workflow, Review Baseline, and Schema 15 extension byte provenance

Do not move a released tag or use a mutable branch as the consumer's only pin.

Version `0.3.0` is the minor release that introduces Schema 15. A Schema 14 manual run remains on Schema 14 even when executed by 0.3.x.
