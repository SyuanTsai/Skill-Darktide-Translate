# SyuanTsai.github.io Article Export

Use this reference when durable course notes must become a specific article for [SyuanTsai/SyuanTsai.github.io](https://github.com/SyuanTsai/SyuanTsai.github.io). The article is an original public synthesis, not a transcript, course substitute, or public copy of the private evidence bundle.

## Contents

- Reinspect the target
- Choose the article contract
- Build a private evidence map
- Transform private teaching into a public article
- Match the current Jekyll post format
- Validate the public payload

## Reinspect the target

Before each article generation, inspect the current repository rather than relying only on this snapshot:

- repository-level instructions and contribution guidance;
- default or publishing branch, working tree, and existing changes when a local checkout is used;
- `_config.yml`, `Gemfile`, the two most recent substantive posts, relevant layouts and includes, and any asset convention;
- documented build, preview, lint, and deployment workflow.

As observed on 2026-08-12, the site publishes from `gh-pages`, uses Jekyll with the Minima remote theme, declares `zh-tw`, and stores posts under `_posts/` as `.markdown` files. Treat these as discoverable defaults, not permanent facts.

If the target repository is temporarily unavailable, a user-requested draft may use the last verified snapshot only when it is labeled provisional. Mark repository-dependent front matter and paths as needing revalidation, and do not call the result compatible, publication-ready, or published.

## Choose the article contract

Record the intended audience, one central question or outcome, article type, output language, intended publication date, and requested publication state. Use the user's requested publication date when supplied. Otherwise use the local draft date and flag it for confirmation before publication. Useful article types include:

- concept explainer: derive a clear mental model and decision criteria;
- hands-on walkthrough: reproduce a bounded operation with prerequisites, verified steps, and results;
- debugging case study: present the symptom, observations, diagnosis, change, and verification;
- lesson synthesis: connect several lessons around one practical conclusion.

If the user has not selected a topic, choose the smallest coherent topic supported by strong evidence from the applicable course materials. Return the chosen title and angle with the draft. Keep draft creation separate from commit, push, pull request, or publication; perform those state-changing actions only when the user requests them.

## Build a private evidence map

Create the smallest useful equivalent of:

```text
exports/syuantsai-github/
├─ article-plan.md
├─ _posts/
│  └─ YYYY-MM-DD-<slug>.markdown
└─ article-evidence-map.json
```

For every substantive claim, code block, procedure, and demonstrated result, record in `article-evidence-map.json`:

- the article section or stable claim identifier;
- course, lesson, material IDs and revisions, and precise source locators such as timestamps, PDF pages, slide numbers, sections, or code revisions;
- supporting event, code snapshot, and visual or document evidence;
- whether the article text is a summary, verified excerpt, adapted example, or inference;
- confidence, uncertainty, privacy decision, and any validation performed.

Keep `article-plan.md` and `article-evidence-map.json` with the private course notes. They are editorial provenance, not website content, and must not be copied into the public repository.

The private evidence map may retain exact stable lesson and artifact references needed for auditability, but it must still minimize unrelated personal or organizational information. Never put credentials, tokens, cookies, or access secrets in it.

## Transform private teaching into a public article

- Write an original explanation organized around the reader's problem and outcome. Do not follow the lecture sentence by sentence.
- Use only facts supported by captured evidence. Resolve disagreements against the source notes and retain qualifications that affect correctness.
- Remove private lesson URLs, account or organization details, access instructions, learner data, credentials, tokens, private endpoints, and identifying screen content.
- Do not publish raw frames, PDF pages, slide reproductions, transcripts, paid attachments, or proprietary project files by default. Include an image or course-supplied asset only when the user is authorized to publish it and explicitly approves that asset.
- Use the minimum code needed to teach the point. A verbatim excerpt must be verified and covered by the user's publication rights. When those rights are unclear, omit the excerpt or write an independently derived generalized example, label that transformation in the private evidence map, and validate it independently when practical. Never assume that a short excerpt is automatically safe to publish.
- Keep instructor claims distinct from the author's analysis, modernization, correction, and external enrichment. Cite public supporting sources when enrichment materially affects the article.
- Do not expose private timestamps, page anchors, material IDs, or evidence paths in the article unless the user explicitly wants them public and readers are authorized to access the source.

## Match the current Jekyll post format

Unless the latest repository conventions differ, generate:

```markdown
---
layout: post
title: "<specific Traditional Chinese title>"
date: YYYY-MM-DD
categories: <categories matching the site's current syntax>
---

# <reader-facing heading>

<opening problem, outcome, and why it matters>

## <mental model or context>

## <verified walkthrough, example, or analysis>

## <result, limitations, and applicable conditions>

## <practical takeaways>
```

Use `_posts/YYYY-MM-DD-<ASCII-kebab-case-slug>.markdown` unless the repository has adopted another convention. Follow the current post style for headings, emphasis, code fencing, links, and categories. Prefer a specific technical title over the course or lesson title, and make the article independently useful to a reader who cannot access the course.

The substantive post inspected on 2026-08-12 uses scalar front matter such as `categories: Code Review`. Preserve that current syntax unless a fresh inspection establishes another convention.

## Validate the public payload

Before presenting an article as publication-ready:

1. Compare every material statement and code block with the private evidence map.
2. Review the post and approved assets for secrets, private URLs, identifying information, copyrighted over-reproduction, and unsupported claims.
3. Check filename, date, front matter, categories, links, Markdown or Liquid syntax, and asset paths against the current repository.
4. Run the repository's documented checks. When none supersede it and dependencies are available, run `bundle exec jekyll build`; also run `git diff --check` for a local repository change.
5. Inspect the rendered article when rendering is available, especially code blocks, headings, lists, links, and mobile-width overflow.
6. Report validation that could not run and keep the status as draft when a material check is missing.

Call an article publication-ready only after fresh repository inspection, claim-to-evidence review, privacy and publication-rights review, repository-format checks, and the applicable documented build checks succeed. Rendering is required when the repository workflow provides it; otherwise report that visual inspection was unavailable. A draft may still be useful when one of these checks is pending, but its handoff must name the missing check.

The publication handoff must identify the generated post path, article angle, evidence-map path, excluded private material, approved public assets, validation results, and whether the article is only a draft, changed locally, committed, pushed, or published.
