-- SPDX-FileCopyrightText: 2026 SyuanTsai
-- SPDX-License-Identifier: Apache-2.0
local localizations = { title = { en = "VFX Swapper", ["zh-tw"] = "特效切換" } }
local MoodSettings = require("scripts/settings/camera/mood/mood_settings")
for mood_type, _ in pairs(MoodSettings.mood_types) do
    local label = string.gsub(mood_type, "_", " ")
    localizations["hide_mood_vfx_" .. mood_type] = {
        en = "Disable " .. label,
    }
end
return localizations
