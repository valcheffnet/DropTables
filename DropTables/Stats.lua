local _, ns = ...

-- Weapons, armor and recipes of any quality are treated as random world drops that any mob of the level can give,
-- unless a well-sampled mob drops one often enough to make it part of its own table.
local WORLD_DROP_CLASSES = { [2] = true, [4] = true, [9] = true }
local OWN_DROP_MIN_RATE = 0.2
-- Another install with more kills than this counts as this many: all its counts are scaled down by the same factor.
local PEER_CAP = 300
-- Installs with at least this many looted corpses of a mob are checked against each other; smaller ones are too
-- noisy to tell a liar from bad luck, so they are always counted.
local BIG_SOURCE = 30
-- The check needs this many big installs, so that the median says what most of them saw.
local MIN_BIG_SOURCES = 3
-- How wide the confidence interval of the outlier check is, in standard deviations.
local OUTLIER_Z = 3
local MONEY = "money"

local function mergeRange(into, from)
    if from.min and from.max then
        into.min = math.min(into.min or from.min, from.min)
        into.max = math.max(into.max or from.max, from.max)
    end
end

local function inMode(bucket, mode)
    return mode == "all" or (mode == "solo") == (bucket == 1)
end

local function round(n)
    return math.floor(n + 0.5)
end

-- Sums one install's buckets that fall in the mode, scaled by factor. Money is the entry MONEY, with copper as
-- its quantity. Returns nil when the install has no kills in the mode.
local function aggregate(buckets, mode, factor)
    local sum = { kills = 0, lootable = 0, opened = 0, entries = {} }
    local function add(key, drops, qty, from)
        local entry = sum.entries[key]
        if not entry then
            entry = { drops = 0, qty = 0 }
            sum.entries[key] = entry
        end
        entry.drops = entry.drops + drops * factor
        entry.qty = entry.qty + qty * factor
        mergeRange(entry, from)
    end
    for bucket, data in pairs(buckets) do
        -- A bucket put together from several messages can claim more drops than opened corpses; it waits.
        if inMode(bucket, mode) and ns.Wire.Complete(data) then
            sum.kills = sum.kills + data.kills * factor
            sum.lootable = sum.lootable + data.lootable * factor
            sum.opened = sum.opened + data.opened * factor
            if data.money.drops > 0 then
                add(MONEY, data.money.drops, data.money.copper, data.money)
            end
            for itemId, item in pairs(data.items) do
                add(itemId, item.drops, item.qty, item)
            end
        end
    end
    return sum.kills > 0 and sum or nil
end

local function median(values)
    local sorted = {}
    for i, value in ipairs(values) do
        sorted[i] = value
    end
    table.sort(sorted)
    local middle = math.floor(#sorted / 2)
    if #sorted % 2 == 1 then
        return sorted[middle + 1]
    end
    return (sorted[middle] + sorted[middle + 1]) / 2
end

-- True when a drop chance of p fits what an install saw (a share seen of its opened corpses): p lies within the
-- Wilson score interval at OUTLIER_Z. The interval widens for small samples and rare items, so noise is not taken
-- for lying.
local function plausible(seen, opened, p)
    local z2 = OUTLIER_Z * OUTLIER_Z
    local center = (seen + z2 / (2 * opened)) / (1 + z2 / opened)
    local half = OUTLIER_Z * math.sqrt(seen * (1 - seen) / opened + z2 / (4 * opened * opened)) / (1 + z2 / opened)
    -- At a share of 0 or 1 the interval ends exactly there; the tolerance keeps rounding from pushing p outside.
    return math.abs(p - center) <= half + 1e-9
end

local function dropShare(sum, key)
    local entry = sum.entries[key]
    return math.min(1, (entry and entry.drops or 0) / sum.opened)
end

-- The installs whose counts make one entry's chance: the player's own and every small install always, big installs
-- only when their share of drops fits the median of the big ones. Installs too far apart to tell which one is off
-- (none fits) all count.
local function usedFor(key, own, small, big)
    local used = { own }
    for _, sum in ipairs(small) do
        table.insert(used, sum)
    end
    if #big < MIN_BIG_SOURCES then
        for _, sum in ipairs(big) do
            table.insert(used, sum)
        end
        return used
    end
    local shares = {}
    for i, sum in ipairs(big) do
        shares[i] = dropShare(sum, key)
    end
    local middle = median(shares)
    local fitting = {}
    for i, sum in ipairs(big) do
        if plausible(shares[i], sum.opened, middle) then
            table.insert(fitting, sum)
        end
    end
    for _, sum in ipairs(#fitting > 0 and fitting or big) do
        table.insert(used, sum)
    end
    return used
end

-- How far apart two shares (seen out of n) are, in standard errors of their difference.
local function zScore(seen1, n1, seen2, n2)
    local p1, p2 = seen1 / n1, seen2 / n2
    local pooled = (seen1 + seen2) / (n1 + n2)
    local se = math.sqrt(pooled * (1 - pooled) * (1 / n1 + 1 / n2))
    if se == 0 then
        return p1 == p2 and 0 or math.huge
    end
    return math.abs(p1 - p2) / se
end

-- The installs whose kills say how many corpses have loot. Empty kills lower every chance of the mob, so an install
-- claiming hundreds of them must not pull all chances down, even when it is the only other one. The install whose
-- share of lootable corpses is furthest from all the others together goes out, one at a time, until the rest fit.
-- The player's own kills and installs with fewer than BIG_SOURCE kills always count.
local function lootableSources(all)
    local used = {}
    for _, sum in ipairs(all) do
        table.insert(used, sum)
    end
    while true do
        local kills, lootable = 0, 0
        for _, sum in ipairs(used) do
            kills, lootable = kills + sum.kills, lootable + sum.lootable
        end
        local worst, worstZ = nil, OUTLIER_Z
        for i, sum in ipairs(used) do
            local restKills = kills - sum.kills
            if not sum.own and sum.kills >= BIG_SOURCE and restKills > 0 then
                local z = zScore(sum.lootable, sum.kills, lootable - sum.lootable, restKills)
                if z > worstZ then
                    worst, worstZ = i, z
                end
            end
        end
        if not worst then
            return used
        end
        table.remove(used, worst)
    end
end

-- One chance from the counts of several installs added together: the share of kills with a lootable corpse times
-- drops / opened. Kills that leave an empty corpse lower every rate, while corpses nobody opened do not.
local function pooledRate(key, used, lootableShare)
    local opened, drops = 0, 0
    for _, sum in ipairs(used) do
        opened = opened + sum.opened
        local entry = sum.entries[key]
        drops = drops + (entry and entry.drops or 0)
    end
    if opened == 0 then
        return 0, 0
    end
    return lootableShare * drops / opened, opened
end

-- The list entry of an item or of money, with drop counts, stack sizes and ranges summed over the given installs.
local function newEntry(key, rate, sums, opened)
    local merged = { drops = 0, qty = 0 }
    for _, sum in ipairs(sums) do
        local entry = sum.entries[key]
        if entry then
            merged.drops = merged.drops + entry.drops
            merged.qty = merged.qty + entry.qty
            mergeRange(merged, entry)
        end
    end
    if merged.drops == 0 then
        return nil
    end
    if key == MONEY then
        -- Money is one more entry of the list (money = true, no itemId), so it is sorted by chance like any item.
        return { money = true, rate = rate, avg = merged.qty / merged.drops, min = merged.min, max = merged.max }
    end
    local meta = ns.db.items[key]
    local classId = select(6, C_Item.GetItemInfoInstant(key))
    return {
        itemId = key,
        rate = rate,
        drops = math.max(1, round(merged.drops)),
        avgQty = merged.qty / merged.drops,
        min = merged.min,
        max = merged.max,
        quality = meta and meta.quality or C_Item.GetItemQualityByID(key),
        world = WORLD_DROP_CLASSES[classId] == true and not (opened >= ns.SMALL_SAMPLE and rate >= OWN_DROP_MIN_RATE),
    }
end

-- Drop rates for one mob. mode is "all", "solo" or "group".
-- Each chance comes from the player's counts and other players' counts added together (see usedFor and
-- lootableSources), so every kill and every message moves it at once. Each other install is scaled down to PEER_CAP
-- kills; scaling leaves fractions, so the totals on screen are rounded. The kill totals leave out installs whose
-- empty kills do not fit the rest.
local function computeStats(npc, mode)
    local own = ns.db.mobs[npc] and aggregate(ns.db.mobs[npc], mode, 1) or nil
    if own then
        own.own = true
    end
    local peers = {}
    if not ns.settings.onlyMine then
        for _, peer in pairs(ns.db.peers[npc] or {}) do
            local kills = ns.SumBuckets(peer.buckets, "kills")
            local sum = aggregate(peer.buckets, mode, kills > PEER_CAP and PEER_CAP / kills or 1)
            if sum then
                table.insert(peers, sum)
            end
        end
    end
    if not own and #peers == 0 then
        return nil
    end
    local all = { own }
    for _, sum in ipairs(peers) do
        table.insert(all, sum)
    end
    local opened, keys = 0, {}
    for _, sum in ipairs(all) do
        opened = opened + sum.opened
        for key in pairs(sum.entries) do
            keys[key] = true
        end
    end
    local kills, lootable = 0, 0
    for _, sum in ipairs(lootableSources(all)) do
        kills, lootable = kills + sum.kills, lootable + sum.lootable
    end
    local lootableShare = lootable / kills
    local stats = {
        npc = npc,
        kills = round(kills),
        opened = round(opened),
        empty = round(kills - lootable),
        ownKills = own and own.kills or 0,
        sources = #peers,
        small = round(opened) < ns.SMALL_SAMPLE,
        list = {},
    }
    local small, big = {}, {}
    for _, sum in ipairs(peers) do
        table.insert(sum.opened >= BIG_SOURCE and big or small, sum)
    end
    for key in pairs(keys) do
        local used = usedFor(key, own, small, big)
        local rate, usedOpened = pooledRate(key, used, lootableShare)
        if rate > 0 then
            local entry = newEntry(key, rate, used, usedOpened)
            if entry then
                table.insert(stats.list, entry)
                if entry.money then
                    stats.money = entry
                end
            end
        end
    end
    table.sort(stats.list, function(a, b)
        if a.rate ~= b.rate then
            return a.rate > b.rate
        end
        return (a.itemId or 0) < (b.itemId or 0)
    end)
    return stats
end

-- Stats are kept per mob and mode until something they come from changes: the mob's counts (own or other players'),
-- the settings, or item info arriving (the quality of an entry). The tooltip, the icons, the details window and the
-- Loot Finder ask for the same mob again and again. Callers only read what they get.
local cache = {}  -- npc -> { [mode] = stats or false }

local function forget(npc)
    cache[npc] = nil
end
ns.On("DT_DATA_CHANGED", forget)
ns.On("DT_COUNTS_CHANGED", forget)
ns.On("DT_SETTINGS_CHANGED", function()
    cache = {}
end)
ns.On("GET_ITEM_INFO_RECEIVED", function()
    cache = {}
end)

function ns.GetStats(npc, mode)
    if not npc then
        return nil
    end
    local byMode = cache[npc]
    if not byMode then
        byMode = {}
        cache[npc] = byMode
    end
    local stats = byMode[mode]
    if stats == nil then
        stats = computeStats(npc, mode) or false
        byMode[mode] = stats
    end
    return stats or nil
end

-- Entries for the icons and the mob tooltip, plus how many world drops and how many items below the minimum
-- quality were left out of them. Money always stays.
function ns.VisibleEntries(stats)
    local entries, worldCount, lowCount = {}, 0, 0
    for _, entry in ipairs(stats.list) do
        if entry.world and ns.settings.collapseWorldDrops then
            worldCount = worldCount + 1
        elseif entry.money or (entry.quality or 0) >= ns.settings.minQuality then
            table.insert(entries, entry)
        else
            lowCount = lowCount + 1
        end
    end
    return entries, worldCount, lowCount
end

function ns.MobName(npc)
    local sight = ns.SeenMob(npc)
    return ns.db.names[npc] or (sight and sight.name) or ("NPC " .. npc)
end

-- Every mob with counts, the player's own and, unless only those are wanted, other players'.
function ns.KnownNpcs()
    local npcs = {}
    for npc in pairs(ns.db.mobs) do
        npcs[npc] = true
    end
    if not ns.settings.onlyMine then
        for npc in pairs(ns.db.peers) do
            npcs[npc] = true
        end
    end
    return npcs
end

-- Level range and kills per map: the player's own records, completed by what other players sent.
-- Kill spots (cells) come only from the player's own kills.
function ns.MobInfo(npc)
    local own = ns.db.info[npc] or ns.SeenMob(npc)
    local peers = not ns.settings.onlyMine and ns.db.peers[npc]
    if not peers or not next(peers) then
        return own
    end
    local info = { maps = {} }
    local function addLevels(minLevel, maxLevel)
        if minLevel then
            info.minLevel = math.min(info.minLevel or minLevel, minLevel)
            info.maxLevel = math.max(info.maxLevel or minLevel, maxLevel or minLevel)
        end
    end
    local function addKills(mapId, kills, cells)
        local place = info.maps[mapId]
        if not place then
            place = { kills = 0, cells = cells or {} }
            info.maps[mapId] = place
        end
        place.kills = place.kills + kills
    end
    if own then
        addLevels(own.minLevel, own.maxLevel)
        for mapId, place in pairs(own.maps) do
            addKills(mapId, place.kills, place.cells)
        end
    end
    for _, peer in pairs(peers) do
        addLevels(peer.minLevel, peer.maxLevel)
        for mapId, kills in pairs(peer.maps) do
            addKills(mapId, kills)
        end
    end
    return info
end
