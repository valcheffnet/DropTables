local _, ns = ...

-- Weapons, armor and recipes of any quality are treated as random world drops that any mob of the level can give,
-- unless a well-sampled mob drops one often enough to make it part of its own table.
local WORLD_DROP_CLASSES = { [2] = true, [4] = true, [9] = true }
-- The Waylaid Crates of crafting materials drop from any mob of their level and are always world drops.
local WORLD_DROP_ITEMS = {}
for itemId = 248682, 248713 do
    if itemId ~= 248700 and itemId ~= 248701 then
        WORLD_DROP_ITEMS[itemId] = true
    end
end
-- Quest items, which the addon never records. Other sources can still carry them, so they stay out of every table.
local QUEST_CLASS = 12
local OWN_DROP_MIN_RATE = 0.2
-- Another install with more kills than this counts as this many, with all its counts scaled down by the same factor.
local PEER_CAP = 300
-- Installs with at least this many looted corpses of a mob are checked against each other. Smaller ones are too noisy
-- to tell a liar from bad luck, so they always count.
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

-- Sums one install's buckets that fall in the mode, scaled by factor. Money goes in as the entry MONEY with copper as
-- its quantity. Returns nil when the install has no kills in the mode.
-- shares, when given, is bucket -> the part of that bucket to count (see newShares).
local function aggregate(buckets, mode, factor, shares)
    local sum = { kills = 0, lootable = 0, opened = 0, entries = {} }
    local function add(key, drops, qty, from, f)
        local entry = sum.entries[key]
        if not entry then
            entry = { drops = 0, qty = 0 }
            sum.entries[key] = entry
        end
        entry.drops = entry.drops + drops * f
        entry.qty = entry.qty + qty * f
        mergeRange(entry, from)
    end
    for bucket, data in pairs(buckets) do
        -- A bucket put together from several messages can claim more drops than opened corpses, so it waits.
        if inMode(bucket, mode) and ns.Wire.Complete(data) then
            local f = factor * (shares and shares[bucket] or 1)
            sum.kills = sum.kills + data.kills * f
            sum.lootable = sum.lootable + data.lootable * f
            sum.opened = sum.opened + data.opened * f
            if data.money.drops > 0 then
                add(MONEY, data.money.drops, data.money.copper, data.money, f)
            end
            for itemId, item in pairs(data.items) do
                add(itemId, item.drops, item.qty, item, f)
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

-- True when a drop chance of p fits what an install saw (seen is its share of opened corpses), meaning p lies within
-- the Wilson score interval at OUTLIER_Z. The interval widens for small samples and rare items, so plain noise doesn't
-- get taken for lying.
local function plausible(seen, opened, p)
    local z2 = OUTLIER_Z * OUTLIER_Z
    local center = (seen + z2 / (2 * opened)) / (1 + z2 / opened)
    local half = OUTLIER_Z * math.sqrt(seen * (1 - seen) / opened + z2 / (4 * opened * opened)) / (1 + z2 / opened)
    -- At a share of 0 or 1 the interval ends exactly there, and the tolerance keeps rounding from pushing p outside.
    return math.abs(p - center) <= half + 1e-9
end

local function dropShare(sum, key)
    local entry = sum.entries[key]
    return math.min(1, (entry and entry.drops or 0) / sum.opened)
end

-- The counts that make up one entry's chance. The player's own, the shared database and every small install always
-- go in, and big installs only when their share of drops fits the median of the big ones. If they're all too far
-- apart to tell which one is off, so that none fits, they all count.
local function usedFor(key, always, small, big)
    local used = {}
    for _, sum in ipairs(always) do
        table.insert(used, sum)
    end
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

-- The installs whose kills decide how many corpses have loot. Empty kills lower every chance of the mob, so an install
-- claiming hundreds of them mustn't drag all the chances down, even when it's the only other one. We drop the install
-- whose share of lootable corpses is furthest from all the others together, one at a time, until the rest fit. The
-- player's own kills, the shared database and installs with fewer than BIG_SOURCE kills always count.
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
            if sum.kind == "peer" and sum.kills >= BIG_SOURCE and restKills > 0 then
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

-- One chance from the counts of several installs added together, worked out as the share of kills with a lootable
-- corpse times drops / opened. Kills that leave an empty corpse lower every rate, while corpses nobody opened don't.
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
    local classId = select(6, C_Item.GetItemInfoInstant(key))
    if classId == QUEST_CLASS then
        return nil
    end
    local meta = ns.db.items[key]
    return {
        itemId = key,
        rate = rate,
        drops = math.max(1, round(merged.drops)),
        avgQty = merged.qty / merged.drops,
        min = merged.min,
        max = merged.max,
        quality = meta and meta.quality or ns.ItemQuality(key),
        world = WORLD_DROP_ITEMS[key]
            or WORLD_DROP_CLASSES[classId] == true and not (opened >= ns.SMALL_SAMPLE and rate >= OWN_DROP_MIN_RATE),
    }
end

-- The part of each bucket of an install's counts that the shared database doesn't hold yet, or nil when it holds none
-- of them. The database lists the installs it was built from with their kills at the time: a number when they were all
-- solo, or the kills of each bucket. Counts only grow, so whatever came after that is the new part, bucket by bucket,
-- so that new group kills don't count old solo kills again.
local function newShares(shared, origin, buckets)
    local before = shared and shared.from[origin]
    if not before then
        return nil
    end
    if type(before) == "number" then
        before = { [1] = before }
    end
    local shares = {}
    for bucket, data in pairs(buckets) do
        local old = before[bucket] or 0
        shares[bucket] = data.kills > old and (data.kills - old) / data.kills or 0
    end
    return shares
end

-- The kills the shared database lists for an install, over all buckets.
function ns.KnownKills(shared, origin)
    local before = shared and shared.from[origin]
    if type(before) == "table" then
        local kills = 0
        for _, k in pairs(before) do
            kills = kills + k
        end
        return kills
    end
    return before
end

-- Drop rates for one mob. mode is "all", "solo" or "group".
-- Each chance comes from the player's counts, other players' counts and the shared database added together (see
-- usedFor and lootableSources), so every kill and every message moves it right away. Other installs are scaled down
-- to PEER_CAP kills, which leaves fractions, so the totals on screen are rounded. The kill totals leave out installs
-- whose empty kills don't fit the rest.
local function computeStats(npc, mode)
    local shared = not ns.settings.onlyMine and ns.shared[npc] or nil
    local ownBuckets = ns.db.mobs[npc]
    local ownTotal = ownBuckets and aggregate(ownBuckets, mode, 1) or nil
    local own = ownBuckets and aggregate(ownBuckets, mode, 1, newShares(shared, ns.db.installId, ownBuckets)) or nil
    local always, peers = {}, {}
    if own then
        own.kind = "own"
        table.insert(always, own)
    end
    local sharedSum = shared and aggregate(shared.buckets, mode, 1) or nil
    if sharedSum then
        sharedSum.kind = "shared"
        table.insert(always, sharedSum)
    end
    if not ns.settings.onlyMine then
        for origin, peer in pairs(ns.db.peers[npc] or {}) do
            local kills = ns.SumBuckets(peer.buckets, "kills")
            local factor = kills > PEER_CAP and PEER_CAP / kills or 1
            local sum = aggregate(peer.buckets, mode, factor, newShares(shared, origin, peer.buckets))
            if sum then
                sum.kind = "peer"
                table.insert(peers, sum)
            end
        end
    end
    if not ownTotal and not sharedSum and #peers == 0 then
        return nil
    end
    local all = {}
    for _, sum in ipairs(always) do
        table.insert(all, sum)
    end
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
    local kills, lootable, byKind = 0, 0, { own = 0, shared = 0, peer = 0 }
    for _, sum in ipairs(lootableSources(all)) do
        kills, lootable = kills + sum.kills, lootable + sum.lootable
        byKind[sum.kind] = byKind[sum.kind] + sum.kills
    end
    local lootableShare = kills > 0 and lootable / kills or 0
    local stats = {
        npc = npc,
        kills = round(kills),
        opened = round(opened),
        empty = round(kills - lootable),
        ownKills = ownTotal and round(ownTotal.kills) or 0,
        ownCounted = round(byKind.own),
        peerKills = round(byKind.peer),
        sharedKills = round(byKind.shared),
        sources = #peers,
        small = round(opened) < ns.SMALL_SAMPLE,
        list = {},
    }
    local small, big = {}, {}
    for _, sum in ipairs(peers) do
        table.insert(sum.opened >= BIG_SOURCE and big or small, sum)
    end
    for key in pairs(keys) do
        local used = usedFor(key, always, small, big)
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

-- Pristine Leather, Pristine Hide and Pristine Scale. The Legacy perk Bountiful Harvest gives up to twice as many of
-- them, so installs see different chances for them and none of them is left out for it.
ns.SCARCE_SKINS = { [249427] = true, [249428] = true, [249429] = true }

-- One install's skinning counts in the shape of aggregate's sums, with the skinned corpses as the opened ones.
local function skinSum(skins, factor)
    if not skins or (skins.skinned or 0) == 0 then
        return nil
    end
    local sum = { kills = 0, lootable = 0, opened = skins.skinned * factor, entries = {} }
    for itemId, item in pairs(skins.items) do
        -- Counts put together from several messages can claim more drops than skinned corpses, so they wait.
        if item.drops > skins.skinned then
            return nil
        end
        local entry = { drops = item.drops * factor, qty = item.qty * factor }
        mergeRange(entry, item)
        sum.entries[itemId] = entry
    end
    return sum
end

-- The part of an install's skinning counts the shared database doesn't hold yet, like newShares for kills.
local function newSkinShare(shared, origin, skins)
    local before = shared and shared.skins and shared.skins.from[origin]
    if not before then
        return 1
    end
    return skins.skinned > before and (skins.skinned - before) / skins.skinned or 0
end

-- What skinning a mob's corpse gives: per item the share of skinned corpses it came from. Every skinned corpse gives
-- something, so there is no empty share as with loot, and the group plays no part. Other installs count as at most
-- PEER_CAP skinned corpses, and a big install whose share of an item doesn't fit the others is left out of that item,
-- except for the scarce materials (see SCARCE_SKINS).
local function computeSkinStats(npc)
    local shared = not ns.settings.onlyMine and ns.shared[npc] or nil
    local own = ns.db.skins[npc]
    local always, small, big = {}, {}, {}
    local ownSum = own and skinSum(own, newSkinShare(shared, ns.db.installId, own))
    if ownSum then
        ownSum.kind = "own"
        table.insert(always, ownSum)
    end
    local sharedSum = shared and shared.skins and skinSum(shared.skins, 1)
    if sharedSum then
        sharedSum.kind = "shared"
        table.insert(always, sharedSum)
    end
    if not ns.settings.onlyMine then
        for origin, peer in pairs(ns.db.peers[npc] or {}) do
            local skins = peer.skins
            if skins and (skins.skinned or 0) > 0 then
                local factor = (skins.skinned > PEER_CAP and PEER_CAP / skins.skinned or 1)
                    * newSkinShare(shared, origin, skins)
                local sum = skinSum(skins, factor)
                if sum then
                    sum.kind = "peer"
                    table.insert(sum.opened >= BIG_SOURCE and big or small, sum)
                end
            end
        end
    end
    local all, keys = {}, {}
    for _, list in ipairs({ always, small, big }) do
        for _, sum in ipairs(list) do
            table.insert(all, sum)
            for key in pairs(sum.entries) do
                keys[key] = true
            end
        end
    end
    if #all == 0 then
        return nil
    end
    local skinnedTotal, byKind = 0, { own = 0, shared = 0, peer = 0 }
    for _, sum in ipairs(all) do
        skinnedTotal = skinnedTotal + sum.opened
        byKind[sum.kind] = byKind[sum.kind] + sum.opened
    end
    if round(skinnedTotal) == 0 then
        return nil
    end
    local stats = {
        npc = npc,
        skinned = round(skinnedTotal),
        ownSkinned = own and own.skinned or 0,
        peerSkinned = round(byKind.peer),
        sharedSkinned = round(byKind.shared),
        small = round(skinnedTotal) < ns.SMALL_SAMPLE,
        list = {},
    }
    for key in pairs(keys) do
        local used = ns.SCARCE_SKINS[key] and all or usedFor(key, always, small, big)
        local rate, usedOpened = pooledRate(key, used, 1)
        if rate > 0 then
            local entry = newEntry(key, rate, used, usedOpened)
            if entry then
                entry.world = nil
                entry.scarce = ns.SCARCE_SKINS[key] or nil
                table.insert(stats.list, entry)
            end
        end
    end
    table.sort(stats.list, function(a, b)
        if a.rate ~= b.rate then
            return a.rate > b.rate
        end
        return a.itemId < b.itemId
    end)
    return stats
end

-- Stats are kept per mob and mode until something they come from changes, which is the mob's counts (own or other
-- players'), the settings, or item info arriving with the quality of an entry. The tooltip, the icons, the details
-- window and the Loot Finder ask for the same mob over and over. Callers only read what they get.
local cache = {}  -- npc -> { [mode] = stats or false }, with the skinning stats as mode "skin"

local function forget(npc)
    cache[npc] = nil
end
ns.On("DT_DATA_CHANGED", forget)
ns.On("DT_COUNTS_CHANGED", forget)
ns.On("DT_SETTINGS_CHANGED", function()
    cache = {}
end)
ns.On("DT_ITEM_INFO_RECEIVED", function()
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
        stats = (mode == "skin" and computeSkinStats(npc) or mode ~= "skin" and computeStats(npc, mode)) or false
        byMode[mode] = stats
    end
    return stats or nil
end

-- What skinning the mob's corpses gives, or nil when nobody skinned it.
function ns.GetSkinStats(npc)
    return ns.GetStats(npc, "skin")
end

-- Entries for the icons and the mob tooltip, plus how many world drops and how many items below the minimum quality
-- were left out. Money always stays in.
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
    local shared = ns.shared[npc]
    return ns.db.names[npc] or (sight and sight.name) or ns.db.peerNames[npc] or (shared and shared.name)
        or ("NPC " .. npc)
end

-- The name the player's client gave the mob, to send with its counts. The shared database names mobs in English, so a
-- client in another language sends none, and names heard from other players aren't passed on.
function ns.NameToSend(npc)
    return GetLocale():sub(1, 2) == "en" and ns.db.names[npc] or nil
end

-- Every mob with counts, the player's own and, unless only those are wanted, other players' and the shared database's.
function ns.KnownNpcs()
    local npcs = {}
    for npc in pairs(ns.db.mobs) do
        npcs[npc] = true
    end
    for npc in pairs(ns.db.skins) do
        npcs[npc] = true
    end
    if not ns.settings.onlyMine then
        for npc in pairs(ns.db.peers) do
            npcs[npc] = true
        end
        for npc in pairs(ns.shared) do
            npcs[npc] = true
        end
    end
    return npcs
end

-- Level range and kills per map from the player's own records, filled in with what other players sent and with the
-- shared database. Kill spots (cells) come from the player's own kills and the shared database, never from other
-- players.
function ns.MobInfo(npc)
    local own = ns.db.info[npc] or ns.SeenMob(npc)
    local peers = not ns.settings.onlyMine and ns.db.peers[npc] or {}
    local shared = not ns.settings.onlyMine and ns.shared[npc] or nil
    if not next(peers) and not shared then
        return own
    end
    local info = { maps = {} }
    local function addLevels(minLevel, maxLevel)
        if minLevel then
            info.minLevel = math.min(info.minLevel or minLevel, minLevel)
            info.maxLevel = math.max(info.maxLevel or minLevel, maxLevel or minLevel)
        end
    end
    -- The cells are added into a table of their own, so the player's saved ones never change.
    local function addKills(mapId, kills, cells)
        local place = info.maps[mapId]
        if not place then
            place = { kills = 0, cells = {} }
            info.maps[mapId] = place
        end
        place.kills = place.kills + kills
        for cell, count in pairs(cells or {}) do
            place.cells[cell] = (place.cells[cell] or 0) + count
        end
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
    if shared then
        addLevels(shared.minLevel, shared.maxLevel)
        for mapId, kills in pairs(shared.maps) do
            addKills(mapId, kills, shared.spots and shared.spots[mapId])
        end
    end
    return info
end
