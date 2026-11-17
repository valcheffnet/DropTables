local _, ns = ...

-- Item class of quest items; they belong to quest helpers, not to drop tables.
local QUEST_CLASS = 12
local MONEY_SLOT = 2
local FIRST_CHECK = 1.5
local FINAL_CHECK = 4
local PENDING_TTL = 900
-- Skinning, mining, herbs and chests are spells with a cast time and open the loot window as they finish; plain
-- corpse loot needs no cast. Loot opened this soon after such a cast is profession loot.
local CAST_LOOT_WINDOW = 1

-- Kills waiting for their corpse to be checked or looted, by victim GUID. States:
-- checking: loot state not known yet; lootable: has loot, kill counted; unknown: CanLootUnit gave no answer;
-- done: empty kill counted or corpse already recorded.
local pending = {}
local casting, lastCastEnd = false, -math.huge

local function groupBucket()
    local members = GetNumGroupMembers()
    if members <= 1 then
        return 1
    elseif IsInRaid() then
        return 6
    end
    return math.min(members, 5)
end

-- Returns the counts of a mob bucket that is about to change; sharing picks the bucket up from DT_COUNTS_CHANGED.
local function bucketData(npc, bucket)
    ns.Fire("DT_COUNTS_CHANGED", npc, bucket)
    local mob = ns.db.mobs[npc]
    if not mob then
        mob = {}
        ns.db.mobs[npc] = mob
    end
    local data = mob[bucket]
    if not data then
        data = { kills = 0, lootable = 0, opened = 0, items = {}, money = { drops = 0, copper = 0 } }
        mob[bucket] = data
    end
    return data
end

local function hasLoot(guid)
    if not CanLootUnit then
        return nil
    end
    local result = CanLootUnit(guid)
    if ns.IsSecret(result) then
        return nil
    end
    return result
end

local function check(guid, final)
    local kill = pending[guid]
    if not kill or kill.state ~= "checking" then
        return
    end
    local loot = hasLoot(guid)
    if loot then
        local data = bucketData(kill.npc, kill.bucket)
        data.kills = data.kills + 1
        data.lootable = data.lootable + 1
        kill.state = "lootable"
        ns.Fire("DT_DATA_CHANGED", kill.npc)
    elseif final then
        if loot == false and kill.bucket > 1 then
            -- In a group a corpse can be someone else's to loot, which looks the same as an empty one.
            kill.state = "done"
        elseif loot == false then
            local data = bucketData(kill.npc, kill.bucket)
            data.kills = data.kills + 1
            kill.state = "done"
            ns.Fire("DT_DATA_CHANGED", kill.npc)
        else
            kill.state = "unknown"
        end
    end
end

local function prune()
    local now = GetTime()
    for guid, kill in pairs(pending) do
        if now - kill.at > PENDING_TTL then
            pending[guid] = nil
        end
    end
end

ns.On("PARTY_KILL", function(_, victim)
    local npc = ns.NpcFromGuid(victim)
    if not npc or pending[victim] then
        return
    end
    prune()
    pending[victim] = { npc = npc, bucket = groupBucket(), at = GetTime(), state = "checking" }
    C_Timer.After(FIRST_CHECK, function()
        check(victim, false)
    end)
    C_Timer.After(FINAL_CHECK, function()
        check(victim, true)
    end)
end)

-- Takes a corpse for recording on its first opening; returns nil for corpses that are not our kills
-- or were opened before (skinning and other profession loot reuse the corpse GUID).
local function claim(guid)
    local kill = pending[guid]
    if not kill or kill.state == "done" then
        return nil
    end
    local data = bucketData(kill.npc, kill.bucket)
    if kill.state ~= "lootable" then
        data.kills = data.kills + 1
        data.lootable = data.lootable + 1
    end
    data.opened = data.opened + 1
    kill.state = "done"
    return kill, data
end

-- A corpse that sparkled but opened with nothing in it is an empty corpse: the kill counts, the loot does not.
local function claimEmpty(guid)
    local kill = pending[guid]
    if not kill or kill.state == "done" then
        return nil
    end
    local data = bucketData(kill.npc, kill.bucket)
    if kill.state == "lootable" then
        data.lootable = data.lootable - 1
    else
        data.kills = data.kills + 1
    end
    kill.state = "done"
    return kill
end

local function isQuestItem(itemId, questFlag)
    return questFlag or select(6, C_Item.GetItemInfoInstant(itemId)) == QUEST_CLASS
end

local function addStack(entry, totalKey, amount)
    entry.drops = entry.drops + 1
    entry[totalKey] = entry[totalKey] + amount
    entry.min = math.min(entry.min or amount, amount)
    entry.max = math.max(entry.max or amount, amount)
end

ns.On("UNIT_SPELLCAST_START", function(unit)
    if unit == "player" then
        casting = true
    end
end)

ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit)
    if unit == "player" and casting then
        casting, lastCastEnd = false, GetTime()
    end
end)

local function castEnded(unit)
    if unit == "player" then
        casting = false
    end
end
ns.On("UNIT_SPELLCAST_INTERRUPTED", castEnded)
ns.On("UNIT_SPELLCAST_FAILED", castEnded)

ns.On("LOOT_OPENED", function(_, fromItem)
    if fromItem or GetTime() - lastCastEnd < CAST_LOOT_WINDOW then
        ns.Debug("loot window skipped: %s", fromItem and "from an item" or "right after a cast (skinning, herbs, ore, chest)")
        return
    end
    -- found[guid] collects one corpse's items and money across all slots before they are counted,
    -- so an item split over two slots still counts as one drop with its full stack.
    local claims, found, changed = {}, {}, {}

    local function corpse(guid)
        if type(guid) ~= "string" or ns.IsSecret(guid) then
            return nil
        end
        if claims[guid] == nil then
            local kill, data = claim(guid)
            claims[guid] = data or false
            if kill then
                found[guid] = { items = {}, money = 0 }
                changed[kill.npc] = true
            end
        end
        return claims[guid] or nil
    end

    local count = GetNumLootItems()
    for slot = 1, count do
        local slotType = GetLootSlotType(slot)
        local _, name, _, _, quality, _, questFlag = GetLootSlotInfo(slot)
        local link = GetLootSlotLink(slot)
        local itemId = link and tonumber(link:match("item:(%d+)"))
        local sources = { GetLootSourceInfo(slot) }
        for s = 1, #sources, 2 do
            local guid, quantity = sources[s], sources[s + 1] or 1
            if corpse(guid) then
                local loot = found[guid]
                if slotType == MONEY_SLOT then
                    loot.money = loot.money + quantity
                elseif itemId and not isQuestItem(itemId, questFlag) then
                    loot.items[itemId] = (loot.items[itemId] or 0) + quantity
                    ns.db.items[itemId] = { name = name, quality = quality }
                elseif itemId then
                    ns.Debug("  quest item %s left out", tostring(name))
                end
            end
        end
    end

    for guid, loot in pairs(found) do
        local data = claims[guid]
        local itemCount = 0
        for _ in pairs(loot.items) do
            itemCount = itemCount + 1
        end
        ns.Debug("loot from %s: %d items, %d copper", ns.MobName(pending[guid].npc), itemCount, loot.money)
        for itemId, quantity in pairs(loot.items) do
            local item = data.items[itemId]
            if not item then
                item = { drops = 0, qty = 0 }
                data.items[itemId] = item
            end
            addStack(item, "qty", quantity)
        end
        if loot.money > 0 then
            addStack(data.money, "copper", loot.money)
        end
    end

    -- A corpse that sparkled but opened empty has no slots to name it; the corpse the interact key or the mouse
    -- is on does. The target is left out: it is often another corpse killed after this one.
    if count == 0 then
        for _, unit in ipairs({ "softinteract", "mouseover" }) do
            local guid = UnitGUID(unit)
            local kill = UnitIsDead(unit) and type(guid) == "string" and not ns.IsSecret(guid) and claimEmpty(guid)
            if kill then
                changed[kill.npc] = true
                ns.Debug("loot window empty: %s counted as a corpse that left nothing", ns.MobName(kill.npc))
                break
            end
        end
    elseif not next(found) then
        ns.Debug("loot window with %d slots from no kill of yours", count)
    end

    for npc in pairs(changed) do
        ns.Fire("DT_DATA_CHANGED", npc)
    end
end)
