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
    onlyMine = false,
    exportReminder = true,
    showMinimap = true,
    minimapAngle = 200,
    debug = false,
}

-- Rates from fewer opened corpses than this are shown greyed out.
ns.SMALL_SAMPLE = 10

local listeners = {}

-- Modules subscribe to game events and to the addon's own messages through ns.On / ns.Fire.
function ns.On(event, callback)
    if not listeners[event] then
        listeners[event] = {}
        if not event:find("^DT_") then
            ns.frame:RegisterEvent(event)
        end
    end
    table.insert(listeners[event], callback)
end

-- Each listener runs on its own: an error in one goes to the error frame and the others still get the event.
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
    print("|cff66ccffDrop Tables|r " .. msg)
end

-- /dt debug: a chat line for every sharing message in and out and every loot window, for testing between players.
-- The lines go to a chat tab named "DT Debug", which /dt debug opens and closes again; without a free tab they go to
-- the main window.
local DEBUG_TAB = "DT Debug"

local function findDebugFrame()
    for i = 1, NUM_CHAT_WINDOWS or 0 do
        local name, _, _, _, _, _, shown = GetChatWindowInfo(i)
        if name and name:lower() == DEBUG_TAB:lower() and shown ~= false and _G["ChatFrame" .. i] then
            return _G["ChatFrame" .. i]
        end
    end
end

local function debugFrame()
    return findDebugFrame() or DEFAULT_CHAT_FRAME
end

-- Opens the DT Debug tab with no other messages in it. Blizzard's chat functions are optional: a client without
-- them keeps the lines in the main window.
local function openDebugTab()
    if findDebugFrame() or not FCF_OpenNewWindow then
        return
    end
    local frame = FCF_OpenNewWindow(DEBUG_TAB, true)
    if frame and ChatFrame_RemoveAllMessageGroups then
        ChatFrame_RemoveAllMessageGroups(frame)
    end
    if frame and ChatFrame_RemoveAllChannels then
        ChatFrame_RemoveAllChannels(frame)
    end
end

local function closeDebugTab()
    local frame = findDebugFrame()
    if frame and frame ~= DEFAULT_CHAT_FRAME and FCF_Close then
        FCF_Close(frame)
    end
end

function ns.Debug(text, ...)
    if ns.settings and ns.settings.debug then
        debugFrame():AddMessage(("|cff888888%s DT|r %s"):format(date("%H:%M:%S"), text:format(...)))
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

-- Like UnitNpc, but nil for creatures the player cannot fight, such as flight masters, vendors and trainers, which
-- drop nothing. Corpses count, and so does a unit whose state the client hides.
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

-- Midnight moved several old globals into namespaces; these pick whichever the client has.
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

function ns.ItemName(itemId)
    local name = C_Item.GetItemInfo(itemId)
    if name then
        return name
    end
    local meta = ns.db.items[itemId]
    return meta and meta.name or ("item:" .. itemId)
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

-- Total of one count (kills, opened, ...) over a mob's buckets.
function ns.SumBuckets(buckets, field)
    local total = 0
    for _, data in pairs(buckets) do
        total = total + data[field]
    end
    return total
end

-- Puts every setting back to its default and forgets window places and sizes; recorded drops are not touched.
-- The same table stays in use, because the options panel holds on to it.
function ns.RestoreDefaults()
    for key in pairs(ns.settings) do
        ns.settings[key] = nil
    end
    for key, value in pairs(ns.DEFAULTS) do
        ns.settings[key] = value
    end
    ns.Fire("DT_SETTINGS_CHANGED")
end

-- "1-3" when the stack size varies, "2" when it never does; data recorded before ranges existed shows the average.
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
    db.mobs = db.mobs or {}
    db.items = db.items or {}
    db.names = db.names or {}
    db.info = db.info or {}
    db.peers = db.peers or {}
    db.refreshed = db.refreshed or {}  -- npc -> time of its last daily question
    db.settings = db.settings or {}
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
    msg = strtrim(msg or ""):lower()
    if msg == "options" or msg == "config" then
        ns.OpenOptions()
    elseif msg == "unlock" or msg == "lock" then
        ns.UnlockStrip(msg == "unlock")
    elseif msg == "reset" then
        ns.ResetStripPosition()
    elseif msg == "find" or msg:find("^find ") then
        local text = strtrim(msg:sub(5))
        ns.ToggleFinder(text ~= "" and text or nil)
    elseif msg == "icons" or msg == "tooltip" or msg == "minimap" then
        local key = ({ icons = "showStrip", tooltip = "showTooltip", minimap = "showMinimap" })[msg]
        ns.settings[key] = not ns.settings[key]
        ns.Fire("DT_SETTINGS_CHANGED")
        ns.Print(("%s %s."):format(msg, ns.settings[key] and "on" or "off"))
    elseif msg == "status" then
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
        ns.Print(("%d of your mobs have new counts since your last /dt export."):format(ns.ChangedCount()))
    elseif msg == "export" then
        ns.ToggleExport()
    elseif msg == "debug" then
        ns.settings.debug = not ns.settings.debug
        ns.Fire("DT_SETTINGS_CHANGED")
        if ns.settings.debug then
            openDebugTab()
            ns.Print("debug messages on, in the DT Debug chat tab. /dt debug again turns them off.")
            ns.Debug("%s", ns.ShareDebugState())
        else
            closeDebugTab()
            ns.Print("debug messages off.")
        end
    else
        ns.ToggleDetails(ns.UnitNpc("target"))
    end
end

function DropTables_OnCompartmentClick(_, button)
    if button == "RightButton" then
        ns.OpenOptions()
    else
        ns.ToggleDetails(ns.UnitNpc("target"))
    end
end
