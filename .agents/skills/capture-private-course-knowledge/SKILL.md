---
name: capture-private-course-knowledge
description: Capture, integrate, summarize, export, publish, and later retrieve authorized course and lecture materials from arbitrary public or private websites and files, including authenticated videos without captions, PDFs, slides, attachments, and code. Use when an agent must inventory a course, extract spoken, visual, and document content, link video timestamps to PDF pages or other sources, preserve code and demonstrations with evidence, create durable notes, NotebookLM-ready sources, or evidence-based Jekyll articles, or reconstruct teaching context without bypassing access controls or claiming analysis of inaccessible material.
---

# Capture Private Course Knowledge

Create one trustworthy, reusable knowledge base from every material in an authorized course. Treat videos, PDFs, slides, code, quizzes, and attachments as related evidence sources rather than independent summaries.

## Preserve authorization and privacy

- Work only with content the user provides or can access through an authorized session.
- Prefer a purpose-built connector, provider API, or official export. Use browser control for visible or interactive page work when no semantic tool can access the content.
- Honor an explicitly requested browser. Otherwise, use an available browser that can reach the course and reuse its signed-in session when permitted.
- Ask the user to sign in or complete MFA or CAPTCHA when required. Never request, inspect, extract, or store passwords, cookies, tokens, browser storage, or session data.
- Do not bypass authentication, paywalls, DRM, playback restrictions, document protections, download controls, or provider safeguards. Do not discover hidden files or media URLs through protected request data.
- Do not replace inaccessible private-course evidence with web search results. Use public sources only when the user separately requests enrichment, and label them as external context.
- Keep downloaded media, documents, transcripts, rendered pages, frames, code snapshots, and notes in a temporary or user-approved private location outside version control. Retain them only as authorized.
- Obtain approval before sending private material to an external transcription, OCR, vision, storage, or knowledge service, especially when it may incur cost.
- Summarize and transform course content instead of reproducing full transcripts, documents, slides, or substantial proprietary source material.

## Establish the deliverable

Identify the course, modules or lessons, included materials, output language, desired depth, and whether the user wants a one-time summary, durable recall, NotebookLM-ready sources, or a public article. Establish a user-approved private destination before durable capture.

For an article, establish the target repository, audience, topic or article type, and whether the user wants a draft, local change, or publication. If the topic is unspecified, default to a draft about one coherent, evidence-backed teaching outcome.

Treat a request to capture or summarize a course URL as permission for read-only access through the user's available session. Ask before downloads, uploads, purchases, enrollment changes, quiz submissions, or other state-changing actions.

Read references only when applicable:

- For durable capture or later retrieval, read [references/course-notes-format.md](references/course-notes-format.md).
- If the course contains video or audio, read [references/video-capture.md](references/video-capture.md).
- If the course contains PDF material, read [references/pdf-material-capture.md](references/pdf-material-capture.md).
- For NotebookLM output, read [references/notebooklm-export.md](references/notebooklm-export.md).
- For `SyuanTsai/SyuanTsai.github.io`, read [references/syuantsai-github-article.md](references/syuantsai-github-article.md) and reinspect the target repository before generating an article.

## Follow the capture workflow

### 1. Inventory the whole course

Record the visible course title, provider, source location, module and lesson names, and every in-scope video, audio file, PDF, slide deck, code archive, link, exercise, quiz, and attachment. For each material record a stable material ID, type, lesson or topic association, version or revision when visible, duration or page count, access status, and available captions, selectable text, official downloads, or other evidence routes.

Use this inventory as the coverage baseline. Do not silently skip inaccessible, duplicate, optional, or zero-duration items. Stable course, lesson, material, event, and evidence identifiers must remain usable if titles or filenames change.

### 2. Choose an authorized route for each material

Use the strongest route available: provider-supplied text or files, an official or user-provided local artifact, an approved official download or export, or visible browser inspection. Select the appropriate format tool or Skill for each file type.

Do not assume that access to one course page exposes every embedded material to media or document tools. Record inaccessible items individually and identify the smallest authorized artifact needed to continue.

### 3. Extract modality-specific evidence

- For video or audio, preserve timestamped narration, visual state, code, actions, and results using `video-capture.md`.
- For PDFs, preserve document structure, page and section anchors, figures, tables, code, OCR confidence, and revision using `pdf-material-capture.md`.
- For slides, images, and other documents, preserve slide, page, section, figure, or file anchors and distinguish directly extracted text, OCR, visible facts, and inference.
- For code or configuration attachments, prefer the authorized source file. Preserve path, version, relevant excerpt or diff, and its relationship to the lesson rather than copying an entire proprietary project.

### 4. Normalize and relate the evidence

Attach every retained claim, explanation, action, code block, and result to one or more source anchors. A source anchor identifies the material and its precise locator, such as a video timestamp range, PDF file page and printed page label, slide number, document section, code path and revision, or exercise identifier.

Link materials when they explain the same teaching sequence. Record when the instructor references a PDF page, when a document supplies details omitted from a video, or when a live demonstration differs from an older handout. Do not silently merge conflicts; preserve the source, version, observed difference, and best-supported interpretation.

### 5. Build contextual lesson events

Create evidence-linked event records that answer:

- What concept or decision was being explained, and why?
- What was spoken, shown, or written in each source?
- What action, code, command, setting, or procedure was demonstrated?
- What result, warning, correction, or verification followed?
- Which timestamps, pages, sections, files, and evidence artifacts support the reconstruction?

Extract learning goals, prerequisites, definitions, procedures, examples, limitations, common mistakes, exercises, and follow-up resources. Keep course claims distinct from external enrichment and agent inference.

### 6. Verify coverage and persist

Compare processed evidence with the inventory and report coverage separately by material type: lessons processed, video or audio duration, PDF pages and OCR status, slides, attachments, code, exercises, and inaccessible ranges or pages. Label each material complete, partial, text-only, visual-only, audio-only, metadata-only, or inaccessible as applicable.

For long courses, checkpoint by lesson and material, write durable artifacts incrementally, and synthesize only after the agreed scope passes coverage checks. Do not label the course complete merely because every video was processed when PDFs or other in-scope materials remain unread.

Generate NotebookLM or article exports from the verified durable notes. Keep exports replaceable and keep private source anchors, raw evidence, and proprietary course artifacts out of public repositories.

## Answer future questions from the notes

1. Search the manifest, material records, lesson notes, events, code, and evidence.
2. Reconstruct the smallest relevant teaching sequence across all applicable materials.
3. Cite the course, lesson, material, precise source anchor, and saved artifact.
4. Distinguish transcript-derived statements, document text, OCR, directly visible facts, verified code, and inference.
5. State uncertainty, conflicts, missing pages, or inaccessible intervals.
6. Reopen only the specific authorized material needed to close a gap, then update the durable notes.

Do not answer from conversational memory when durable notes exist. Do not imply that uncaptured context can be recovered later.

## Produce the result

Write in the user's language unless requested otherwise. Report scope, inventory and coverage, executive summary, lesson map, key concepts and procedures, cross-source relationships, verified code or configuration, demonstrated operations, and caveats. For durable capture, provide the course index, manifest, lesson notes, events, code, evidence, and material records. For NotebookLM or an article, provide the corresponding export manifest or draft, privacy review, validation, and external-action status.

## Stop or ask for help when necessary

Stop and explain the exact blocker when the user must sign in or complete verification; every authorized route to a required material fails; the only remaining route would bypass protections; a no-caption video requires unavailable audio; a scanned or protected PDF cannot be read with available authorized tools; private material would leave the current environment without approval; durable recall has no safe destination; public output cannot avoid private or unlicensed material; target publishing conventions cannot be inspected; or the scope cannot support honest coverage.

State what was inspected, what remains inaccessible, and the smallest user action or artifact needed to continue.
