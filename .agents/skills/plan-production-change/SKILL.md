---
name: plan-production-change
description: Create or update evidence-based implementation plans for production-code changes, with detail proportionate to scope, risk, and uncertainty, including validation and TDD sequencing. Use when asked to plan a feature, fix, refactor, migration, or other production-code change, or when repository guidance requires a plan before implementation.
---

# Plan a Production Change

1. Search the relevant symbols, files, interfaces, direct references, and existing conventions before planning. Keep the investigation scoped to evidence needed for implementation and acceptance.
2. Read the repository's applicable testing and domain rules. Convert applicable guardrails into concrete change, validation, or delivery steps instead of copying irrelevant rule text.
3. Separate verified facts from assumptions. Identify affected files or symbols, direct dependents, and public contracts. When an unresolved decision would materially change the implementation, ask the user before finalizing the plan.
4. Match plan detail to scope, risk, and uncertainty:
   - Use the concise format for a well-understood, low-risk change within one area that needs no migration or coordinated rollout.
   - Use the full format for cross-area or uncertain work, data migrations, security changes, public contracts, operational risk, or other high-risk changes.
5. Follow the applicable testing rules. When TDD is required or appropriate, describe the Red-Green-Refactor sequence. When an exemption applies, state the reason and closest alternative validation. Include smoke and regression coverage according to risk.
6. Write the plan in the user's language, translate the template headings, and include only information that helps implementation or acceptance. Use concrete repository paths and symbols supported by the investigation; do not invent details to fill a template.

Concise format:

```markdown
- Objective / scope:
- Evidence / targets:
- Change:
- Validation / TDD:
- Risks / assumptions / out of scope:
```

Full format:

```markdown
# Plan: <feature or problem>

## 1. Objective and scope
- Expected outcome:
- Acceptance criteria:
- Deliverables:
- Out of scope:
- Assumptions / dependencies:
- Open decisions:

## 2. Planned changes

### 2.1 <change item>
- Target files / symbols:
- Current behavior or convention:
- Change:
- Reason:
- Impact or risk:

## 3. Test scenarios

### 3.1 <scenario>
- Related change:
- Test level:
- Given:
- When:
- Then:
- TDD: Red <failing test> → Green <minimum production change> → Refactor <cleanup while tests pass>; when exempt, give the reason and alternative validation.

## 4. Delivery and validation
- Validation commands or checks and expected results:
- Smoke / regression coverage:
- Rollout or migration:
- Rollback or recovery:
- Monitoring and success signals:

## 5. Risks and unresolved items
- Risk and mitigation:
- Unresolved or blocking item:
```

Omit optional operational entries that do not apply. For changes affecting persisted data, access control, public contracts, or production availability, explicitly cover compatibility or migration, recovery, and post-change verification.
