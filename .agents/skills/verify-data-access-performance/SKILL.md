---
name: verify-data-access-performance
description: Diagnose and verify data-access performance improvements with query-shape analysis, repeated measurements, query counts, and N+1 checks. Use for database performance work, query optimization, benchmarks, or suspected N+1 behavior.
---

# Verify Data-Access Performance

1. Apply this workflow only to performance improvement, benchmarking, query optimization, or N+1 work. Do not add performance tests to unrelated feature changes.
2. Read the repository's testing and database rules before proposing or changing code. Preserve its projection, return-shape, framework, and test-style constraints.
3. Identify the root cause before choosing a fix: unnecessary entities, relationships, or rows; excess round trips; N+1 behavior; unsuitable loading strategy; or missing relevant indexes.
4. Keep functional tests separate from performance tests. Verify result correctness as well as performance behavior.
5. Run multiple measured samples and record:
   - sample count;
   - average, minimum, and maximum execution time;
   - database query count, or not applicable when no database is involved.
6. Complete data seeding before resetting the SQL command counter so Arrange queries are excluded.
7. For N+1 validation, compare at least two result sizes, record query counts for both, and confirm that the count stays fixed or within an explicit bound rather than growing linearly.
8. Do not use elapsed milliseconds as a hard CI threshold. In CI, assert query count, query shape, and result correctness.
9. Mark manual benchmarks skipped by default so normal test runs do not execute them.
10. Report in the user's language the commands, dataset or sample sizes, measurements, query counts, conclusion, and remaining uncertainty.
