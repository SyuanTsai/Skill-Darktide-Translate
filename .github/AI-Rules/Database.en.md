# Database Rules

- Improve data-access performance by first identifying unnecessary entities, relationships, or rows loaded by one query, along with excess round trips, N+1 behavior, and other root causes, then adjust the query scope and loading strategy.
- Do not treat projection as a complete performance solution. Use it only to retrieve a key or ID, a count, a boolean flag, or no more than three scalar fields.
- Do not use projection as a business response shape, DTO, primary application return model, or carrier for core logic.
- Do not add a model, DTO, or class to carry returned data unless the user explicitly approves it.
- Before changing data access, inspect only the relevant existing queries, entity relationships, indexes, and conventions.
- For query performance or N+1 work, also use `.agents/skills/verify-data-access-performance/SKILL.md` for diagnosis and validation.
