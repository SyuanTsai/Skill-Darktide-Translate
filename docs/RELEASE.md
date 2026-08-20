# Release and source pin contract

## Versioning

This repository is versioned independently from the target DARKTIDE MOD repository and from AI-Instructions consumers. Use SemVer-compatible tags (`vMAJOR.MINOR.PATCH`) and keep `VERSION` equal to the tag without the leading `v`.

## Release checklist

1. Run `pwsh -File ./tests/Invoke-Tests.ps1`.
2. Run `pwsh -File ./.agents/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1`.
3. Run `pwsh -File ./scripts/Get-SourcePin.ps1 -Ref HEAD` and retain the resolved commit and content SHA-256.
4. Confirm the catalog exposes only `auto-update-darktide-mod` through the opt-in `darktide-mod-maintenance` profile.
5. Confirm the GitHub `Validate` and `Skill Quality Gate` workflows pass on the exact PR head.
6. Merge the approved release commit to `main`.
7. Create an annotated tag matching `VERSION`, resolve it to an immutable commit, and regenerate the source content hash.
8. Consumers pin the requested tag, resolved commit, repository content SHA-256, and installed Skill reference hashes.

## Compatibility-sensitive contracts

- Stable source ID: `darktide-translate`
- Skill ID and path: `auto-update-darktide-mod` at `.agents/skills/auto-update-darktide-mod`
- Profile ID: `darktide-mod-maintenance`
- Schema 14 state semantics and C0/C1/C2/C3/F evidence boundaries
- Package path mapping in `references/package-binding.md`
- Workflow and Review Baseline byte provenance

Do not move a released tag or use a mutable branch as the consumer's only pin.
