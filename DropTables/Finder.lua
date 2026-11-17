local _, ns = ...

-- Loot finder, laid out like the auction house: categories on the left, the items of the chosen category on the
-- right, and for one item the mobs that drop it. Zone and level filters apply to both lists.
local Style = ns.Style
local C = Style.colors
local TOP = Style.HEADER
local ROW_HEIGHT = 24
local TREE_ROW_HEIGHT = 22
local SIDEBAR = 228
local RIGHT = SIDEBAR + 14
local SCROLLBAR_GAP = 18
local MAP_BUTTON = 22
local INDENT = 14
local MOB_COLUMNS = {
    { key = "name", label = "Mob" },
    { key = "level", label = "Level", width = 46, justify = "CENTER" },
    { key = "zone", label = "Zone", width = 128, justify = "LEFT" },
    { key = "rate", label = "Chance", width = 60, justify = "RIGHT" },
    { key = "drops", label = "Drops", width = 52, justify = "RIGHT" },
}
local ITEM_COLUMNS = {
    { key = "name", label = "Item" },
    { key = "mobs", label = "Mobs", width = 44, justify = "CENTER" },
    { key = "best", label = "Best mob", width = 150, justify = "LEFT" },
    { key = "rate", label = "Chance", width = 60, justify = "RIGHT" },
}

local frame = Style.Window("DropTablesFinder", 800, 500, 660, 320, "finderPos", "finderSize", "finderAlpha")
frame:SetPoint("CENTER", 0, 40)
frame.title:SetText("Loot Finder")
frame.subtitle:SetText("Which mobs drop an item, and where")
Style.OpacitySlider(frame)
table.insert(UISpecialFrames, "DropTablesFinder")

-- view is "category" (the items of a category) or "item" (the mobs that drop one item).
-- category is "all" or a tree key: "c<class>" or "s<class>:<subclass>".
local view, category, openClass = "category", "all", nil
local selectedItem
local droppers = {}
local filters = {}
local mobSort, mobDescending = "rate", true
local itemSort, itemDescending = "rate", true
local renderTree, renderMain, selectItem, selectCategory
local search

local function createList(left, top)
    local scroll, content = Style.ScrollList(frame)
    scroll:SetPoint("TOPLEFT", left, top)
    return scroll, content
end

-- Columns of fixed width are packed from the right edge (after "reserved"); the first column takes the rest.
local function columnOffsets(columns, reserved)
    local offsets, right = {}, reserved
    for i = #columns, 2, -1 do
        offsets[i] = right
        right = right + columns[i].width + 8
    end
    return offsets, right
end

local function currentItems()
    return ns.SearchItems(search:GetText(), ns.settings.finderQualities)
end

-- Sidebar: search, quality switches and the category tree.
search = Style.Input(frame, SIDEBAR - 24, "Search looted items", "Interface\\Common\\UI-Searchbox-Icon")
search.box:SetPoint("TOPLEFT", 12, -(TOP + 12))
search:HookScript("OnTextChanged", function(self, userInput)
    if userInput then
        category, view = "all", "category"
    end
    selectCategory(category)
end)

local qualityLabel = Style.Text(frame, "label")
qualityLabel:SetPoint("TOPLEFT", 14, -(TOP + 46))
qualityLabel:SetText("QUALITY")
local qualityButtons = {}
for quality = 0, 4 do
    local button = CreateFrame("Button", nil, frame, "BackdropTemplate")
    button:SetSize(14, 14)
    button:SetPoint("LEFT", qualityLabel, "RIGHT", 8 + quality * 18, 0)
    button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    local r, g, b = ns.QualityRGB(quality)
    button.r, button.g, button.b = r or 1, g or 1, b or 1
    function button:Refresh()
        local on = ns.settings.finderQualities[quality]
        self:SetBackdropColor(self.r, self.g, self.b, on and 0.85 or 0.08)
        self:SetBackdropBorderColor(self.r, self.g, self.b, on and 1 or 0.45)
    end
    button:SetScript("OnClick", function(self)
        ns.settings.finderQualities[quality] = not ns.settings.finderQualities[quality] or nil
        self:Refresh()
        renderTree()
        renderMain()
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(_G["ITEM_QUALITY" .. quality .. "_DESC"] or "", self.r, self.g, self.b)
        GameTooltip:AddLine(ns.settings.finderQualities[quality] and "Shown, click to hide" or "Hidden, click to show",
            1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    qualityButtons[quality] = button
end

local treeLabel = Style.Text(frame, "label")
treeLabel:SetPoint("TOPLEFT", 14, -(TOP + 68))
treeLabel:SetText("CATEGORIES")

local treeScroll, treeContent = createList(8, -(TOP + 82))
treeScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", SIDEBAR - SCROLLBAR_GAP, 12)
local treeRows = {}

local divider = Style.Line(frame, C.faint)
divider:SetWidth(1)
divider:SetPoint("TOPLEFT", SIDEBAR, -(TOP + 1))
divider:SetPoint("BOTTOMLEFT", SIDEBAR, 1)

local treeEmpty = Style.Text(treeContent, "muted")
treeEmpty:SetPoint("TOPLEFT", 6, -(TREE_ROW_HEIGHT + 6))
treeEmpty:SetPoint("RIGHT", -6, 0)
treeEmpty:SetJustifyH("LEFT")
treeEmpty:SetWordWrap(true)

local function treeRow(index)
    local row = treeRows[index]
    if row then
        return row
    end
    row = Style.ListRow(treeContent, index, TREE_ROW_HEIGHT)
    row.arrow = row:CreateTexture(nil, "ARTWORK")
    row.arrow:SetSize(12, 12)
    row.count = Style.Text(row, "muted")
    row.count:SetPoint("RIGHT", -6, 0)
    row.count:SetJustifyH("RIGHT")
    row.name = Style.Text(row, "body")
    row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")
    row:SetScript("OnClick", function(self)
        -- Opening a class closes the one open before; a second click on the chosen open class closes it.
        if self.hasSubs then
            openClass = (category == self.key and openClass == self.key) and nil or self.key
            ns.settings.finderOpenClass = openClass
        end
        selectCategory(self.key)
    end)
    treeRows[index] = row
    return row
end

local function fillTreeRow(index, key, depth, name, count, hasSubs, open)
    local row = treeRow(index)
    row.key, row.hasSubs = key, hasSubs
    row.arrow:ClearAllPoints()
    row.arrow:SetPoint("LEFT", 4 + depth * INDENT, 0)
    row.arrow:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
    row.arrow:SetShown(hasSubs)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", 20 + depth * INDENT, 0)
    row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
    row.name:SetText(name)
    row.name:SetTextColor(unpack(depth == 0 and C.gold or C.text))
    row.count:SetText(count)
    Style.SetRowState(row, index, key == category)
    row:Show()
end

-- Draws the tree for the current search and quality switches.
function renderTree()
    local items = currentItems()
    local tree = ns.BuildItemTree(items)
    local searching = strtrim(search:GetText()) ~= ""
    local used = 1
    fillTreeRow(used, "all", 0, searching and "Search results" or "All items", #items, false, false)
    for _, class in ipairs(tree) do
        local key = "c" .. class.classId
        local open = class.subs ~= nil and openClass == key
        used = used + 1
        fillTreeRow(used, key, 0, class.name, class.count, class.subs ~= nil, open)
        if open then
            for _, sub in ipairs(class.subs) do
                used = used + 1
                fillTreeRow(used, "s" .. class.classId .. ":" .. sub.subclassId, 1, sub.name, sub.count, false, false)
            end
        end
    end
    for i = used + 1, #treeRows do
        treeRows[i]:Hide()
    end
    treeEmpty:SetShown(#items == 0)
    treeEmpty:SetText(searching and "Nothing you have looted matches." or "Loot something first; every item you loot shows up here.")
    treeContent:SetHeight(used * TREE_ROW_HEIGHT + (#items == 0 and 40 or 0))
end

-- The items and title of a category; a category that no longer exists (search, quality) falls back to all items.
local function categoryContents(key)
    local items = currentItems()
    if key ~= "all" then
        for _, class in ipairs(ns.BuildItemTree(items)) do
            if "c" .. class.classId == key then
                return class.items, class.name
            end
            for _, sub in ipairs(class.subs or {}) do
                if "s" .. class.classId .. ":" .. sub.subclassId == key then
                    return sub.items, sub.name
                end
            end
        end
    end
    return items, strtrim(search:GetText()) ~= "" and "Search results" or "All items", "all"
end

-- Main pane header: item icon (item view), title, summary and a way back to the category.
local headIcon = Style.ItemIcon(frame, 36)
headIcon:SetPoint("TOPLEFT", RIGHT, -(TOP + 12))
local headTitle = Style.Text(frame, "heading")
headTitle:SetJustifyH("LEFT")
local headSummary = Style.Text(frame, "muted")
headSummary:SetPoint("TOPLEFT", headTitle, "BOTTOMLEFT", 0, -4)
headSummary:SetPoint("RIGHT", -16, 0)
headSummary:SetJustifyH("LEFT")

local back = CreateFrame("Button", nil, frame)
back:SetHeight(16)
back:SetPoint("TOPRIGHT", -16, -(TOP + 14))
back.text = Style.Text(back, "label")
back.text:SetPoint("RIGHT")
back:SetScript("OnClick", function()
    selectCategory(category)
end)
back:SetScript("OnEnter", function(self)
    self.text:SetTextColor(unpack(C.text))
end)
back:SetScript("OnLeave", function(self)
    self.text:SetTextColor(unpack(C.gold))
end)

local function placeTitle(withIcon)
    headIcon:SetShown(withIcon)
    headTitle:ClearAllPoints()
    if withIcon then
        headTitle:SetPoint("TOPLEFT", headIcon, "TOPRIGHT", 10, -1)
    else
        headTitle:SetPoint("TOPLEFT", RIGHT, -(TOP + 13))
    end
    headTitle:SetPoint("RIGHT", back, "LEFT", -12, 0)
end

-- Filters, shared by both views.
local filterY = -(TOP + 64)
local zoneLabel = Style.Text(frame, "label")
zoneLabel:SetPoint("TOPLEFT", RIGHT, filterY - 6)
zoneLabel:SetText("ZONE")
local zoneDropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
zoneDropdown:SetWidth(170)
zoneDropdown:SetPoint("LEFT", zoneLabel, "RIGHT", 8, 0)
zoneDropdown:SetDefaultText("All zones")

local levelLabel = Style.Text(frame, "label")
levelLabel:SetPoint("LEFT", zoneDropdown, "RIGHT", 18, 0)
levelLabel:SetText("LEVEL")

local function levelBox(key)
    local edit = Style.Input(frame, 34, "")
    edit:SetNumeric(true)
    edit:SetMaxLetters(2)
    edit:SetJustifyH("CENTER")
    edit:HookScript("OnTextChanged", function(self)
        filters[key] = tonumber(self:GetText())
        renderMain()
    end)
    return edit
end
local levelFrom = levelBox("minLevel")
levelFrom.box:SetPoint("LEFT", levelLabel, "RIGHT", 8, 0)
local levelDash = Style.Text(frame, "muted")
levelDash:SetPoint("LEFT", levelFrom.box, "RIGHT", 5, 0)
levelDash:SetText("to")
local levelTo = levelBox("maxLevel")
levelTo.box:SetPoint("LEFT", levelDash, "RIGHT", 5, 0)

local resultCount = Style.Text(frame, "muted")
resultCount:SetPoint("TOPRIGHT", -16, filterY - 6)
resultCount:SetJustifyH("RIGHT")

-- Offers the given maps in the zone dropdown; a chosen zone that is not among them is dropped.
-- Returns true when the zone filter had to be cleared.
local function setupZones(maps)
    local cleared = false
    if filters.mapId and not tContains(maps, filters.mapId) then
        filters.mapId = nil
        cleared = true
    end
    zoneDropdown:SetupMenu(function(_, root)
        root:CreateRadio("All zones", function()
            return filters.mapId == nil
        end, function()
            filters.mapId = nil
            renderMain()
        end)
        for _, mapId in ipairs(maps) do
            root:CreateRadio(ns.MapName(mapId), function()
                return filters.mapId == mapId
            end, function()
                filters.mapId = mapId
                renderMain()
            end)
        end
    end)
    return cleared
end

local headerY = -(TOP + 100)
local filterRule = Style.Line(frame, C.faint)
filterRule:SetHeight(1)
filterRule:SetPoint("TOPLEFT", RIGHT, headerY + 6)
filterRule:SetPoint("TOPRIGHT", -12, headerY + 6)

-- A sortable table in the main pane: headers, a scrolling list and an empty state.
local function makeTable(columns, reserved, onSort)
    local offsets, firstRight = columnOffsets(columns, reserved)
    local tbl = { columns = columns, offsets = offsets, firstRight = firstRight, headers = {}, rows = {} }
    for i, column in ipairs(columns) do
        local header = Style.Header(frame, column.label, column.justify)
        if column.width then
            header:SetWidth(column.width)
            header:SetPoint("TOPRIGHT", -(SCROLLBAR_GAP + offsets[i]), headerY)
        else
            header:SetPoint("TOPLEFT", RIGHT + 8, headerY)
            header:SetPoint("RIGHT", frame, "RIGHT", -(SCROLLBAR_GAP + firstRight), 0)
        end
        header.key = column.key
        header:SetScript("OnClick", function(self)
            onSort(self.key)
        end)
        table.insert(tbl.headers, header)
    end
    tbl.scroll, tbl.content = createList(RIGHT, headerY - 20)
    tbl.scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_GAP, 12)
    tbl.emptyTitle = Style.Text(tbl.content, "heading")
    tbl.emptyTitle:SetPoint("TOP", 0, -36)
    tbl.emptyTitle:SetTextColor(unpack(C.muted))
    tbl.emptyText = Style.Text(tbl.content, "muted")
    tbl.emptyText:SetPoint("TOP", tbl.emptyTitle, "BOTTOM", 0, -6)
    function tbl:SetShown(shown)
        self.scroll:SetShown(shown)
        for _, header in ipairs(self.headers) do
            header:SetShown(shown)
        end
    end
    function tbl:SetSort(key, descending)
        for _, header in ipairs(self.headers) do
            header:SetSorted(header.key == key, descending)
        end
    end
    -- Creates row cells for every fixed column and a chance bar behind the "rate" column.
    function tbl:NewRow(index)
        local row = Style.ListRow(self.content, index, ROW_HEIGHT)
        row.cells = {}
        for i = 2, #self.columns do
            local column = self.columns[i]
            local cell = Style.Text(row, column.key == "rate" and "body" or "muted")
            cell:SetWidth(column.width)
            cell:SetPoint("RIGHT", -self.offsets[i], 0)
            cell:SetJustifyH(column.justify)
            row.cells[column.key] = cell
        end
        row.bar = Style.ChanceBar(row, row.cells.rate)
        row.name = Style.Text(row, "body")
        row.name:SetPoint("RIGHT", -self.firstRight, 0)
        row.name:SetJustifyH("LEFT")
        self.rows[index] = row
        return row
    end
    function tbl:Finish(used, emptyTitle, emptyText)
        for i = used + 1, #self.rows do
            self.rows[i]:Hide()
        end
        self.emptyTitle:SetText(emptyTitle or "")
        self.emptyText:SetText(emptyText or "")
        self.emptyTitle:SetShown(used == 0)
        self.emptyText:SetShown(used == 0)
        self.content:SetHeight(math.max(1, used * ROW_HEIGHT))
    end
    return tbl
end

local itemTable = makeTable(ITEM_COLUMNS, 8, function(key)
    if itemSort == key then
        itemDescending = not itemDescending
    else
        itemSort, itemDescending = key, key == "rate" or key == "mobs"
    end
    renderMain()
end)

local mobTable = makeTable(MOB_COLUMNS, MAP_BUTTON + 8, function(key)
    if mobSort == key then
        mobDescending = not mobDescending
    else
        mobSort, mobDescending = key, key == "rate" or key == "drops"
    end
    renderMain()
end)

local function itemRow(index)
    local row = itemTable.rows[index]
    if row then
        return row
    end
    row = itemTable:NewRow(index)
    row.icon = Style.ItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 6, 0)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
    row:SetScript("OnClick", function(self)
        if not ns.TryLinkItem(self.itemId) then
            selectItem(self.itemId)
        end
    end)
    row:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemId)
        GameTooltip:AddLine("Click: the mobs that drop it", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:HookScript("OnLeave", GameTooltip_Hide)
    return row
end

local function mobRow(index)
    local row = mobTable.rows[index]
    if row then
        return row
    end
    row = mobTable:NewRow(index)
    row.name:SetPoint("LEFT", 8, 0)
    row.map = CreateFrame("Button", nil, row)
    row.map:SetSize(16, 16)
    row.map:SetPoint("RIGHT", -6, 0)
    row.map.icon = row.map:CreateTexture(nil, "ARTWORK")
    row.map.icon:SetAllPoints()
    row.map.icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
    row.map.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.map.icon:SetDesaturated(true)
    row.map.icon:SetAlpha(0.6)
    row.map:SetScript("OnClick", function()
        ns.ShowOnMap(row.dropper.npc, filters.mapId or (row.dropper.maps[1] and row.dropper.maps[1].mapId))
    end)
    row.map:SetScript("OnEnter", function(self)
        self.icon:SetDesaturated(false)
        self.icon:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Show on map")
        GameTooltip:AddLine("Marks where this mob was killed and sets a waypoint.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.map:SetScript("OnLeave", function(self)
        self.icon:SetDesaturated(true)
        self.icon:SetAlpha(0.6)
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        ns.ShowDetails(self.dropper.npc)
    end)
    row:HookScript("OnEnter", function(self)
        local dropper = self.dropper
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(dropper.name)
        for _, map in ipairs(dropper.maps) do
            GameTooltip:AddDoubleLine(ns.MapName(map.mapId), ("%d kills"):format(map.kills), 1, 1, 1, 0.7, 0.7, 0.7)
        end
        GameTooltip:AddLine(("Dropped %d times in %d looted corpses"):format(dropper.drops, dropper.opened), 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Click for the mob's full table", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:HookScript("OnLeave", GameTooltip_Hide)
    return row
end

local function filterNote()
    local parts = {}
    if filters.mapId then
        table.insert(parts, ns.MapName(filters.mapId))
    end
    if filters.minLevel or filters.maxLevel then
        table.insert(parts, ("level %s-%s"):format(filters.minLevel or "1", filters.maxLevel or "60"))
    end
    return #parts > 0 and ("  |  " .. table.concat(parts, ", ")) or ""
end

local function renderCategory()
    itemTable:SetSort(itemSort, itemDescending)
    local items, title, fallback = categoryContents(category)
    if fallback then
        category = "all"
    end
    local summaries, maps = ns.SummarizeItems(items, filters)
    if setupZones(maps) then
        summaries = ns.SummarizeItems(items, filters)
    end
    ns.SortSummaries(summaries, itemSort, itemDescending)
    for i, summary in ipairs(summaries) do
        local row = itemRow(i)
        row.itemId = summary.itemId
        Style.SetRowState(row, i, false)
        row.icon:SetItem(ns.ItemIcon(summary.itemId), summary.quality)
        row.name:SetText(ns.QualityColor(summary.quality) .. summary.name .. "|r")
        row.cells.mobs:SetText(summary.mobs)
        row.cells.best:SetText(summary.best)
        row.cells.rate:SetText(ns.FormatRate(summary.rate))
        row.bar:SetChance(summary.rate, ITEM_COLUMNS[4].width)
        row:Show()
    end
    itemTable:Finish(#summaries, #items == 0 and "Nothing here yet" or "No item matches",
        #items == 0 and "Loot more, or change the search and quality." or "Widen the zone or level filter.")
    placeTitle(false)
    headTitle:SetText(title)
    headTitle:SetTextColor(unpack(C.gold))
    headSummary:SetText(("%d items%s  |  click one to see the mobs that drop it"):format(#summaries, filterNote()))
    resultCount:SetText(("%d items"):format(#summaries))
    back:Hide()
end

local function levelText(dropper)
    if not dropper.minLevel then
        return "?"
    elseif dropper.minLevel == dropper.maxLevel then
        return tostring(dropper.minLevel)
    end
    return dropper.minLevel .. "-" .. dropper.maxLevel
end

local function renderMobs()
    mobTable:SetSort(mobSort, mobDescending)
    local list = ns.FilterDroppers(droppers, filters, mobSort, mobDescending)
    for i, dropper in ipairs(list) do
        local row = mobRow(i)
        row.dropper = dropper
        Style.SetRowState(row, i, false)
        row.name:SetText(dropper.name)
        row.cells.level:SetText(levelText(dropper))
        local zone = dropper.zone
        if #dropper.maps > 1 then
            zone = zone .. (" +%d"):format(#dropper.maps - 1)
        end
        row.cells.zone:SetText(zone)
        row.cells.rate:SetText(ns.FormatRate(dropper.rate))
        row.cells.rate:SetAlpha(dropper.small and 0.6 or 1)
        row.bar:SetChance(dropper.rate, MOB_COLUMNS[4].width)
        row.cells.drops:SetText(dropper.drops .. "/" .. dropper.opened)
        row.map:SetShown(#dropper.maps > 0)
        row:Show()
    end
    mobTable:Finish(#list, "No mob matches", "Widen the zone or level filter.")
    resultCount:SetText(("%d of %d mobs"):format(#list, #droppers))

    local meta = ns.db.items[selectedItem]
    local quality = meta and meta.quality
    placeTitle(true)
    headIcon:SetItem(ns.ItemIcon(selectedItem), quality)
    local r, g, b = ns.QualityRGB(quality)
    headTitle:SetText(ns.ItemName(selectedItem))
    headTitle:SetTextColor(r or C.text[1], g or C.text[2], b or C.text[3])
    local best
    for _, dropper in ipairs(list) do
        if not best or dropper.rate > best.rate then
            best = dropper
        end
    end
    local zones = #ns.DropperMaps(list)
    local summary = ("Drops from %d %s"):format(#list, #list == 1 and "mob" or "mobs")
    if zones > 0 then
        summary = summary .. (" in %d %s"):format(zones, zones == 1 and "zone" or "zones")
    end
    if best then
        summary = summary .. ("  |  best: %s, %s"):format(best.name, ns.FormatRate(best.rate))
    end
    headSummary:SetText(summary .. filterNote())
    local _, title = categoryContents(category)
    back.text:SetText("BACK TO " .. title:upper())
    back:SetWidth(back.text:GetStringWidth())
    back:Show()
end

function renderMain()
    itemTable:SetShown(view == "category")
    mobTable:SetShown(view == "item")
    if view == "item" then
        renderMobs()
    else
        renderCategory()
    end
end

function selectCategory(key)
    view, category = "category", key
    ns.settings.finderCategory = key
    renderTree()
    renderMain()
end

function selectItem(itemId)
    view, selectedItem = "item", itemId
    droppers = ns.FindDroppers(itemId)
    setupZones(ns.DropperMaps(droppers))
    renderTree()
    renderMain()
end

-- Opens the finder on an item (its mobs), on a search text, or where it was left.
function ns.OpenFinder(itemOrText)
    frame:Show()
    if type(itemOrText) == "number" then
        selectItem(itemOrText)
    elseif itemOrText and itemOrText ~= "" then
        search:SetText(itemOrText)
        selectCategory("all")
    elseif view == "item" and selectedItem then
        selectItem(selectedItem)
    else
        selectCategory(category)
    end
end

function ns.ToggleFinder(text)
    if frame:IsShown() and not text then
        frame:Hide()
    else
        ns.OpenFinder(text)
    end
end

ns.On("DT_READY", function()
    frame:RestorePlacement()
    if not ns.settings.finderQualities then
        ns.settings.finderQualities = { [0] = true, true, true, true, true }
    end
    category = ns.settings.finderCategory or "all"
    openClass = ns.settings.finderOpenClass
    for _, button in pairs(qualityButtons) do
        button:Refresh()
    end
end)

local function redraw()
    if not frame:IsShown() then
        return
    end
    if view == "item" then
        droppers = ns.FindDroppers(selectedItem)
    end
    renderTree()
    renderMain()
end

-- Kills, looks at mobs and item info arriving can come many times a second; one redraw covers them all.
local REFRESH_DELAY = 0.5
local refreshPending = false
local function refresh()
    if refreshPending or not frame:IsShown() then
        return
    end
    refreshPending = true
    C_Timer.After(REFRESH_DELAY, function()
        refreshPending = false
        redraw()
    end)
end

ns.On("DT_DATA_CHANGED", refresh)
ns.On("DT_INFO_CHANGED", refresh)
ns.On("DT_SETTINGS_CHANGED", refresh)
ns.On("GET_ITEM_INFO_RECEIVED", refresh)
