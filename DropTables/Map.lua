local _, ns = ...

-- Kill spots of one mob, the player's own and the shared database's, drawn on the world map as soft round spots that
-- get stronger where more kills happened.
-- The marks follow the player around the map, so every zone the mob was killed in shows its spots, and a line at the
-- top names the mob and its other zones. Closing the map ends the marking.
local GRID = ns.GRID

local overlay, banner
local pins = {}
local shownNpc

local function hidePins()
    for _, pin in ipairs(pins) do
        pin:Hide()
    end
end

local function otherZones(info, mapId)
    local zones = {}
    for otherId, place in pairs(info.maps) do
        if otherId ~= mapId then
            table.insert(zones, { name = ns.MapName(otherId), kills = place.kills })
        end
    end
    table.sort(zones, function(a, b)
        return a.kills > b.kills
    end)
    local names = {}
    for _, zone in ipairs(zones) do
        table.insert(names, zone.name)
    end
    return names
end

local function drawPins()
    hidePins()
    banner:Hide()
    if not shownNpc or not WorldMapFrame:IsShown() then
        return
    end
    local mapId = WorldMapFrame:GetMapID()
    local info = ns.MobInfo(shownNpc)
    local place = info and info.maps[mapId]

    local text = "|cffe8c46aForever Drop Tables:|r " .. ns.MobName(shownNpc)
    if place then
        text = text .. ("  |  %d kills here"):format(place.kills)
    end
    local others = info and otherZones(info, mapId) or {}
    if #others > 0 then
        text = text .. "  |  also in: " .. table.concat(others, ", ")
    end
    banner.text:SetText(text)
    banner:Show()
    if not place then
        return
    end

    local canvas = WorldMapFrame:GetCanvas()
    local width, height = canvas:GetSize()
    local most = 1
    for _, kills in pairs(place.cells) do
        most = math.max(most, kills)
    end
    local index = 0
    for cell, kills in pairs(place.cells) do
        index = index + 1
        local pin = pins[index]
        if not pin then
            pin = overlay:CreateTexture(nil, "OVERLAY")
            pin:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
            pins[index] = pin
        end
        local x, y = ns.CellCenter(cell)
        -- A round spot a bit larger than its grid cell, so neighbouring spots blend into one area.
        local size = math.min(width, height) / GRID * 1.6
        pin:SetVertexColor(1, 0.45, 0.1, 0.2 + 0.35 * kills / most)
        pin:SetSize(size, size)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", canvas, "TOPLEFT", x * width, -y * height)
        pin:Show()
    end
end

local function hookMap()
    if overlay then
        return
    end
    local canvas = WorldMapFrame:GetCanvas()
    overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel(canvas:GetFrameLevel() + 100)

    local container = WorldMapFrame.ScrollContainer or WorldMapFrame
    banner = CreateFrame("Frame", nil, container)
    banner:SetFrameLevel(container:GetFrameLevel() + 200)
    banner:SetPoint("TOPLEFT", 8, -8)
    banner:SetPoint("TOPRIGHT", -8, -8)
    banner:SetHeight(22)
    local shade = banner:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.55)
    banner.text = ns.Style.Text(banner, "body")
    banner.text:SetPoint("LEFT", 8, 0)
    banner.text:SetPoint("RIGHT", -8, 0)
    banner.text:SetJustifyH("LEFT")
    banner:Hide()

    hooksecurefunc(WorldMapFrame, "OnMapChanged", drawPins)
    WorldMapFrame:HookScript("OnHide", function()
        shownNpc = nil
        hidePins()
        banner:Hide()
    end)
    canvas:HookScript("OnSizeChanged", drawPins)
end

local function busiestCell(place)
    local best, bestKills
    for cell, kills in pairs(place.cells) do
        if not bestKills or kills > bestKills then
            best, bestKills = cell, kills
        end
    end
    return best
end

-- Opens the world map on the given map, marks the mob's kill spots and puts a waypoint on the busiest one.
function ns.ShowOnMap(npc, mapId)
    if not mapId then
        return
    end
    if InCombatLockdown() then
        ns.Print("The map can be opened after combat.")
        return
    end
    if not WorldMapFrame then
        C_AddOns.LoadAddOn("Blizzard_WorldMap")
    end
    hookMap()
    if not WorldMapFrame:IsShown() then
        ToggleWorldMap()
    end
    shownNpc = npc
    WorldMapFrame:SetMapID(mapId)
    drawPins()

    local info = ns.MobInfo(npc)
    local cell = info and info.maps[mapId] and busiestCell(info.maps[mapId])
    if cell and C_Map.CanSetUserWaypointOnMap(mapId) then
        local x, y = ns.CellCenter(cell)
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapId, x, y))
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
end
