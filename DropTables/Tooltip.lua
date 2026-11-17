local _, ns = ...

local function addDropLines(tooltip, data)
    if tooltip ~= GameTooltip or not ns.settings or not ns.settings.showTooltip then
        return
    end
    local npc = ns.NpcFromGuid(data and data.guid)
    local stats = npc and ns.GetStats(npc, "all")
    if not stats then
        return
    end
    local entries, worldCount = ns.VisibleEntries(stats)
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
    if #more > 0 then
        tooltip:AddLine(table.concat(more, ", ") .. " in /dt", 0.6, 0.6, 0.6)
    end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, addDropLines)
