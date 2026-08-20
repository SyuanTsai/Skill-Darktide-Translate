# Skill package binding

Read this file before the packaged Schema 14 Workflow. It changes only how the Workflow and Review Baseline are located after conversion from the original `AI Prompt` files into an independently versioned Skill source. Every other Workflow and Baseline requirement remains normative.

## Stable Skill source

- Source ID: `darktide-translate`
- Repository: `https://github.com/SyuanTsai/Skill-Darktide-Translate.git`
- Skill ID: `auto-update-darktide-mod`
- Skill path: `.agents/skills/auto-update-darktide-mod`

A new run requires the consumer's immutable source pin: requested tag or ref, resolved 40-character source commit, and deterministic repository content SHA-256. If the installed Skill cannot be tied to that tuple, do not create a claim; stop as `waiting-user`. Resuming a run uses only its previously recorded tuple.

## Original-to-package path mapping

| Original Workflow path | Compressed packaged path | Expanded filename |
| --- | --- | --- |
| `AI Prompt/AI-Auto-Update-MOD-Workflow.md` | `.agents/skills/auto-update-darktide-mod/assets/workflow-schema-14.md.gz` | `workflow-schema-14.md` |
| `AI Prompt/AI-Auto-Update-MOD-Review-Baseline.md` | `.agents/skills/auto-update-darktide-mod/assets/review-baseline.md.gz` | `review-baseline.md` |

The original commands that use `git show <workflow-commit>:AI Prompt/...` mean: read the byte-exact content expanded from the mapped package at the same resolved `darktide-translate` source commit. Check out that source commit, run `scripts/Test-ReferenceIntegrity.ps1`, and use `scripts/Expand-Schema14Reference.ps1` with `-Document Workflow` or `-Document ReviewBaseline`. Expand into a fresh temporary directory outside both repositories; the script refuses to replace an existing output file.

The compressed files are transport containers that keep automatic Skill discovery within its progressive-disclosure budget. Their expanded bytes, sizes, and SHA-256 values remain identical to the original Schema 14 documents. A content-addressed installation may use its installed package only when the consumer manifest proves the same resolved source commit and repository content hash.

Never look for these packaged references in the target MOD repository. The target MOD repository remains the location for queue/state/worktree/Git evidence and MOD changes; the Skill source is the location for Workflow and Review policy.

## State and evidence mapping

For new packaged runs:

- `workflow_ref` records the requested immutable Skill source ref or tag.
- `workflow_commit_oid` records the resolved `darktide-translate` source commit.
- `workflow_path` records `.agents/skills/auto-update-darktide-mod/assets/workflow-schema-14.md.gz`.
- `workflow_sha256` records the expanded Workflow content SHA-256; `workflow_package_sha256` records the compressed container SHA-256.
- `reference_sources[]` records the Workflow, Review Baseline, this package binding, and `SKILL.md`, including package-relative path, resolved source commit, compressed and expanded sizes, and both SHA-256 values. Its `gitBlobOid` is the packaged file's Git blob at `workflow_commit_oid`, so the commit, path, and blob form one reproducible tuple.
- For converted documents, `packagedGitBlobOid` names that packaged gzip blob while `sourceGitBlobOid` retains the original uncompressed authoring blob. Never substitute `sourceGitBlobOid` into runtime `reference_sources[].gitBlobOid`.
- The consumer source pin's repository URL and content SHA-256 are retained with the run evidence so a future verifier can reconstruct the package.

The source provenance in `source-provenance.json` proves which original Schema 14 documents were converted. It is authoring provenance, not a replacement for the current run's immutable Skill source pin.

## Precedence

For package-location questions only, this binding overrides the original `AI Prompt` paths and workflow-branch lookup commands. It does not change content scope, status values, concurrency, safety checks, archive handling, localization eligibility, Git normalization, C0/C1/C2/C3/F evidence, Candidate Gate, Review classification, append-only refresh, main-advance handling, or finalization requirements.
