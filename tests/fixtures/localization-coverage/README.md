<!-- SPDX-FileCopyrightText: 2026 SyuanTsai -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Reduced localization regressions

LoadoutMonitor preserves the real generator body, `def_abb` / `highlights` positional rows and `player_Feats_order_1`–`4` numeric assignments. The two constant language arrays are bound to local variables, the form already supported by #67; the real inline-array calls remain unsupported and must block. OLD contains repository-only zh-tw while NEW contains none, including a common row that has never had zh-tw. Fixtures contain only a few illustrative rows, not copies of the full MOD.

The VFX fixture preserves the upstream `pairs(MoodSettings.mood_types)` / `string.gsub` / `hide_mood_vfx_*` shape. The source and map contain two illustrative game names. Removing a mapping, adding a source name, or retaining an English-only generator requires review and cannot pass as translated output.

Read-only reference files inspected for this task were the LoadoutMonitor and vfx_swapper localization main files under `F:/GitFile/Persion - Games/Warhammer-40-000-DARKTIDE-Mods/Warhammer 40,000 DARKTIDE/mods/`. No installed MOD translations are modified by these tests.
