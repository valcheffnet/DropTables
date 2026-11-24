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
    minimapAngle = 200,
    debug = false,
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
    print("|cff66ccffDrop Tables|r " .. msg)
end

-- The version in the toc, "?" when the client can't say.
function ns.Version()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    return get and get("DropTables", "Version") or "?"
end

-- /dt debug writes a chat line for every sharing message in and out and for every loot window, which helps when testing
-- with another player. The lines go only to a chat tab called "DT Debug" that /dt debug opens and closes again, or to
-- the main window when there's no free tab. The last lines are kept over a /reload and put back in the tab, and a new
-- login starts with none.
local DEBUG_TAB = "DT Debug"
local DEBUG_KEEP = 500

-- A docked tab that isn't the selected one is hidden, and the client then calls it not shown, so a tab counts while it
-- is shown or docked. A tab closed by hand is neither.
local function findDebugFrame()
    for i = 1, NUM_CHAT_WINDOWS or 0 do
        local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
        if name and name:lower() == DEBUG_TAB:lower() and (shown ~= false or docked) and _G["ChatFrame" .. i] then
            return _G["ChatFrame" .. i]
        end
    end
end

-- Opens the DT Debug tab with no other messages in it. If the client lacks Blizzard's chat functions, the lines just
-- stay in the main window.
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

-- The DT Debug tab, opened again when it was closed by hand while debug is on.
local function debugFrame()
    if not findDebugFrame() then
        openDebugTab()
    end
    return findDebugFrame() or DEFAULT_CHAT_FRAME
end

-- How many debug lines came while the DT Debug tab wasn't in front, as a number in a red circle on its tab, the way
-- Chat+ marks other tabs. Bringing the tab to the front clears it.
local unread, badge, badgeFrame = 0, nil, nil
local hookedFrames = {}

local function updateBadge()
    if not badge then
        return
    end
    local tab = badgeFrame and _G[badgeFrame:GetName() .. "Tab"]
    if unread > 0 and tab and tab:IsShown() then
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", tab, "TOPRIGHT", -6, -6)
        badge.text:SetText(unread > 99 and "99+" or tostring(unread))
        badge:SetWidth(math.max(16, badge.text:GetStringWidth() + 8))
        badge:Show()
    else
        badge:Hide()
    end
end

local function createBadge()
    badge = CreateFrame("Frame", nil, UIParent)
    badge:SetSize(16, 16)
    badge:SetFrameStrata("MEDIUM")
    local circle = badge:CreateTexture(nil, "BACKGROUND")
    circle:SetAllPoints()
    circle:SetColorTexture(0.85, 0.12, 0.12, 1)
    local mask = badge:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(circle)
    circle:AddMaskTexture(mask)
    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    badge.text:SetPoint("CENTER", 0, 0)
    badge:Hide()
    ns.debugBadge = badge
end

-- Counts a line written to the tab while it is hidden. A frame without a tab, the main window, counts nothing.
local function countUnread(frame)
    local tab = frame.GetName and frame ~= DEFAULT_CHAT_FRAME and _G[frame:GetName() .. "Tab"]
    if not tab then
        return
    end
    if not badge then
        createBadge()
    end
    if not hookedFrames[frame] then
        hookedFrames[frame] = true
        frame:HookScript("OnShow", function(self)
            if self == badgeFrame then
                unread = 0
                updateBadge()
            end
        end)
        tab:HookScript("OnShow", updateBadge)
        tab:HookScript("OnHide", updateBadge)
    end
    if badgeFrame ~= frame then
        badgeFrame, unread = frame, 0
    end
    if not frame:IsShown() then
        unread = unread + 1
    end
    updateBadge()
end

local function closeDebugTab()
    unread = 0
    updateBadge()
    local frame = findDebugFrame()
    if frame and frame ~= DEFAULT_CHAT_FRAME and FCF_Close then
        FCF_Close(frame)
    end
end

-- The tab follows the setting no matter what changed it, be it /dt debug or Restore defaults.
local debugShown
ns.On("DT_SETTINGS_CHANGED", function()
    if ns.settings.debug == debugShown then
        return
    end
    debugShown = ns.settings.debug
    if debugShown then
        openDebugTab()
    else
        closeDebugTab()
        wipe(ns.db.debugLog)
    end
end)

function ns.Debug(text, ...)
    if ns.settings and ns.settings.debug then
        local line = ("|cff888888%s DT|r %s"):format(date("%H:%M:%S"), text:format(...))
        local frame = debugFrame()
        frame:AddMessage(line)
        countUnread(frame)
        local log = ns.db.debugLog
        log[#log + 1] = line
        if #log > DEBUG_KEEP then
            table.remove(log, 1)
        end
    end
end

-- A /reload empties the chat tabs, so the kept lines go back into the DT Debug tab.
ns.On("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
    if isInitialLogin then
        wipe(ns.db.debugLog)
    elseif isReloadingUi and ns.settings.debug then
        local frame = debugFrame()
        for _, line in ipairs(ns.db.debugLog) do
            frame:AddMessage(line)
        end
    end
end)

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

-- Items asked about before the client knew them. The client loads items all the time for other addons and for the
-- gear of the players around, so only the arrival of these ones fires DT_ITEM_INFO_RECEIVED, the signal to work the
-- values out again and redraw. An item the server can't load comes back as a failure and changes nothing; a redraw
-- for it would only ask for it again and fail again, every second.
local awaited = {}
function ns.AwaitItem(itemId)
    awaited[itemId] = true
end

ns.On("GET_ITEM_INFO_RECEIVED", function(itemId, success)
    if awaited[itemId] and success ~= false then
        awaited[itemId] = nil
        ns.Fire("DT_ITEM_INFO_RECEIVED", itemId)
    end
end)

function ns.ItemQuality(itemId)
    local quality = C_Item.GetItemQualityByID(itemId)
    if quality == nil then
        ns.AwaitItem(itemId)
    end
    return quality
end

function ns.ItemName(itemId)
    local name = C_Item.GetItemInfo(itemId)
    if name then
        return name
    end
    ns.AwaitItem(itemId)
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
    db.mobs = db.mobs or {}
    db.skins = db.skins or {}  -- npc -> { skinned, items }, what skinning its corpses gave
    db.items = db.items or {}
    db.names = db.names or {}
    db.info = db.info or {}
    db.peers = db.peers or {}
    db.refreshed = db.refreshed or {}  -- npc -> time of its last daily question
    db.settings = db.settings or {}
    db.debugLog = db.debugLog or {}  -- the last debug lines of this session, put back after a /reload
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
    elseif msg == "debug" then
        ns.settings.debug = not ns.settings.debug
        ns.Fire("DT_SETTINGS_CHANGED")
        if ns.settings.debug then
            ns.Print("debug messages on, in the DT Debug chat tab. /dt debug again turns them off.")
            ns.Debug("%s", ns.ShareDebugState())
        else
            ns.Print("debug messages off.")
        end
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
