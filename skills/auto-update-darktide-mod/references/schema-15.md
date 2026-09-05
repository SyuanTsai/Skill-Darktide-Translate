# Schema 15 automatic source and localization workset extension

This reference is normative for new Schema 15 runs. It extends the packaged Schema 14 Workflow; every Schema 14 safety, Git evidence, Candidate Gate, Review, publication, and recovery requirement remains in force unless this document explicitly replaces that behavior.

Existing Schema 14 states remain pinned to their recorded Skill source tuple. Never migrate or reinterpret them as Schema 15.

## Source identity

A Schema 15 source request is unique only when all of these values are present:

- Nexus game domain
- Nexus MOD ID
- Nexus Main file ID
- Main file version
- expected filename
- canonical Nexus page URL
- Nexus page Version and Last updated values
- Main file uploaded-at UTC timestamp

Do not use an older file, alternate file, mirror, or filename-only match when the tuple cannot be proven. An official SHA-256 may strengthen the tuple but does not replace the Main file ID and version.

Use source-request `schemaVersion: 2` before claim. Claim archives the request and writes one immutable `review-artifacts/source-tuple.json` that binds the run ID, acquisition method, complete Nexus page/Main-file identity, full archive filename including extension, size, SHA-256, request SHA-256, and receipt SHA-256 when applicable. Schema 14 manual ZIP claims use the same complete Nexus metadata tuple with `acquisitionMethod=manual-queue`; they do not invent a receipt.

## Acquisition ordering

The fixed ordering is:

1. validate the source request and known archive extension;
2. reserve the canonical MOD identity for one run ID;
3. create the run-local `AI Auto Update/In Progress/<normalized-mod-slug>-<first-eight-run-id-characters>/.incoming-<run-id>` directory; an `.incoming-*` sibling directly below `AI Auto Update` is not run-local;
4. acquire through the API provider or an existing signed-in browser session;
5. ignore partial files and observe size and mtime twice;
6. identify the archive from magic bytes;
7. compute SHA-256 and compare the immutable source tuple and official hash when present;
8. write an immutable receipt;
9. atomically deliver the verified source;
10. independently verify the receipt before claim or worktree creation.

The incoming, verified, claimed, and run-owned source paths are distinct. Never overwrite an existing queue, claim, incoming, verified, or run source. Preserve the verified source referenced by the receipt after claim.

## Providers and credentials

Prefer an allowed Nexus API flow. Keep endpoint-specific behavior behind the provider boundary because official file APIs and entitlements may change independently of the runner.

API keys and ephemeral signed download URLs come only from environment variables or an approved secret provider. Never accept credentials as persisted request fields, print them, put them in state, or include URL query, fragment, or user information in a receipt.

The browser provider consumes only a file produced by an existing signed-in session. It never enters a password, API key, OTP, or payment data and never bypasses CAPTCHA, terms, permissions, rate limits, or download protection.

Use `waiting-user` only for login, OTP, CAPTCHA, terms, permissions, or a known unsupported archive requiring user action. Use `waiting-system` for partial downloads, instability, unavailable ephemeral URLs, rate limiting, or retryable network state. A source identity or hash mismatch is blocked, not `waiting-user`.

## Archive boundary

The first release accepts ZIP only.

- A known RAR or 7z filename stops before download with `unsupported_archive_format`.
- `.part` and `.crdownload` files never enter verification.
- ZIP, RAR, and 7z are identified by signature bytes, not extension alone.
- RAR, 7z, or unknown bytes detected after download remain in incoming with their receipt and never reach claim, extraction, or installation.

The receipt records request identity, provider, sanitized source URL, filename, size, SHA-256, archive format, official-hash result, two stability observations, timestamps, delivered path, and separate download, wait, verify, and delivery timings.

## Concurrency and recovery

At most four distinct canonical MOD identities may acquire concurrently. The same canonical MOD has one reservation and writer. Waiting workers release their execution slot but retain their exact run reservation.

Every resume uses the same run ID, source request hash, receipt hash, MOD lock owner, Skill source pin, base OID, and paths. A changed tuple stops. A crash after receipt creation or source delivery reattaches only when the preserved bytes and receipt still pass independent verification.

The active reservation worker is bound to machine, PID, process-start time, reservation token, and worker token. Long-running reads and child processes refresh heartbeat atomically. Every owner write rechecks both tokens. A normal exit or a `waiting-user`, `waiting-system`, or `awaiting-user-merge` stop clears the worker identity and leaves the run reservation in `reserved`; stale same-run reattachment retains the previous owner as evidence and never deletes a newer owner.

Use `source-acquisition.lock` only around queue inventory/claim and source destination moves. Use `git-coordination.lock` only around shared fetch, branch/worktree metadata, and the remote-ref publication performed by `git push`. Both are short, owner-checked leases with retained stale evidence; neither may wrap download, localization, evidence commits, Candidate Gate, GitHub PR mutation, Review, or the overall run lifecycle.

## Localization eligibility

Discover exactly one `*_localization.lua` below the canonical MOD boundary at the fixed base OID and exactly one physical NEW file below run-local staging. Check containment and every path component for symlinks or reparse points.

A localization entry containing only `mod:io_dofile` loader routing is `AUTOMATION_EXCLUDED: localization_entry_is_loader`. Determine this before starting a production update branch whenever eligibility metadata is available. Do not combine its referenced files into a synthetic localization source.

Inventory counts are acceptance observations, not constants. Recompute them from the pinned base OID.

## Static Lua scanner

Never execute Lua. The scanner is lexical and structural only. It must tolerate comments, quoted and long strings, escaped characters, bracketed language keys, same-line fields, a final field without a comma, nested tables, multiline expressions, concatenation, function calls, table expressions, and dynamic keys.

Each localization unit has the stable identity:

`source_id :: container_path :: key :: occurrence`

Duplicate keys remain separate occurrences. Expressions retain their raw bytes and source spans. Canonical token sequences are used only for conservative comparison; a comparison that cannot be proven safe becomes `BLOCKED` or `AI_REQUIRED`, never an automatic rewrite.

## Single localization workset

`New-LocalizationWorkset.ps1` reads OLD bytes from `base_oid` with Git object access and NEW bytes from physical staging. It writes exactly:

`AI Auto Update/In Progress/<slug>-<run-short>/review-artifacts/localization-workset.json`

The write is atomic. Repeating generation for the same base/source hashes reuses the existing workset so approved decisions are not overwritten. A different tuple is rejected.

The deterministic classifications and actions are:

| Change type | Action |
| --- | --- |
| `unchanged` | `NONE` |
| `localized_source` | `NONE` |
| `missing_zh_tw` | `AI_REQUIRED` |
| `zh_tw_only_changed` | `RESTORE_OLD_ZH_TW` |
| `source_changed_translation_unchanged` | `AI_REQUIRED` |
| `source_and_translation_changed` | `AI_REQUIRED` |
| `new_key` | `AI_REQUIRED` |
| `deleted_key` | `ACCEPT_REMOVAL` |
| `blocked` | `BLOCKED` |

When English/source structure is unchanged, upstream zh-tw drift is reverted to OLD. If OLD has no zh-tw and NEW adds it, remove the NEW field. These decisions are deterministic and are not sent to AI.

Treat every reliable OLD zh-tw unit as a curated human translation asset. An unchanged English/source expression and structure therefore preserve that unit byte-for-byte. Garbled text, Simplified Chinese leakage, a wrong number, wrong unit, damaged placeholder or markup, reversed meaning, or a materially wrong mechanic becomes an objective quality finding. Because the Schema 15 update workset keeps deterministic unchanged units intact, apply such a correction through an explicitly authorized correction run with a schema-provided exact zh-tw edit path. Style preference, terminology preference, greater explicitness, and an omitted nonessential modifier alone preserve OLD.

For `AI_REQUIRED` units, English source and in-game context are the primary meaning authority. Use zh-cn as a clarification reference, not a wording template. Produce natural Taiwan Traditional Chinese and preserve functional meaning, gameplay conditions, values, placeholders, and markup. Evaluate semantic completeness as functional meaning in context, not word-for-word coverage; idiomatic compression or restructuring is valid, and an omitted nonessential modifier alone does not make a translation unusable.

An active unit whose OLD and NEW entries both lack zh-tw is `missing_zh_tw`; it remains an explicit translation target and cannot silently pass as unchanged. The narrow exception applies only when both OLD and NEW lack zh-tw and the complete NEW source expression is provably composed solely of unshadowed global `Localize(...)` calls, parentheses, `..` concatenation operators, and string literals whose decoded content contains no Unicode letters or numbers. Classify it as `localized_source/NONE` because every visible text fragment is resolved through the active locale and neutral separators contain no text to translate. A direct `Localize(...)` call is the simplest qualifying form. Preserve an existing OLD zh-tw field through the normal classification table. Literal text, formatting, fallback, method, shadowed, dynamic, or otherwise unproven expressions remain classified by the normal table.

AI receives the `AI_REQUIRED` units and contributes `reviewStatus` plus `suggestedZhTwExpression` for the same unit IDs. Deterministic units retain `reviewStatus=not-required` and a null suggestion, while the generator supplies byte spans, actions, insertion points, and non-zh-tw fields. The generator records `immutableContractSha256` over every workset input, classification, and action except those two AI fields; generation resume, apply, and the independent Candidate Gate recompute it so the translation contribution stays precisely attributable.

## Workset apply

`Apply-LocalizationWorkset.ps1` validates the entire NEW SHA-256 before applying anything. It derives INSERT, REPLACE, or REMOVE edits, validates every approved expression as one Lua field value, applies non-overlapping edits from highest byte offset to lowest, and preserves UTF-8 BOM and newline style.

After apply, reparse the result. Every unit identity and non-zh-tw source expression must equal NEW. Bind all review fields into `reviewContractSha256`, then record each edit's original SHA-256, replacement bytes, replacement SHA-256, unit ID, and operation. The independent Candidate Gate does not trust that mutable receipt: it recomputes the review contract and exact edit plan from the immutable workset units and raw NEW bytes, compares every receipt field, reconstructs merged bytes, and proves that bytes outside the recomputed edits did not change.

## Git evidence and Candidate Gate

The existing C0/C1/C2/C3/F boundaries remain normative:

- C1 contains upstream non-localization bytes.
- C2 checkpoints raw upstream localization bytes.
- C3 contains only program-selected zh-tw workset edits.
- F adds only allowlisted metadata after C3 when required.

The independent Candidate Gate revalidates the source request, preserved receipt source, claimed archive, workset SHA-256, classification permissions, edit spans, raw and merged artifacts, Git-normalized blobs, C0/C1/C2/C3/F trees, manifests, and target paths.

When C2 or C3 has the same tree as its parent, state still records a non-empty structured `KEEP` reason. The reason binds checkpoint, recognized code, localization mode, parent/current trees, target-path hash/count, localization-manifest SHA-256, and a reconstructible contract SHA-256. Missing, blank, unknown, contradictory, or evidence-mismatched reasons fail closed. `metadata-preview.json` binds the immutable source tuple and independently rechecked README/formal-hash fields; both metadata files retain the complete archive filename including extension and may not mix facts from different Nexus Main files.

README and formal-hash source facts both preserve the complete 11-field tuple: Nexus MOD ID, page URL/version/updated time, Main file ID/version/upload time, full archive filename, size, SHA-256, and acquisition method. README uses one unique labeled list entry per field, such as `- Nexus URL: ...` and `- Archive filename: ...`; the value after every label must equal the tuple value exactly (optional paired Markdown code ticks are allowed). Substring, prefix/suffix, duplicate-label, missing-label, and contradictory values fail. Formal hash records likewise require exactly one anchored `key=value` entry for every tuple field.

The PR body contains a deterministic classification-count table and receipt/workset hashes. Delete `localization-workset.json` after a passed Candidate Gate and before publication. Preserve its SHA-256, counts, edit count, validation result, and deletion evidence in state and the Gate report. The workset must never be added to Git.

Before any C1/C2/C3/F checkpoint is created or resumed, `build-commits` invokes the independent payload-security-only validation mode. It reopens the claimed archive, verifies the extraction manifest and any exact approval receipt, reconstructs risky payload dispositions against C0, and persists `precommit-security-validation.json`; this keeps the security boundary ahead of commits as well as ahead of publication.

Archive listing accepts only ordinary files/directories. Windows reparse attributes, Unix symlinks or other special entry types, directory/file duplicates, and file/ancestor collisions stop before extraction.

## Publication and rollback

Schema 15 does not authorize push, PR mutation, merge, destructive cleanup, credential entry, or security overrides. Existing authorization boundaries remain unchanged.

Before publication, rollback retains the receipt, verified source, workset evidence hash, run reservation, rejected artifacts, worktree, and branch until the exact run is explicitly abandoned. After publication, rollback remains append-only. Restoring Skill 0.2.x resumes only Schema 14 states; it cannot resume a Schema 15 state.
