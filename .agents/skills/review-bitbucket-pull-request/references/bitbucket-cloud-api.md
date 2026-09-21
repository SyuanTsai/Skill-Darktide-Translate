# Bitbucket Cloud PR API reference

## Authentication and scopes

Use `https://api.bitbucket.org/2.0` for Bitbucket Cloud REST API calls. With an Atlassian API token, use HTTP Basic authentication with the Atlassian account email as the username and the API token as the password. Construct the authorization header only in memory.

Read these settings from environment variables or an approved secret store:

| Variable | Purpose | Safe validation |
| --- | --- | --- |
| `BITBUCKET_EMAIL` | Atlassian account email associated with the token | Presence and email shape only |
| `BITBUCKET_API_TOKEN` | Scoped Atlassian API token for Bitbucket | Presence only; never inspect token length or characters |
| `BITBUCKET_API_BASE_URL` | Bitbucket Cloud REST base | Exactly `https://api.bitbucket.org/2.0` |
| `BITBUCKET_WORKSPACE` | Optional default workspace | Confirm against the PR target before use |

Create or rotate tokens through [Atlassian API token settings](https://id.atlassian.com/manage-profile/security/api-tokens) and verify current requirements in [Bitbucket's API-token guide](https://support.atlassian.com/bitbucket-cloud/docs/using-api-tokens/).

Use the minimum current scope needed by this skill:

- Read PR metadata, descriptions, participants, comments, tasks, activity, and statuses, and create a PR comment: `read:pullrequest:bitbucket`.
- Do not provision `write:pullrequest:bitbucket` for this skill. That scope enables higher-risk review-state actions that this workflow does not perform.
- Obtain source and diffs through the user's separately approved Git credential path. Do not add `read:repository:bitbucket` merely to download an API diff.

Bitbucket scopes do not imply one another. Recheck [Bitbucket API-token permissions](https://support.atlassian.com/bitbucket-cloud/docs/api-token-permissions/) when creating or rotating a token.

## Read endpoints

Use this prefix:

```text
${BITBUCKET_API_BASE_URL}/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}
```

Read only what the review needs:

| Purpose | Method and suffix |
| --- | --- |
| PR metadata | `GET` with no suffix |
| Activity | `GET /activity` |
| Comments | `GET /comments` |
| Tasks | `GET /tasks` |
| Build statuses | `GET /statuses` |

Honor pagination and rate-limit responses. Read all pages of comments, tasks, and activity so feedback from any participant is not silently omitted.

## Complete diff through Git

Use PR metadata only to identify the exact source and destination commit hashes. Fetch both commits through an existing approved Git credential helper, SSH agent, or other repository access path. Never embed a credential in a clone URL, command argument, or persisted remote. Fetch without checking out or altering the user's working tree.

Verify that the fetched object IDs match the hashes reported by the PR, then review the three-dot diff from the destination/source merge base:

```text
git diff <destination-commit>...<source-commit>
git diff --name-status <destination-commit>...<source-commit>
git diff --stat <destination-commit>...<source-commit>
git diff --numstat <destination-commit>...<source-commit>
```

Use the same verified commit pair for every command and account for every changed path. This avoids [Bitbucket API and web diff limits](https://support.atlassian.com/bitbucket-cloud/docs/limits-for-viewing-content-and-diffs/) and excluded-file presentation rules. If Git cannot fetch or validate both exact commits, the review is incomplete: do not report a clean review and do not publish a comment.

## Feedback endpoints

Use the [official pull-request API reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/) to confirm the current payload before a write.

| Action | Method and suffix |
| --- | --- |
| Create a PR comment | `POST /comments` |

This skill supports only `POST /comments`. Do not call endpoints that edit or resolve comments, approve, request changes, decline, merge, or modify PR metadata.

For a global comment, send only the Markdown content required by the API. For an inline comment, also identify the changed file path and a line represented in the current diff. Use destination-side line coordinates for added or context lines and source-side coordinates for removed lines. If the mapping is not certain, use a global comment that names the path and hunk instead of risking a misplaced inline comment.

Before posting, re-read the PR and compare its source commit hash with the reviewed hash. If it changed, fetch the new commit and repeat the review. After posting, record and re-read the returned comment identifiers. Never retry a timed-out write until a read confirms whether the first request succeeded.
