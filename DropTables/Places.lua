local _, ns = ...

-- Where and at what level each mob was met: name and level range from target, mouseover and nameplates,
-- and per map the number of kills plus the kill spots on a GRID x GRID grid (the player's position at the kill).
local GRID = 50
local MAX_CELLS = 40

local placed = {} -- victim GUIDs already counted this session

local function mobInfo(npc)
    local info = ns.db.info[npc]
    if not info then
        info = { maps = {} }
        ns.db.info[npc] = info
    end
    return info
end

function ns.CellCenter(cell)
    return (math.floor(cell / GRID) + 0.5) / GRID, (cell % GRID + 0.5) / GRID
end

-- Returns the player's map and grid cell; the cell is nil where the map gives no position (instances).
local function playerSpot()
    local mapId = C_Map.GetBestMapForUnit("player")
    if not mapId or ns.IsSecret(mapId) then
        return nil
    end
    local position = C_Map.GetPlayerMapPosition(mapId, "player")
    if not position then
        return mapId
    end
    local x, y = position:GetXY()
    if ns.IsSecret(x) or ns.IsSecret(y) or not x or x <= 0 or x >= 1 or y <= 0 or y >= 1 then
        return mapId
    end
    return mapId, math.floor(x * GRID) * GRID + math.floor(y * GRID)
end

ns.On("PARTY_KILL", function(_, victim)
    local npc = ns.NpcFromGuid(victim)
    if not npc or placed[victim] then
        return
    end
    placed[victim] = true
    local mapId, cell = playerSpot()
    if not mapId then
        return
    end
    local info = mobInfo(npc)
    local place = info.maps[mapId]
    if not place then
        place = { kills = 0, cells = {} }
        info.maps[mapId] = place
    end
    place.kills = place.kills + 1
    if cell then
        local known = 0
        for _ in pairs(place.cells) do
            known = known + 1
        end
        if place.cells[cell] or known < MAX_CELLS then
            place.cells[cell] = (place.cells[cell] or 0) + 1
        end
    end
    ns.Fire("DT_INFO_CHANGED", npc)
end)

local function remember(unit)
    local npc = ns.UnitNpc(unit)
    if not npc then
        return
    end
    local name = UnitName(unit)
    if name and not ns.IsSecret(name) then
        ns.db.names[npc] = name
    end
    local level = UnitLevel(unit)
    if not level or ns.IsSecret(level) or level <= 0 then
        return
    end
    local info = mobInfo(npc)
    local changed = false
    if not info.minLevel or level < info.minLevel then
        info.minLevel = level
        changed = true
    end
    if not info.maxLevel or level > info.maxLevel then
        info.maxLevel = level
        changed = true
    end
    if changed then
        ns.Fire("DT_INFO_CHANGED", npc)
    end
end

ns.On("PLAYER_TARGET_CHANGED", function()
    remember("target")
end)

ns.On("UPDATE_MOUSEOVER_UNIT", function()
    remember("mouseover")
end)

ns.On("NAME_PLATE_UNIT_ADDED", function(unit)
    remember(unit)
end)
