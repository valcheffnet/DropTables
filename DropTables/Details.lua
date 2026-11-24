local _, ns = ...

-- The drop table of one mob. The window stays open until it's closed with its X button or /dt, so Escape leaves it
-- alone.
local Style = ns.Style
local C = Style.colors
local TOP = Style.HEADER
local ROW_HEIGHT = 24
local SCROLLBAR_GAP = 18
local MODES = { { key = "all", label = "All" }, { key = "solo", label = "Solo" }, { key = "group", label = "Group" } }
local COLUMNS = {
    { key = "rate", label = "Chance", width = 60 },
    { key = "drops", label = "Drops", width = 44 },
    { key = "qty", label = "Count", width = 44 },
    { key = "price", label = "Price", width = 72 },
}

local SOURCE_COLORS = { own = C.gold, peer = { 0.52, 0.66, 0.74 }, shared = { 0.78, 0.5, 0.16 } }

local frame = Style.Window("DropTablesDetails", 430, 540, 300, 320, "detailsPos", "detailsSize", "detailsAlpha")
frame:HookScript("OnShow", function()
    ns.settings.detailsOpen = true
end)
frame:HookScript("OnHide", function()
    ns.settings.detailsOpen = false
end)

local opacity = Style.OpacitySlider(frame)
opacity:SetWidth(60)
opacity:ClearAllPoints()
opacity:SetPoint("TOPRIGHT", -16, -39)
frame.title:SetJustifyH("LEFT")
frame.subtitle:SetJustifyH("LEFT")

local function fitTitle()
    frame.title:SetWidth(math.max(40, frame:GetWidth() - 52))
    frame.subtitle:SetWidth(math.max(40, frame:GetWidth() - 33 - (opacity:GetWidth() + opacity.label:GetStringWidth() + 28)))
end
frame:HookScript("OnSizeChanged", fitTitle)
fitTitle()

local shownNpc
local shownItems = {} -- itemId -> true for the items the window lists
local mode = "all"
local tabs = {}
local render

-- The ledger line under the title, with three totals and a bar showing where the kills come from (the player, other
-- players or the shared database) above its legend.
local STATS_Y = -(TOP + 10)
local TOTAL_WIDTH = 42
local function total(label, index)
    local value = Style.Text(frame, "heading")
    value:SetWidth(TOTAL_WIDTH)
    value:SetJustifyH("CENTER")
    value:SetPoint("TOPLEFT", 10 + (index - 1) * (TOTAL_WIDTH + 2), STATS_Y)
    local caption = Style.Text(frame, "label")
    caption:SetWidth(TOTAL_WIDTH + 4)
    caption:SetJustifyH("CENTER")
    caption:SetPoint("TOP", value, "BOTTOM", 0, -3)
    caption:SetText(label)
    return value
end
local killsTotal = total("KILLS", 1)
local lootedTotal = total("LOOTED", 2)
local emptyTotal = total("EMPTY", 3)
local SOURCES_X = 10 + 3 * (TOTAL_WIDTH + 2) + 12

local sourceCaption = Style.Text(frame, "label")
sourceCaption:SetPoint("TOPLEFT", SOURCES_X, STATS_Y - 1)
sourceCaption:SetText("KILL SOURCES")
local sourceBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
sourceBar:SetHeight(4)
sourceBar:SetPoint("TOPLEFT", sourceCaption, "BOTTOMLEFT", 0, -5)
local function fitBar()
    sourceBar:SetWidth(math.max(40, (frame:GetWidth() - SOURCES_X - 16) * 2 / 3))
end
frame:HookScript("OnSizeChanged", fitBar)
fitBar()
sourceBar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
Style.Paint(function()
    sourceBar:SetBackdropColor(C.raised[1], C.raised[2], C.raised[3], 1)
end)
local segments = {}
for i, kind in ipairs({ "own", "peer", "shared" }) do
    local segment = sourceBar:CreateTexture(nil, "ARTWORK")
    Style.Paint(function()
        segment:SetColorTexture(unpack(SOURCE_COLORS[kind]))
    end)
    segment:SetPoint("TOP")
    segment:SetPoint("BOTTOM")
    segments[i] = { kind = kind, texture = segment }
end
local sourceLegend = Style.Text(frame, "muted")
sourceLegend:SetPoint("TOPLEFT", sourceBar, "BOTTOMLEFT", 0, -5)
sourceLegend:SetPoint("RIGHT", -16, 0)
sourceLegend:SetJustifyH("LEFT")

local function colored(kind, text)
    local color = SOURCE_COLORS[kind]
    return ("|cff%02x%02x%02x%s|r"):format(color[1] * 255, color[2] * 255, color[3] * 255, text)
end

-- Fills the totals and the bar. The bar splits up the kills that went into the chances, while the legend gives the
-- player's own kills in full, even though the shared database may already hold part of them.
local function showSources(stats)
    if not stats then
        killsTotal:SetText("-")
        lootedTotal:SetText("-")
        emptyTotal:SetText("-")
        sourceBar:Hide()
        sourceLegend:SetText("")
        return
    end
    killsTotal:SetText(stats.kills)
    lootedTotal:SetText(stats.opened)
    emptyTotal:SetText(stats.kills > 0 and ("%d%%"):format(math.floor(stats.empty / stats.kills * 100 + 0.5)) or "-")
    local counts = { own = stats.ownCounted, peer = stats.peerKills, shared = stats.sharedKills }
    local sum = counts.own + counts.peer + counts.shared
    sourceBar:Show()
    local width, left = sourceBar:GetWidth(), 0
    for _, segment in ipairs(segments) do
        local part = sum > 0 and width * counts[segment.kind] / sum or 0
        segment.texture:SetShown(part >= 1)
        segment.texture:SetPoint("LEFT", left, 0)
        segment.texture:SetWidth(math.max(part, 1))
        left = left + part
    end
    local legend = { colored("own", ("You %d"):format(stats.ownKills)) }
    if stats.sources > 0 then
        table.insert(legend, colored("peer", ("Players %d"):format(stats.peerKills)))
    end
    if stats.sharedKills > 0 then
        table.insert(legend, colored("shared", ("Shared %d"):format(stats.sharedKills)))
    end
    sourceLegend:SetText(table.concat(legend, "   "))
end
sourceBar:SetScript("OnSizeChanged", function()
    if frame:IsShown() and render then
        render()
    end
end)

local TOGGLES_Y = -(TOP + 50)
local CONTROLS_Y = -(TOP + 76)
local previous
for _, info in ipairs(MODES) do
    local tab = Style.Tab(frame, info.label)
    if previous then
        tab:SetPoint("LEFT", previous, "RIGHT", 2, 0)
    else
        tab:SetPoint("TOPLEFT", 10, CONTROLS_Y)
    end
    tab:SetScript("OnClick", function()
        mode = info.key
        render()
    end)
    tabs[info.key] = tab
    previous = tab
end

-- The mob's gold an hour, the same as in the Loot Finder, at the right end of the tab row.
local gphText = Style.Text(frame, "body")
gphText:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
gphText:SetPoint("TOP", previous, "TOP", 0, 0)
gphText:SetPoint("BOTTOM", previous, "BOTTOM", 0, 0)
gphText:SetJustifyH("RIGHT")

local toggles = {}

-- A checkbox bound to a setting, placed left to right. It returns the checkbox so the next one can go after it.
local function toggle(key, label, tooltip, after)
    local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetSize(20, 20)
    check.label = Style.Text(check, "muted")
    check.label:SetPoint("LEFT", check, "RIGHT", 1, 0)
    check.label:SetText(label)
    local labelWidth = check.label:GetStringWidth()
    if after then
        check:SetPoint("LEFT", after, "RIGHT", after.label:GetStringWidth() + 14, 0)
    else
        check:SetPoint("TOPLEFT", 8, TOGGLES_Y)
    end
    check:SetHitRectInsets(0, -labelWidth - 4, 0, 0)
    check:SetScript("OnClick", function(self)
        ns.settings[key] = self:GetChecked()
        ns.Fire("DT_SETTINGS_CHANGED")
    end)
    check:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label)
        GameTooltip:AddLine(tooltip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    check:SetScript("OnLeave", GameTooltip_Hide)
    toggles[key] = check
    return check
end

local follow = toggle("detailsFollow", "Follow target", "Switch to each mob you target. Off keeps the current mob.")
toggle("onlyMine", "Only mine", "Count only your own kills, without what other players and the shared database add.",
    follow)

local headerY = -(TOP + 110)
local rule = Style.Line(frame, C.faint)
rule:SetHeight(1)
rule:SetPoint("TOPLEFT", 10, headerY + 6)
rule:SetPoint("TOPRIGHT", -10, headerY + 6)

local offsets, right = {}, 6
for i, column in ipairs(COLUMNS) do
    offsets[i] = right
    right = right + column.width + 8
end
local nameRight = right

local itemHeader = Style.Header(frame, "Item")
itemHeader:SetPoint("TOPLEFT", 16, headerY)
itemHeader:SetPoint("RIGHT", frame, "RIGHT", -(SCROLLBAR_GAP + nameRight), 0)
itemHeader:SetSorted(false)
itemHeader:EnableMouse(false)
for i, column in ipairs(COLUMNS) do
    local header = Style.Header(frame, column.label, "RIGHT")
    header:SetWidth(column.width)
    header:SetPoint("TOPRIGHT", -(SCROLLBAR_GAP + offsets[i]), headerY)
    header:SetSorted(i == 1, true)
    header:EnableMouse(false)
end

local scroll, content = Style.ScrollList(frame)
scroll:SetPoint("TOPLEFT", 8, headerY - 20)
scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_GAP, 12 + Style.SHARE_CARD + 8)

local shareCard = Style.ShareCard(frame)
shareCard:SetPoint("BOTTOMLEFT", 10, 12)
shareCard:SetPoint("RIGHT", -10, 0)

local emptyTitle = Style.Text(content, "heading")
emptyTitle:SetPoint("TOP", 0, -36)
Style.Paint(function()
    emptyTitle:SetTextColor(unpack(C.muted))
end)
local emptyText = Style.Text(content, "muted")
emptyText:SetPoint("TOP", emptyTitle, "BOTTOM", 0, -6)

local rows = {}

local function rowEnter(self)
    if not self.itemId then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemId)
    GameTooltip:AddLine(self.skin and "Click: which other mobs give it when skinned" or "Click: which other mobs drop it",
        0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function rowClick(self)
    if self.itemId and not ns.TryLinkItem(self.itemId) then
        ns.OpenFinder(self.itemId, self.skin and "skin" or nil)
    end
end

local function getRow(index)
    local row = rows[index]
    if row then
        return row
    end
    row = Style.ListRow(content, index, ROW_HEIGHT)
    row.icon = Style.ItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 6, 0)
    row.cells = {}
    for i, column in ipairs(COLUMNS) do
        local cell = Style.Text(row, column.key == "rate" and "body" or "muted")
        cell:SetWidth(column.width)
        cell:SetPoint("RIGHT", -offsets[i], 0)
        cell:SetJustifyH("RIGHT")
        row.cells[column.key] = cell
    end
    row.bar = Style.ChanceBar(row, row.cells.rate)
    row.name = Style.Text(row, "body")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
    row.name:SetPoint("RIGHT", -nameRight, 0)
    row.name:SetJustifyH("LEFT")
    -- Section rows (world drops) use a label and a rule instead of the item columns.
    row.section = Style.Text(row, "label")
    row.section:SetPoint("BOTTOMLEFT", 8, 4)
    row.sectionNote = Style.Text(row, "muted")
    row.sectionNote:SetPoint("LEFT", row.section, "RIGHT", 8, 0)
    row.sectionRule = Style.Line(row, C.faint)
    row.sectionRule:SetHeight(1)
    row.sectionRule:SetPoint("BOTTOMLEFT", 6, 0)
    row.sectionRule:SetPoint("BOTTOMRIGHT", -6, 0)
    row:SetScript("OnClick", rowClick)
    row:HookScript("OnEnter", rowEnter)
    row:HookScript("OnLeave", GameTooltip_Hide)
    rows[index] = row
    return row
end

local function setSection(row, isSection)
    row.icon:SetShown(not isSection)
    row.name:SetShown(not isSection)
    row.bar:SetShown(not isSection)
    for _, cell in pairs(row.cells) do
        cell:SetShown(not isSection)
    end
    row.section:SetShown(isSection)
    row.sectionNote:SetShown(isSection)
    row.sectionRule:SetShown(isSection)
    row:EnableMouse(not isSection)
end

local function fillEntry(index, entry, small, skin)
    local row = getRow(index)
    setSection(row, false)
    Style.SetRowState(row, index, false)
    row.skin = skin
    if entry.money then
        row.itemId = nil
        row.icon:SetItem("Interface\\Icons\\INV_Misc_Coin_01")
        row.name:SetText("Money")
        row.cells.drops:SetText("")
        row.cells.qty:SetText(ns.CoinText(entry.avg))
        row.cells.price:SetText("")
    else
        row.itemId = entry.itemId
        row.icon:SetItem(ns.ItemIcon(entry.itemId), entry.quality)
        row.name:SetText(ns.QualityColor(entry.quality) .. ns.ItemName(entry.itemId) .. "|r")
        row.cells.drops:SetText(tostring(entry.drops))
        row.cells.qty:SetText(ns.FormatStack(entry))
        -- The price g/ph uses, faded for an item that doesn't count in it.
        row.cells.price:SetText(ns.FormatGold(ns.UnitPrice(entry.itemId, entry.world) or 0))
        row.cells.price:SetAlpha(ns.CountsInValue(entry) and 1 or 0.45)
    end
    row.cells.rate:SetText(ns.FormatRate(entry.rate))
    row.cells.rate:SetAlpha(small and 0.6 or 1)
    row.bar:SetChance(entry.rate, COLUMNS[1].width)
    row:Show()
end

local function fillSection(index, label, note)
    local row = getRow(index)
    setSection(row, true)
    Style.SetRowState(row, 1, false)
    row.itemId = nil
    row.section:SetText(label)
    row.sectionNote:SetText(note or "")
    row:Show()
end

-- "Level 5-7  |  Elwynn Forest", from the mob's level range and the map with the most kills.
local function mobSubtitle(npc)
    local parts = {}
    local info = ns.MobInfo(npc)
    if info and info.minLevel then
        local level = info.minLevel == info.maxLevel and info.minLevel or (info.minLevel .. "-" .. info.maxLevel)
        table.insert(parts, "Level " .. level)
    end
    local bestMap, bestKills
    for mapId, place in pairs(info and info.maps or {}) do
        if not bestKills or place.kills > bestKills then
            bestMap, bestKills = mapId, place.kills
        end
    end
    if bestMap then
        table.insert(parts, ns.MapName(bestMap))
    end
    return table.concat(parts, "  |  ")
end

-- What skinning the mob gives, under a section of its own below the loot, since its chances are per skinned corpse.
-- The group plays no part in skinning, so the section is the same on every tab.
local function fillSkins(used, skin)
    used = used + 1
    fillSection(used, "SKINNING", ("%d skinned corpses"):format(skin.skinned))
    local scarce = false
    for _, entry in ipairs(skin.list) do
        used = used + 1
        fillEntry(used, entry, skin.small, true)
        scarce = scarce or entry.scarce
    end
    if skin.small then
        used = used + 1
        fillSection(used, "", ("Rates from %d skinned corpses are rough."):format(skin.skinned))
    end
    if scarce then
        used = used + 1
        fillSection(used, "", "Pristine materials depend on the Bountiful Harvest perk.")
    end
    return used
end

function render()
    for key, tab in pairs(tabs) do
        tab:SetChosen(key == mode)
    end
    frame.title:SetText(shownNpc and ns.MobName(shownNpc) or "Drop Tables")
    local stats = shownNpc and ns.GetStats(shownNpc, mode)
    local skin = shownNpc and ns.GetSkinStats(shownNpc)
    shownItems = {}
    for _, list in ipairs({ stats and stats.list or {}, skin and skin.list or {} }) do
        for _, entry in ipairs(list) do
            if entry.itemId then
                shownItems[entry.itemId] = true
            end
        end
    end
    local gph = shownNpc and ns.GoldPerHour(shownNpc) or 0
    gphText:SetText(gph > 0 and ("%s |cff999999g/ph|r"):format(ns.FormatGold(gph)) or "")
    local used = 0
    showSources(stats)
    shareCard:Refresh()
    if not shownNpc then
        frame.subtitle:SetText("Drop chances of the mobs you meet")
        emptyTitle:SetText("Target a mob")
        emptyText:SetText("Its drop table shows up here.")
    elseif not stats then
        frame.subtitle:SetText(skin and mobSubtitle(shownNpc) or "")
        emptyTitle:SetText(mode == "all" and "No data yet" or ("No " .. mode .. " kills yet"))
        emptyText:SetText(mode == "all" and "Kill and loot this mob to start its table." or "Switch to All to see every kill.")
        if skin then
            used = fillSkins(used, skin)
        end
    else
        frame.subtitle:SetText(mobSubtitle(shownNpc))
        local world = {}
        for _, entry in ipairs(stats.list) do
            if entry.world then
                table.insert(world, entry)
            else
                used = used + 1
                fillEntry(used, entry, stats.small)
            end
        end
        if #world > 0 then
            used = used + 1
            fillSection(used, "WORLD DROPS", ("random gear, recipes and crates, %d items"):format(#world))
            for _, entry in ipairs(world) do
                used = used + 1
                fillEntry(used, entry, stats.small)
            end
        end
        if #stats.list == 0 then
            emptyTitle:SetText(stats.opened > 0 and "Nothing dropped yet" or "Nothing looted yet")
            emptyText:SetText(stats.opened > 0 and "The looted corpses had no items or money so far."
                or "Kills are counted, but no corpse of this mob has been looted yet.")
        elseif stats.small then
            used = used + 1
            fillSection(used, "", ("Rates from %d looted corpses are rough."):format(stats.opened))
        end
        if skin then
            used = fillSkins(used, skin)
        end
    end
    emptyTitle:SetShown(used == 0)
    emptyText:SetShown(used == 0)
    for i = used + 1, #rows do
        rows[i]:Hide()
    end
    content:SetHeight(math.max(1, used * ROW_HEIGHT))
end

local function setNpc(npc)
    shownNpc = npc
    ns.settings.detailsNpc = npc
end

-- Shows the window on the given mob or the last one, and with neither it waits for a target.
function ns.ShowDetails(npc)
    if npc then
        setNpc(npc)
    end
    frame:Show()
    render()
end

function ns.ToggleDetails(npc)
    if frame:IsShown() then
        frame:Hide()
    else
        ns.ShowDetails(npc)
    end
end

local function syncToggles()
    for key, check in pairs(toggles) do
        check:SetChecked(ns.settings[key])
    end
end

ns.On("DT_READY", function()
    frame:RestorePlacement()
    syncToggles()
    if ns.settings.detailsOpen then
        ns.ShowDetails(ns.settings.detailsNpc)
    end
end)

-- A kill, a loot window and an answer from another player each change the counts, often in the same moment, and an
-- options slider changes the settings on every step, so one redraw a little later covers them all.
local REDRAW_DELAY = 0.1
local redrawPending = false
local function redrawSoon()
    if redrawPending or not frame:IsShown() then
        return
    end
    redrawPending = true
    C_Timer.After(REDRAW_DELAY, function()
        redrawPending = false
        if frame:IsShown() then
            render()
        end
    end)
end

ns.On("DT_SETTINGS_CHANGED", function()
    syncToggles()
    redrawSoon()
end)
ns.On("DT_PRICES_CHANGED", redrawSoon)

ns.On("PLAYER_TARGET_CHANGED", function()
    if not frame:IsShown() or not ns.settings.detailsFollow then
        return
    end
    local npc = ns.UnitMob("target")
    if npc and npc ~= shownNpc then
        setNpc(npc)
        render()
    end
end)

local function refresh(npc)
    if npc == shownNpc then
        redrawSoon()
    end
end
ns.On("DT_DATA_CHANGED", refresh)
ns.On("DT_INFO_CHANGED", refresh)

-- Item names arrive from the server after the first request, so we redraw once they do. Items of other windows (bags,
-- vendors, chat links) don't concern this one, and neither does an item the server failed to load, which a redraw would
-- only ask for again.
ns.On("GET_ITEM_INFO_RECEIVED", function(itemId, success)
    if shownItems[itemId] and success ~= false then
        redrawSoon()
    end
end)
