# BornReady real-MOD trial report (2026-08-30)

## Outcome

The installed `auto-update-darktide-mod` 0.3.5 package was verified against immutable commit `165d7200acbca9c4b88994e4815f8af9d0dc07ca` and exercised against live Nexus Main files without running the repository test suite. An initial NoBrainer run exposed one reproducible Schema 14 runner defect. A second BornReady run supplied an explicit byte-span localization plan and completed source verification, extraction, installation, layered Git evidence, Candidate Gate, publication, local Review, and Review completion.

BornReady PR [#111](https://github.com/SyuanTsai/Warhammer-40-000-DARKTIDE-Mods/pull/111) is open at final candidate `ff1beb34a8d3ba8f01fbff6fdffc5a976033e70a` and is waiting for merge. The retained NoBrainer run was not abandoned or rewritten; its reservation and evidence remain intact because rollback requires explicit operator authorization.

## Package baseline

- Installed package version: `0.3.5`
- Pinned repository commit: `165d7200acbca9c4b88994e4815f8af9d0dc07ca`
- Source-pin SHA-256: `be4f8c1dbe0356dd7ece599fb347de82298d79168b6cb5c9bec6958adeaf5016`
- Source content SHA-256: `b5d907bde422f9a14c20cb2d7b7f82e32f70c0fda944e10a0f8396424d1f19d7`
- Reference integrity: passed for all 22 pinned package files
- Repository tests: intentionally not run for this trial

## Finding: registered Schema 14 localization silently defaulted to none

### Observed behavior

NoBrainer run `eb45d710-80da-479b-b7fa-ab9429c06096` installed Nexus Main file `7844` from archive `NoBrainer 896 3.1.4 2026-08-28T19-13Z 3OsdoOUuY.zip` (`b359b374dfc0ac5efea654c5e4734e85f9d13b5484fc8287a98a951d804d47ef`). Its root `NoBrainer.mod` explicitly registered `mod_localization`, and the installed tree contained `NoBrainer_localization.lua`. Because the aggregate run omitted `-LocalizationPlanPath`, Schema 14 nevertheless completed localization with `localizationMode=none`, an empty localization-file list, and an empty evidence-target set. It then advanced to the unrelated metadata-preparation handoff.

### Impact

- Active `zh-tw` maintenance could be skipped without an Agent decision.
- C2/C3 would become not applicable, so the layered evidence chain could attest a candidate that never reviewed the registered localization source.
- The later metadata handoff hid the earlier semantic omission and made the run appear safely resumable.

### Fix in 0.3.6

- When Schema 14 has no supplied plan, inspect ordinary root `.mod` descriptors as UTF-8 data without executing Lua.
- If a descriptor registers `mod_localization`, return `waiting-input` at `localization-plan` with `waitingReason.code=localization_plan_required` and the matching descriptor path.
- Resume the same pinned run only after an explicit `zh-tw` plan or an explicitly reviewed `none` plan is supplied.
- Preserve the existing no-plan `none` compatibility path when no root descriptor registers localization.

### Regression coverage

- Added `UnitT137_SuspendsSchema14LocalizationWhenARegisteredSourceHasNoPlan`.
- Preserved `UnitT135_CompletesSchema14LocalizationWithoutAPlan` for the genuine no-registration case.
- The tests were added but intentionally not executed, following the trial instruction.

## Successful BornReady candidate

- Run ID: `a976fab0-ef65-4a7f-8587-36da419f8d12`
- Nexus MOD/Main file: `96` / `7660`
- Archive: `BornReady 96 1.7 2026-08-23T21-04Z mz1PFzZkA.zip`
- Archive size/SHA-256: 4,907 bytes / `e3e378ea6be5aa4cb6a5bdc0cba77bd331cda73ab0ed13cf28fb81478bf9a005`
- Translation added: `leave_party["zh-tw"] = "離開小隊"`
- C0: `9980eba2b3adf9774e2cf4ac7e6c41a0344a7222`
- C1: `c54c00f0304fbcc22a178bc1a8eb6e0b96b4364b`
- C2: `fbf03e2d0a432068bb222b77327340f1ac2f1ea1`
- C3: `35b5487b53f3abcaf6257cbccc815ed60f7329ea`
- F: `ff1beb34a8d3ba8f01fbff6fdffc5a976033e70a`
- Candidate Gate validation SHA-256: `d233b82904d06e16823da370f464b8be66c826ccbbc9b49bb9cdc3213a7aaa5a`
- Local Review findings: none
- Review completion SHA-256: `683fbde4bc639e9fbd24244aaa706fb72ddb5147bea3a597dad24d0a47cc7fe5`
- External Review: requested-pending, with no polling scheduled

## Non-product execution errors

1. A runner invocation used the nonexistent `-Action` parameter instead of positional command `run`; PowerShell rejected it before state mutation. This was an operator command error, not a runner defect.
2. The sandbox account failed Git's dubious-ownership check for the user-owned worktree. The same state was safely resumed under the owning Windows user; the failed build-commits attempt remained in stage timing evidence.
3. The target MOD repository instructions bootstrap initially failed closed on an unrelated customized managed file. No managed file was overwritten; the current repository instructions were read directly before proceeding.

## Merge and fingerprint status

At report creation, PR #111 was open and the run remained `awaiting-user-merge`. Fingerprint finalization must not run until GitHub reports the PR merged and the merged commit is proven to contain F. The same run reservation and archive evidence remain available for that finalization.
