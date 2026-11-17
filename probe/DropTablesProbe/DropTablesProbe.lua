-- Test-only probe: records what the Forever client exposes for loot, kills, secret values and addon messages.
-- Everything goes to the DropTablesProbeDB saved variable, which is written on /reload or logout.

local ADDON = ...
local PREFIX = "DTProbe"
local CHANNEL_NAME = "DropTablesProbe"
local LOG_LIMIT = 3000
local PAYLOAD_LIMIT = 100

local db
local lastSpell

local API_PATHS = {
    "GetNumLootItems", "GetLootSlotInfo", "GetLootSlotLink", "GetLootSlotType", "GetLootSourceInfo", "IsFishingLoot",
    "GetLootMethod", "C_PartyInfo.GetLootMethod",
    "C_Item.GetItemInfoInstant", "GetItemInfoInstant",
    "C_ChatInfo.RegisterAddonMessagePrefix", "C_ChatInfo.SendAddonMessage", "C_ChatInfo.SendAddonMessageLogged",
    "C_ChatInfo.InChatMessagingLockdown", "JoinTemporaryChannel", "JoinChannelByName", "GetChannelName",
    "issecretvalue", "canaccesssecrets", "IsEncounterInProgress", "CombatLogGetCurrentEventInfo",
    "C_EncodingUtil.SerializeCBOR", "C_EncodingUtil.CompressString",
    "C_EncounterJournal", "EJ_GetInstanceInfo",
    "TooltipDataProcessor.AddTooltipPostCall", "C_NamePlate.GetNamePlateForUnit",
    "Settings.RegisterAddOnCategory", "TargetFrame",
}

-- Events that may or may not exist on Forever; registration is attempted and the outcome recorded.
-- The blocked-action events come first so they catch a forbidden registration further down the list.
local OPTIONAL_EVENTS = {
    "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED",
    "PARTY_KILL", "UNIT_DIED", "ENCOUNTER_START", "ENCOUNTER_END",
    "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "LOOT_SLOT_CLEARED", "CHAT_MSG_LOOT", "CHAT_MSG_MONEY",
    "CHAT_MSG_ADDON", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED",
    "UPDATE_MOUSEOVER_UNIT", "UNIT_HEALTH", "UNIT_FLAGS", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
}

local function say(msg)
    print("|cff66ccffDropTablesProbe|r " .. msg)
end

local function clean(v)
    if issecretvalue and issecretvalue(v) then
        return "<secret>"
    end
    local tv = type(v)
    if tv == "string" or tv == "number" or tv == "boolean" or tv == "nil" then
        return v
    end
    return tostring(v)
end

local function packed(...)
    return { n = select("#", ...), ... }
end

-- Calls fn and returns its results with secrets replaced, or { error = message }.
local function probe(fn, ...)
    local r = packed(pcall(fn, ...))
    if not r[1] then
        return { error = tostring(r[2]) }
    end
    local out = { n = r.n - 1 }
    for i = 2, r.n do
        out[i - 1] = clean(r[i])
    end
    return out
end

local function one(fn, ...)
    local r = probe(fn, ...)
    if r.error then
        return "error: " .. r.error
    end
    return r[1]
end

local function readable(guid)
    return type(guid) == "string" and guid ~= "<secret>" and guid:sub(1, 6) ~= "error:"
end

local function bump(key)
    db.counts[key] = (db.counts[key] or 0) + 1
    return db.counts[key]
end

local function log(kind, data)
    data = data or {}
    data.kind = kind
    data.t = time()
    data.combat = InCombatLockdown()
    data.instance = (select(2, IsInInstance()))
    table.insert(db.log, data)
    if #db.log > LOG_LIMIT then
        table.remove(db.log, 1)
    end
end

local function resolve(path)
    local t = _G
    for part in path:gmatch("[^.]+") do
        if type(t) ~= "table" then
            return nil
        end
        t = t[part]
    end
    return t
end

local function recordEnvironment()
    db.env = {
        build = probe(GetBuildInfo),
        projectId = WOW_PROJECT_ID,
        api = {},
    }
    for _, path in ipairs(API_PATHS) do
        db.env.api[path] = type(resolve(path))
    end
end

local function lootMethod()
    if C_PartyInfo and C_PartyInfo.GetLootMethod then
        return probe(C_PartyInfo.GetLootMethod)
    elseif GetLootMethod then
        return probe(GetLootMethod)
    end
    return { error = "no loot method API" }
end

local function itemClass(link)
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not link or not getInfo then
        return nil
    end
    local r = probe(getInfo, link)
    return r[6]
end

-- Marks a creature as seen dead so looted corpses can be compared against detected kills.
local function checkDead(unit, via)
    local dead = one(UnitIsDead, unit)
    if dead ~= true then
        if dead == "<secret>" then
            bump("deadSecret:" .. via)
        end
        return
    end
    local guid = one(UnitGUID, unit)
    if not readable(guid) then
        bump("deadGuidUnreadable:" .. via)
        return
    end
    if db.deaths[guid] then
        return
    end
    local kind, _, _, _, _, npcId = strsplit("-", guid)
    if kind ~= "Creature" then
        return
    end
    db.deaths[guid] = {
        npc = tonumber(npcId),
        via = via,
        tapDenied = one(UnitIsTapDenied, unit),
        combat = InCombatLockdown(),
        t = time(),
    }
    bump("deaths")
    bump("deathsVia:" .. via)
end

local function snapshotUnit(unit, via)
    local key = (InCombatLockdown() and "unitSnapshotsCombat:" or "unitSnapshots:") .. via
    if bump(key) > 20 then
        return
    end
    log("unit", {
        via = via,
        guid = one(UnitGUID, unit),
        name = one(UnitName, unit),
        dead = one(UnitIsDead, unit),
        tapDenied = one(UnitIsTapDenied, unit),
        isPlayer = one(UnitIsPlayer, unit),
        level = one(UnitLevel, unit),
    })
end

local function recordLoot(autoLoot, fromItem)
    local count = GetNumLootItems()
    local entry = {
        auto = clean(autoLoot),
        fromItem = clean(fromItem),
        slots = count,
        group = GetNumGroupMembers(),
        raid = IsInRaid(),
        method = lootMethod(),
        fishing = IsFishingLoot and one(IsFishingLoot) or nil,
        items = {},
        seenDead = false,
    }
    if lastSpell and GetTime() - lastSpell.at < 3 then
        entry.lastSpell = lastSpell.id
    end
    for i = 1, count do
        local link = one(GetLootSlotLink, i)
        local sources = probe(GetLootSourceInfo, i)
        for s = 1, sources.n or 0, 2 do
            if readable(sources[s]) and db.deaths[sources[s]] then
                entry.seenDead = true
            end
        end
        entry.items[i] = {
            info = probe(GetLootSlotInfo, i),
            link = link,
            slotType = one(GetLootSlotType, i),
            classId = type(link) == "string" and itemClass(link) or nil,
            sources = sources,
        }
    end
    if count == 0 then
        bump("emptyOpens")
    else
        bump("lootOpens")
        if entry.seenDead then
            bump("lootOpensWithSeenDeath")
        end
    end
    log("loot", entry)
end

local function joinChannel()
    local joined = probe(JoinTemporaryChannel, CHANNEL_NAME)
    C_Timer.After(2, function()
        log("channelJoin", { join = joined, id = probe(GetChannelName, CHANNEL_NAME) })
    end)
end

local function send(chatType, target)
    local result = probe(C_ChatInfo.SendAddonMessage, PREFIX, "test:" .. chatType .. ":" .. time(), chatType, target)
    log("commSend", {
        chatType = chatType,
        target = target,
        result = result,
        encounter = IsEncounterInProgress and one(IsEncounterInProgress) or nil,
        lockdown = C_ChatInfo.InChatMessagingLockdown and probe(C_ChatInfo.InChatMessagingLockdown) or nil,
    })
    local code = result.error or tostring(result[result.n or 1])
    say(chatType .. " -> " .. code)
end

local function commTest()
    send("WHISPER", UnitName("player"))
    if IsInGuild() then
        send("GUILD")
    end
    if IsInGroup() then
        send("PARTY")
    end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        send("INSTANCE_CHAT")
    end
    local id = GetChannelName(CHANNEL_NAME)
    if id and id > 0 then
        send("CHANNEL", id)
    else
        say("not in channel " .. CHANNEL_NAME .. ", run /dtp join first")
    end
end

local strip = CreateFrame("Frame", "DropTablesProbeStrip", UIParent)
strip:SetSize(6 * 26, 24)
strip:Hide()

local function buildStrip()
    if TargetFrame then
        strip:SetPoint("TOPLEFT", TargetFrame, "BOTTOMLEFT", 40, 4)
    else
        strip:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
    for i = 1, 6 do
        local button = CreateFrame("Button", nil, strip)
        button:SetSize(24, 24)
        button:SetPoint("LEFT", (i - 1) * 26, 0)
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        local label = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        label:SetPoint("BOTTOMRIGHT", 1, -1)
        label:SetText(i * 5 .. "%")
        button:SetScript("OnClick", function()
            log("iconClick", { index = i })
            say("icon " .. i .. " clicked" .. (InCombatLockdown() and " (in combat)" or ""))
        end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Drop Tables probe icon " .. i)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
    end
end

local function updateStrip()
    local exists = one(UnitExists, "target")
    local isPlayer = one(UnitIsPlayer, "target")
    local ok = pcall(strip.SetShown, strip, exists == true and isPlayer ~= true)
    if not ok then
        bump("stripShowFailed")
    elseif InCombatLockdown() then
        bump("stripUpdatesInCombat")
    end
end

local frame = CreateFrame("Frame")
local handlers = {}

function handlers.PLAYER_ENTERING_WORLD(isLogin, isReload)
    if isLogin or isReload then
        C_Timer.After(5, joinChannel)
    end
end

function handlers.LOOT_READY(autoLoot)
    log("lootReady", { auto = clean(autoLoot), slots = GetNumLootItems() })
end

function handlers.LOOT_OPENED(autoLoot, fromItem)
    recordLoot(autoLoot, fromItem)
end

function handlers.LOOT_CLOSED()
    log("lootClosed")
end

function handlers.CHAT_MSG_LOOT(text)
    if bump("chatLoot") <= 200 then
        log("chatLoot", { text = clean(text) })
    end
end

function handlers.CHAT_MSG_ADDON(prefix, text, chatType, sender, target, zoneChannelId, localId, channelName)
    if prefix ~= PREFIX then
        return
    end
    log("commReceive", {
        text = clean(text), chatType = clean(chatType), sender = clean(sender),
        localId = clean(localId), channelName = clean(channelName),
    })
    say("received " .. tostring(clean(chatType)) .. " from " .. tostring(clean(sender)))
end

function handlers.PLAYER_TARGET_CHANGED()
    snapshotUnit("target", "target")
    checkDead("target", "target")
    updateStrip()
end

function handlers.UPDATE_MOUSEOVER_UNIT()
    snapshotUnit("mouseover", "mouseover")
    checkDead("mouseover", "mouseover")
end

function handlers.NAME_PLATE_UNIT_ADDED(unit)
    snapshotUnit(unit, "nameplate")
    checkDead(unit, "nameplate")
end

function handlers.NAME_PLATE_UNIT_REMOVED(unit)
    checkDead(unit, "nameplateRemoved")
end

function handlers.UNIT_HEALTH(unit)
    if unit == "target" or unit:find("^nameplate") then
        checkDead(unit, unit == "target" and "targetHealth" or "nameplateHealth")
    end
end

handlers.UNIT_FLAGS = handlers.UNIT_HEALTH

function handlers.UNIT_SPELLCAST_SUCCEEDED(unit, castGuid, spellId)
    lastSpell = { id = clean(spellId), at = GetTime() }
end

local function logPayload(event, ...)
    if bump("payload:" .. event) > PAYLOAD_LIMIT then
        return
    end
    local args = packed(...)
    local out = { event = event, n = args.n }
    for i = 1, args.n do
        out[i] = clean(args[i])
    end
    log("payload", out)
end

for _, event in ipairs({ "PARTY_KILL", "UNIT_DIED", "ENCOUNTER_START", "ENCOUNTER_END" }) do
    handlers[event] = function(...)
        logPayload(event, ...)
    end
end

local function onBlocked(event, addon, fn)
    if addon ~= ADDON then
        return
    end
    fn = tostring(clean(fn))
    db.blocked[fn] = (db.blocked[fn] or 0) + 1
    log("blocked", { event = event, fn = fn })
    say(event .. ": " .. fn)
end

for _, event in ipairs({ "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }) do
    handlers[event] = function(...)
        onBlocked(event, ...)
    end
end

function handlers.PLAYER_REGEN_DISABLED()
    log("combatStart")
end

function handlers.PLAYER_REGEN_ENABLED()
    log("combatEnd")
end

local function registerAll()
    db.events = {}
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    for _, event in ipairs(OPTIONAL_EVENTS) do
        local ok, err = pcall(frame.RegisterEvent, frame, event)
        db.events[event] = ok and "ok" or tostring(err)
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then
            return
        end
        DropTablesProbeDB = DropTablesProbeDB or {}
        db = DropTablesProbeDB
        db.log = db.log or {}
        db.counts = db.counts or {}
        db.deaths = db.deaths or {}
        db.blocked = db.blocked or {}
        recordEnvironment()
        registerAll()
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        buildStrip()
        frame:UnregisterEvent("ADDON_LOADED")
        return
    end
    local handler = handlers[event]
    if handler then
        handler(...)
    end
end)
frame:RegisterEvent("ADDON_LOADED")

local function status()
    local c = db.counts
    say(("loot opens %d (with kill seen before: %d), empty opens %d, kills seen %d"):format(
        c.lootOpens or 0, c.lootOpensWithSeenDeath or 0, c.emptyOpens or 0, c.deaths or 0))
    local failed = {}
    for event, result in pairs(db.events) do
        if result ~= "ok" then
            table.insert(failed, event)
        end
    end
    table.sort(failed)
    say("events not available: " .. (#failed > 0 and table.concat(failed, ", ") or "none"))
    local blocked = {}
    for fn, n in pairs(db.blocked) do
        table.insert(blocked, fn .. " x" .. n)
    end
    say("blocked actions: " .. (#blocked > 0 and table.concat(blocked, ", ") or "none"))
    say("commands: /dtp comm, /dtp join, /dtp leave, /dtp reset")
end

SLASH_DROPTABLESPROBE1 = "/dtp"
SlashCmdList.DROPTABLESPROBE = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "comm" then
        commTest()
    elseif msg == "join" then
        joinChannel()
        say("joining " .. CHANNEL_NAME)
    elseif msg == "leave" then
        LeaveChannelByName(CHANNEL_NAME)
        say("left " .. CHANNEL_NAME)
    elseif msg == "reset" then
        wipe(db.log)
        wipe(db.counts)
        wipe(db.deaths)
        wipe(db.blocked)
        recordEnvironment()
        say("log cleared")
    else
        status()
    end
end
