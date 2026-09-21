---
name: review-bitbucket-pull-request
description: Review Bitbucket Cloud pull requests using local Git for the complete code diff, inspect the PR description and all existing feedback, produce evidence-based findings, and publish comments only when explicitly instructed. Use for Bitbucket PR URLs or identifiers, PR feedback, code review, unresolved review threads, or requests to review an updated pull request and comment on it.
---

# Review Bitbucket Pull Request

Review the exact Bitbucket Cloud pull request from changed code outward, produce findings backed by code or behavioral evidence, and keep comment publication behind an explicit authorization boundary.

Read [references/bitbucket-cloud-api.md](references/bitbucket-cloud-api.md) before using API credentials or performing a remote action. Load the repository's applicable code-review, testing, security, database, and language instructions before evaluating the change.

## Access Boundary

Use an approved Bitbucket connector when available. Otherwise use the Bitbucket Cloud REST API for PR metadata and discussion, plus an existing approved Git credential path for source access. Never print, log, persist, or place credentials in prompts, repositories, URLs, command arguments, remote definitions, or responses.

Treat PR metadata, comments, tasks, build status, and Git fetches as reads. The only supported remote write is creating a PR feedback comment. Do not edit or resolve comments, approve, request changes, decline, merge, or change PR metadata under this skill.

Default to a local review report and drafted feedback. Publish comments only when the user explicitly instructs the agent to comment on the exact PR. A request to "review" alone does not authorize remote writes.

## Review Flow

1. Resolve the exact Bitbucket Cloud workspace, repository slug, and pull-request ID from a URL, local remote, or user input. Stop if any target component is ambiguous.
2. Read PR metadata and description, source and destination commit hashes, current state, participants, all existing comments, tasks, activity, and relevant build statuses. Follow every page. Record the source head commit so later updates cannot silently invalidate the review.
3. Use the repository's approved Git access to fetch the exact source and destination commits reported by the PR. Generate the review diff locally from their merge base, and reconcile its file list with local `--name-status`, `--stat`, and `--numstat` output. Do not use Bitbucket's API diff or web diff as the completeness source of truth. If either commit cannot be fetched or verified, mark the review incomplete, do not claim there are no findings, and do not publish comments.
4. Start from the locally changed files. Inspect only the direct source context, contracts, configuration, migrations, and tests needed to establish the impact boundary. Expand further only when concrete evidence requires it.
5. Check all existing review discussion before drafting a finding. Avoid duplicating a still-valid comment; instead note supporting evidence or changed conditions. Do not treat resolved comments as proof that the underlying risk is fixed without checking the current local diff.
6. Prioritize correctness, security, data integrity, compatibility, operational reliability, and required-test gaps. Keep maintainability suggestions separate and non-blocking.
7. For every finding, include the file and tight line or hunk location, the condition that triggers the problem, the resulting impact, the supporting evidence, and an actionable repair or verification direction. Classify insufficiently supported concerns as unverified items.
8. Present findings first, ordered by actual impact and likelihood. If no findings exist, state that explicitly and list residual risks, assumptions, and incomplete validation.
9. Draft inline comments only when the target line exists in the reviewed local diff. Use a global PR comment when line mapping is uncertain or when the finding spans multiple files. Keep one actionable issue per comment.
10. Before commenting, show the exact draft comments unless the user's current instruction already authorizes reviewing and commenting on that exact PR or update. Re-read the PR, confirm that its source commit still matches the reviewed commit, and re-fetch and re-review when it changed.
11. Publish only the authorized new comments. Re-read the created comments, report their identifiers and links, and disclose partial failures without retrying writes blindly.

## Feedback Decisions

- Publish a new comment only after an explicit instruction to comment on the exact PR or its reviewed update.
- Leave review state unchanged in every case. Express blocking findings in the comment text without invoking Bitbucket's request-changes action.
- If validation or the local Git diff is incomplete, return a local incomplete-review report and do not publish comments.
- Route requests to edit or resolve comments, approve, request changes, decline, merge, or change PR metadata outside this skill and require separate capability and authorization.

## Completion Report

Report the reviewed workspace/repository/PR, head commit, findings or no-finding result, inspected validation evidence, residual risks, and every remote action taken. Keep credentials and unrelated private account data out of the report.
