<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Coordination format extension

This repository-native normative extension replaces only the lock and reservation storage-format rules in Schema 14 Workflow §3.2 (the `.locks` entries in the directory layout), §3.3 (lock publication and ownership), §3.4 (lock scanning, reattachment, stale-owner evidence, and release/orphan tombstones), §5.1 (coordination and MOD-reservation format), and §13 steps 7–9 (terminal reservation release). All other Workflow requirements remain normative, including the single-generation invariant, evidence archival, and cleanup of the completed run's claim and run artifacts.

## Persistent owner files

The live owner paths are persistent single files, not directories:

- `AI Auto Update/In Progress/.locks/source-acquisition.lock`
- `AI Auto Update/In Progress/.locks/git-coordination.lock`
- `AI Auto Update/In Progress/.locks/mod/<mod-path-sha256>.lock`

The shared coordination files use schema version 2. Their required fields are `state`, `resourceKey`, `owner`, `expiresAt`, `platform`, and `lockPrimitive`. `owner` contains `runId`, `machineName`, `processId`, `processStartTicks`, `token`, `acquiredAt`, and `heartbeat`. A released record also contains `releasedByOwnerToken`, `releaseReceiptPath`, `releaseReceiptSha256`, `coordinationReceiptId`, and `coordinationCompletedAt`.

The canonical-MOD reservation file uses schema version 3. Its required ownership tuple contains `state`, `runId`, `canonicalModRelativePath`, `modLockKey`, `plannedStatePath`, `statePath`, `reservationToken`, `workerToken`, `machineName`, `workerId`, `workerProcessStartTicks`, `leaseMode`, `reservationState`, `acquiredAt`, `heartbeat`, `expiresAt`, `platform`, and `lockPrimitive`. The top-level `state` is `held` or `released`; while it is held, `reservationState=cleanup-pending` records the recoverable terminal-cleanup boundary. `leaseMode=active` carries the complete worker tuple and `leaseMode=reserved` clears it. A released record binds `releasedByOwnerToken`, `releaseReceiptPath`, `releaseReceiptSha256`, and the persisted cleanup/finalization tuple.

Initial publication is no-replace. Every heartbeat, takeover, cleanup transition, and release is serialized by the owner-update lock and checked against the observed length and SHA-256 before same-directory replacement. The file remains after release; release never deletes it.

## Acquire, retry, stale recovery, and release

A retry bearing the same shared coordination owner token and run ID reattaches to its held owner record. A canonical-MOD retry must match the same run, reservation token, lock key, canonical path, and planned state path; an active worker additionally matches its machine, process, process-start, and worker-token tuple. A live foreign token or different generation never takes ownership. A compare-and-swap race is retried only within the runtime's bounded acquisition loop or fails closed.

A shared coordination owner is stale only when its `expiresAt` has passed and its recorded process identity is no longer active. Shared leases expire after three minutes and heartbeat refresh extends that deadline. Their displaced stale owner bytes are retained beside the owner as `.<resource-key>.lock.stale-<sha256>.json` before replacement. An absent shared owner is protected by a namespace-level owner-update guard that checks every recognizable `.<owner-leaf>.publish-<guid>.tmp` publication temporary in the shared lock root.

If a process stops after flushing a publication temporary but before `File.Move`, a subsequent shared acquisition fails `BLOCKED` when the shared owner is absent and any recognizable temporary remains. A subsequent MOD acquisition checks only `.<that-mod-owner-leaf>.publish-<guid>.tmp`, so another MOD's temporary does not block it. Neither guard publishes or changes state when it blocks. Completed shared stale takeover evidence remains usable because the replacement owner and its takeover tuple are present. The exact `BLOCKED: incomplete owner publication residue exists under '<relative-lock-root>' (...). Follow 'Manual recovery for incomplete owner publication' in references/automation.md.` message identifies the applicable shared or MOD lock root. Follow that recovery procedure and remove or restore only the named file after verifying ownership; do not delete the lock root recursively.

A canonical-MOD reservation is not available to a different generation merely because a worker stopped. Only the same run may reattach an active worker after its heartbeat is more than 30 minutes old and the recorded worker process identity is no longer active; the previous owner is retained in `.owner-history/<mod-path-sha256>/`. Normal and waiting exits clear the worker tuple and leave the reservation held in `reserved` mode.

Release first publishes an immutable terminal receipt and then compare-and-swap replaces the matching owner record with `state=released`. Shared receipts are `<resource-key>.released-<owner-token>.json`; MOD receipts are `<mod-path-sha256>.lock.released-<reservation-token>.json`. A retry, or reuse of a released path by a later owner, must validate the receipt bytes, path, SHA-256, owner token, and applicable operational or cleanup/finalization tuple. A missing, changed, or foreign receipt fails closed and leaves the current owner file intact.

For Schema 14 §13, the single-file transition replaces only the old directory-tombstone rename/delete operation. The Workflow's preceding requirements still apply: archive and verify final evidence, clean the completed run's staging, original artifacts, claim directory, run state/root, worktree, and branches at their owner-checked boundaries, then publish the terminal receipt and released owner. `cleanup-pending` makes an interrupted cleanup resumable; it does not authorize permanent claim or run-artifact retention.

## Legacy directory boundary

Any directory found at one of the live `.lock` paths is the legacy format and is treated as held with unknown ownership. The runtime fails closed and does not delete, rename, convert, or reuse it. Stop every participant, independently establish that no owner is active, move the entire legacy directory to a preserved evidence archive outside the live `.locks` namespace, and verify that the live path is absent before retrying with one pinned Skill version. Do not turn `owner.json` into a new owner file or synthesize a release receipt. If ownership cannot be established, leave the state stopped. See `docs/ROLLBACK.md` for the rollback/forward procedure.
