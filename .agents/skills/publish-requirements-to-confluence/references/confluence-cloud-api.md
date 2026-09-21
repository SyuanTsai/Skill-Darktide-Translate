# Confluence Cloud publishing reference

## Authentication and settings

For a scoped Atlassian API token, use this API base:

```text
https://api.atlassian.com/ex/confluence/{cloudId}
```

Authenticate with HTTP Basic authentication using the Atlassian account email and scoped API token. Construct the header only in memory.

Read these settings from environment variables or an approved secret store:

| Variable | Purpose | Safe validation |
| --- | --- | --- |
| `CONFLUENCE_BASE_URL` | Browser-facing Confluence Cloud site | Absolute HTTPS URL; normally an `*.atlassian.net` host |
| `CONFLUENCE_EMAIL` | Atlassian account email associated with the token | Presence and email shape only |
| `CONFLUENCE_API_TOKEN` | Scoped token containing Confluence permissions | Presence only; never inspect token length or characters |
| `CONFLUENCE_CLOUD_ID` | Cloud tenant identifier | UUID obtained from `/_edge/tenant_info` |
| `CONFLUENCE_API_BASE_URL` | Scoped-token REST base | Exactly `https://api.atlassian.com/ex/confluence/{CONFLUENCE_CLOUD_ID}` |

Jira and Confluence may share a site, account, and Cloud ID. Reuse a Jira-configured email, Cloud ID, or token only after confirming that the target is the same and the token has the required Confluence scopes. Never assume Jira permissions imply Confluence permissions.

Create or rotate a scoped token through [Atlassian API token settings](https://id.atlassian.com/manage-profile/security/api-tokens). Verify current scoped-token behavior in [Atlassian's Confluence guidance](https://support.atlassian.com/confluence/kb/scoped-api-tokens-in-confluence-cloud/).

For the documented REST v2 flow, provision the minimum applicable scopes:

- resolve spaces: `read:space:confluence`;
- search and read pages: `read:page:confluence`;
- create or update pages: `write:page:confluence`.

The account also needs the corresponding Confluence site, space, create, and update permissions.

## Read-only discovery

Prefix the following paths with `CONFLUENCE_API_BASE_URL`:

| Purpose | Request |
| --- | --- |
| Resolve a space key | `GET /wiki/api/v2/spaces?keys={spaceKey}` |
| Search a page by title and space | `GET /wiki/api/v2/pages?space-id={spaceId}&title={title}&status=current` |
| Read current body and version | `GET /wiki/api/v2/pages/{pageId}?body-format=storage` |
| Read the current page with its draft view | `GET /wiki/api/v2/pages/{pageId}?body-format=storage&get-draft=true` |

Follow pagination and require an exact target. Do not select the first result when multiple pages match.

## Create a page

Use `POST /wiki/api/v2/pages` with `Content-Type: application/json`. The essential payload is:

```json
{
  "spaceId": "<space-id>",
  "status": "current",
  "title": "<approved-title>",
  "parentId": "<approved-parent-page-id>",
  "body": {
    "representation": "storage",
    "value": "<escaped-storage-markup>"
  }
}
```

Omit `parentId` only when the user has approved a root-level page. A published page requires a title. The API returns the created page when successful.

## Update a page

Read both the latest published page and the `get-draft=true` view before building an update. Compare status, version, and storage body. If the draft view differs from the published page, treat it as unpublished collaborative work: stop, summarize the divergence without exposing unrelated content, and obtain explicit authorization for a user-approved merge or preservation plan. Never overwrite or automatically reconcile a diverged draft.

Immediately before writing, repeat both reads. If either view changed after preview or authorization, stop and rebuild the update. Only then use `PUT /wiki/api/v2/pages/{pageId}` with the full approved latest body and an incremented version:

```json
{
  "id": "<page-id>",
  "status": "current",
  "title": "<approved-title>",
  "body": {
    "representation": "storage",
    "value": "<complete-approved-storage-markup>"
  },
  "version": {
    "number": 2,
    "message": "Publish analyzed requirements"
  }
}
```

Replace the example version with the latest published page version plus one. Never update from a stale version, partial body, or unresolved draft.

Confirm request and response shapes against the [official Confluence REST v2 page reference](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/) before publishing. On an uncertain timeout, search or read the target before retrying to avoid duplicate pages or duplicate versions.
