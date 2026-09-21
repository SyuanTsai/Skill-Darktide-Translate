# Video and Audio Capture

Use this reference for course video or audio, including authenticated playback and video without captions. Preserve spoken and on-screen evidence together whenever both are needed to understand the lesson.

## Choose the evidence route

Use the strongest authorized route available:

1. Use provider-supplied transcripts, captions, chapters, slides, or lesson notes as text evidence while still inspecting visuals that add information.
2. Use an official or user-provided local video or audio file when available.
3. Use an approved official download or export when it changes external state or creates a local copy.
4. Use visible browser playback to inspect timestamps, slides, diagrams, code, UI actions, and results when media acquisition is unavailable.

For video without captions, require an audio-capable route for a complete spoken-content summary. If tools can inspect frames but cannot receive playback audio, produce only a labeled visual summary or request an authorized media file. Never infer narration from visuals alone.

## Build timestamped audio evidence

- Transcribe in bounded segments using the source player's time base.
- Preserve the source language and technical terms.
- Overlap adjacent chunks slightly, then deduplicate the overlap.
- Mark uncertain terms, inaudible intervals, language changes, and speaker ambiguity instead of guessing.
- Map each segment to its course, lesson, material ID, and timestamp range.

If transcription requires an unavailable dependency or unapproved external service, report the missing capability and nearest safe fallback.

## Build timestamped visual evidence

- Capture lesson openings, transitions, diagrams, code, terminal output, configuration screens, demonstrations, results, and summaries.
- Add periodic samples across visually stable sections so long unchanged scenes remain represented.
- Increase sampling around rapid UI changes, live coding, commands, charts, and step-by-step demonstrations.
- Capture the state before a material action, the action when visible, and the resulting state.
- Apply OCR when available, then verify important commands, identifiers, values, and errors against clear frames.
- Record the material ID and exact player timestamp for every retained observation.

Treat transcript text, OCR, directly visible facts, and visual inference as different evidence types when ambiguity matters.

## Preserve code and demonstrated operations

For every meaningful sequence, record the timestamp range, application, file or resource, visible environment, instructor purpose, initial state, ordered actions, code or commands, result, correction, and verification. Link representative before, during, and after evidence.

Prefer an authorized source file or copyable course text. Reconstruct code from video only when clear overlapping frames verify it. Mark cropped, obscured, blurred, scrolled-away, inferred, or uncertain portions; never silently complete code from general knowledge. Preserve successive snapshots or a verified diff when edits are instructional.

Capture only the teaching-relevant excerpt, change, and context for a large proprietary file or project.

## Verify video coverage

- Compare analyzed duration with known duration.
- Report audio or transcript coverage separately from visual sampling coverage.
- Sample the beginning, middle, and end of every processed lesson.
- Revisit gaps around transitions, code edits, and demonstrations.
- Report inaccessible or failed intervals and whether the result is complete, partial, audio-only, visual-only, or metadata-only.

Do not mark a video complete when a material portion of required audio or visuals was unavailable.
