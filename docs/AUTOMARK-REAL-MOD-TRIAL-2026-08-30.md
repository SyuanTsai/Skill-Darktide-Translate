# AutoMark 2.5.1 real-MOD trial — 2026-08-30

## Scope

- Target repository: `SyuanTsai/Warhammer-40-000-DARKTIDE-Mods`
- Nexus MOD: Auto Mark (`736`)
- Main file: `7544`, version `2.5.1`
- Archive SHA-256: `403e47f41ee7b68227c08c57195d3afdd130505749c6ba74186b62901687e20e`
- Installed Skill baseline: `0.3.6` at `01cec8d100ba5b43185d69ef9bbfe72def8d99cb`
- Test suites were intentionally not run for this trial. Immutable source checks, Schema 14 receipts, payload security validation, and Candidate Gate remain required workflow gates.

## Observations

1. A semantic `-RunId` value failed at `Guid.Parse()` because the public parameter is typed only as `string` and does not validate the GUID shape before execution. A fixed GUID resumed the trial without creating a partial claim.
2. A localization plan initially used the C0 Git blob as `indexedSha256`. Schema 14 actually binds approved spans to the Git-normalized raw upstream installation. The runner rejected the mismatch and the same run was recoverable after rebuilding the plan from the immutable raw-install artifact.
3. Editing the raw localization file with a line-oriented patch changed CRLF to LF. The pre-C1 raw-install manifest correctly rejected this byte drift. Restoring CRLF returned the file to its recorded SHA-256 before the same run resumed.
4. AutoMark's tracked formal hash is `.hash/AutoMark.hash`, while its canonical slug is `automark`. Supplying `.hash/automark.hash` passed Windows filesystem lookup but later failed Git index object lookup. Supplying `.hash/AutoMark.hash` then failed the pre-C1 path contract because `0.3.6` required the lowercase spelling byte-for-byte. The generation could not be repaired without rewriting immutable partial evidence, so it was abandoned before publication with its evidence retained, source archive returned by SHA-256, and exact run-owned worktree, branch, claim, and reservation released.
5. The upstream 2.5.1 zh-tw changes contained terminology regressions against the repository glossary, including `Execution Order` as `處決指令`, generic `Companion` wording in Cyber-Mastiff-only context, and simplified characters. The approved Schema 14 plan retained correct prior wording and authorized only reviewed replacements.
6. The first 0.3.7 candidate queried `git ls-files` with the caller's lowercase path. Git pathspec matching did not return the differently cased tracked entry, even on the case-insensitive Windows worktree, so the caller spelling survived into F and reproduced the index lookup failure. The corrected implementation enumerates the bounded `README.md`/`.hash` tracked set first and performs an explicit ordinal-ignore-case match in PowerShell.
7. After the runner persisted `.hash/AutoMark.hash` and completed C1–F, the independent Candidate Gate still reconstructed the required formal-hash path with the lowercase slug and compared it byte-for-byte. The Gate was updated to require exactly one README and one formal-hash path with ordinal-ignore-case identity while continuing to verify the preview and F blobs through their preserved canonical spelling.
8. The first PR validation found that the new path-matching locals used `$matches`, which collides case-insensitively with PowerShell's automatic `$Matches` variable. They were renamed to `$pathMatches` in both the runner and independent Candidate Gate.
9. The first canonical-casing implementation called `Invoke-Git` before reporting a first-time missing metadata file. That broke the isolated preflight contract and added an unnecessary dependency to the resumable `metadata-preparation` handoff. The runner now performs the bounded filesystem missing-file check first and consults the Git index only after both metadata files exist.
10. Bumping the repository to 0.3.7 left the Nexus API client's traceable User-Agent at 0.3.6. The literal was synchronized to `Skill-Darktide-Translate/0.3.7`.
11. The target repository still had a version-1 managed-instructions manifest that the current bootstrap could not consume directly. A one-time safe migration preserved all customized bytes and kept runtime instruction artifacts ignored; this was a repository bootstrap compatibility issue, not a MOD-run state mutation.
12. The optional system `quick_validate.py` helper could not start because neither available Python environment included `PyYAML` (`ModuleNotFoundError: yaml`). No package was installed and no test suite was substituted; the PowerShell parser, packaged reference-integrity validation, and workflow Candidate Gate supplied the recorded non-test validation evidence.
13. The first Review Baseline expansion attempt used `-OutputPath`, but the packaged expander accepts `-OutputDirectory`. The failed invocation wrote no artifact; rerunning with the declared parameter produced the hash-bound Review Baseline used for Local Review.

## Fix in 0.3.7

`Assert-BuildMetadataPaths` now matches the two required logical metadata paths case-insensitively, reports missing first-time metadata without a Git dependency, resolves each complete tracked path through `git ls-files`, and persists the tracked Git spelling into `state.metadataPaths` before C1. Downstream preview, staging, allowlists, evidence, and Candidate Gate therefore address the same canonical index path on Windows. The entrypoint also validates `RunId` as a GUID during parameter binding and returns an actionable format message before claim planning. New locals avoid PowerShell automatic-variable names, and the Nexus API User-Agent is synchronized with the repository version.

Localization-plan authoring ergonomics remain a recorded follow-up observation; they did not require a safety bypass in this trial.
