# Git Commit Generation Rules

Apply these rules only when generating a Git commit message. Return only the final commit message. Do not include explanations, analysis, validation results, or Markdown code fences.

## Objective

Generate an accurate, focused, and reviewable commit message from the staged changes:

- The first line follows the company-required Jira Smart Commit format.
- The English commit content uses Conventional Commit type, scope, and description structure.
- A faithful Taiwan Traditional Chinese translation lets the user verify the English content.
- Every statement is supported by the branch name or staged changes.
- Never invent a Jira ticket, work duration, change intent, system behavior, or implementation detail.

## Information Sources

Use only the staged changes and the current branch name when it is actually present in the request context. Do not treat `$GIT_BRANCH_NAME` as a real branch name or assume that Copilot always receives the branch name.

Extract a Jira ticket matching `[A-Z]{2,}-[0-9]+` from the branch name. For example:

```text
origin/feature/PROJ-11805-asset-class-import-by-asset-external-ID
```

Extract `PROJ-11805`. If the branch name is unavailable or contains no valid ticket, use `PROJECT-XXXX` as an explicit placeholder on the first line. Never guess or create a ticket; the user must verify and replace the placeholder before committing.

## Commit Message Format

```text
<ticket or PROJECT-XXXX>, #time XXm

<type>[optional scope][optional !]: <English description>

[optional English body]

zh-TW:
<Traditional Chinese meaning of the type>[same optional scope]: <translated description>

[optional Traditional Chinese body]

[optional machine-readable footer(s)]
```

Example:

```text
PROJ-11805, #time XXm

fix(import): handle missing external asset IDs

Prevent records without an external asset ID from failing the entire import.

zh-TW:
修正(import)：處理缺少的外部資產 ID

避免缺少外部資產 ID 的資料導致整批匯入失敗。
```

## Jira Ticket and Work Duration

- Always use `<ticket>, #time XXm` on the first line.
- Use only the Jira ticket actually present in the branch name. The ticket appears only on the first line and is not repeated in the Chinese section or a footer.
- Preserve `XXm` literally as a placeholder for the user to enter the work duration.
- Never estimate duration from the size or complexity of the staged changes, and never replace `XXm` automatically.
- Before committing, the user must replace `XXm` with the actual duration, such as `30m` or `1h`.

## Generation Process

1. Review the staged changes.
2. When the request context contains the branch name, extract the Jira ticket.
3. Identify the primary purpose of the staged changes and select one commit type that best represents it.
4. Generate the English description and add an English body only when useful.
5. Translate the English content faithfully into Taiwan Traditional Chinese.
6. Verify that both languages state the same facts and that the structure is valid, then return only the commit message.

When the staged changes contain independent purposes, describe only the primary purpose. Do not put commit-splitting advice in the commit message.

## Commit Type Selection

Choose one primary type per commit:

- `feat`: adds functionality or a new user-observable capability.
- `fix`: corrects existing incorrect behavior.
- `refactor`: changes internal structure without changing intended external behavior.
- `perf`: improves performance while preserving intended behavior.
- `test`: changes tests only.
- `docs`: changes documentation only.
- `style`: changes formatting without affecting behavior.
- `build`: changes the build system or external dependencies.
- `ci`: changes CI/CD or deployment configuration.
- `chore`: performs maintenance not represented by a more specific type.
- `revert`: reverses an earlier commit.

Choose the type from the primary purpose of the staged changes, not from filenames alone. A production bug fix with test updates normally uses `fix`; a feature with tests normally uses `feat`; prefer `test` only when the staged changes are test-only.

## Scope and English Content

- Add a short, stable scope only when the staged changes clearly identify a component, module, service, or subsystem.
- Use exactly the same untranslated scope in both languages; omit it when it cannot be determined accurately.
- Write the English description in the imperative form and describe the completed behavior or result instead of listing files.
- Avoid vague descriptions such as `update code`, `fix issue`, or `make changes`.
- Add a body only when it materially explains motivation, important behavior, before-and-after behavior, constraints, or non-obvious decisions.
- Every statement must be supported by the staged changes. Omit the body rather than speculate.

## Taiwan Traditional Chinese Translation

Start the Traditional Chinese section with `zh-TW:`. It is a faithful translation of the English commit content, not an independent summary:

- Both languages state exactly the same facts. Do not add, remove, broaden, or reinterpret content.
- Translate every behavior stated in English; do not add intent, reasons, or effects absent from the English content.
- Translate the semantic meaning of the commit type, such as `fix` to `修正`, while preserving the same scope.
- Preserve classes, methods, properties, APIs, Jira tickets, code symbols, and technical terms whose translation would reduce precision.
- Do not repeat the Jira ticket or work duration in the Chinese section.

## Footers and Breaking Changes

Machine-readable footers must be the final section of the commit message. Do not translate footer tokens such as `BREAKING CHANGE`, `Reviewed-by`, or `Refs`; put any required Chinese explanation in the `zh-TW:` section.

Mark an incompatible API or behavior change with `!` or add:

```text
BREAKING CHANGE: <English description>
```

Keep `BREAKING CHANGE` uppercase. Do not repeat the Jira ticket from the first line in a `Refs` footer.

## Final Validation

Before returning the result, confirm that:

- The first line follows `<ticket>, #time XXm`; the ticket comes from the supplied branch name, otherwise `PROJECT-XXXX` is used.
- `XXm` remains for manual input and neither the ticket nor duration was inferred.
- One primary type is selected, and the description, scope, and optional body are supported by the staged changes.
- The English and Chinese content state the same facts, with no additional claims in Chinese.
- Breaking changes are explicit and machine-readable footers are last.
- The final output contains no explanation, analysis, advice, validation checklist, or Markdown code fence.
