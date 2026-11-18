local _, ns = ...

function ns.MapName(mapId)
    local info = mapId and C_Map.GetMapInfo(mapId)
    return info and info.name or ("Map " .. tostring(mapId))
end

-- Items seen in loot windows whose name contains the text (any case) or whose id is the text; all of them for
-- empty text. qualities, when given, is a set of the qualities to keep.
function ns.SearchItems(text, qualities)
    text = strtrim(text or ""):lower()
    local id = tonumber(text)
    local results = {}
    for itemId, meta in pairs(ns.db.items) do
        local name = ns.ItemName(itemId)
        local quality = meta.quality or C_Item.GetItemQualityByID(itemId) or 1
        if (text == "" or itemId == id or name:lower():find(text, 1, true))
            and (not qualities or qualities[quality]) then
            local _, _, _, _, _, classId, subclassId = C_Item.GetItemInfoInstant(itemId)
            table.insert(results, {
                itemId = itemId, name = name, quality = quality, classId = classId or 15, subclassId = subclassId or 0,
            })
        end
    end
    table.sort(results, function(a, b)
        return a.name < b.name
    end)
    return results
end

-- Item classes in the auction house order; anything else follows in id order.
local CLASS_ORDER = { 2, 4, 1, 3, 8, 0, 16, 7, 9, 17, 12, 15, 5, 6, 11, 13 }
local CLASS_RANK = {}
for rank, classId in ipairs(CLASS_ORDER) do
    CLASS_RANK[classId] = rank
end

local function className(classId)
    return C_Item.GetItemClassInfo(classId) or ("Class " .. classId)
end

local function subclassName(classId, subclassId)
    return C_Item.GetItemSubClassInfo(classId, subclassId) or ("Type " .. subclassId)
end

-- Groups items like the auction house: classes in its order, subclasses by name, items by name.
-- A class whose items all share one subclass has no subclass level (subs is nil, items are on the class).
function ns.BuildItemTree(items)
    local byClass = {}
    for _, item in ipairs(items) do
        local class = byClass[item.classId]
        if not class then
            class = { classId = item.classId, name = className(item.classId), count = 0, items = {}, bySub = {} }
            byClass[item.classId] = class
        end
        class.count = class.count + 1
        table.insert(class.items, item)
        local sub = class.bySub[item.subclassId]
        if not sub then
            sub = { subclassId = item.subclassId, name = subclassName(item.classId, item.subclassId), count = 0, items = {} }
            class.bySub[item.subclassId] = sub
        end
        sub.count = sub.count + 1
        table.insert(sub.items, item)
    end
    local tree = {}
    for _, class in pairs(byClass) do
        local subs = {}
        for _, sub in pairs(class.bySub) do
            table.insert(subs, sub)
        end
        if #subs > 1 then
            table.sort(subs, function(a, b)
                return a.name < b.name
            end)
            class.subs = subs
        end
        class.bySub = nil
        table.insert(tree, class)
    end
    table.sort(tree, function(a, b)
        local ra, rb = CLASS_RANK[a.classId] or 100 + a.classId, CLASS_RANK[b.classId] or 100 + b.classId
        return ra < rb
    end)
    return tree
end

-- The droppers of every item, built from one GetStats per mob. A mob's entries are rebuilt only after its counts or
-- info change, all of them after a settings change; the Loot Finder asks for hundreds of items per redraw.
local byNpc = {}      -- npc -> { [itemId] = dropper } from the mob's current chances
local dirty = {}      -- npcs whose entries are out of date
local allDirty = true
local index           -- itemId -> { dropper, ... }, nil while it needs rebuilding

-- One dropper per item in the mob's chances. The counts can hold an item while the chances leave it out (an install
-- far off the rest); such an item has no dropper here.
local function droppersOf(npc)
    local stats = ns.GetStats(npc, "all")
    local found = {}
    if not stats then
        return found
    end
    local info = ns.MobInfo(npc)
    local maps = {}
    for mapId, place in pairs(info and info.maps or {}) do
        table.insert(maps, { mapId = mapId, kills = place.kills })
    end
    table.sort(maps, function(a, b)
        return a.kills > b.kills
    end)
    local name, zone = ns.MobName(npc), maps[1] and ns.MapName(maps[1].mapId) or ""
    for _, entry in ipairs(stats.list) do
        if entry.itemId then
            found[entry.itemId] = {
                npc = npc,
                name = name,
                rate = entry.rate,
                drops = entry.drops,
                opened = stats.opened,
                kills = stats.kills,
                small = stats.small,
                minLevel = info and info.minLevel,
                maxLevel = info and info.maxLevel,
                maps = maps,
                zone = zone,
            }
        end
    end
    return found
end

local function currentIndex()
    if index and not allDirty and not next(dirty) then
        return index
    end
    if allDirty then
        byNpc = {}
        for npc in pairs(ns.KnownNpcs()) do
            byNpc[npc] = droppersOf(npc)
        end
    else
        local known = ns.KnownNpcs()
        for npc in pairs(dirty) do
            byNpc[npc] = known[npc] and droppersOf(npc) or nil
        end
    end
    allDirty, dirty, index = false, {}, {}
    for _, found in pairs(byNpc) do
        for itemId, dropper in pairs(found) do
            local list = index[itemId]
            if not list then
                list = {}
                index[itemId] = list
            end
            table.insert(list, dropper)
        end
    end
    return index
end

local function mobChanged(npc)
    if npc then
        dirty[npc] = true
    else
        allDirty = true
    end
end
ns.On("DT_DATA_CHANGED", mobChanged)
ns.On("DT_INFO_CHANGED", mobChanged)
ns.On("DT_SETTINGS_CHANGED", function()
    allDirty = true
end)

-- Every mob with recorded drops of the item, with its chance over all kills, level range and maps by kill count.
-- The list is new on every call; the droppers in it are shared and must not be changed.
function ns.FindDroppers(itemId)
    local results = {}
    for i, dropper in ipairs(currentIndex()[itemId] or {}) do
        results[i] = dropper
    end
    return results
end

-- One line per item for a category: how many mobs drop it and which one gives the best chance (on a tie the one with
-- more kills behind it), counting only mobs that pass the zone and level filters. With a filter set, items no listed mob drops are left out.
-- Also returns the maps of all droppers (before filtering), for the zone choice.
function ns.SummarizeItems(items, filters)
    filters = filters or {}
    local active = filters.mapId or filters.minLevel or filters.maxLevel
    local results, maps, seenMaps = {}, {}, {}
    for _, item in ipairs(items) do
        local droppers = ns.FindDroppers(item.itemId)
        for _, mapId in ipairs(ns.DropperMaps(droppers)) do
            if not seenMaps[mapId] then
                seenMaps[mapId] = true
                table.insert(maps, mapId)
            end
        end
        if active then
            droppers = ns.FilterDroppers(droppers, filters, "rate", true)
        end
        if #droppers > 0 or not active then
            local summary = { itemId = item.itemId, name = item.name, quality = item.quality, mobs = #droppers, rate = 0,
                best = "", kills = 0 }
            for _, dropper in ipairs(droppers) do
                if dropper.rate > summary.rate or dropper.rate == summary.rate and dropper.kills > summary.kills then
                    summary.rate, summary.best, summary.bestNpc = dropper.rate, dropper.name, dropper.npc
                    summary.kills, summary.small = dropper.kills, dropper.small
                end
            end
            table.insert(results, summary)
        end
    end
    table.sort(maps, function(a, b)
        return ns.MapName(a) < ns.MapName(b)
    end)
    return results, maps
end

-- Sorts by value(entry) in either direction; equal values fall back to entry[idKey] so the order is stable.
local function sortBy(list, value, descending, idKey)
    table.sort(list, function(a, b)
        local va, vb = value(a), value(b)
        if va == vb then
            return a[idKey] < b[idKey]
        end
        if descending then
            return va > vb
        end
        return va < vb
    end)
    return list
end

local SUMMARY_SORT = {
    name = function(s) return s.name end,
    mobs = function(s) return s.mobs end,
    best = function(s) return s.best end,
    rate = function(s) return s.rate end,
    kills = function(s) return s.kills end,
}

function ns.SortSummaries(summaries, sortKey, descending)
    return sortBy(summaries, SUMMARY_SORT[sortKey] or SUMMARY_SORT.name, descending, "itemId")
end

-- Maps the droppers were killed on, for the zone filter, sorted by name.
function ns.DropperMaps(droppers)
    local seen, maps = {}, {}
    for _, dropper in ipairs(droppers) do
        for _, map in ipairs(dropper.maps) do
            if not seen[map.mapId] then
                seen[map.mapId] = true
                table.insert(maps, map.mapId)
            end
        end
    end
    table.sort(maps, function(a, b)
        return ns.MapName(a) < ns.MapName(b)
    end)
    return maps
end

local function onMap(dropper, mapId)
    for _, map in ipairs(dropper.maps) do
        if map.mapId == mapId then
            return true
        end
    end
    return false
end

local SORT_VALUES = {
    name = function(d) return d.name end,
    level = function(d) return d.minLevel or 0 end,
    zone = function(d) return d.zone end,
    rate = function(d) return d.rate end,
    drops = function(d) return d.drops end,
}

-- filters: mapId, minLevel, maxLevel (all optional). A level filter leaves out mobs whose level is unknown.
function ns.FilterDroppers(droppers, filters, sortKey, descending)
    local results = {}
    for _, dropper in ipairs(droppers) do
        local keep = not filters.mapId or onMap(dropper, filters.mapId)
        if keep and filters.minLevel then
            keep = dropper.maxLevel ~= nil and dropper.maxLevel >= filters.minLevel
        end
        if keep and filters.maxLevel then
            keep = dropper.minLevel ~= nil and dropper.minLevel <= filters.maxLevel
        end
        if keep then
            table.insert(results, dropper)
        end
    end
    return sortBy(results, SORT_VALUES[sortKey] or SORT_VALUES.rate, descending, "npc")
end
