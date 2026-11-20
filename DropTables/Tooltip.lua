local _, ns = ...

local SKIN_ITEMS = 3

-- One line with what skinning the mob gives, the most frequent first.
local function addSkinLine(tooltip, skin)
    local parts = {}
    for i = 1, math.min(SKIN_ITEMS, #skin.list) do
        local entry = skin.list[i]
        table.insert(parts, ("%s%s|r %s"):format(ns.QualityColor(entry.quality), ns.ItemName(entry.itemId),
            ns.FormatRate(entry.rate)))
    end
    if #skin.list > SKIN_ITEMS then
        table.insert(parts, ("+%d"):format(#skin.list - SKIN_ITEMS))
    end
    local shade = skin.small and 0.6 or 1
    tooltip:AddLine(("|cffffd100Skinning|r  %s"):format(table.concat(parts, ", ")), shade, shade, shade, true)
end

local function addDropLines(tooltip, data)
    if tooltip ~= GameTooltip or not ns.settings or not ns.settings.showTooltip then
        return
    end
    local npc = ns.NpcFromGuid(data and data.guid)
    local stats = npc and ns.GetStats(npc, "all")
    local skin = npc and ns.GetSkinStats(npc)
    if not stats then
        if skin then
            tooltip:AddLine(" ")
            tooltip:AddDoubleLine("Drop Tables", ("%d skinned"):format(skin.skinned), 1, 0.82, 0, 0.6, 0.6, 0.6)
            addSkinLine(tooltip, skin)
        end
        return
    end
    local entries, worldCount, lowCount = ns.VisibleEntries(stats)
    local rateShade = stats.small and 0.6 or 1
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Drop Tables", ("%d kills"):format(stats.kills), 1, 0.82, 0, 0.6, 0.6, 0.6)
    local shown = math.min(ns.settings.tooltipLines, #entries)
    for i = 1, shown do
        local entry = entries[i]
        local left
        if entry.money then
            left = ("|T%s:14:14|t Money (avg %s)"):format("Interface\\Icons\\INV_Misc_Coin_01", ns.CoinText(entry.avg))
        else
            local stack = ""
            if (entry.max or 1) > 1 or entry.avgQty > 1.05 then
                stack = " |cffaaaaaax" .. ns.FormatStack(entry) .. "|r"
            end
            left = ("|T%s:14:14|t %s%s|r%s"):format(ns.ItemIcon(entry.itemId), ns.QualityColor(entry.quality),
                ns.ItemName(entry.itemId), stack)
        end
        tooltip:AddDoubleLine(left, ns.FormatRate(entry.rate), 1, 1, 1, rateShade, rateShade, rateShade)
    end
    local more = {}
    if #entries > shown then
        table.insert(more, ("+%d more"):format(#entries - shown))
    end
    if worldCount > 0 then
        table.insert(more, ("%d world drops"):format(worldCount))
    end
    if lowCount > 0 then
        table.insert(more, ("%d below min quality"):format(lowCount))
    end
    if #more > 0 then
        tooltip:AddLine(table.concat(more, ", ") .. " in /dt", 0.6, 0.6, 0.6)
    end
    if skin then
        addSkinLine(tooltip, skin)
    end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, addDropLines)
