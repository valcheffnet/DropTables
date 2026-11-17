local _, ns = ...

-- Sends this install's counts to bridge players, and in bridge mode collects everyone else's.
-- The hidden channel only carries discovery ("W" who-is-there, "B" bridge here); data and acks go by whisper.
local Wire = ns.Wire
local PREFIX = "DropTables"
local CHANNEL = "DropTablesShare"
local TICK = 1.1
local JOIN_DELAY = 6
local ACK_TIMEOUT = 120
local BRIDGE_TTL = 900
local ANNOUNCE_EVERY = 300
local ACK_FLUSH_EVERY = 3
local FAIL_PAUSE = 30
local SUCCESS = Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success or 0

local bridges = {}     -- whisper target -> GetTime() when last heard
local queue = {}       -- built messages waiting to go out
local inflight = {}    -- seq -> message sent and not yet acknowledged
local keyState = {}    -- bucket key -> { pending = messages carrying it, failed = bool }
local pendingAcks = {} -- bridge mode: sender -> list of sequence numbers to acknowledge
local channelId
local pausedUntil, nextAnnounce, nextAckFlush = 0, 0, 0
local session = { sent = 0, failed = 0, relayed = 0 }

local function bucketKey(npc, bucket)
    return npc .. ":" .. bucket
end

-- dirty[key] holds a change counter, so an acknowledgement only clears a bucket that has not changed since it was sent.
local function markDirty(key)
    local share = ns.db.share
    share.change = share.change + 1
    share.dirty[key] = share.change
end

ns.On("DT_COUNTS_CHANGED", function(npc, bucket)
    markDirty(bucketKey(npc, bucket))
end)

ns.On("DT_INFO_CHANGED", function(npc)
    markDirty("i:" .. npc)
end)

-- The records a dirty key stands for: "<npc>:<bucket>" is a mob's counts, "i:<npc>" its levels and places.
local function recordsFor(key)
    local npc = tonumber(key:match("^i:(%d+)$"))
    if npc then
        local info = ns.db.info[npc]
        return info and Wire.InfoRecords(npc, info)
    end
    local bucket
    npc, bucket = key:match("^(%d+):(%d+)$")
    npc, bucket = tonumber(npc), tonumber(bucket)
    local data = npc and ns.db.mobs[npc] and ns.db.mobs[npc][bucket]
    return data and Wire.BucketRecords(npc, bucket, data)
end

local function messagingBlocked()
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return true
    end
    return IsEncounterInProgress and IsEncounterInProgress()
end

local function send(text, chatType, target)
    if C_ChatInfo.SendAddonMessage(PREFIX, text, chatType, target) == SUCCESS then
        return true
    end
    session.failed = session.failed + 1
    return false
end

local function pickBridge()
    local now, best, bestHeard = GetTime(), nil, 0
    for name, heard in pairs(bridges) do
        if now - heard > BRIDGE_TTL then
            bridges[name] = nil
        elseif heard > bestHeard then
            best, bestHeard = name, heard
        end
    end
    return best
end

local function newMessage()
    local share = ns.db.share
    share.seq = share.seq + 1
    return { seq = share.seq, text = Wire.Header(ns.db.installId, share.seq), keys = {} }
end

local function addKey(message, key, version)
    if not message.keys[key] then
        message.keys[key] = version
        local state = keyState[key]
        if not state then
            state = { pending = 0, failed = false }
            keyState[key] = state
        end
        state.pending = state.pending + 1
    end
end

-- Packs every dirty bucket that is not already on its way into as few messages as fit.
local function buildQueue()
    local share = ns.db.share
    local message
    for key, version in pairs(share.dirty) do
        if not keyState[key] then
            local records = recordsFor(key)
            if records then
                for _, record in ipairs(records) do
                    if message and #message.text + 1 + #record > Wire.MAX_MESSAGE then
                        table.insert(queue, message)
                        message = nil
                    end
                    if message then
                        message.text = message.text .. ";" .. record
                    else
                        message = newMessage()
                        message.text = message.text .. record
                    end
                    addKey(message, key, version)
                end
            else
                share.dirty[key] = nil
            end
        end
    end
    if message then
        table.insert(queue, message)
    end
end

local function settle(message, delivered)
    local dirty = ns.db.share.dirty
    for key, version in pairs(message.keys) do
        local state = keyState[key]
        state.pending = state.pending - 1
        state.failed = state.failed or not delivered
        if state.pending == 0 then
            if not state.failed and dirty[key] == version then
                dirty[key] = nil
            end
            keyState[key] = nil
        end
    end
end

local function acknowledge(seq)
    local message = inflight[seq]
    if message then
        inflight[seq] = nil
        settle(message, true)
    end
end

local function clientTick(now)
    for seq, message in pairs(inflight) do
        if now - message.sentAt > ACK_TIMEOUT then
            inflight[seq] = nil
            settle(message, false)
        end
    end
    if not ns.settings.shareData or now < pausedUntil or messagingBlocked() then
        return
    end
    local bridge = pickBridge()
    if not bridge then
        return
    end
    if #queue == 0 then
        buildQueue()
    end
    local message = queue[1]
    if not message then
        return
    end
    if send(message.text, "WHISPER", bridge) then
        table.remove(queue, 1)
        message.sentAt = now
        inflight[message.seq] = message
        session.sent = session.sent + 1
    else
        pausedUntil = now + FAIL_PAUSE
    end
end

local function child(parent, key, fresh)
    local value = parent[key]
    if not value then
        value = fresh
        parent[key] = value
    end
    return value
end

-- Relay entries mirror the sender's own tables: mobs[npc][bucket] and info[npc].
local function storeRecords(installId, records)
    local entry = child(ns.db.relay, installId, { mobs = {}, info = {} })
    entry.info = entry.info or {}
    entry.t = time()
    for _, record in ipairs(records) do
        local kind = record.kind
        if kind == "M" or kind == "I" then
            local data = child(child(entry.mobs, record.npc, {}), record.bucket, { items = {} })
            if kind == "M" then
                data.kills, data.lootable, data.opened = record.kills, record.lootable, record.opened
                data.money = { drops = record.moneyDrops, copper = record.copper, min = record.moneyMin, max = record.moneyMax }
            else
                data.items[record.item] = { drops = record.drops, qty = record.qty, min = record.min, max = record.max }
            end
        else
            local info = child(entry.info, record.npc, { maps = {} })
            if kind == "L" then
                info.minLevel, info.maxLevel = record.minLevel, record.maxLevel
            else
                local place = child(info.maps, record.map, { kills = 0, cells = {} })
                if kind == "Z" then
                    place.kills = record.kills
                else
                    place.cells[record.cell] = record.kills
                end
            end
        end
    end
    session.relayed = session.relayed + #records
end

local function flushAcks()
    for sender, seqs in pairs(pendingAcks) do
        local text = "A|"
        for _, seq in ipairs(seqs) do
            local part = Wire.EncodeNumber(seq)
            if #text + #part + 1 > Wire.MAX_MESSAGE then
                send(text, "WHISPER", sender)
                text = "A|"
            end
            text = text .. (text == "A|" and "" or ",") .. part
        end
        send(text, "WHISPER", sender)
    end
    wipe(pendingAcks)
end

local function announce()
    if channelId then
        send("B|" .. ns.db.installId, "CHANNEL", channelId)
    end
end

local function bridgeTick(now)
    if messagingBlocked() then
        return
    end
    if now >= nextAnnounce then
        announce()
        nextAnnounce = now + ANNOUNCE_EVERY
    end
    if now >= nextAckFlush then
        flushAcks()
        nextAckFlush = now + ACK_FLUSH_EVERY
    end
end

local function tick()
    local now = GetTime()
    if ns.settings.bridgeMode then
        bridgeTick(now)
    else
        clientTick(now)
    end
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, chatType, sender)
    if prefix ~= PREFIX or ns.IsSecret(text) or ns.IsSecret(sender) then
        return
    end
    local kind = text:sub(1, 2)
    if kind == "B|" or kind == "W|" then
        if text:sub(3) == ns.db.installId then
            return
        end
        if kind == "B|" then
            bridges[sender] = GetTime()
        elseif ns.settings.bridgeMode then
            send("B|" .. ns.db.installId, "WHISPER", sender)
        end
    elseif kind == "A|" then
        if chatType == "WHISPER" then
            for seq in text:sub(3):gmatch("[0-9a-z]+") do
                acknowledge(tonumber(seq, 36))
            end
        end
    elseif ns.settings.bridgeMode and chatType == "WHISPER" then
        local installId, seq, records = Wire.Decode(text)
        if installId and installId ~= ns.db.installId then
            storeRecords(installId, records)
            pendingAcks[sender] = pendingAcks[sender] or {}
            table.insert(pendingAcks[sender], seq)
        end
    end
end)

local function joinChannel()
    if not (ns.settings.shareData or ns.settings.bridgeMode) then
        return
    end
    JoinTemporaryChannel(CHANNEL)
    C_Timer.After(2, function()
        local id = GetChannelName(CHANNEL)
        channelId = id and id > 0 and id or nil
        if not channelId then
            return
        end
        if ns.settings.bridgeMode then
            nextAnnounce = 0
        else
            send("W|" .. ns.db.installId, "CHANNEL", channelId)
        end
    end)
end

ns.On("DT_READY", function()
    local db = ns.db
    db.relay = db.relay or {}
    if not db.share then
        -- First run with sharing: everything collected so far still has to go out.
        db.share = { dirty = {}, seq = 0, change = 0 }
        for npc, mob in pairs(db.mobs) do
            for bucket in pairs(mob) do
                markDirty(bucketKey(npc, bucket))
            end
        end
    end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.After(JOIN_DELAY, joinChannel)
    C_Timer.NewTicker(TICK, tick)
end)

function ns.SetBridgeMode(on)
    ns.settings.bridgeMode = on
    wipe(queue)
    if on then
        nextAnnounce = 0
        if not channelId then
            joinChannel()
        end
    end
end

function ns.ShareStatus()
    local waiting, bridgeCount, relayInstalls = 0, 0, 0
    for _ in pairs(ns.db.share.dirty) do
        waiting = waiting + 1
    end
    pickBridge()
    for _ in pairs(bridges) do
        bridgeCount = bridgeCount + 1
    end
    for _ in pairs(ns.db.relay) do
        relayInstalls = relayInstalls + 1
    end
    if ns.settings.bridgeMode then
        return ("Bridge mode: %d records received this session, data from %d installs stored."):format(
            session.relayed, relayInstalls)
    end
    return ("Sharing %s: %d mob tables waiting, %d bridges online, %d messages sent this session, %d failed."):format(
        ns.settings.shareData and "on" or "off", waiting, bridgeCount, session.sent, session.failed)
end
