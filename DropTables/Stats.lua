local _, ns = ...

-- Weapons, armor and recipes of any quality are treated as random world drops that any mob of the level can give,
-- unless a well-sampled mob drops one often enough to make it part of its own table.
local WORLD_DROP_CLASSES = { [2] = true, [4] = true, [9] = true }
local OWN_DROP_MIN_RATE = 0.2

local function mergeRange(into, from)
    if from.min then
        into.min = math.min(into.min or from.min, from.min)
        into.max = math.max(into.max or from.max, from.max)
    end
end

local function inMode(bucket, mode)
    return mode == "all" or (mode == "solo") == (bucket == 1)
end

-- Drop rates for one mob. mode is "all", "solo" or "group".
-- rate = (lootable / kills) * (drops / opened): kills that leave an empty corpse lower every rate,
-- while corpses the player never opened do not.
function ns.GetStats(npc, mode)
    local mob = npc and ns.db.mobs[npc]
    if not mob then
        return nil
    end
    local kills, lootable, opened, moneyDrops, copper = 0, 0, 0, 0, 0
    local moneyRange = {}
    local items = {}
    for bucket, data in pairs(mob) do
        if inMode(bucket, mode) then
            kills = kills + data.kills
            lootable = lootable + data.lootable
            opened = opened + data.opened
            moneyDrops = moneyDrops + data.money.drops
            copper = copper + data.money.copper
            mergeRange(moneyRange, data.money)
            for itemId, item in pairs(data.items) do
                local sum = items[itemId]
                if not sum then
                    sum = { drops = 0, qty = 0 }
                    items[itemId] = sum
                end
                sum.drops = sum.drops + item.drops
                sum.qty = sum.qty + item.qty
                mergeRange(sum, item)
            end
        end
    end
    if kills == 0 then
        return nil
    end

    local share = lootable / kills
    local stats = {
        npc = npc,
        kills = kills,
        opened = opened,
        empty = kills - lootable,
        small = opened < ns.SMALL_SAMPLE,
        list = {},
    }
    for itemId, item in pairs(items) do
        local rate = opened > 0 and share * item.drops / opened or 0
        local meta = ns.db.items[itemId]
        local quality = meta and meta.quality or C_Item.GetItemQualityByID(itemId)
        local classId = select(6, C_Item.GetItemInfoInstant(itemId))
        table.insert(stats.list, {
            itemId = itemId,
            rate = rate,
            drops = item.drops,
            avgQty = item.qty / item.drops,
            min = item.min,
            max = item.max,
            quality = quality,
            world = WORLD_DROP_CLASSES[classId] == true and not (opened >= ns.SMALL_SAMPLE and rate >= OWN_DROP_MIN_RATE),
        })
    end
    -- Money is one more entry of the list (money = true, no itemId), so it is sorted by chance like any item.
    if moneyDrops > 0 and opened > 0 then
        stats.money = {
            money = true,
            rate = share * moneyDrops / opened,
            avg = copper / moneyDrops,
            min = moneyRange.min,
            max = moneyRange.max,
        }
        table.insert(stats.list, stats.money)
    end
    table.sort(stats.list, function(a, b)
        if a.rate ~= b.rate then
            return a.rate > b.rate
        end
        return (a.itemId or 0) < (b.itemId or 0)
    end)
    return stats
end

-- Entries for the icons and the mob tooltip, plus how many world drops were left out of them.
-- Items below the minimum quality are left out; money always stays.
function ns.VisibleEntries(stats)
    local entries, worldCount = {}, 0
    for _, entry in ipairs(stats.list) do
        if entry.world and ns.settings.collapseWorldDrops then
            worldCount = worldCount + 1
        elseif entry.money or (entry.quality or 0) >= ns.settings.minQuality then
            table.insert(entries, entry)
        end
    end
    return entries, worldCount
end

function ns.MobName(npc)
    return ns.db.names[npc] or ("NPC " .. npc)
end
