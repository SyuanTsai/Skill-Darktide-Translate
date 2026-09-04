<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->
# Taiwan Traditional Chinese translation quality contract

This reference is normative for Schema 14 and Schema 15 translation selection, translation writing, local Review, and external-feedback classification. Read it before deciding translation eligibility and again with the packaged Review Baseline. It refines only semantic translation quality; source identity, byte-span/workset authorization, Lua structure, security, Git evidence, Candidate Gate, publication, and finalization contracts keep their existing authority.

When the packaged Workflow or Review Baseline describes faithful coverage of English details, apply the outcome standard below. Functional meaning in game context determines fidelity. A one-to-one English-to-Chinese detail checklist is supporting evidence, not the acceptance definition.

## Meaning authority

English source and in-game context are the primary meaning authority. Use UI location, gameplay behavior, placeholders, values, and related English strings to resolve ambiguity. Use zh-cn as a clarification reference, not a wording template. Build terminology, syntax, and tone independently for Taiwan Traditional Chinese.

## Preserve curated zh-tw

An existing reliable C0 zh-tw unit is a curated human translation asset. When its English/source expression and execution structure are unchanged, preserve the complete zh-tw unit byte-for-byte.

Evidence of garbled text, Simplified Chinese leakage, a wrong number, wrong unit, damaged placeholder or markup, reversed meaning, or a materially wrong mechanic is an objective quality finding. Correct an unchanged-source unit when the user authorizes that quality-revision scope and the active schema provides its exact zh-tw edit path. Style preference, terminology preference, increased explicitness, or an omitted nonessential modifier alone keeps the existing unit reliable and preserved.

## Produce natural translations

For new, missing, source-changed, or otherwise eligible units, produce fluent Taiwan Traditional Chinese in the established MOD and game voice. Preserve the functional meaning, gameplay conditions, values, units, placeholders, and markup that affect use or behavior.

Judge semantic completeness by functional meaning in context, not word-for-word coverage. Idiomatic compression, restructuring, implicit subjects, and omission of nonessential modifiers are valid when the same gameplay meaning reaches the player. An omitted nonessential modifier alone does not make a translation unusable.

## Review the outcome

A translation passes semantic Review when:

- the player receives the correct mechanic, action, target, condition, value, unit, limitation, and exception that materially affect use;
- the wording is natural Taiwan Traditional Chinese and consistent with the surrounding MOD/game voice;
- placeholders, markup, escapes, dynamic expressions, and Lua structure retain their required behavior; and
- no objective defect makes the message misleading, broken, or unusable.

Record a missing English detail as a Finding only when its omission changes functional meaning or creates an objective defect. Treat optional wording refinements as non-blocking observations unless the user authorized a quality-revision scope.

## Evidence boundaries

Apply every eligible correction through the schema-authorized path. Schema 14 represents approved semantic decisions as exact byte spans. Schema 15 sends deterministic `AI_REQUIRED` units for wording and preserves unchanged reliable OLD zh-tw through its workset classification. An objective defect in a deterministic unchanged Schema 15 unit is recorded for an explicitly scoped correction run; the update workset keeps its classification intact. This contract changes how the Agent judges translation quality while source expressions, non-zh-tw fields, and evidence boundaries retain their established ownership.
