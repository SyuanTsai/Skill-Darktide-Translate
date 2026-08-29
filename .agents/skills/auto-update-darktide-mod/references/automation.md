# Deterministic MOD Update Automation

Load this reference only when executing, resuming, diagnosing, or extending the fixed stage runner. The expanded Schema 14 Workflow remains normative when this reference omits a policy detail.

## Install

Install the complete `auto-update-darktide-mod` Skill directory from one immutable `darktide-translate` source pin. PowerShell 7, Git, and Pester 5 are required. Publication additionally requires authenticated `gh` access to the target MOD repository.

Before a real run, retain the JSON emitted by `scripts/Get-SourcePin.ps1` for the selected release outside the installed Skill and target repository. Verify the complete installed package against it, then materialize the Workflow outside both repositories:

```powershell
./scripts/Test-ReferenceIntegrity.ps1 -SkillSourcePinPath $skillSourcePinPath
./scripts/Expand-Schema14Reference.ps1 -Document Workflow -OutputDirectory $freshTemporaryDirectory
```

Do not copy only `mod-update.ps1`; the runner, independent validator, packaged Workflow, package binding, and state contract form one versioned unit.

## Usage

For a Schema 14 manual claim, the archive must be a stable, ordinary ZIP directly under the target repository's `AI Auto Update` directory. The canonical MOD directory must already be known and must match the ZIP's single root directory.

Manual and automatic claims both require a source-request `schemaVersion: 2` containing the complete Nexus page/Main-file tuple: game domain, MOD ID, canonical page URL, page Version/Last updated, Main file ID/version/uploaded-at UTC, and the full filename including extension. The claim copies it to `review-artifacts/source-request.json` and binds it with archive size/SHA-256 and acquisition method in `source-tuple.json`.

Start a run:

```powershell
./scripts/mod-update.ps1 claim `
  -RepositoryRoot 'D:\Games\Warhammer-40-000-DARKTIDE-Mods' `
  -ArchivePath 'D:\Games\Warhammer-40-000-DARKTIDE-Mods\AI Auto Update\ExampleMod.zip' `
  -ModDirectory 'ExampleMod' `
  -SourceRequestPath 'D:\Source Facts\ExampleMod-source-request.json' `
  -MetadataPath 'README.md', '.hash/examplemod.hash' `
  -SkillSourcePinPath 'D:\Pins\darktide-translate-v0.3.1.json'
```

### Schema 15 automatic source

Read `references/schema-15.md` completely before a new automatic-source run. Supply the normalized Schema 15 source request and a fixed run ID. The request contains identity metadata, never credentials or a signed download URL.

For an existing signed-in browser session, download only into the fixed aggregate run path `AI Auto Update/In Progress/<normalized-mod-slug>-<first-eight-run-id-characters>/.incoming-<run-id>`. The runner normalizes the MOD directory to a lowercase safe slug, so compute the path before starting the browser download; a sibling `.incoming-*` directly under `AI Auto Update` is outside the run boundary and is rejected. A single `run` invocation acquires, independently verifies, receipt-binds, claims, and continues the ordered stages:

```powershell
./scripts/mod-update.ps1 run `
  -RepositoryRoot 'D:\Games\Warhammer-40-000-DARKTIDE-Mods' `
  -ModDirectory 'ExampleMod' `
  -RunId '11111111-2222-4333-8444-555555555555' `
  -SourceRequestPath 'D:\...\source-request.json' `
  -SkillSourcePinPath 'D:\Pins\darktide-translate-v0.3.1.json' `
  -Provider browser `
  -DownloadedFilePath 'D:\Games\Warhammer-40-000-DARKTIDE-Mods\AI Auto Update\In Progress\examplemod-11111111\.incoming-11111111-2222-4333-8444-555555555555\ExampleMod.zip'
```

`acquire-source` and receipt-bound `claim` remain separately callable for coordinators and diagnosis. New automatic runs preflight immutable base localization before branch creation; a loader-only entry returns `AUTOMATION_EXCLUDED: localization_entry_is_loader` while retaining acquisition evidence and the per-MOD reservation.

For a bounded diagnostic or coordinator handoff, `run -Until source-verified` and `run -Until localized` stop after those completed boundaries; the default remains `awaiting-user-merge`.

After localization passes and before `build-commits`, prepare both metadata inputs from the archived `review-artifacts/source-tuple.json`: add or replace the complete 11-field provenance block inside the current MOD's Nexus-linked README section, leaving other MOD sections intact, and create or replace `.hash/<normalized-slug>.hash` with the same exact values. Preserve timestamp strings byte-for-byte from the tuple; do not let a native JSON parser convert them to local `DateTime` values. The runner validates and commits these Agent-prepared files but does not synthesize them. When either input is missing, `build-commits` returns a resumable `waiting-input` metadata-preparation handoff with the exact missing paths and source-tuple receipt before security validation or C1; a missing or changed file after metadata preview remains a fail-closed recovery error.

Acquisition atomically archives the supplied request as run-local `review-artifacts/source-request.json` and the verified Skill pin as `review-artifacts/skill-source-pin.json`; receipt-bound claim accepts only that exact tuple and verifies its hashes against `source-acquisition.json` and the MOD reservation owner. Claim then creates `source-tuple.json`, whose contract SHA binds run, acquisition method, complete Nexus facts, request/receipt, and archive filename/size/SHA. Every resume proves that the supplied state file is physically below the requested repository, that its `repositoryRoot`, `statePath`, and `runRoot` self-bind to that file, and that its MOD lock key and path equal the canonical reservation derived from the MOD identity. Every reservation-owner read or write, source read, receipt write, delivery move, workset apply, and workset deletion rechecks all existing path components for reparse points. The API provider reads an ephemeral HTTPS Nexus download URL from `NEXUS_DOWNLOAD_URI` and an optional API key from `NEXUS_API_KEY`. Automatic redirects are disabled; at most ten redirect hops are followed manually, and every hop must remain HTTPS on `nexusmods.com` or one of its subdomains before any credential-bearing request is sent. These environment values are never written to state or receipts. Missing URLs, partial files, instability, and rate limits are `waiting-system`; login, OTP, CAPTCHA, terms, permissions, unsupported archives, and a missing or invalid Skill pin are `waiting-user`. Identity or hash mismatches are blocked.

Use `scripts/Invoke-ModUpdateQueue.ps1 -SkillSourcePinPath <pin.json>` for acquisition concurrency. Its throttle is restricted to one through four distinct MOD identities; duplicate identities are rejected before workers start, and every worker receives the same verified source pin.

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

If `extract` reports a changed risky payload, do not edit `state.json`. After the user approves the exact file, provide a separate JSON artifact and resume the same stage with `-SecurityOverridePath`:

```json
{
  "schemaVersion": 1,
  "runId": "<same run ID>",
  "archiveSha256": "<same archive SHA-256>",
  "approvals": [
    {
      "relativePath": "ExampleMod/bin/payload.dll",
      "fileSha256": "<exact extracted file SHA-256>"
    }
  ]
}
```

The runner accepts no wildcard, directory, or reusable approval. It copies the canonical approval to `artifacts/security-overrides.json`, binds it to the current run/archive, and records `approved-exact-tuple` in the extraction manifest. Added or changed native executables, DLLs, install/system scripts, executable-mode or executable-magic files, and nested archives remain `waiting-user` without that exact tuple; unchanged risky bytes already present at C0 are recorded as `unchanged-from-c0`. Before `build-commits` creates or resumes any C1/C2/C3/F commit, the independent validator reopens the claimed archive, re-hashes the extraction manifest and exact approval receipt, reconstructs every risky-payload disposition against C0, and writes `artifacts/precommit-security-validation.json`. A changed or missing receipt therefore stops before another checkpoint commit, not only at the later Candidate Gate.

ZIP listing rejects Windows reparse attributes, Unix symlinks and other non-regular special entry types, exact/case/Unicode collisions, directory/file collisions, and a file entry that is also an ancestor of another entry before extraction begins.

`run` executes the same ordered stages. After publication it captures one zero-wait PR feedback/external-review snapshot and returns `waiting-input` instead of pretending to perform semantic Review. Expand and read the packaged Review Baseline, review the immutable F plus the returned feedback snapshot, write the local Review artifact below, then resume the same `run` with `-StatePath` and `-LocalReviewPath`. The second invocation revalidates that same snapshot and stops at `awaiting-user-merge`. It does not merge a PR or release the MOD identity reservation.

Every completed-stage result contains the run ID, stage, state, primary artifact SHA-256, and `wallClockMilliseconds`, `activeMilliseconds`, `waitingMilliseconds`, `stabilityObservationMilliseconds`, and `coordinationWaitMilliseconds`. Active plus waiting equals wall-clock; Schema 14 claim classifies its required archive stability observation as waiting, while contended shared-lock acquisition is recorded separately as coordination wait. Completed stages are idempotent: rerunning them reuses the matching same-run receipt instead of creating duplicate commits or PRs. Before any state-mutating resume takes its writer lock, and again before a completed-stage fast path reuses a receipt, the runner verifies the complete installed Skill package against the run-local `review-artifacts/skill-source-pin.json` and matches its pin SHA, repository, version, immutable commit, and repository content hash to state. Package drift fails closed without replacing or updating the old run pin. A completed localization receipt repairs a stale top-level `installed` state to `localized` without reapplying localization.

New Schema 14 and Schema 15 states record the runtime Skill pin. A pre-0.3 Schema 14 state that lacks `workflowSourcePinPath` remains on its legacy authoring-reference tuple and is validated through the legacy Schema 14 compatibility path; it is never rewritten or upgraded in place. Schema 15 has no implicit downgrade or pin migration.

### Localization plan

This subsection is Schema 14 only.

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

### Schema 15 localization workset

After raw installation, `localization` creates the fixed run-local `review-artifacts/localization-workset.json` with `New-LocalizationWorkset.ps1`. OLD comes from `baseOid`; NEW is a byte-identical physical staging copy. The scanner never executes Lua.

If the workset contains pending `AI_REQUIRED` units, including active `missing_zh_tw` units, the runner returns `waiting-input`. Review only those unit IDs, set `reviewStatus` to `approved`, and provide `suggestedZhTwExpression`. Do not edit classification, action, paths, source spans, or non-AI units; non-AI review fields remain `not-required` and null. `immutableContractSha256` binds every other field and is independently recomputed. Resume the same `localization` stage.

`Apply-LocalizationWorkset.ps1` selects INSERT, REPLACE, or REMOVE, preserves BOM/newlines, and records byte edits. It persists a `pending` deterministic apply receipt before replacing NEW bytes; a resume accepts only the recorded input or output hash, then completes the same receipt. C2 checkpoints raw upstream localization and C3 applies the merged workset artifact. `Test-LocalizationWorksetReceipt.ps1` independently recomputes the exact authorized edits from immutable units plus raw NEW bytes and rejects any self-authorizing receipt mutation before the Gate proves the merged and Git bytes. A passing Gate records the workset hash and counts, then deletes the JSON through a separate pending/deleted receipt before publication; it is never added to Git.

### Local Review artifact

Local Review is an Agent decision over the packaged Review Baseline, not a result the deterministic script can invent. The first `review-snapshot` or aggregate `run` call after publication captures one immutable `artifacts/review-snapshot.json` and returns `waiting-input`. The bounded capture includes review bodies, issue comments, and up to 100 review threads with up to 100 comments per thread; pagination beyond that fixed capacity fails closed instead of silently omitting feedback. This capture happens even when `localizationMode=none` makes optional external localization Review not applicable. Review that fixed artifact together with F and the Candidate Gate, then bind the supplied Review to all three:

```json
{
  "schemaVersion": 1,
  "result": "passed",
  "headOid": "<F commit OID>",
  "candidateGateSha256": "<validation-report SHA-256>",
  "feedbackSnapshotSha256": "<review-snapshot.json SHA-256>",
  "reviewedAt": "<ISO-8601>",
  "findings": [],
  "securityBlocking": []
}
```

Every actionable finding must contain priority, location, violated baseline, evidence, consequence, and a completed `keep` or `resolved` disposition. Out-of-scope observations are not findings. The runner copies this input into run-local `artifacts/review.json`; the independent validator then re-hashes the immutable feedback snapshot, checks its run/F/external-observation tuple against state, verifies the local Review's snapshot SHA and timestamp/finding schema, and verifies local HEAD, remote branch, non-draft PR head, F, reviewed OID, Gate SHA, and immutable evidence receipt/artifacts before state can become `awaiting-user-merge`. A completed-stage resume reruns that independent completion check instead of trusting only the old completion artifact.

## Recovery

Keep `state.json`, the claimed archive, MOD identity lock, worktree, branch, and artifacts together. A retry must use the exact returned `statePath`; never create a replacement generation to bypass a failed run.

- Every pinned resume validates the complete installed Skill package against the fixed run-local `review-artifacts/skill-source-pin.json` before acquiring the reservation worker or state writer lease. A package file, content hash, commit, compressed reference, or expanded reference mismatch fails as package drift without changing state, lock evidence, source, or the immutable pin. The completed-stage fast path repeats this binding check immediately before receipt reuse.
- A completed stage returns its existing receipt only after the package binding passes, re-hashing its primary artifact, rechecking the lock-owner tuple, and—after evidence exists—confirming HEAD still equals F.
- Claim resolves the immutable base and worktree plan before taking the MOD identity lock, records the fixed Workflow/Baseline source tuple, and writes writer-protected `state.json` before moving the stable source into `.claims/<run-id>/source` or creating the worktree. Retrying that state can recover the ZIP from its original queue path, reattach a partially created worktree or branch, and move the same claimed archive into the run; it never starts a replacement generation. `claim.json` and `owner.json` retain the planned state path so the narrower pre-state crash window remains attributable to the same run.
- Every state-mutating resume uses an atomic run-local writer lock bound to machine, PID, process start time, state path, and an unguessable token. A live owner blocks the second writer; a stale lock is retained as evidence before the original run resumes.
- The MOD reservation separately binds reservation/worker tokens plus machine, PID, and process-start time. Active workers refresh heartbeat during long file, Git, download, and Gate operations; every owner write is token-guarded. Normal process exit and waiting states atomically clear the active worker tuple and retain the same run as `reserved`.
- `source-acquisition.lock` protects only queue inventory/claim/destination moves; `git-coordination.lock` protects only shared fetch/branch/worktree metadata and remote-ref publication by `git push`. Both are short-lived and owner-checked, stale lock directories are retained instead of overwritten, and neither lock wraps commits, Candidate Gate, GitHub PR/Review calls, or the run lifecycle.
- An interrupted extraction preserves the previous directory under a recovery name before atomically installing the new extraction.
- `build-commits` re-hashes the complete raw install tree against its immutable manifest before C1/C2 recovery, validates the immutable source tuple plus both required metadata paths (`README.md` and the current `.hash/<slug>.hash`), and writes `metadata-preview.json` before C1. Every required metadata field must match that tuple. Metadata bytes remain unstaged until after C3, and a partial-checkpoint resume rejects any change from the recorded preview inputs.
- Before every C1/C2/C3/F commit, the runner reads the complete staged path set, rejects entries outside that checkpoint's deterministic allowlist, and re-hashes index blobs against the immutable normalization, indexed-localization, merged-localization, or metadata-preview representation. It resets only the MOD index before a C1 retry so a rejected clean-filter result cannot survive recovery, then executes `git diff --cached --check`. Only exact warnings on staged immutable-upstream paths in C1/C2 are retained as upstream-whitespace exceptions; C3/F warnings are blocking.
- The independent Candidate Gate reconstructs the metadata-preview input contract and re-reads both metadata blobs from immutable F. Their blob OID, indexed size/SHA, and `none|crlf-to-lf` transform must match the preview; matching only the raw worktree file is insufficient.
- After every C1/C2/C3/F checkpoint, `build-commits` immediately persists its OID/tree; C1/C2/C3 additionally retain their parent OID/tree tuple. A later error records the failed timing attempt, partial HEAD/tree, checkpoint, generation, and `same-run-checkpoint-resume` disposition. Resume accepts only the latest recorded checkpoint whose HEAD/tree and applicable parent-tree invariants still match; it continues the same generation without duplicate commits. Missing or contradictory partial evidence fails closed. Failed attempts remain in `stageTimings.build-commits.attempts` after a later successful resume.
- Failures and Schema 15 localization `waiting-input` exits in every started stage preserve the actual attempt result plus wall/active/wait timing and append-only attempt history, including attempts reached through the aggregate `run` command.
- Git diff and name-status evidence captures Git stdout as exact bytes; it is never trimmed, decoded/re-encoded, or rewritten with platform-specific line endings.
- One evidence generation launches the fixed Git diff/name-status tasks with a maximum concurrency of four, then records every task's base/head/tree, exact artifact path/size/SHA, start/completion time, the candidate-tree enumeration, the manifest-bound batch input tuple, Git/parameter versions, and coordinator verification in receipt schema 2. The coordinator independently rereads every C1/C2/C3/F range, records the deterministic paths plus their SHA and allowlist class, and hashes that contract. The independent Gate reconstructs the receipt, changed-path contract, every artifact, and every Git tree instead of trusting only the receipt file SHA or a self-asserted `passed` value.
- Recorded C0/C1/C2/C3/F OIDs and trees are revalidated by the independent Gate before publication.
- Empty C2/C3 trees require structured `KEEP` reasons bound to target paths, localization mode/manifest, parent/current trees, and a reconstructible contract hash. The Gate rejects missing, fake, unknown, or contradictory reasons and independently binds README/formal-hash metadata preview fields to the same complete source tuple. Both files must preserve all 11 tuple fields. README uses unique labeled list entries with exact values; substring, prefix/suffix, missing, duplicate, and contradictory matches fail.
- GitHub CLI operations run from the recorded worktree and publication uses the remote stored in state. An existing open PR is updated; a second PR is not created. A closed, retargeted, head-mismatched, or stale/electronically edited evidence-summary body stops publication or Review completion. The runner compares the normalized remote body with its canonical rendering, and the independent completion Gate confirms the body still carries the current F/Gate/evidence tuple.
- After publication, history is append-only. Never reset, rebase, squash, force-push, or replace rejected evidence.
- External review takes one zero-wait snapshot. `requested-pending` is non-blocking and schedules no watcher, but is emitted only when an existing request is observed or the new request call succeeds; a failed request is recorded as `unavailable` with failure evidence.

When identity, archive provenance, path containment, or security evidence is ambiguous, the run becomes `waiting-user` and retains its reservation and artifacts.

## Rollback

Before publication, abandon a run only with explicit user authorization: retain rejected evidence, remove only the exact run-owned worktree and branch, return the archive without overwriting a different file, and release only the matching lock-owner tuple.

After publication, rollback is a new append-only repair or PR closure; never rewrite the published branch. After merge, use Schema 14 finalization to verify the merged F, archive evidence, and owner tuple before removing the worktree or releasing the reservation.

Rolling back the Skill itself means restoring a previous immutable `darktide-translate` source pin. Existing MOD runs remain pinned to the source tuple recorded in their own `state.json`.

## Known limitations

- Only ZIP archives are accepted by the deterministic extractor.
- Nexus identity remains receipt-verified. Translation wording is Agent-supplied only for Schema 15 `AI_REQUIRED` units or Schema 14 approved spans; scripts do not log in, bypass CAPTCHA, scrape credentials, or invent translations.
- The runner assumes one canonical MOD directory and one repository-local `main` base. Conflicting or multi-root archives stop.
- Publication needs authenticated `git` and `gh`; unavailable external review is recorded and does not trigger login prompts.
- The automation does not merge PRs, poll reviews, release reservations, or finalize merged runs automatically.

## MOD exceptions

Put a MOD-specific exception in a separate reference and load it only after canonical identity is known. An exception may describe active localization paths, dynamic lookup discovery, placeholders, markup, metadata locations, or validation additions. It must not weaken archive containment, single-writer locking, byte preservation, C0/C1/C2/C3/F evidence, the independent Candidate Gate, append-only publication, or zero-wait review behavior.

Add regression coverage before enabling a new exception. Use neutral synthetic fixtures for structure; use a real MOD only for the required authorized end-to-end trial and retain its stage timings and artifact hashes.
