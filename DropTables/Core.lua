local ADDON, ns = ...

ns.DEFAULTS = {
    showStrip = true,
    stripIcons = 6,
    stripScale = 1,
    showTooltip = true,
    tooltipLines = 5,
    collapseWorldDrops = true,
    minQuality = 0,
    detailsFollow = true,
    detailsOpen = true,
    detailsAlpha = 1,
    finderAlpha = 1,
    theme = "classic",
    onlyMine = false,
    exportReminder = true,
    showMinimap = true,
    sharePlayers = true,  -- ask, answer and swap counts with other players in game
    killsPerHour = 70,  -- on mobs of the player's level, for g/ph in the Loot Finder
    gphWorldDrops = false,  -- random gear and recipes count in g/ph, at their vendor price
    finderMinKills = 1,  -- the Loot Finder lists mobs with at least this many kills
    finderMinRate = 0,  -- and at least this chance in percent, 0 for any
    minimapAngle = 200,
}

-- Rates from fewer opened corpses than this are shown greyed out.
ns.SMALL_SAMPLE = 10

local listeners = {}

-- Modules listen to game events and to the addon's own messages through ns.On / ns.Fire. Passing a unit registers a
-- unit event for just that unit, because otherwise the casts of every nameplate and raid member come in by the hundred.
function ns.On(event, callback, unit)
    if not listeners[event] then
        listeners[event] = {}
        if unit then
            ns.frame:RegisterUnitEvent(event, unit)
        elseif not event:find("^DT_") then
            ns.frame:RegisterEvent(event)
        end
    end
    table.insert(listeners[event], callback)
end

-- Each listener runs separately, so an error in one goes to the error frame while the others still get the event.
function ns.Fire(event, ...)
    local count, args = select("#", ...), { ... }
    for _, callback in ipairs(listeners[event] or {}) do
        xpcall(function()
            callback(unpack(args, 1, count))
        end, geterrorhandler())
    end
end

ns.frame = CreateFrame("Frame")
ns.frame:SetScript("OnEvent", function(_, event, ...)
    ns.Fire(event, ...)
end)

function ns.Print(msg)
    print("|cff66ccffForever Drop Tables|r " .. msg)
end

-- The version in the toc, "?" when the client can't say.
function ns.Version()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    return get and get("DropTables", "Version") or "?"
end

-- The Drop Tables Debug addon, a test helper that isn't part of the download, hands its writer here while it is on
-- (nil turns it off) and gets the sharing state for its first line. Without it the debug lines go nowhere.
local debugWriter

function DropTables_SetDebugWriter(writer)
    debugWriter = writer
    return ns.ShareDebugState
end

function ns.Debug(text, ...)
    if debugWriter then
        debugWriter(text:format(...))
    end
end

local function isSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end
ns.IsSecret = isSecret

-- Returns the npc id for a creature GUID, or nil for players, pets, objects and unreadable values.
function ns.NpcFromGuid(guid)
    if type(guid) ~= "string" or isSecret(guid) then
        return nil
    end
    local kind, _, _, _, _, npcId = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then
        return nil
    end
    return tonumber(npcId)
end

function ns.UnitNpc(unit)
    local guid = UnitGUID(unit)
    return ns.NpcFromGuid(guid), guid
end

-- Like UnitNpc, but nil for creatures the player can't fight. Flight masters, vendors and trainers drop nothing, so
-- there's no point counting them. Corpses still count, and so does a unit whose state the client hides.
function ns.UnitMob(unit)
    local npc, guid = ns.UnitNpc(unit)
    if not npc then
        return nil
    end
    local canAttack, dead = UnitCanAttack("player", unit), UnitIsDead(unit)
    if isSecret(canAttack) or canAttack or isSecret(dead) or dead then
        return npc, guid
    end
    return nil
end

function ns.ItemIcon(itemId)
    return select(5, C_Item.GetItemInfoInstant(itemId)) or 134400
end

-- Returns r, g, b for an item quality, or nil when the client does not know it.
function ns.QualityRGB(quality)
    if not quality then
        return nil
    end
    if C_Item.GetItemQualityColor then
        return C_Item.GetItemQualityColor(quality)
    end
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then
        return color.r, color.g, color.b
    end
end

function ns.QualityColor(quality)
    local r, g, b = ns.QualityRGB(quality)
    if not r then
        return "|cffffffff"
    end
    return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

-- Midnight moved several old globals into namespaces, so these use whichever one the client has.
local coinText = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
function ns.CoinText(copper)
    return coinText(math.floor(copper + 0.5))
end

function ns.InsertLink(link)
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    insert(link)
end

-- Shift-click on an item puts its link into the chat box.
function ns.TryLinkItem(itemId)
    if not IsModifiedClick("CHATLINK") then
        return false
    end
    local _, link = C_Item.GetItemInfo(itemId)
    if link then
        ns.InsertLink(link)
    end
    return true
end

-- What Drop Tables reads of an item, kept for the session once the client has given it. The client's own item cache
-- lets go of items while the Loot Finder goes through two thousand of them, and asking again for one it let go loads
-- it again, which would redraw the Finder and ask once more.
local itemInfo = {}

local function readItem(itemId)
    local name, _, quality, _, _, _, _, _, _, _, sellPrice, _, _, bindType = C_Item.GetItemInfo(itemId)
    if not name then
        return nil
    end
    local info = { name = name, quality = quality, sellPrice = sellPrice, bindType = bindType }
    itemInfo[itemId] = info
    return info
end

-- Items asked about before the client knew them, with the GetTime() of the last ask. The client loads items all the
-- time for other addons and for the gear of the players around, so only the arrival of these ones fires
-- DT_ITEM_INFO_RECEIVED, the signal to work the values out again and redraw. An item the server can't load comes back
-- as a failure, changes nothing and isn't asked for again this session: a redraw for it would only ask again and fail
-- again, every second. An item whose answer never comes is asked for again ASK_AGAIN seconds later, the next time
-- something needs it; asking again redraws nothing by itself. An item is read the moment it arrives, and if the client
-- can't give it even then, another redraw won't help either.
local ASK_AGAIN = 30
local awaited, arrived, failed = {}, {}, {}
function ns.AwaitItem(itemId)
    if not arrived[itemId] and not failed[itemId] then
        awaited[itemId] = awaited[itemId] or GetTime()
    end
end

ns.On("GET_ITEM_INFO_RECEIVED", function(itemId, success)
    if not awaited[itemId] and not failed[itemId] then
        return
    end
    awaited[itemId] = nil
    if success == false then
        failed[itemId] = true
        return
    end
    -- It can still come later, when something else asks for it.
    arrived[itemId], failed[itemId] = true, nil
    readItem(itemId)
    ns.Fire("DT_ITEM_INFO_RECEIVED", itemId)
end)

-- Name, quality, sell price and bind type of an item, or nil while the client doesn't know it yet. An item already
-- asked for isn't asked for again until ASK_AGAIN seconds have passed: the Loot Finder's gold per hour needs the items
-- of two thousand mobs, and asking for each unknown one every time a mob drops it ran into the game's time limit.
function ns.ItemInfo(itemId)
    local info = itemInfo[itemId]
    local asked = awaited[itemId]
    if info or failed[itemId] or asked and GetTime() - asked < ASK_AGAIN then
        return info
    end
    info = readItem(itemId)
    if not info then
        awaited[itemId] = nil
        ns.AwaitItem(itemId)
    end
    return info
end

function ns.ItemQuality(itemId)
    local info = itemInfo[itemId]
    if info and info.quality then
        return info.quality
    end
    local quality = C_Item.GetItemQualityByID(itemId)
    if quality == nil then
        ns.AwaitItem(itemId)
    end
    return quality
end

function ns.ItemName(itemId)
    local info = ns.ItemInfo(itemId)
    if info then
        return info.name
    end
    local meta = ns.db.items[itemId]
    return meta and meta.name or ("item:" .. itemId)
end

-- The Skinning skill a mob of this level needs: 1 up to level 10, then 10 more per level up to 20, then level x 5.
function ns.SkinningSkill(level)
    if not level then
        return nil
    elseif level <= 10 then
        return 1
    elseif level <= 20 then
        return (level - 10) * 10
    end
    return level * 5
end

function ns.FormatRate(rate)
    if rate >= 0.995 then
        return "100%"
    elseif rate >= 0.1 then
        return ("%d%%"):format(rate * 100 + 0.5)
    elseif rate >= 0.01 then
        return ("%.1f%%"):format(rate * 100)
    end
    return ("%.2f%%"):format(rate * 100)
end

-- The shared database from Data.lua, npc -> { buckets, from, minLevel, maxLevel, maps, name, skins }, kept in the same
-- shape as the player's own counts. It comes with the addon, and nothing ever saves, sends or exports it.
ns.shared = {}

function ns.AddSharedData(chunk)
    for npc, mob in pairs(chunk()) do
        ns.shared[npc] = mob
    end
end

-- Total of one count (kills, opened, ...) over a mob's buckets.
function ns.SumBuckets(buckets, field)
    local total = 0
    for _, data in pairs(buckets) do
        total = total + data[field]
    end
    return total
end

-- Puts every setting back to its default and forgets where the windows were and how big they were, while recorded
-- drops stay. It refills the same table because the options panel holds on to it.
function ns.RestoreDefaults()
    for key in pairs(ns.settings) do
        ns.settings[key] = nil
    end
    for key, value in pairs(ns.DEFAULTS) do
        ns.settings[key] = value
    end
    ns.Fire("DT_SETTINGS_CHANGED")
end

-- "1-3" when the stack size varies and "2" when it doesn't. Data recorded before ranges existed shows the average.
function ns.FormatStack(entry)
    if entry.min and entry.max then
        return entry.min == entry.max and tostring(entry.min) or (entry.min .. "-" .. entry.max)
    end
    if entry.avgQty == math.floor(entry.avgQty) then
        return tostring(entry.avgQty)
    end
    return ("%.1f"):format(entry.avgQty)
end

local function newInstallId()
    local parts = {}
    for i = 1, 4 do
        parts[i] = ("%04x"):format(math.random(0, 0xffff))
    end
    return table.concat(parts)
end

ns.On("ADDON_LOADED", function(name)
    if name ~= ADDON then
        return
    end
    DropTablesDB = DropTablesDB or {}
    local db = DropTablesDB
    db.version = 1
    db.installId = db.installId or newInstallId()
    -- Goes at the end of every export string and never anywhere else. The share page turns it into a hash before
    -- anything is public, so nobody else can send an export as this install.
    db.exportKey = db.exportKey or (newInstallId() .. newInstallId())
    db.mobs = db.mobs or {}
    db.skins = db.skins or {}  -- npc -> { skinned, items }, what skinning its corpses gave
    db.looted = db.looted or {}  -- npc -> true for mobs counted from their corpses in a dungeon, kills unknown
    db.items = db.items or {}
    db.names = db.names or {}  -- npc -> the name the player's client showed
    db.peerNames = db.peerNames or {}  -- npc -> the name another player's addon sent
    db.info = db.info or {}
    db.peers = db.peers or {}
    db.refreshed = db.refreshed or {}  -- npc -> time of its last daily question
    db.settings = db.settings or {}
    -- Versions up to 0.6.3 kept the debug switch and its lines here.
    db.debugLog, db.settings.debug = nil, nil
    for key, value in pairs(ns.DEFAULTS) do
        if db.settings[key] == nil then
            db.settings[key] = value
        end
    end
    ns.db = db
    ns.settings = db.settings
    ns.Fire("DT_READY")
end)

SLASH_DROPTABLES1 = "/dt"
SLASH_DROPTABLES2 = "/droptables"
SlashCmdList.DROPTABLES = function(msg)
    local text = strtrim(msg or "")
    msg = text:lower()
    if msg == "options" or msg == "config" then
        ns.OpenOptions()
    elseif msg == "unlock" or msg == "lock" then
        ns.UnlockStrip(msg == "unlock")
    elseif msg == "reset" then
        ns.ResetStripPosition()
    elseif msg == "find" or msg:find("^find ") then
        local search = strtrim(text:sub(5))
        ns.ToggleFinder(search ~= "" and search or nil)
    elseif msg == "icons" or msg == "tooltip" or msg == "minimap" then
        local key = ({ icons = "showStrip", tooltip = "showTooltip", minimap = "showMinimap" })[msg]
        ns.settings[key] = not ns.settings[key]
        ns.Fire("DT_SETTINGS_CHANGED")
        ns.Print(("%s %s."):format(msg, ns.settings[key] and "on" or "off"))
    elseif msg == "status" then
        ns.Print("version " .. ns.Version())
        local mobs, kills = 0, 0
        for _, mob in pairs(ns.db.mobs) do
            mobs = mobs + 1
            for _, data in pairs(mob) do
                kills = kills + data.kills
            end
        end
        ns.Print(("%d mobs, %d kills recorded. Empty-corpse check: %s."):format(mobs, kills,
            CanLootUnit and "available" or "not available, rates may read high"))
        ns.Print(ns.ShareStatus())
        ns.Print(("%d of your mobs have new counts to share (/dt export)."):format(ns.NewCount()))
    elseif msg == "export" then
        ns.ToggleExport()
    else
        ns.ToggleDetails(ns.UnitMob("target"))
    end
end

function DropTables_OnCompartmentClick(_, button)
    if button == "RightButton" then
        ns.OpenOptions()
    else
        ns.ToggleDetails(ns.UnitMob("target"))
    end
end
