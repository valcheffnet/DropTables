local _, ns = ...

-- Item class of quest items; they belong to quest helpers, not to drop tables.
local QUEST_CLASS = 12
local MONEY_SLOT = 2
local FIRST_CHECK = 1.5
local FINAL_CHECK = 4
local PENDING_TTL = 900
-- Skinning is a spell with a cast time and opens the loot window of the corpse as it finishes; plain corpse loot
-- needs no cast. Loot opened this soon after such a cast is profession loot, unless the corpse was known to hold loot:
-- a caster may loot one corpse right after a cast at the next mob.
local CAST_LOOT_WINDOW = 1
-- Units that can show the corpse whose loot window is open.
local CORPSE_UNITS = { "softinteract", "mouseover", "target" }

-- Kills waiting for their corpse to be checked or looted, by victim GUID. States:
-- checking: loot state not known yet; lootable: has loot, kill counted; unknown: CanLootUnit gave no answer;
-- empty: no loot at the last check, kill counted (opened later with loot after all, the loot still counts);
-- unclaimed: in a group, no loot for the player at the last check, often someone else's corpse, nothing counted;
-- done: the corpse is recorded.
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
            kill.state = "unclaimed"
        elseif loot == false then
            local data = bucketData(kill.npc, kill.bucket)
            data.kills = data.kills + 1
            kill.state = "empty"
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
        if kill.state ~= "empty" then
            data.kills = data.kills + 1
        end
        data.lootable = data.lootable + 1
    end
    data.opened = data.opened + 1
    kill.state = "done"
    return kill, data
end

local function emptyCandidate(kill)
    return kill and kill.state ~= "done" and kill.state ~= "empty"
end

-- A corpse that sparkled but opened with nothing in it is an empty corpse: the kill counts, the loot does not.
local function claimEmpty(guid)
    local kill = pending[guid]
    if not emptyCandidate(kill) then
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

-- The GUID of a dead creature under one of the units, or nil. Unreadable values count as no answer.
local function deadUnitGuid(unit)
    local guid, dead = UnitGUID(unit), UnitIsDead(unit)
    if type(guid) ~= "string" or ns.IsSecret(guid) or ns.IsSecret(dead) or not dead then
        return nil
    end
    return guid
end

-- A corpse of a mob that no one in the group finished (a guard, another player or a damage over time effect after
-- leaving the group) has no PARTY_KILL. Its kill is taken when the player opens it while it is under the interact
-- key, the mouse or the target. A living mob (pickpocketing) is not a corpse.
local function lateKill(guid)
    local npc = ns.NpcFromGuid(guid)
    if not npc then
        return
    end
    for _, unit in ipairs(CORPSE_UNITS) do
        if deadUnitGuid(unit) == guid then
            pending[guid] = { npc = npc, bucket = groupBucket(), at = GetTime(), state = "checking" }
            ns.Debug("  %s was finished by someone else, counted from its corpse", ns.MobName(npc))
            return
        end
    end
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

ns.On("UNIT_SPELLCAST_START", function()
    casting = true
end, "player")

ns.On("UNIT_SPELLCAST_SUCCEEDED", function()
    if casting then
        casting, lastCastEnd = false, GetTime()
    end
end, "player")

local function castEnded()
    casting = false
end
ns.On("UNIT_SPELLCAST_INTERRUPTED", castEnded, "player")
ns.On("UNIT_SPELLCAST_FAILED", castEnded, "player")

ns.On("LOOT_OPENED", function(_, fromItem)
    if fromItem then
        ns.Debug("loot window skipped: from an item")
        return
    end
    local afterCast = GetTime() - lastCastEnd < CAST_LOOT_WINDOW
    -- found[guid] collects one corpse's items and money across all slots before they are counted,
    -- so an item split over two slots still counts as one drop with its full stack.
    local claims, found, changed = {}, {}, {}

    local function corpse(guid)
        if type(guid) ~= "string" or ns.IsSecret(guid) then
            return nil
        end
        if claims[guid] == nil then
            local kill = pending[guid]
            if afterCast and not (kill and kill.state == "lootable") then
                claims[guid] = false
                ns.Debug("  loot right after a cast (skinning) left out")
                return nil
            end
            if not kill then
                lateKill(guid)
            end
            local claimed, data = claim(guid)
            claims[guid] = data or false
            if claimed then
                found[guid] = { items = {}, money = 0 }
                changed[claimed.npc] = true
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
    -- is on does. The target is left out: it is often another corpse killed after this one. When the two show
    -- different corpses of the player's kills, nothing tells which one was opened, and neither is counted.
    if count == 0 then
        local chosen, candidates = nil, 0
        for _, unit in ipairs({ "softinteract", "mouseover" }) do
            local guid = deadUnitGuid(unit)
            if guid and guid ~= chosen and emptyCandidate(pending[guid]) then
                chosen, candidates = guid, candidates + 1
            end
        end
        local kill = candidates == 1 and claimEmpty(chosen)
        if kill then
            changed[kill.npc] = true
            ns.Debug("loot window empty: %s counted as a corpse that left nothing", ns.MobName(kill.npc))
        elseif candidates > 1 then
            ns.Debug("loot window empty: the interact key and the mouse are on two corpses, neither counted")
        end
    elseif not next(found) then
        ns.Debug("loot window with %d slots from no kill of yours", count)
    end

    for npc in pairs(changed) do
        ns.Fire("DT_DATA_CHANGED", npc)
    end
end)
