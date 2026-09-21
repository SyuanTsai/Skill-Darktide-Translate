# Durable Course Notes Format

Use this format for persistent notes and later question answering. Preserve stable identifiers and precise source anchors across every material type.

## Contents

- Artifact set
- Material record
- Event record
- Lesson note
- Code fidelity
- Retrieval and retention

## Artifact set

Create the smallest useful equivalent of:

```text
<course-id>/
├─ index.md
├─ manifest.json
├─ materials/
│  └─ <material-id>.json
├─ lessons/
│  └─ <lesson-id>.md
├─ events/
│  └─ <lesson-id>.jsonl
├─ code/
│  └─ <lesson-id>/
├─ evidence/
│  └─ <lesson-id>/
└─ exports/
   ├─ notebooklm/
   └─ syuantsai-github/
```

- `index.md`: course summary, lesson and material map, concepts, coverage, gaps, and links.
- `manifest.json`: stable course, lesson, material, event, and evidence identifiers plus capture status and artifact paths.
- `materials/<material-id>.json`: source type, private source location, lesson associations, duration or pages, revision, access state, evidence methods, coverage, and gaps.
- `lessons/<lesson-id>.md`: readable notes in teaching order with cross-source anchors.
- `events/<lesson-id>.jsonl`: one searchable explanation, operation, result, warning, or correction per line.
- `code/<lesson-id>/`: verified excerpts, snapshots, or diffs named with source context.
- `evidence/<lesson-id>/`: minimal representative video frames, rendered document regions, or other private artifacts.
- `exports/notebooklm/`: replaceable sources derived from durable notes; see `notebooklm-export.md`.
- `exports/syuantsai-github/`: article draft plus a private claim-to-evidence map; see `syuantsai-github-article.md`.

If storage cannot represent directories or JSONL, preserve the same logical fields in pages, records, or tables. Prefer relative artifact paths so the private bundle can move without breaking links.

## Material record

Assign a stable ID to every video, audio file, PDF, slide deck, code attachment, exercise, or other source. Record only the private locator needed to reopen it; never store credentials or session data. Include:

- material ID, type, title, version, and course or lesson association;
- provider URL or authorized local path;
- duration, file pages and printed labels, slide count, or file revision as applicable;
- text, audio, visual, OCR, code, and attachment availability;
- processed range and modality-specific coverage;
- access restrictions, uncertainty, and material gaps.

## Event record

Use an event for each coherent teaching sequence. Attach one or more anchors when several materials support the same context:

```json
{
  "event_id": "lesson-03-retry-policy",
  "lesson_id": "lesson-03",
  "topic": "Configure retry policy",
  "summary": "Why the default retry behavior is insufficient",
  "anchors": [
    {
      "material_id": "lesson-03-video",
      "kind": "video",
      "start": "00:12:41",
      "end": "00:14:08"
    },
    {
      "material_id": "retry-handbook-v2",
      "kind": "pdf",
      "file_page": 28,
      "page_label": "27",
      "section": "Retry policy"
    }
  ],
  "state": "IDE configuration and the handbook defaults table",
  "action": "Changed retry count and delay, then ran the service",
  "result": "The request retried twice before succeeding",
  "artifacts": ["code/lesson-03/retry-options.cs"],
  "evidence": ["evidence/lesson-03/video-result.png", "evidence/lesson-03/pdf-page-028.png"],
  "confidence": "high",
  "uncertainty": null
}
```

Keep summaries neutral rather than storing extensive verbatim narration or document text.

## Lesson note

For each meaningful sequence, write:

```markdown
### <topic>

- Source anchors: <material IDs plus timestamps, file pages, slide numbers, sections, or revisions>
- Teaching context: <what and why>
- Screen or document state: <application, file, page, diagram, table, or code>
- Actions or procedure:
  1. <ordered action>
  2. <ordered action>
- Code or command: <verified snapshot or short essential excerpt>
- Result: <visible outcome, output, error, or verification>
- Cross-source relationship: <how the sources reinforce, update, or conflict>
- Evidence: <event and representative artifact links>
- Confidence / gap: <uncertainty or inaccessible source portion>
```

## Code fidelity

- Preserve language, filename or context, source material, precise locator, and revision.
- Prefer an authorized source artifact. Otherwise combine only evidence that verifies continuity and mark unreadable or omitted regions.
- Preserve successive snapshots or a verified diff when edits are instructional.
- Keep instructor or course code separate from agent-proposed corrections, generalized examples, or modernizations.
- Capture the teaching-relevant excerpt instead of reconstructing a substantial proprietary codebase.

## Retrieval and retention

Answer later questions with the lesson and every source anchor needed to support the response. Identify whether evidence came from narration, selectable document text, OCR, a rendered page, visible UI, code, or inference. Preserve conflicts rather than citing only the preferred source.

Store only evidence needed for understanding and retrieval. Apply access protection appropriate to the original course. Do not place the bundle or private evidence maps in source control or a shared system unless the user explicitly chooses that destination and is authorized to do so.
