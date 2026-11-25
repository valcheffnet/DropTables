local _, ns = ...

-- The rate sits under each icon, so the gap leaves room for "100%" between neighbours.
local SIZE, GAP = 26, 10
-- What skinning gives goes on a second row, below the first row's rates.
local SKIN_ROW_Y = -(SIZE + 20)
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local MONEY_ICON = "Interface\\Icons\\INV_Misc_Coin_01"

local strip = CreateFrame("Frame", "DropTablesStrip", UIParent)
strip:SetSize(SIZE, SIZE)
strip:SetMovable(true)
strip:SetClampedToScreen(true)
strip:Hide()

local buttons = {}
local skinButtons = {}
local currentNpc
local unlocked = false

-- Shown while the strip can be dragged, which is in Blizzard's Edit Mode or after /dt unlock.
local mover = CreateFrame("Frame", nil, strip)
mover:SetPoint("TOPLEFT", -6, 6)
mover:SetPoint("BOTTOMRIGHT", 6, -18)
mover:SetFrameLevel(strip:GetFrameLevel() + 10)
mover:EnableMouse(true)
mover:RegisterForDrag("LeftButton")
mover:Hide()
local moverTint = mover:CreateTexture(nil, "BACKGROUND")
moverTint:SetAllPoints()
moverTint:SetColorTexture(0.1, 0.45, 0.9, 0.35)
local moverLabel = mover:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
moverLabel:SetPoint("BOTTOM", mover, "TOP", 0, 2)
moverLabel:SetText("Forever Drop Tables")

-- Anchor offsets are in the strip's own scaled units, so they get divided by the scale, which keeps the top-left
-- corner in place when the icon size changes. stripPos holds that corner in UIParent units.
local function placeStrip()
    local scale = ns.settings.stripScale
    strip:SetScale(scale)
    strip:ClearAllPoints()
    local pos = ns.settings.stripPos
    if pos and #pos == 2 then
        strip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1] / scale, pos[2] / scale)
    elseif TargetFrame then
        strip:SetPoint("TOPLEFT", TargetFrame, "BOTTOMLEFT", 40 / scale, 4 / scale)
    else
        strip:SetPoint("TOP", UIParent, "CENTER", 0, -150 / scale)
    end
end

mover:SetScript("OnDragStart", function()
    strip:StartMoving()
end)

mover:SetScript("OnDragStop", function()
    strip:StopMovingOrSizing()
    local scale = strip:GetScale()
    ns.settings.stripPos = { strip:GetLeft() * scale, strip:GetTop() * scale }
    strip:SetUserPlaced(false)
    placeStrip()
end)

local function showEntryTooltip(button)
    local stats = button.stats
    if button.skin then
        local entry = button.entry
        GameTooltip:SetItemByID(entry.itemId)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Skinning chance", ns.FormatRate(entry.rate), 1, 0.82, 0, 1, 1, 1)
        if (entry.max or 1) > 1 or entry.avgQty > 1.05 then
            GameTooltip:AddDoubleLine("Per skin", ns.FormatStack(entry), 1, 0.82, 0, 1, 1, 1)
        end
        GameTooltip:AddLine(("Given %d times in %d skinned corpses"):format(entry.drops, stats.skinned), 0.7, 0.7, 0.7)
        if entry.scarce then
            GameTooltip:AddLine("The Bountiful Harvest perk gives more of it.", 0.7, 0.7, 0.7, true)
        end
        if stats.small then
            GameTooltip:AddLine(("Only %d skinned corpses so far, rates are rough."):format(stats.skinned),
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine("Click for the full table", 0.5, 0.5, 0.5)
        return
    elseif button.entry then
        local entry = button.entry
        GameTooltip:SetItemByID(entry.itemId)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Drop chance", ns.FormatRate(entry.rate), 1, 0.82, 0, 1, 1, 1)
        if (entry.max or 1) > 1 or entry.avgQty > 1.05 then
            GameTooltip:AddDoubleLine("Per drop", ns.FormatStack(entry), 1, 0.82, 0, 1, 1, 1)
        end
        GameTooltip:AddLine(("Dropped %d times in %d looted corpses"):format(entry.drops, stats.opened), 0.7, 0.7, 0.7)
    elseif button.money then
        local money = stats.money
        GameTooltip:SetText("Money")
        GameTooltip:AddDoubleLine("Drop chance", ns.FormatRate(money.rate), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Average", ns.CoinText(money.avg), 1, 0.82, 0, 1, 1, 1)
        if money.min then
            GameTooltip:AddDoubleLine("Range", ns.CoinText(money.min) .. " - " .. ns.CoinText(money.max), 1, 0.82, 0, 1, 1, 1)
        end
    else
        GameTooltip:SetText("Forever Drop Tables")
        if stats and #stats.list > 0 then
            local _, worldCount, lowCount = ns.VisibleEntries(stats)
            local reason
            if worldCount > 0 and lowCount > 0 then
                reason = "only world drops and items below your minimum quality so far"
            elseif worldCount > 0 then
                reason = "only world drops so far"
            else
                reason = "everything it dropped is below your minimum quality (see Options)"
            end
            GameTooltip:AddLine(("Killed %d times, %s."):format(stats.kills, reason), 1, 1, 1, true)
        elseif stats then
            local text = stats.opened > 0 and "nothing has dropped yet" or "nothing looted yet"
            GameTooltip:AddLine(("Killed %d times, %s."):format(stats.kills, text), 1, 1, 1, true)
        else
            GameTooltip:AddLine("No data for this mob yet. Kill and loot it to start its table.", 1, 1, 1, true)
        end
    end
    if stats and stats.small then
        GameTooltip:AddLine(("Only %d looted corpses so far, rates are rough."):format(stats.opened), 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine("Click for the full table", 0.5, 0.5, 0.5)
end

local function onEnter(self)
    if unlocked then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    showEntryTooltip(self)
    GameTooltip:Show()
end

local function onClick(self)
    if self.entry and ns.TryLinkItem(self.entry.itemId) then
        return
    end
    ns.ShowDetails(currentNpc)
end

-- A button of the first row, or of the skinning row with skin set.
local function getButton(index, skin)
    local list = skin and skinButtons or buttons
    local button = list[index]
    if button then
        return button
    end
    button = CreateFrame("Button", nil, strip)
    button:SetSize(SIZE, SIZE)
    button:SetPoint("TOPLEFT", (index - 1) * (SIZE + GAP), skin and SKIN_ROW_Y or 0)
    button.skin = skin
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.border = button:CreateTexture(nil, "OVERLAY")
    button.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    button.border:SetBlendMode("ADD")
    button.border:SetPoint("CENTER")
    button.border:SetSize(SIZE * 1.8, SIZE * 1.8)
    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetPoint("TOP", button, "BOTTOM", 0, -2)
    button:SetScript("OnEnter", onEnter)
    button:SetScript("OnLeave", GameTooltip_Hide)
    button:SetScript("OnClick", onClick)
    list[index] = button
    return button
end

local function setButton(index, stats, texture, quality, label, skin)
    local button = getButton(index, skin)
    button.stats = stats
    button.entry, button.money = nil, nil
    button.icon:SetTexture(texture)
    local r, g, b = ns.QualityRGB(quality)
    if r and quality >= 2 then
        button.border:SetVertexColor(r, g, b)
        button.border:Show()
    else
        button.border:Hide()
    end
    button.label:SetText(label or "")
    if stats and stats.small then
        button.label:SetTextColor(0.6, 0.6, 0.6)
    else
        button.label:SetTextColor(1, 1, 1)
    end
    button:Show()
    return button
end

local function fill(npc)
    local stats = npc and ns.GetStats(npc, "all")
    local used = 0
    local entries = stats and ns.VisibleEntries(stats) or {}
    if #entries > 0 then
        used = math.min(ns.settings.stripIcons, #entries)
        for i = 1, used do
            local entry = entries[i]
            if entry.money then
                setButton(i, stats, MONEY_ICON, nil, ns.FormatRate(entry.rate)).money = true
            else
                setButton(i, stats, ns.ItemIcon(entry.itemId), entry.quality, ns.FormatRate(entry.rate)).entry = entry
            end
        end
    else
        used = 1
        setButton(1, stats, UNKNOWN_ICON, nil, stats and tostring(stats.kills) or "")
    end
    return used
end

-- The skinning row: what skinning the mob gives, the most frequent first. Returns how many icons it shows.
local function fillSkins(npc)
    local skin = npc and ns.GetSkinStats(npc)
    local used = skin and math.min(ns.settings.stripIcons, #skin.list) or 0
    for i = 1, used do
        local entry = skin.list[i]
        setButton(i, skin, ns.ItemIcon(entry.itemId), entry.quality, ns.FormatRate(entry.rate), true).entry = entry
    end
    for i = used + 1, #skinButtons do
        skinButtons[i]:Hide()
    end
    return used
end

-- While unlocked the strip shows a full row of placeholders so its size is visible.
local function fillPreview()
    for i = 1, ns.settings.stripIcons do
        setButton(i, nil, UNKNOWN_ICON, nil, "12%")
    end
    return ns.settings.stripIcons
end

local function update()
    local npc = ns.settings and ns.settings.showStrip and ns.UnitMob("target")
    currentNpc = npc
    if not npc and not unlocked then
        strip:Hide()
        return
    end
    local used = unlocked and fillPreview() or fill(npc)
    for i = used + 1, #buttons do
        buttons[i]:Hide()
    end
    used = math.max(used, fillSkins(not unlocked and npc or nil))
    strip:SetWidth(used * (SIZE + GAP) - GAP)
    strip:Show()
end

local function setUnlocked(value)
    unlocked = value
    mover:SetShown(value)
    update()
end

function ns.UnlockStrip(value)
    setUnlocked(value)
    ns.Print(value and "Icons unlocked: drag the blue box, then /dt lock." or "Icons locked.")
end

function ns.ResetStripPosition()
    ns.settings.stripPos = nil
    placeStrip()
    ns.Print("Icon position reset to the target frame.")
end

local function applySettings()
    placeStrip()
    update()
end

ns.On("DT_READY", function()
    applySettings()
    EventRegistry:RegisterCallback("EditMode.Enter", function()
        setUnlocked(true)
    end, strip)
    EventRegistry:RegisterCallback("EditMode.Exit", function()
        setUnlocked(false)
    end, strip)
end)

ns.On("PLAYER_TARGET_CHANGED", update)
ns.On("DT_SETTINGS_CHANGED", applySettings)
ns.On("DT_DATA_CHANGED", function(npc)
    if npc == currentNpc then
        update()
    end
end)
