# Testing Rules

## Test-First Development

- Use the TDD Red-Green-Refactor cycle by default: first create the smallest test that fails because the target behavior is missing, write the smallest production change that makes it pass, then refactor under test protection.
- During feature analysis or planning, define the expected behavior, suitable test level, and smallest failing test, then plan smoke and regression coverage according to the change's risk.
- Prefer unit tests.
- If unit testing is unsuitable, explain why to the user first, then use the closest applicable approach in the existing test architecture.

The following changes are exempt from test-first development:

- Configuration-only changes such as YAML, pipelines, CI/CD, or appsettings.
- Thin Controller changes limited to routes, attributes, binding, authorization annotations, or calls to an existing service.
- Formatting, comments, log messages, or renaming only.

A Controller containing business logic, conditions, error handling, or data transformation still requires tests first.

## Testing Strategy

1. Prefer unit tests for faster and more stable feedback.
2. Use integration tests when unit tests cannot adequately verify component integration, databases, or external boundaries. Do not add slower integration tests for behavior that unit tests can cover.
3. Use smoke tests to verify that primary features and critical paths have not completely failed.
4. Use regression tests to verify that the change has not broken related existing behavior.

## Framework and Style

- Follow the existing framework: use xUnit in xUnit projects, NUnit in NUnit projects, and prefer NUnit only for a new project with no convention.
- Structure tests using Given-When-Then.
- When adding tests, prefix every test name or IDE display name with its test level and a fixed-width two-digit scenario number: use the `UnitT00_` format for unit tests and the `InterT00_` format for integration tests, such as `UnitT10_`, `UnitT20_`, `InterT10_`, or `InterT20_`; when modifying an existing test that lacks a number, add one as part of the change. Scope numbering to the same test class, fixture, or context, and use stable numbers with reserved gaps that follow the business flow under test.
- When new behavior is inserted into the middle of a production-code flow, also check and adjust the display order of the related tests. Prefer an available number between adjacent scenarios at the same test level, such as `UnitT25_` between `UnitT20_` and `UnitT30_`, or `InterT25_` between `InterT20_` and `InterT30_`. Renumber related tests within the same class, fixture, or context only when no suitable number remains or the current order has become misleading; do not renumber unrelated tests.
- Scenario numbers express reading order in the IDE only, not execution order. Every test must run independently; do not use NUnit `Order`, an xUnit test orderer, or shared state to create test dependencies for the sake of numbered order.
- When adding tests, place a `Scenario` explanation (preconditions and triggering action) and a `Purpose` explanation (the protected behavior, risk, or regression) next to every test declaration; when modifying an existing test that lacks them, add them as part of the change. Prefer a framework-visible description when available, otherwise use concise comments. The test name must still describe the behavior and expected result; neither the number nor the explanation replaces a meaningful name.
- In NUnit, prefer `Assert.Multiple` when verifying multiple conditions.
- In xUnit, follow the project's existing assertion style and do not use NUnit-only APIs.

## Coverage

Cover as applicable:

- Normal success.
- Boundaries such as no data, no subscription, or `null`.
- Failures such as insufficient permissions, invalid states, or cancellation.
- Ordering and earliest or most recent data.
- Database side effects caused by writes.
