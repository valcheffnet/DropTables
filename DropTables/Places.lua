local _, ns = ...

-- Where and at what level each mob was met. Name and level range come from the target, mouseover and nameplates, and
-- each map keeps its number of kills plus the kill spots on a GRID x GRID grid (where the player stood at the kill).
local GRID = 50
ns.GRID = GRID
local MAX_CELLS = 40

local PLACED_TTL = 900
local placed = {} -- victim GUID -> when its kill was placed; kept a while against a second PARTY_KILL for it
-- Names and levels of mobs without any counts stay in this session only, because most of them never get killed
-- (critters, mobs passed on the road). They get saved along with the mob's first counts.
local seen = {}   -- npc -> { name, minLevel, maxLevel, maps = {} }

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

-- Returns the player's map and grid cell. The cell is nil where the map gives no position, as in instances.
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

local function hasCounts(npc)
    return ns.db.mobs[npc] or ns.db.skins[npc] or ns.db.info[npc] or ns.db.peers[npc]
end

-- Writes what was seen of the mob into the saved data and returns true when its level range changed.
local function save(npc, sight)
    if sight.name then
        ns.db.names[npc] = sight.name
    end
    local info = mobInfo(npc)
    local changed = false
    if sight.minLevel and (not info.minLevel or sight.minLevel < info.minLevel) then
        info.minLevel, changed = sight.minLevel, true
    end
    if sight.maxLevel and (not info.maxLevel or sight.maxLevel > info.maxLevel) then
        info.maxLevel, changed = sight.maxLevel, true
    end
    return changed
end

-- Name and level range of a mob seen this session that has no saved data, or nil.
function ns.SeenMob(npc)
    return seen[npc]
end

local function forgetOldKills(now)
    for guid, at in pairs(placed) do
        if now - at > PLACED_TTL then
            placed[guid] = nil
        end
    end
end

-- Puts one kill of the mob on the map the player stands on.
local function placeKill(npc)
    if seen[npc] then
        save(npc, seen[npc])
    end
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
end

ns.On("PARTY_KILL", function(_, victim)
    local npc = ns.NpcFromGuid(victim)
    if not npc or placed[victim] then
        return
    end
    local now = GetTime()
    forgetOldKills(now)
    placed[victim] = now
    placeKill(npc)
end)

-- A corpse counted without a kill, as in a dungeon, where the client hides which mob died.
ns.PlaceCorpse = placeKill

local function remember(unit)
    local npc = ns.UnitMob(unit)
    if not npc then
        return
    end
    local sight = seen[npc]
    if not sight then
        sight = { maps = {} }
        seen[npc] = sight
    end
    local name = UnitName(unit)
    if name and not ns.IsSecret(name) then
        sight.name = name
    end
    local level = UnitLevel(unit)
    if level and not ns.IsSecret(level) and level > 0 then
        sight.minLevel = math.min(sight.minLevel or level, level)
        sight.maxLevel = math.max(sight.maxLevel or level, level)
    end
    if hasCounts(npc) and save(npc, sight) then
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

-- Earlier versions saved the name and level of every creature seen, so the ones without any counts are dropped at
-- login.
ns.On("DT_READY", function()
    local db = ns.db
    for npc, info in pairs(db.info) do
        if not db.mobs[npc] and not db.skins[npc] and not db.peers[npc] and not next(info.maps or {}) then
            db.info[npc] = nil
        end
    end
    for npc in pairs(db.names) do
        if not db.mobs[npc] and not db.skins[npc] and not db.peers[npc] and not db.info[npc] then
            db.names[npc] = nil
        end
    end
end)
