# BetterMelk real-MOD trial report (2026-08-30)

## Outcome

The `auto-update-darktide-mod` package was exercised against the live Nexus Main file for BetterMelk. The trial found two reproducible runner defects before publication. Both defects now have regression coverage and fixes in the 0.3.5 candidate. The MOD candidate itself was not published: the independent Candidate Gate rejected the run, so no push or MOD pull request occurred.

The retained run is intentionally left in place for review. Abandoning it, releasing its reservation, or requeuing it requires an explicit operator decision under the workflow contract.

## Package baseline

- Installed package version at trial start: `0.3.4`
- Pinned repository commit: `c49bc242c0aa3929c35b294545c1f5a428d89f63`
- Source-pin SHA-256: `0817de587868e0f79b700f63db42887a15a9c63c89a76a85d0a462be14c946d9`
- Installed source content SHA-256: `03f21c89343ef24cd811b4d938a3dae4cd731d661e66af8cc12a025558a531f3`
- Reference-integrity result: passed for all 22 pinned package files
- Pre-change regression result: 144 passed, 0 failed

## Immutable source tuple

- MOD: BetterMelk
- Nexus MOD ID: `71`
- Nexus file ID: `7659`
- Nexus page version: `1.14`
- Main-file upload time (UTC): `2026-08-23T21:04:00.0000000+00:00`
- Archive: `BetterMelk 71 1.14 2026-08-23T21-04Z DEJ2kEWse.zip`
- Archive size: 5,138 bytes
- SHA-256: `ec83a973598ea646d5b97782d623f9024b0681ca0f519b9aad469d26c21e0610`
- Nexus/VirusTotal SHA-256 comparison: matched
- Source tuple SHA-256: `26d875887455e9d8fb1bada8c05d2bc3e0e5cccf0d2dc42539b5c1ca550b1f9f`

The live signed-in Nexus page was used because public search indexing still showed the older 1.13 release.

## Trial identity and checkpoints

- Run ID: `428d14f8-c5cf-408b-b446-9e8aea3409fd`
- Branch: `Update/bettermelk/20260829-428d14f8`
- Status: `failed`
- Completed stages: `claim`, `verify-source`, `extract`, `install`, `localization`, `build-commits`
- C0: `9980eba2b3adf9774e2cf4ac7e6c41a0344a7222`
- C1: `3542566d5645c78d385396170838ea4eaf2e00ac`
- C2/C3: not applicable (`localizationMode=none`)
- F: `de5d77a46007353da05997c8734a4f2e5cb48f29`
- Candidate Gate: `rejected`
- Validation report SHA-256: `6ae99c00ac345e18377866751214c71b2693592ffc37e93b499263c09474885d`
- Evidence-generation receipt SHA-256: `faf3508f673c1d577501e518c554f8985cd50856dcfa69ac932a2970a492e824`
- Publication: no push and no MOD pull request

## Finding 1: first-time metadata was classified as a failure

### Observed behavior

The first `build-commits` attempt stopped with `Metadata path is missing: .hash/bettermelk.hash`. BetterMelk did not yet have formal README/hash metadata, so this was an expected first-time Agent preparation handoff rather than an unrecoverable run failure or a request for user-supplied provenance.

### Impact

- The state became `failed`, obscuring that the workflow could safely resume after bounded metadata preparation.
- The error did not return the complete set of missing metadata paths or bind the handoff to the immutable source tuple.
- Operators could mistake an Agent-owned preparation step for a user decision point.

### Fix in 0.3.5

- Discover all missing formal metadata paths before security validation or C1 creation.
- Return `waiting-input` at a dedicated `metadata-preparation` stage.
- Persist `waitingReason.code=metadata_preparation_required` and the exact missing paths, and return the source-tuple path/SHA in the handoff.
- Preserve strict fail-closed behavior for later metadata validation and preview.

### Regression evidence

- Red/Green test: `UnitT181_SuspendsForFirstTimeMetadataPreparationBeforeCreatingC1`
- Existing end-to-end integration expectation updated: `InterT200_ExecutesABytePreservingLocalizedCandidateEndToEnd`

For the already pinned 0.3.4 run, README and `.hash/bettermelk.hash` were prepared from the immutable tuple and applied as an unstaged patch before resuming. The run was not migrated to modified code.

## Finding 2: not-applicable checkpoint contracts changed null into an empty string

### Observed behavior

After the resumed build created C1 and F, the independent Candidate Gate rejected the candidate with `C2 reason is unknown, blank, contradictory, or not bound to independently revalidated evidence.` The C2/C3 reason objects correctly said localization was not applicable, but their `parentTreeOid` and `treeOid` values were serialized as empty strings by the producer. The validator reconstructed those fields as JSON null, producing a different contract SHA-256.

### Impact

- Valid no-localization candidates could never pass independent validation.
- The defect appeared only at the publication gate, after build evidence had been generated.
- The fail-closed Gate prevented an invalidly attested candidate from being pushed.

### Fix in 0.3.5

- Normalize blank tree identifiers to actual null before both contract hashing and reason serialization.
- Keep real tree identifiers strict and unchanged.

### Regression evidence

- Red/Green test: `UnitT201_PreservesNullTreesInNotApplicableCheckpointReasons`
- Targeted tests for T181/T201 passed.
- The byte-preserving end-to-end integration test passed after its expected first-time metadata handoff and attempt accounting were updated.

## Candidate validation

- PowerShell parser validation: passed
- Targeted UnitT181/UnitT201 regression tests: 2 passed, 0 failed
- Updated InterT200 end-to-end integration test: passed
- Full post-change suite: 145 passed, 0 failed, 0 skipped in 665.19 seconds

## Process observations

1. Live Nexus page data must take precedence over stale search indexing, but the acquired archive must still be bound to a file ID, UTC upload time, size, and SHA-256.
2. Agent-prepared formal metadata is a distinct resumable input class; it should not share `waiting-user` semantics with provenance or authorization decisions.
3. Optional checkpoint fields need one canonical JSON representation before hashing. PowerShell string parameter coercion can otherwise turn null into an empty string.
4. Candidate Gate rejection worked as intended: it retained evidence and prevented publication.
5. A run must remain bound to its pinned package. Fixing the package does not authorize migrating an in-progress run to the new code.

## Suggested Jira candidates (operator decision)

The fixes are already included in the 0.3.5 candidate PR, so Jira tickets would be useful mainly for traceability or follow-up hardening:

- **First-time metadata preparation lifecycle** — track the new `metadata-preparation` contract, UI/operator wording, and coverage for README-only, hash-only, and both-missing variants.
- **Canonical nullable checkpoint hashing** — audit other signed/hashed JSON contracts for null-versus-empty-string coercion and add shared canonicalization helpers if the pattern recurs.

## Recovery recommendation

After 0.3.5 is reviewed and installed, explicitly authorize abandonment of the retained 0.3.4 BetterMelk run, release its reservation through the workflow command, and submit a fresh immutable source request. Do not reuse or edit the old run state. The fresh run should then prove the corrected metadata handoff and nullable checkpoint contract end to end before any MOD PR is opened.
