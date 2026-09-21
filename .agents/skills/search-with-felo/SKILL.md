---
name: search-with-felo
description: Search current public external information through the FELO CLI and return only a compact cited result. Use for time-sensitive, multi-source, or multilingual public research, or when the authoritative source location is unknown. Do not use for repository content, code, diffs, logs, internal documents, customer data, private context, or tasks that can be answered from local evidence or one known official page.
---

# Search With FELO

Use FELO only as a public external search provider. Keep reasoning, source judgment, high-risk verification, and all repository or code work with the calling agent.

## Workflow

1. Load the applicable platform's `ExternalResearch` conditional rule as directed by its Base Instructions.
2. Confirm the query can stand alone using only neutral public information. Never add repository, code, diff, test, log, internal-document, customer, credential, unpublished-name, or other private context.
3. Prefer current conversation, repository, local files, or a known authoritative page when they already answer the question. Use FELO only when freshness, multi-source exploration, multilingual search, or source discovery adds value.
4. Run `scripts/search-with-felo.ps1` with PowerShell 7 and pass only the public query:

   ```powershell
   pwsh -NoProfile -File <skill-directory>/scripts/search-with-felo.ps1 -Query '<public query>'
   ```

5. Read only the compact JSON printed by the wrapper. Never invoke `felo search --json` directly or expose its raw stdout, stderr, identifiers, query analysis, snippets, or excess sources.
6. Use the compact summary as a research lead rather than a final authority. Judge source authority from the compact URLs first, then open only the minimum original authoritative sources needed for verification. Always verify original authoritative sources when accuracy, law, contracts, security, health, finance, or another high-risk decision requires it.

## Compact Contract

Successful output contains only:

```json
{
  "status": "ok",
  "asOf": "2026-01-01T00:00:00.0000000+00:00",
  "summary": "A locally limited FELO answer.",
  "sources": [
    {
      "title": "Public source",
      "url": "https://example.com/source"
    }
  ],
  "truncated": false,
  "retried": false
}
```

The wrapper limits `summary` to 800 Unicode text elements, normalizes and deduplicates HTTP(S) URLs, returns at most five sources, and sets `truncated` when either limit removes content. `retried` reports whether the wrapper made its one permitted retry. The wrapper does not cache results.

Failure output contains only `status`, `asOf`, a safe `error` classification such as `cli-unavailable`, `authentication`, `quota-unavailable`, `timeout`, `request-failed`, `invalid-response`, or `no-sources`, and `retried`. Never request or reveal a credential while diagnosing an error.

## Fallback

The wrapper waits a random 1–2 seconds and retries once only when FELO returns `request-failed`. Do not issue another Agent-level FELO retry after receiving the final compact result. When the final result is still a failure, use a suitable already-approved connector when one is available. Otherwise use the calling platform's native web-search capability. Report that current verification is unavailable only when neither fallback can complete the search.

## Requirements

- Use Windows with PowerShell 7 for the first version.
- Require an installed and authenticated `felo-ai` CLI. Let the CLI use its private user configuration; never copy its API key into a prompt, command argument, output, or repository file.
