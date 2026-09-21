---
name: work-with-jira
description: Safely route, read, search, create, comment on, assign, edit, or transition Jira Cloud issues using approved access paths and scoped API credentials. Use for Jira URLs, issue keys, JQL searches, work-context lookup, or requested Jira changes.
---

# Work With Jira Cloud

## Target Selection

1. Treat the origin in a user-provided Jira URL as the authoritative site selector. Extract the site origin and issue key or resource identifier before choosing an access path.
2. Verify that every connector or REST request targets the same Jira site or resolved Cloud ID as the authoritative URL. A matching issue key on another site is a different resource and must never be substituted.
3. Use an Atlassian connector only when its accessible site matches the authoritative URL. If it is connected to a different site, do not search or retrieve content there as a fallback.
4. Use environment-based REST access only when `JIRA_BASE_URL` matches the authoritative URL's Jira site, then use the corresponding `JIRA_CLOUD_ID` and `JIRA_API_BASE_URL` for API calls. If no configured access path matches, stop and report the site mismatch without exposing private site details.
5. When the request contains only an issue key or JQL, use a single explicitly named or unambiguously configured site. If configured access paths disagree about the target site, ask the user to provide the Jira URL or choose the site; never default to the currently authenticated connector.
6. A Jira URL identifies the target but does not authorize a write. Continue to apply the write-authorization rules below.

## Access

If Jira API access is missing, invalid, or not yet verified, use `configure-jira-api-access` to guide setup and read-only validation before continuing.

1. Read `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_CLOUD_ID`, and `JIRA_API_BASE_URL` only from environment variables or an approved secret store.
2. Base every `/rest/api/3/...` and `/rest/agile/1.0/...` request on `JIRA_API_BASE_URL`; never call those REST endpoints through `JIRA_BASE_URL`.
3. If `JIRA_CLOUD_ID` or `JIRA_API_BASE_URL` is missing, use a read-only request to `${JIRA_BASE_URL}/_edge/tenant_info` to obtain the Cloud ID, then construct `https://api.atlassian.com/ex/jira/{cloudId}`. Stop and report missing inputs if this cannot be done safely; do not guess.
4. After resolving the target site, prefer an approved connector or local Jira REST helper that follows these endpoint and credential rules. Use Atlassian MCP or Rovo only when the organization explicitly permits it, the environment is configured, and its accessible site matches the resolved target; a token's presence alone is not authorization.
5. Never print, log, persist, or place credential values in prompts, repositories, command arguments, or responses. Do not reveal them through diagnostic commands.

## Operations

1. Default to read-only queries. Perform external writes only when the user explicitly requests them.
2. Resolve ambiguous issue keys, JQL, projects, users, transitions, or other identifiers before acting; never guess a target.
3. Request only the fields needed for the task and avoid exposing unrelated personal data, internal links, or sensitive content.
4. Before a write, verify the target issue and intended change. Obtain confirmation before bulk, destructive, or difficult-to-reverse operations.
5. On failure, report the HTTP status, operation type, and a safely redacted error summary. Never return an Authorization header, token, or complete sensitive response body.
6. Report in the user's language what was read or changed, the target issue keys, and any unresolved permission or configuration problem without exposing secrets.
