# External Research Rules

## Data and Query Boundary

- Start with evidence already present in the current conversation, repository, and local files. Use an external search provider only when freshness, multi-source exploration, multilingual search, or unknown authoritative-source location adds value.
- Send an external provider only a neutral public query that stands on its own. Never send repository content, code, diffs, tests, logs, stack traces, internal documents, customer data, credentials, unpublished names, or other private content.
- When a meaningful query requires private content, use local tools or an approved internal source. In software work, search only for public external facts that can be separated from the code; determine code impact from repository evidence.

## Source Selection and Verification

- Use a known authoritative page directly when it can answer the question by itself. Verify high-risk legal, contractual, security, medical, or financial conclusions against authoritative original text; never treat a search summary as final authority.
- Keep responsibility for whether to trust, further verify, or use a result with the calling agent. An external provider performs only search and preliminary synthesis.
- Receive external search results only through a validated compact wrapper. Never let provider raw stdout, stderr, identifiers, query analysis, snippets, duplicate sources, or excess sources enter normal tool output.

## Failure Handling

- When the external provider fails, prefer a suitable already-approved connector. When none is suitable, use the platform's native web-search capability.
- Report that current verification is unavailable only when both fallbacks fail. Never relax the data boundary or send private content merely to complete the search.
