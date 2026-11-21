local _, ns = ...

function ns.MapName(mapId)
    local info = mapId and C_Map.GetMapInfo(mapId)
    return info and info.name or ("Map " .. tostring(mapId))
end

local currentIndex, currentSkinIndex

-- Items seen in loot windows whose name contains the text (in any case) or whose id is the text, or all of them when
-- the text is empty. qualities, when given, is a set of the qualities to keep. Items that only ever came from skinning
-- are left to SkinItems.
function ns.SearchItems(text, qualities)
    text = strtrim(text or ""):lower()
    local id = tonumber(text)
    local results = {}
    local looted, skinnedOnly = currentIndex(), currentSkinIndex()
    for itemId, meta in pairs(ns.db.items) do
        local name = ns.ItemName(itemId)
        local quality = meta.quality or C_Item.GetItemQualityByID(itemId) or 1
        if (looted[itemId] or not skinnedOnly[itemId])
            and (text == "" or itemId == id or name:lower():find(text, 1, true))
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

-- Item classes in the auction house order, with anything else after them in id order.
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

-- Groups items the way the auction house does, classes in its order and subclasses and items by name. A class whose
-- items all share one subclass gets no subclass level (subs is nil and the items sit on the class).
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

-- The droppers of every item, built from one GetStats per mob. A mob's entries are only rebuilt after its counts or
-- info change, and all of them after a settings change, because the Loot Finder asks for hundreds of items per redraw.
local byNpc = {}      -- npc -> { [itemId] = dropper } from the mob's current chances
local skinsByNpc = {} -- npc -> { [itemId] = dropper } from what skinning the mob gives
local mobs = {}       -- npc -> the mob for the mob search, nil when it has no chances of either kind
local dirty = {}      -- npcs whose entries are out of date
local allDirty = true
local index           -- itemId -> { dropper, ... }, nil while it needs rebuilding
local skinIndex       -- the same for skinning

-- One dropper per item in the mob's chances. The counts can hold an item that the chances leave out, when it came
-- from an install far off the rest, and such an item gets no dropper here.
local function placesOf(npc)
    local info = ns.MobInfo(npc)
    local maps, spots = {}, false
    for mapId, place in pairs(info and info.maps or {}) do
        table.insert(maps, { mapId = mapId, kills = place.kills })
        spots = spots or next(place.cells) ~= nil
    end
    table.sort(maps, function(a, b)
        return a.kills > b.kills
    end)
    return info, maps, spots, maps[1] and ns.MapName(maps[1].mapId) or ""
end

-- One skinner per item that skinning the mob gives. Its kills are the skinned corpses, so the rules on how many kills
-- a mob needs work the same for both.
local function skinnersOf(npc)
    local stats = ns.GetSkinStats(npc)
    local found = {}
    if not stats then
        return found
    end
    local info, maps, spots, zone = placesOf(npc)
    local name = ns.MobName(npc)
    for _, entry in ipairs(stats.list) do
        found[entry.itemId] = {
            npc = npc,
            name = name,
            rate = entry.rate,
            drops = entry.drops,
            opened = stats.skinned,
            kills = stats.skinned,
            small = stats.small,
            scarce = entry.scarce,
            minLevel = info and info.minLevel,
            maxLevel = info and info.maxLevel,
            skill = ns.SkinningSkill(info and info.minLevel),
            skin = true,
            maps = maps,
            spots = spots,
            zone = zone,
        }
    end
    return found
end

-- The mob itself for the mob search, in the shape of a dropper without an item: its kills are the most of its looted
-- and its skinned corpses.
local function mobOf(npc)
    local stats, skin = ns.GetStats(npc, "all"), ns.GetSkinStats(npc)
    if not stats and not skin then
        return nil
    end
    local info, maps, spots, zone = placesOf(npc)
    return {
        npc = npc,
        name = ns.MobName(npc),
        kills = math.max(stats and stats.kills or 0, skin and skin.skinned or 0),
        minLevel = info and info.minLevel,
        maxLevel = info and info.maxLevel,
        maps = maps,
        spots = spots,
        zone = zone,
    }
end

local function droppersOf(npc)
    local stats = ns.GetStats(npc, "all")
    local found = {}
    if not stats then
        return found
    end
    local info, maps, spots, zone = placesOf(npc)
    local name = ns.MobName(npc)
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
                spots = spots,
                zone = zone,
            }
        end
    end
    return found
end

-- What a dropper's mob brings in an hour: its loot, or for a skinner what skinning it brings.
function ns.MobGoldPerHour(dropper)
    return dropper.skin and ns.SkinGoldPerHour(dropper.npc) or ns.GoldPerHour(dropper.npc)
end

-- itemId -> { dropper, ... } from npc -> { [itemId] = dropper }.
local function byItem(perNpc)
    local result = {}
    for _, found in pairs(perNpc) do
        for itemId, dropper in pairs(found) do
            local list = result[itemId]
            if not list then
                list = {}
                result[itemId] = list
            end
            table.insert(list, dropper)
        end
    end
    return result
end

function currentIndex()
    if index and not allDirty and not next(dirty) then
        return index
    end
    if allDirty then
        byNpc, skinsByNpc, mobs = {}, {}, {}
        for npc in pairs(ns.KnownNpcs()) do
            byNpc[npc] = droppersOf(npc)
            skinsByNpc[npc] = skinnersOf(npc)
            mobs[npc] = mobOf(npc)
        end
    else
        local known = ns.KnownNpcs()
        for npc in pairs(dirty) do
            byNpc[npc] = known[npc] and droppersOf(npc) or nil
            skinsByNpc[npc] = known[npc] and skinnersOf(npc) or nil
            mobs[npc] = known[npc] and mobOf(npc) or nil
        end
    end
    allDirty, dirty = false, {}
    index, skinIndex = byItem(byNpc), byItem(skinsByNpc)
    return index
end

function currentSkinIndex()
    currentIndex()
    return skinIndex
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

-- Every mob with recorded drops of the item, with its chance over all kills, its level range and its maps by kill
-- count. The list is new on every call, but the droppers in it are shared, so don't change them.
function ns.FindDroppers(itemId)
    local results = {}
    for i, dropper in ipairs(currentIndex()[itemId] or {}) do
        results[i] = dropper
    end
    return results
end

-- Every mob whose skinned corpses gave the item, with its chance per skinned corpse and the Skinning skill its lowest
-- level needs, in the same shape as FindDroppers.
function ns.FindSkinners(itemId)
    local results = {}
    for i, skinner in ipairs(currentSkinIndex()[itemId] or {}) do
        results[i] = skinner
    end
    return results
end

-- Mobs whose name contains the text (in any case) or whose id is the text, or all of them when the text is empty, by
-- name. Like FindDroppers, the list is new but the mobs in it are shared.
function ns.SearchMobs(text)
    text = strtrim(text or ""):lower()
    local id = tonumber(text)
    currentIndex()
    local results = {}
    for npc, mob in pairs(mobs) do
        if text == "" or npc == id or mob.name:lower():find(text, 1, true) then
            table.insert(results, mob)
        end
    end
    table.sort(results, function(a, b)
        if a.name == b.name then
            return a.npc < b.npc
        end
        return a.name < b.name
    end)
    return results
end

-- A mob needs this many kills to be an item's best mob, unless no mob that drops it has that many.
local BEST_MIN_KILLS = 3

-- The dropper that brings the most gold an hour, and among mobs worth the same (without any prices, say) the one with
-- the best chance and then the most kills behind it. One or two lucky kills say little, so mobs with fewer than
-- BEST_MIN_KILLS kills only count when no other mob drops the item.
function ns.BestDropper(droppers)
    local best, bestFew
    for _, dropper in ipairs(droppers) do
        local gold = ns.GoldPerHour(dropper.npc)
        local better = function(current)
            if not current then
                return true
            end
            local currentGold = ns.GoldPerHour(current.npc)
            if gold ~= currentGold then
                return gold > currentGold
            end
            return dropper.rate > current.rate or dropper.rate == current.rate and dropper.kills > current.kills
        end
        if dropper.kills >= BEST_MIN_KILLS then
            if better(best) then
                best = dropper
            end
        elseif better(bestFew) then
            bestFew = dropper
        end
    end
    return best or bestFew
end

-- The skinner with the lowest level, where the item can be had soonest (on a tie, the better chance, then more skinned
-- corpses). Mobs skinned fewer than BEST_MIN_KILLS times only count when no other mob gives the item, and mobs of
-- unknown level come last.
function ns.LowestSkinner(skinners)
    local best, bestFew
    for _, skinner in ipairs(skinners) do
        local level = skinner.minLevel or math.huge
        local better = function(current)
            if not current then
                return true
            end
            local currentLevel = current.minLevel or math.huge
            if level ~= currentLevel then
                return level < currentLevel
            elseif skinner.rate ~= current.rate then
                return skinner.rate > current.rate
            end
            return skinner.kills > current.kills
        end
        if skinner.kills >= BEST_MIN_KILLS then
            if better(best) then
                best = skinner
            end
        elseif better(bestFew) then
            bestFew = skinner
        end
    end
    return best or bestFew
end

-- One line per item for a category, saying how many mobs give it and which one is the best of them, as pick chooses
-- it. Only mobs that pass the zone and level filters count, and with a filter set, items none of those mobs give are
-- left out. Also returns the maps of all the mobs before filtering, for the zone choice.
local function summarize(items, filters, find, pick)
    filters = filters or {}
    local active = filters.mapId or filters.minLevel or filters.maxLevel
    local results, maps, seenMaps = {}, {}, {}
    for _, item in ipairs(items) do
        local droppers = find(item.itemId)
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
            local best = pick(droppers)
            if best then
                summary.rate, summary.best, summary.bestNpc = best.rate, best.name, best.npc
                summary.kills, summary.small = best.kills, best.small
                summary.minLevel, summary.maxLevel = best.minLevel, best.maxLevel
                summary.gph = ns.MobGoldPerHour(best)
            end
            table.insert(results, summary)
        end
    end
    table.sort(maps, function(a, b)
        return ns.MapName(a) < ns.MapName(b)
    end)
    return results, maps
end

-- The loot items of a category, with their best mob (see ns.BestDropper).
function ns.SummarizeItems(items, filters)
    return summarize(items, filters, ns.FindDroppers, ns.BestDropper)
end

-- The skinning items, with the lowest mob that gives each (see ns.LowestSkinner).
function ns.SummarizeSkinItems(items, filters)
    return summarize(items, filters, ns.FindSkinners, ns.LowestSkinner)
end

-- Items that skinning gave, filtered like SearchItems. They come from every mob anyone skinned, the shared database
-- included, so the list doesn't wait for the player to skin something first.
function ns.SkinItems(text, qualities)
    text = strtrim(text or ""):lower()
    local id = tonumber(text)
    local results = {}
    for itemId in pairs(currentSkinIndex()) do
        local name = ns.ItemName(itemId)
        local meta = ns.db.items[itemId]
        local quality = meta and meta.quality or C_Item.GetItemQualityByID(itemId) or 1
        if (text == "" or itemId == id or name:lower():find(text, 1, true))
            and (not qualities or qualities[quality]) then
            table.insert(results, { itemId = itemId, name = name, quality = quality })
        end
    end
    table.sort(results, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.itemId < b.itemId
    end)
    return results
end

-- Sorts by value(entry) in either direction, falling back to entry[idKey] on equal values so the order stays stable.
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
    level = function(s) return s.minLevel or math.huge end,
    gph = function(s) return s.gph or 0 end,
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
    skill = function(d) return d.minLevel or 0 end,
    zone = function(d) return d.zone end,
    rate = function(d) return d.rate end,
    drops = function(d) return d.drops end,
    kills = function(d) return d.kills or 0 end,
    gph = function(d) return ns.MobGoldPerHour(d) end,
}

-- filters can hold mapId, minLevel and maxLevel, all optional. A level filter leaves out mobs whose level is unknown.
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
