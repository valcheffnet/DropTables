-- Forever Drop Tables Data: the shared drop counts of Forever Drop Tables, merged on GitHub from what players send in
-- and from the imports named in Data.lua. Any addon can read them through the global DropTablesData.
--
--   DropTablesData.version   the build, "2026.11.28", with ".2" for a second build on the same day
--   DropTablesData.built     unix time of the newest counts in it
--   DropTablesData.format    1; raised only when the layout changes so that a reader written for the old one breaks
--   DropTablesData.GetMob(npcId)             the raw counts of one mob, or nil
--   DropTablesData.GetChance(npcId, itemId)  the chance in percent, and the looted corpses it rests on
--
-- A mob record: buckets (group size -> kills, lootable, opened, money, items: item id -> drops, qty, min, max), name,
-- minLevel, maxLevel, maps (map id -> kills), spots, from (source -> kills) and, for skinnable mobs, skins. The
-- functions are the stable part; the tables can change from one format to the next.
--
-- The data is under CC BY-SA 4.0, credited to the Drop Tables contributors,
-- https://github.com/valcheffnet/DropTables. Reading it in game needs only that credit; a data file built from it and
-- passed on has to stay under CC BY-SA 4.0 too. The notices of the imports are at the top of Data.lua.

DropTablesData = {
    format = 1,
    mobs = {},
}

function DropTablesData.GetMob(npcId)
    return DropTablesData.mobs[tonumber(npcId)]
end

-- The chance that one kill drops the item: the share of kills that left a lootable corpse, times the share of looted
-- corpses that held the item. It comes from these counts alone, where Drop Tables also adds the player's own kills and
-- other players' counts, so the two can differ. Returns nil when the database has no looted corpse of the mob.
function DropTablesData.GetChance(npcId, itemId)
    local mob = DropTablesData.GetMob(npcId)
    if not mob then
        return nil
    end
    itemId = tonumber(itemId)
    local kills, lootable, opened, drops = 0, 0, 0, 0
    for _, bucket in pairs(mob.buckets) do
        kills = kills + bucket.kills
        lootable = lootable + bucket.lootable
        opened = opened + bucket.opened
        local item = bucket.items[itemId]
        drops = drops + (item and item.drops or 0)
    end
    if opened == 0 then
        return nil
    end
    local lootableShare = kills > 0 and math.min(1, lootable / kills) or 1
    return 100 * lootableShare * drops / opened, opened
end
