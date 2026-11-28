-- SPDX-FileCopyrightText: 2026 SyuanTsai
-- SPDX-License-Identifier: Apache-2.0
-- Reduced from the LoadoutMonitor positional and numeric generator shapes.
local locr = { title = { en = "Loadout Monitor" } }
local function generate_translation(t,prefix,suffix,lids)
    if type(t) ~= "table" then return end
    local prefix = prefix or ""
    local suffix = suffix or ""
    local full_id = ""
    for id,text in pairs(t) do
        full_id = prefix..id..suffix
        locr[full_id] = locr[full_id] or {}
        if type(text) == "table" and type(lids) == "table" and #lids == #text then
            for i = 1,#lids do
                locr[full_id][lids[i]] = text[i]
            end
        elseif type(text) == "string" and type(lids) == "string" then
            locr[full_id][lids] = text
        end
    end
end
for i = 1,4 do
    locr[string.format("player_Feats_order_%s",i)] = {
        en = "Slot: "..tostring(i),
        ["zh-cn"] = "槽位："..tostring(i),
    }
end
local locale_order = {"en","zh-cn"}
local common_order = {"en","zh-cn"}
local def_abb = { executioner = {"ES","刽"} }
local highlights = { shout = {"VoC","战吼"} }
local common = { new_option = {"New option","新选项"} }
generate_translation(def_abb,"def_","",locale_order)
generate_translation(highlights,"highlight_","",locale_order)
generate_translation(common,nil,nil,common_order)
return locr
