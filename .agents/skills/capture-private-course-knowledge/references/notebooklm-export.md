# NotebookLM Export

Use this reference when NotebookLM is requested. Verify current supported source types and account limits in official Google documentation before producing or uploading a large export because capabilities and quotas can change.

## Design principles

- Keep durable notes, material records, events, code, and evidence as the source of truth. Treat the NotebookLM bundle as a rebuildable export.
- Do not submit a private, authenticated, paywalled, or embedded course URL as if it were an ingestible course source.
- Prefer self-contained Markdown or Google Docs for searchable teaching context. Include an authorized original PDF only when current NotebookLM support, publication rights, and privacy permit it and when the original layout adds value.
- Pair raw audio, PDFs, images, or other media with structured notes when they do not independently preserve the instructor's context, cross-source relationships, verified code, actions, and results.
- Keep each notebook independently useful; default to one notebook per course unless the user explicitly needs another organization.
- Respect the original course restrictions before uploading private content to Google or sharing a notebook.

## Export bundle

Generate the smallest useful equivalent of:

```text
exports/notebooklm/
├─ 00-course-guide.md
├─ 10-module-<id>.md
├─ 80-code-and-operations-<id>.md
├─ 90-visual-evidence-<id>.pdf
├─ 99-source-map.md
└─ export-manifest.json
```

- `00-course-guide.md`: purpose, prerequisites, module and material map, concepts, coverage, gaps, naming convention, and example questions.
- `10-module-<id>.md`: lessons in teaching order with timestamp, page, slide, section, code, and exercise anchors.
- `80-code-and-operations-<id>.md`: verified excerpts, diffs, commands, procedures, results, errors, and explanations.
- `90-visual-evidence-<id>.pdf`: optional selected frames or document regions with captions and precise anchors. Omit it when text sources preserve the context.
- `99-source-map.md`: mapping among course, lesson, material ID and revision, source locator, event, code, evidence, confidence, and gaps.
- `export-manifest.json`: export version, generated time, durable-note revision, source titles and order, sizes, ingestion route, and static or synchronized status. Keep it as local metadata unless the user needs it as a source.

Group lessons by module when one source per lesson would exhaust current limits. Split before current word or file-size limits and avoid sources so short that citations lose useful granularity. Use stable descriptive source titles.

## Source document requirements

Make every source self-contained. Start Markdown or Google Docs with:

```markdown
# <stable source title>

- Course ID and title:
- Module and lessons:
- Included material IDs and revisions:
- Original provider:
- Capture or export version:
- Evidence coverage:
- Material gaps:
```

For each teaching sequence, use a marker such as:

```text
[lesson-03 | lesson-03-video 00:12:41–00:14:08 | retry-handbook-v2 file p.28, printed p.27]
```

Then include the explanation and purpose; screen or document state; ordered action or procedure; verified code or command; result, error, correction, or verification; cross-source relationship; concise evidence caption; confidence; and uncertainty.

Do not rely on relative links, comments, footnotes, image filenames, or JSONL alone to carry essential context. Put the facts and source anchors in the document body.

## Choose the ingestion route

### Google Drive route

When an authorized Drive workflow is available, create or update Google Docs with controlled access and use current supported synchronization behavior. Keep other source types separate as needed. Do not assume edits inside NotebookLM update the original source.

### Local upload route

Without an authorized Drive integration, deliver supported Markdown, PDF, audio, image, or other files for manual upload after checking current capabilities. Treat uploads as static copies. Increment the export version and identify sources to replace after regeneration.

### Original-material route

Include an authorized original PDF or audio file only with explicit approval. Keep the structured notes as a separate source so NotebookLM can retrieve cross-source teaching context. Never upload private material merely because the product accepts its file type.

## Validate after import

Run representative questions such as:

- What did the instructor explain and demonstrate at a specified timestamp, and which PDF page adds the documented rule?
- Show the verified code for an operation and cite every supporting material and revision.
- Where do the video demonstration and PDF handout differ, and which evidence establishes the difference?
- Which pages, intervals, or attachments remain missing or uncertain?

Confirm that answers cite the expected module sources, precise timestamps and pages, correct actions, code, results, and source relationships. If retrieval is weak, improve titles, grouping, or body context, regenerate affected sources, and rerun the questions.

## Handoff

Report the notebook title, source count and upload order, included material types, ingestion route, static or synchronized status, current-limit checks, privacy and sharing decisions, sources requiring manual approval, and suggested retrieval questions. Keep upload as a separate authorized action when it writes to Google or exposes private material to a new service.
