local _, ns = ...

-- The drop table of one mob. The window stays open until closed with its X button or /dt,
-- so Escape does not close it.
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
}

local frame = Style.Window("DropTablesDetails", 430, 500, 360, 280, "detailsPos", "detailsSize", "detailsAlpha")
frame:SetScript("OnShow", function()
    ns.settings.detailsOpen = true
end)
frame:SetScript("OnHide", function()
    ns.settings.detailsOpen = false
end)

local share = CreateFrame("Button", nil, frame)
share:SetPoint("TOPRIGHT", -36, -11)
share.label = Style.Text(share, "label")
share.label:SetPoint("RIGHT")
share.label:SetText("SHARE")
share:SetSize(share.label:GetStringWidth() + 4, 16)
share:SetScript("OnClick", function()
    ns.ToggleExport()
end)
share:SetScript("OnEnter", function(self)
    self.label:SetTextColor(unpack(C.text))
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Share my tables")
    GameTooltip:AddLine("Copy your drop counts into the shared database, for every player's tables.", 1, 1, 1, true)
    GameTooltip:Show()
end)
share:SetScript("OnLeave", function(self)
    self.label:SetTextColor(unpack(C.gold))
    GameTooltip:Hide()
end)

local shownNpc
local mode = "all"
local tabs = {}
local render

local previous
for _, info in ipairs(MODES) do
    local tab = Style.Tab(frame, info.label)
    if previous then
        tab:SetPoint("LEFT", previous, "RIGHT", 2, 0)
    else
        tab:SetPoint("TOPLEFT", 10, -(TOP + 8))
    end
    tab:SetScript("OnClick", function()
        mode = info.key
        render()
    end)
    tabs[info.key] = tab
    previous = tab
end

local toggles = {}

-- A checkbox bound to a setting; the icons and tooltip toggles share their settings with the options panel.
local function toggle(key, label, tooltip, anchor)
    local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetSize(20, 20)
    if anchor then
        check:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
    else
        check:SetPoint("TOPLEFT", 10, -(TOP + 32))
    end
    check.label = Style.Text(check, "muted")
    check.label:SetPoint("LEFT", check, "RIGHT", 1, 0)
    check.label:SetText(label)
    check:SetHitRectInsets(0, -check.label:GetStringWidth() - 4, 0, 0)
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
    return check.label
end

local last = toggle("detailsFollow", "Follow target", "Switch to each mob you target. Off keeps the current mob.")
last = toggle("showStrip", "Icons", "Show the likely drops of your target as icons.", last)
last = toggle("showTooltip", "Tooltip", "Add the likely drops to the mob tooltip.", last)
toggle("onlyMine", "Only mine", "Count only your own kills, without the drop counts other players shared.", last)

local headerY = -(TOP + 62)
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
for i, column in ipairs(COLUMNS) do
    local header = Style.Header(frame, column.label, "RIGHT")
    header:SetWidth(column.width)
    header:SetPoint("TOPRIGHT", -(SCROLLBAR_GAP + offsets[i]), headerY)
    header:SetSorted(i == 1, true)
end

local scroll, content = Style.ScrollList(frame)
scroll:SetPoint("TOPLEFT", 8, headerY - 20)
scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_GAP, 12)

local emptyTitle = Style.Text(content, "heading")
emptyTitle:SetPoint("TOP", 0, -36)
emptyTitle:SetTextColor(unpack(C.muted))
local emptyText = Style.Text(content, "muted")
emptyText:SetPoint("TOP", emptyTitle, "BOTTOM", 0, -6)

local rows = {}

local function rowEnter(self)
    if not self.itemId then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemId)
    GameTooltip:AddLine("Click: which other mobs drop it", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function rowClick(self)
    if self.itemId and not ns.TryLinkItem(self.itemId) then
        ns.OpenFinder(self.itemId)
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

local function fillEntry(index, entry, small)
    local row = getRow(index)
    setSection(row, false)
    Style.SetRowState(row, index, false)
    if entry.money then
        row.itemId = nil
        row.icon:SetItem("Interface\\Icons\\INV_Misc_Coin_01")
        row.name:SetText("Money")
        row.cells.drops:SetText("")
        row.cells.qty:SetText(ns.CoinText(entry.avg))
    else
        row.itemId = entry.itemId
        row.icon:SetItem(ns.ItemIcon(entry.itemId), entry.quality)
        row.name:SetText(ns.QualityColor(entry.quality) .. ns.ItemName(entry.itemId) .. "|r")
        row.cells.drops:SetText(tostring(entry.drops))
        row.cells.qty:SetText(ns.FormatStack(entry))
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

function render()
    for key, tab in pairs(tabs) do
        tab:SetChosen(key == mode)
    end
    frame.title:SetText(shownNpc and ns.MobName(shownNpc) or "Drop Tables")
    local stats = shownNpc and ns.GetStats(shownNpc, mode)
    local used = 0
    if not shownNpc then
        frame.subtitle:SetText("Drop chances of the mobs you meet")
        emptyTitle:SetText("Target a mob")
        emptyText:SetText("Its drop table shows up here.")
    elseif not stats then
        frame.subtitle:SetText("")
        emptyTitle:SetText(mode == "all" and "No data yet" or ("No " .. mode .. " kills yet"))
        emptyText:SetText(mode == "all" and "Kill and loot this mob to start its table." or "Switch to All to see every kill.")
    else
        local text
        if stats.sources > 0 then
            text = ("%d kills by you, %d by %d %s  |  %d looted"):format(stats.ownKills, stats.kills - stats.ownKills,
                stats.sources, stats.sources == 1 and "player" or "players", stats.opened)
        else
            text = ("%d kills  |  %d looted  |  %d left nothing"):format(stats.kills, stats.opened, stats.empty)
        end
        local info = ns.MobInfo(shownNpc)
        if info and info.minLevel then
            local level = info.minLevel == info.maxLevel and info.minLevel or (info.minLevel .. "-" .. info.maxLevel)
            text = ("Level %s  |  "):format(level) .. text
        end
        frame.subtitle:SetText(text)
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
            fillSection(used, "WORLD DROPS", ("random gear and recipes, %d items"):format(#world))
            for _, entry in ipairs(world) do
                used = used + 1
                fillEntry(used, entry, stats.small)
            end
        end
        if #stats.list == 0 then
            emptyTitle:SetText("Not enough data yet")
            emptyText:SetText(("Other players' counts show up once they reach %d looted corpses."):format(
                ns.MIN_SOURCE_SAMPLE))
        elseif stats.small then
            used = used + 1
            fillSection(used, "", ("Rates from %d looted corpses are rough."):format(stats.opened))
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

-- Shows the window, on the given mob or the last one; with neither it waits for a target.
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

ns.On("DT_SETTINGS_CHANGED", function()
    syncToggles()
    if frame:IsShown() then
        render()
    end
end)

ns.On("PLAYER_TARGET_CHANGED", function()
    if not frame:IsShown() or not ns.settings.detailsFollow then
        return
    end
    local npc = ns.UnitNpc("target")
    if npc and npc ~= shownNpc then
        setNpc(npc)
        render()
    end
end)

local function refresh(npc)
    if frame:IsShown() and npc == shownNpc then
        render()
    end
end
ns.On("DT_DATA_CHANGED", refresh)
ns.On("DT_INFO_CHANGED", refresh)

-- Item names arrive from the server after the first request; redraw once they do.
ns.On("GET_ITEM_INFO_RECEIVED", function()
    if frame:IsShown() then
        render()
    end
end)
