# PDF Course Material Capture

Use this reference for course handbooks, slide exports, worksheets, lab guides, reference sheets, scanned documents, and other PDF material. Preserve both searchable content and visual structure when layout conveys meaning.

## Inventory and classify the PDF

Record a stable material ID, filename or visible title, lesson or module association, source location, file revision or date when visible, file page count, printed page labels, table of contents, language, and access status. Classify the document as text-native, scanned, or hybrid and note whether text extraction, rendering, OCR, annotations, links, attachments, or document restrictions are present.

Treat a revised PDF as a new material revision. Preserve its relationship to earlier notes rather than silently replacing page anchors that may have moved.

## Extract text and visual evidence

1. Extract selectable text while preserving headings, lists, page boundaries, reading order, code blocks, tables, captions, footnotes, and hyperlinks where possible.
2. Render relevant pages when diagrams, columns, positioning, callouts, screenshots, formulas, or tables carry meaning that text extraction loses.
3. Apply OCR to scanned or image-only regions when available. Record OCR confidence and verify technical terms, code, commands, identifiers, numbers, and formulas against the rendered page.
4. Inspect page images directly when extracted text is empty, reordered, duplicated, truncated, or inconsistent with the layout.

Distinguish selectable text, OCR output, directly visible facts, annotations, and inference. Never fill unreadable content from general knowledge.

## Preserve precise page anchors

Use the PDF file's one-based page index as the stable locator and also record any printed page label. Add section, heading, figure, table, exercise, or paragraph context when it improves retrieval. For example:

```json
{
  "material_id": "retry-handbook-v2",
  "kind": "pdf",
  "file_page": 28,
  "page_label": "27",
  "section": "Retry policy",
  "figure": null
}
```

Do not cite only the printed page label because covers and front matter may offset it from the file page index.

## Capture code, tables, and procedures

- Preserve language, filename or context, page anchor, visible omissions, and revision for code or commands.
- Prefer an authorized code attachment when the PDF contains wrapped, truncated, rasterized, or syntax-damaged code.
- Reconstruct a table only when row and column relationships can be verified. Retain units, headers, notes, and empty-cell meaning.
- Preserve ordered steps, prerequisites, warnings, expected results, and exercise instructions without completing quizzes or submissions unless the user separately requests that state-changing action.
- For formulas or diagrams, retain a concise explanation plus a rendered evidence reference when text alone is insufficient.

Capture the smallest teaching-relevant excerpt. Do not reproduce a substantial paid handbook, slide deck, worksheet, or proprietary codebase.

## Relate PDFs to other course evidence

Link a PDF page to the video timestamp, slide, code file, exercise, or lesson event that discusses it. Record whether the document introduces, reinforces, contradicts, or updates the other source. If a demonstration differs from the PDF, preserve both versions and do not decide which is current without supporting evidence.

## Verify PDF coverage

- Compare processed pages with the inventory and agreed scope.
- Report selectable-text coverage, rendered-page inspection, and OCR coverage separately.
- Inspect the beginning, middle, and end plus every relevant section, figure, table, code example, and appendix.
- Record skipped blank, duplicate, inaccessible, corrupt, or irrelevant pages explicitly.
- Mark the material complete, partial, text-only, visual-only, OCR-dependent, metadata-only, or inaccessible.

If the PDF is encrypted or protected and the authorized tools cannot read it, request an unlocked authorized copy rather than credentials or a protection bypass.
