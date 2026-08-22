# Deterministic MOD Update Automation

Load this reference only when executing, resuming, diagnosing, or extending the fixed stage runner. The expanded Schema 14 Workflow remains normative when this reference omits a policy detail.

## Install

Install the complete `auto-update-darktide-mod` Skill directory from one immutable `darktide-translate` source pin. PowerShell 7, Git, and Pester 5 are required. Publication additionally requires authenticated `gh` access to the target MOD repository.

Before a real run, verify the package and materialize the Workflow outside both repositories:

```powershell
./scripts/Test-ReferenceIntegrity.ps1
./scripts/Expand-Schema14Reference.ps1 -Document Workflow -OutputDirectory $freshTemporaryDirectory
```

Do not copy only `mod-update.ps1`; the runner, independent validator, packaged Workflow, package binding, and state contract form one versioned unit.

## Usage

The archive must be a stable, ordinary ZIP directly under the target repository's `AI Auto Update` directory. The canonical MOD directory must already be known and must match the ZIP's single root directory.

Start a run:

```powershell
./scripts/mod-update.ps1 claim `
  -RepositoryRoot 'D:\Games\Warhammer-40-000-DARKTIDE-Mods' `
  -ArchivePath 'D:\Games\Warhammer-40-000-DARKTIDE-Mods\AI Auto Update\ExampleMod.zip' `
  -ModDirectory 'ExampleMod'
```

The JSON result returns the generated `statePath`. Resume individual stages with that exact file:

```powershell
./scripts/mod-update.ps1 verify-source -RepositoryRoot $repository -StatePath $statePath
./scripts/mod-update.ps1 extract -RepositoryRoot $repository -StatePath $statePath
./scripts/mod-update.ps1 install -RepositoryRoot $repository -StatePath $statePath
./scripts/mod-update.ps1 localization -RepositoryRoot $repository -StatePath $statePath -LocalizationPlanPath $plan
./scripts/mod-update.ps1 build-commits -RepositoryRoot $repository -StatePath $statePath
./scripts/mod-update.ps1 validate -RepositoryRoot $repository -StatePath $statePath
./scripts/mod-update.ps1 publish -RepositoryRoot $repository -StatePath $statePath
./scripts/mod-update.ps1 review-snapshot -RepositoryRoot $repository -StatePath $statePath -LocalReviewPath $localReview
```

`run` executes the same ordered stages. After publication it returns `waiting-input` instead of pretending to perform semantic Review. Expand and read the packaged Review Baseline, review the immutable F, write the local Review artifact below, then resume the same `run` with `-StatePath` and `-LocalReviewPath`. The second invocation completes the zero-wait external snapshot and stops at `awaiting-user-merge`. It does not merge a PR or release the MOD identity reservation.

Every result contains the run ID, stage, state, active and waiting milliseconds, and the primary artifact SHA-256. Completed stages are idempotent: rerunning them reuses the matching same-run receipt instead of creating duplicate commits or PRs.

### Localization plan

The Agent first determines active `zh-tw` targets, wording, placeholders, markup, and lookup structure under Schema 14. It then supplies deterministic byte-span approvals over the Git-normalized indexed base:

```json
{
  "schemaVersion": 1,
  "mode": "zh-tw",
  "removedPaths": [
    "Warhammer 40,000 DARKTIDE/mods/ExampleMod/scripts/mods/ExampleMod/removed_localization.lua"
  ],
  "files": [
    {
      "relativePath": "Warhammer 40,000 DARKTIDE/mods/ExampleMod/scripts/mods/ExampleMod/ExampleMod_localization.lua",
      "indexedSha256": "<sha256>",
      "approvedSpans": [
        {
          "startByte": 120,
          "length": 6,
          "oldSha256": "<sha256>",
          "replacementBase64": "<base64>"
        }
      ]
    }
  ]
}
```

Spans must not overlap. `oldSha256` binds each decision to the immutable indexed bytes. The generator applies only those replacements; the independent validator separately proves that every byte outside the approved spans is unchanged. Direct fields and dynamic lookups use the same byte contract because semantic selection stays outside the script. Put an upstream-deleted active target in `removedPaths`; the runner requires it to be absent after raw installation and checkpoints that deletion in C2. A newly added target is a normal `files` entry and may have an empty `approvedSpans` array when upstream bytes are intentionally unchanged.

### Local Review artifact

Local Review is an Agent decision over the packaged Review Baseline, not a result the deterministic script can invent. Bind it to the current PR F and Candidate Gate:

```json
{
  "schemaVersion": 1,
  "result": "passed",
  "headOid": "<F commit OID>",
  "candidateGateSha256": "<validation-report SHA-256>",
  "reviewedAt": "<ISO-8601>",
  "findings": [],
  "securityBlocking": []
}
```

Every finding must have a completed `keep`, `resolved`, or `out-of-scope` disposition. The runner copies this input into run-local `artifacts/review.json`; the independent validator then verifies local HEAD, remote branch, non-draft PR head, F, reviewed OID, Gate SHA, and the zero-wait external observation before state can become `awaiting-user-merge`.

## Recovery

Keep `state.json`, the claimed archive, MOD identity lock, worktree, branch, and artifacts together. A retry must use the exact returned `statePath`; never create a replacement generation to bypass a failed run.

- A completed stage returns its existing receipt only after re-hashing its primary artifact, rechecking the lock-owner tuple, and—after evidence exists—confirming HEAD still equals F.
- Claim first moves the stable source into `.claims/<run-id>/source`, records the fixed Workflow/Baseline source tuple, and writes `state.json` with the immutable run/worktree/archive tuple before creating the worktree. Retrying that state reattaches a partially created worktree or branch and moves the same claimed archive into the run; it never starts a replacement generation. `claim.json` and `owner.json` retain the planned state path so the narrower pre-state crash window remains attributable to the same run.
- Every state-mutating resume uses an atomic run-local writer lock bound to machine, PID, process start time, state path, and an unguessable token. A live owner blocks the second writer; a stale lock is retained as evidence before the original run resumes.
- An interrupted extraction preserves the previous directory under a recovery name before atomically installing the new extraction.
- Recorded C0/C1/C2/C3/F OIDs and trees are revalidated by the independent Gate before publication.
- An existing open PR is updated; a second PR is not created. A closed PR stops for user recovery.
- After publication, history is append-only. Never reset, rebase, squash, force-push, or replace rejected evidence.
- External review takes one zero-wait snapshot. `requested-pending` is non-blocking and schedules no watcher.

When identity, archive provenance, path containment, or security evidence is ambiguous, the run becomes `waiting-user` and retains its reservation and artifacts.

## Rollback

Before publication, abandon a run only with explicit user authorization: retain rejected evidence, remove only the exact run-owned worktree and branch, return the archive without overwriting a different file, and release only the matching lock-owner tuple.

After publication, rollback is a new append-only repair or PR closure; never rewrite the published branch. After merge, use Schema 14 finalization to verify the merged F, archive evidence, and owner tuple before removing the worktree or releasing the reservation.

Rolling back the Skill itself means restoring a previous immutable `darktide-translate` source pin. Existing MOD runs remain pinned to the source tuple recorded in their own `state.json`.

## Known limitations

- Only ZIP archives are accepted by the deterministic extractor.
- Nexus identity and translation wording remain Agent-verified inputs; the script does not log in, bypass CAPTCHA, scrape credentials, or invent translations.
- The runner assumes one canonical MOD directory and one repository-local `main` base. Conflicting or multi-root archives stop.
- Publication needs authenticated `git` and `gh`; unavailable external review is recorded and does not trigger login prompts.
- The automation does not merge PRs, poll reviews, release reservations, or finalize merged runs automatically.

## MOD exceptions

Put a MOD-specific exception in a separate reference and load it only after canonical identity is known. An exception may describe active localization paths, dynamic lookup discovery, placeholders, markup, metadata locations, or validation additions. It must not weaken archive containment, single-writer locking, byte preservation, C0/C1/C2/C3/F evidence, the independent Candidate Gate, append-only publication, or zero-wait review behavior.

Add regression coverage before enabling a new exception. Use neutral synthetic fixtures for structure; use a real MOD only for the required authorized end-to-end trial and retain its stage timings and artifact hashes.
