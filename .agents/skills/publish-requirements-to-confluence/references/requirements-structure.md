# Requirements page structure

Use only sections supported by the source. Omit empty sections unless the absence itself is important, in which case state that the information remains open.

## Recommended order

1. **Summary** — concise statement of the problem, proposed outcome, and current decision state.
2. **Background and context** — why the work is needed, relevant users or systems, and source references.
3. **Goals** — measurable outcomes the requirements are intended to achieve.
4. **Non-goals** — explicitly excluded behavior or scope.
5. **Stakeholders and ownership** — only confirmed owners, reviewers, and decision makers.
6. **User journeys or use cases** — actors, triggers, primary flow, and relevant alternate or failure flows.
7. **Functional requirements** — stable ID when available, requirement statement, rationale, priority if confirmed, and acceptance criteria.
8. **Non-functional requirements** — security, privacy, performance, reliability, accessibility, compatibility, observability, and operational constraints supported by the source.
9. **Data and integration contracts** — entities, validation, APIs, events, dependencies, migrations, and retention requirements.
10. **Acceptance and validation** — testable outcomes, launch checks, and evidence needed for sign-off.
11. **Dependencies and rollout** — upstream or downstream work, sequencing, feature flags, migration, fallback, and support needs.
12. **Risks and mitigations** — confirmed risks, impact, likelihood when known, mitigation, and owner when provided.
13. **Decisions** — decision, rationale, date, and decision maker only when present in the source.
14. **Open questions** — unresolved item, why it matters, and needed owner or decision date without inventing either.
15. **Traceability** — source documents, Jira issues, meeting notes, designs, related Confluence pages, and revision notes.

## Writing rules

- Preserve normative force: distinguish **must**, **should**, and **may** when the source does.
- Prefer one independently testable behavior per requirement.
- Keep solution proposals separate from confirmed requirements unless the proposal is itself approved.
- Consolidate true duplicates but retain all distinct constraints and acceptance conditions.
- State contradictions and missing evidence; do not resolve them silently.
- Use tables only for repeated fields such as requirement IDs, priorities, owners, or traceability. Use prose for rationale and nuanced constraints.
- Keep private or sensitive source content out of the page unless the target space and audience are approved for it.
