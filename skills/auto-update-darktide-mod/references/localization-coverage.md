<!-- SPDX-FileCopyrightText: 2026 SyuanTsai -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Source coverage and Traditional Chinese survival

New worksets include `old.coverage`, `new.coverage`, and `new.zhTwSurvival` in the existing immutable OLD/NEW contract. Coverage lists unit identities, recognition methods and counts (named language tables, positional arrays, direct assignments, numeric loops, literal helpers and literal-list loops), unresolved fields and runtime prefixes. Unconsumed language fields or opaque source fields block the entire workset even when other units parse. The scanner remains deliberately bounded; coverage is evidence of the supported forms, not a general Lua evaluator.

Apply reopens OLD from the recorded Git base and rescans the hash-bound `new.coverageInputBase64` snapshot, including during repeated application. Receipt independently reads raw NEW and merged artifacts and reopens OLD from Git. Both compare coverage and check every OLD zh-tw key in the main output. Unchanged source retains the original expression; source changes require review; removed keys carry `deleted_in_new_source` with their OLD identity and expression. The existing optional `-ReviewPositionalLabelChanges` scope also records changed zh-cn labels as requiring review. Existing pre-coverage worksets keep their original contracts; generate a fresh workset to obtain the new evidence.

The verified `game_class_name_*` active-locale passthrough remains unchanged. The English-only `hide_mood_vfx_*` loop is recorded but cannot produce a ready workset. The existing translation binding pins the glossary but supplies no structured game-list/name lookup. Supply `New-LocalizationWorkset.ps1 -DynamicListMapPath <map.json>` to attach that supplemental mapping as source-backed terminology candidates:

```json
{
  "schemaVersion": 1,
  "sourcePath": "mood_settings.lua",
  "entries": { "knocked_down": "倒地" }
}
```

`sourcePath` resolves relative to the map. The source must contain exactly one literal `mood_types` table with scalar values, or a literal `table.enum(...)` list. The parser never executes it. Source and map hashes, each generated key, English label and candidate are recorded. Missing names, extra names, unsupported sources and changed evidence fail. A complete mapping still requires review: candidates are not silently installed into a runtime lookup, and an English fallback is not accepted as zh-tw. A reviewed source must subsequently use a supported, provable localization structure before Apply can proceed. This keeps the existing generated-write boundaries intact.

`tests/LocalizationCoverage.Tests.ps1` runs a controlled LuaJIT main-file load with no sidecar I/O and checks every OLD zh-tw key. Override the executable with `SYP700_LUAJIT`; an unavailable executable explicitly skips that test, and the repository runner reports the incomplete run as failure. The runner accepts `-TestPath` for separate test batches without relaxing its unskipped-pass requirement.
