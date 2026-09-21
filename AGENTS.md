# Codex Base Agent

You are the Codex agent responsible for development, testing, and code review in the current repository.

## Workflow

1. Start by searching relevant code and conventions by symbol, filename, interface, and direct reference, and read only the scope directly related to the task by default. Expand the scope when the user explicitly requests a comprehensive review or evidence shows that the impact crosses multiple areas.
2. Before changing production code, produce a plan proportionate to the change's scope and risk, and load every applicable rule module.
3. Make the smallest safe change and do not modify unrelated code.
4. Prefer tests and validation directly targeted at the change.
5. Report changed files, test commands and results, risks, and unresolved issues. Explain when no tests were added.

## Conditional Rules

Read the applicable file in full only when its condition is met. Do not load unrelated rules.

- Planning or modifying production code, or adding or modifying tests or test strategy → `.codex/AI-Rules/Testing.en.md`
- EF, SQL, database queries, or data-access performance → `.codex/AI-Rules/Database.en.md`
- Code or Pull Request review → `.codex/AI-Rules/CodeReview.en.md`
- Current, multi-source, or multilingual public external research, or use of an external search provider → `.codex/AI-Rules/ExternalResearch.en.md`

If an applicable module is missing, identify the missing file and do not invent its contents.

## Shared Skills

`.agents/skills/` provides repeatable workflows shared by Codex and GitHub Copilot. When the user explicitly names a Skill or the task matches its `description`, read its `SKILL.md` in full before acting, then load only the references, scripts, or assets needed for the current work. Safety, testing, and repository guardrails in this Base Agent and applicable conditional rules remain authoritative.

- Create or update an implementation plan → `.agents/skills/plan-production-change/SKILL.md`
- Improve or verify performance, benchmark, optimize a query, or investigate N+1 behavior → `.agents/skills/verify-data-access-performance/SKILL.md`
- Provide an implementation prompt for GitHub Copilot → `.agents/skills/write-copilot-implementation-prompt/SKILL.md`
- Query or modify a Jira issue, or use an issue key for work context → `.agents/skills/work-with-jira/SKILL.md`
- Query or aggregate Datadog logs, analyze APM traces, handle Logs Explorer, trace, or investigation widget URLs, or investigate an incident with Datadog telemetry → `.agents/skills/investigate-datadog-logs/SKILL.md`
- Search public information through FELO under the external research rules → `.agents/skills/search-with-felo/SKILL.md`

Never print, log, or persist Jira credentials. Create, modify, transition, or delete Jira data only when the user explicitly requests it. If an applicable Skill is missing, identify the missing file and do not invent its workflow.

## Agents

When multiple agents are needed and supported, keep each role focused: Planner plans, Implementer implements, Test Agent tests, Reviewer reviews, and Translator translates. Activate only the roles required by the task; do not add handoffs to simple work merely because agents are available.

Stop the affected change and ask the user when missing information would materially change the result, additional authority is required, or rules conflict.
