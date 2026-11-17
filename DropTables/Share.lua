local _, ns = ...

-- Sharing between players. A player who targets a mob with little data asks on a hidden channel and says which
-- installs' counts they already hold; players with other or bigger counts whisper them back:
--   Q|<asking install id>|<npc>|<held>   held: "<first 6 hex of an install id><its kills>" joined by ","
--   D|<origin install id>|<records of one mob>   (whisper to the asker)
--   C|<asking install id>|<npc>                  (channel: the asker has enough, pending answers are dropped)
-- The asker collects until it holds SAMPLE_TARGET looted corpses of the mob, or MAX_ORIGINS_PER_QUESTION installs
-- answered; bigger sources answer sooner, so one or two big ones often end a question before small ones send.
-- Group members also send each other their own counts once a minute, over the group's addon channel:
--   D|<own install id>|<records of one mob>      (PARTY, RAID or INSTANCE_CHAT)
-- Counts are kept per origin install and replaced, never added, so the same counts arriving twice change nothing.
-- Known trade-off: two members who see the same kill both count it, so each one's rates stay right but the kill
-- totals of party kills ("312 by 7 players") come out too high. Telling the copies apart needs corpse GUIDs that
-- match across clients, which is not confirmed for Forever.
local Wire = ns.Wire
local PREFIX = "DropTables"
local CHANNEL = "DropTablesShare"
local TICK = 1.1
local JOIN_DELAY = 6
local MAX_SOURCES = 12      -- other installs kept per mob
local SAMPLE_TARGET = 100   -- looted corpses of a mob (own plus other installs') worth asking for
local MAX_ORIGINS_PER_QUESTION = 10
local QUERY_COOLDOWN = 600  -- seconds before the same mob is asked about again
local QUERY_GAP = 5         -- seconds between any two questions
local ANSWER_WINDOW = 120   -- whispered counts are taken only this long after asking about that mob
local ANSWER_ORIGINS = 3    -- installs one player whispers back per question, the biggest first
-- Answer delay: BIG_DELAY for a source with SAMPLE_TARGET corpses or more, growing to BIG_DELAY + SIZE_DELAY for one
-- with almost none, plus up to JITTER so equal sizes do not collide.
local BIG_DELAY, SIZE_DELAY, JITTER = 0.3, 3, 0.7
local NEW_ORIGINS_PER_SENDER = 3 -- installs the player has never seen that one sender may bring per day
local HELD_PREFIX = 6
local QUEUE_TTL = 60
local CHANNEL_PER_TICK, WHISPERS_PER_TICK, GROUP_PER_TICK = 1, 4, 1
local GROUP_INTERVAL = 60   -- seconds between two sends of the player's changed counts to the group
local GROUP_FLUSH_CAP = 10  -- messages per group send; mobs that do not fit wait for the next one
local SUCCESS = Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success or 0

local channelId
local queue = {}     -- { text, at, chatType, target } waiting to go out
local planned = {}   -- "<asker>:<npc>" -> { npc, target, due = { [origin] = time } } answers waiting to go out
local asked = {}     -- npc -> { at, origins = { [origin] = true }, count, calledOff } of the player's last question
local lastQuery = -QUERY_GAP
local knownOrigins   -- set of every install id the player holds counts of
local newBySender = {} -- sender -> { day, count } of installs that sender brought; this session only, never saved
local groupDirty = {}  -- npc -> true: the player's own counts changed since the last group send
local lastGroupSend = 0
local session = { queries = 0, answers = 0, received = 0, refused = 0, failed = 0, groupSent = 0, groupReceived = 0 }

-- The player's own counts of a mob in the same shape as another install's: buckets, levels, kills per map.
function ns.OwnSource(npc)
    local own = ns.db.mobs[npc]
    if not own then
        return nil
    end
    local info = ns.db.info[npc]
    local maps = {}
    for mapId, place in pairs(info and info.maps or {}) do
        maps[mapId] = place.kills
    end
    return {
        origin = ns.db.installId, buckets = own, maps = maps,
        minLevel = info and info.minLevel, maxLevel = info and info.maxLevel,
    }
end

-- Every install's counts the player holds for a mob, own included, the most kills first.
local function sources(npc)
    local list = { ns.OwnSource(npc) }
    for origin, peer in pairs(ns.db.peers[npc] or {}) do
        table.insert(list, {
            origin = origin, buckets = peer.buckets, maps = peer.maps,
            minLevel = peer.minLevel, maxLevel = peer.maxLevel,
        })
    end
    for _, source in ipairs(list) do
        source.kills = ns.SumBuckets(source.buckets, "kills")
    end
    table.sort(list, function(a, b)
        if a.kills ~= b.kills then
            return a.kills > b.kills
        end
        return a.origin < b.origin
    end)
    return list
end

local function pack(header, records)
    local texts, text = {}, nil
    for _, record in ipairs(records) do
        if text and #text + 1 + #record > Wire.MAX_MESSAGE then
            table.insert(texts, text)
            text = nil
        end
        text = text and (text .. ";" .. record) or (header .. record)
    end
    table.insert(texts, text)
    return texts
end

local function enqueue(text, chatType, target)
    table.insert(queue, { text = text, at = GetTime(), chatType = chatType, target = target })
end

-- Looted corpses of a mob the player holds: their own plus every other install's.
local function sampleOf(npc)
    local own = ns.db.mobs[npc]
    local opened = own and ns.SumBuckets(own, "opened") or 0
    for _, peer in pairs(ns.db.peers[npc] or {}) do
        opened = opened + ns.SumBuckets(peer.buckets, "opened")
    end
    return opened
end

local function wantsData(npc)
    return sampleOf(npc) < SAMPLE_TARGET
end

-- The question with as many held installs as fit, the biggest first.
local function question(npc)
    local text = "Q|" .. ns.db.installId .. "|" .. Wire.EncodeNumber(npc) .. "|"
    local first = true
    for _, source in ipairs(sources(npc)) do
        if source.origin ~= ns.db.installId then
            local held = source.origin:sub(1, HELD_PREFIX) .. Wire.EncodeNumber(source.kills)
            if #text + #held + 1 > Wire.MAX_MESSAGE then
                break
            end
            text = text .. (first and "" or ",") .. held
            first = false
        end
    end
    return text
end

local function ask(npc)
    local now = GetTime()
    if not channelId or not ns.settings.shareData or now - lastQuery < QUERY_GAP
        or (asked[npc] and now - asked[npc].at < QUERY_COOLDOWN) or not wantsData(npc) then
        return
    end
    asked[npc], lastQuery = { at = now, origins = {}, count = 0 }, now
    enqueue(question(npc), "CHANNEL", channelId)
    session.queries = session.queries + 1
end

-- Picks up to ANSWER_ORIGINS installs the asker lacks or holds with fewer kills.
local function planAnswer(asker, npc, heldText, sender)
    if not ns.settings.shareData then
        return
    end
    local held = {}
    for entry in heldText:gmatch("[^,]+") do
        local prefix, kills = entry:match("^(%x%x%x%x%x%x)([0-9a-z]+)$")
        if prefix then
            held[prefix] = Wire.ReadNumber(kills)
        end
    end
    local due, count = {}, 0
    for _, source in ipairs(sources(npc)) do
        local theirs = held[source.origin:sub(1, HELD_PREFIX)]
        if source.origin ~= asker and (not theirs or theirs < source.kills) then
            local size = math.min(ns.SumBuckets(source.buckets, "opened"), SAMPLE_TARGET) / SAMPLE_TARGET
            due[source.origin] = GetTime() + BIG_DELAY + SIZE_DELAY * (1 - size) + math.random() * JITTER
            count = count + 1
            if count == ANSWER_ORIGINS then
                break
            end
        end
    end
    if count > 0 then
        planned[asker .. ":" .. npc] = { npc = npc, target = sender, due = due }
    end
end

local function sendDueAnswers(now)
    for key, plan in pairs(planned) do
        for _, source in ipairs(sources(plan.npc)) do
            local due = plan.due[source.origin]
            if due and now >= due then
                plan.due[source.origin] = nil
                local records = Wire.SourceRecords(plan.npc, source, ns.db.names[plan.npc])
                for _, text in ipairs(pack("D|" .. source.origin .. "|", records)) do
                    enqueue(text, "WHISPER", plan.target)
                end
                session.answers = session.answers + 1
            end
        end
        if not next(plan.due) then
            planned[key] = nil
        end
    end
end

local function rememberItem(itemId)
    if not ns.db.items[itemId] then
        ns.db.items[itemId] = { quality = C_Item.GetItemQualityByID(itemId) }
        if C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemId)
        end
    end
end

-- Keeps the MAX_SOURCES installs updated most recently. Size plays no part, so big made-up counts do not push
-- real ones out.
local function trim(peers)
    local count, oldest = 0, nil
    for origin, peer in pairs(peers) do
        count = count + 1
        local old = oldest and peers[oldest]
        if not old or peer.t < old.t or (peer.t == old.t and origin < oldest) then
            oldest = origin
        end
    end
    if count > MAX_SOURCES then
        peers[oldest] = nil
        trim(peers)
    end
end

local function newBucket()
    return { kills = 0, lootable = 0, opened = 0, items = {}, money = { drops = 0, copper = 0 } }
end

local function store(origin, npc, records)
    knownOrigins[origin] = true
    local peers = ns.db.peers[npc]
    if not peers then
        peers = {}
        ns.db.peers[npc] = peers
    end
    local peer = peers[origin]
    if not peer then
        peer = { buckets = {}, maps = {} }
        peers[origin] = peer
    end
    peer.t = time()
    for _, r in ipairs(records) do
        if r.kind == "M" or r.kind == "I" then
            local data = peer.buckets[r.bucket]
            if not data then
                data = newBucket()
                peer.buckets[r.bucket] = data
            end
            if r.kind == "M" then
                data.kills, data.lootable, data.opened = r.kills, r.lootable, r.opened
                data.money = { drops = r.moneyDrops, copper = r.copper, min = r.moneyMin, max = r.moneyMax }
            else
                data.items[r.item] = { drops = r.drops, qty = r.qty, min = r.min, max = r.max }
                rememberItem(r.item)
            end
        elseif r.kind == "L" then
            peer.minLevel, peer.maxLevel = r.minLevel, r.maxLevel
        elseif r.kind == "Z" then
            peer.maps[r.map] = r.kills
        elseif r.kind == "N" and not ns.db.names[npc] then
            ns.db.names[npc] = r.name
        end
    end
    trim(peers)
end

-- A sender (a name the server vouches for) may bring only a few installs the player has never seen per day, so
-- one player cannot fill the tables with made-up installs. Updates of known installs are taken from anyone.
local function allowNewOrigin(sender)
    local day = math.floor(time() / 86400)
    local entry = newBySender[sender]
    if not entry or entry.day ~= day then
        entry = { day = day, count = 0 }
        newBySender[sender] = entry
    end
    if entry.count >= NEW_ORIGINS_PER_SENDER then
        return false
    end
    entry.count = entry.count + 1
    return true
end

local function messagingBlocked()
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return true
    end
    return IsEncounterInProgress and IsEncounterInProgress()
end

-- The call-off skips the queue: every moment it waits, another player may start whispering.
local function callOff(npc)
    local text = "C|" .. ns.db.installId .. "|" .. Wire.EncodeNumber(npc)
    if not channelId or messagingBlocked()
        or C_ChatInfo.SendAddonMessage(PREFIX, text, "CHANNEL", channelId) ~= SUCCESS then
        enqueue(text, "CHANNEL", channelId)
    end
end

-- Origin, npc and records of a well-formed answer about one mob of another install, or nil.
local function decodeAnswer(text)
    local origin, body = text:match("^D|(%x+)|(.+)$")
    if not origin or #origin ~= 16 or origin == ns.db.installId then
        return nil
    end
    local records = Wire.DecodeRecords(body)
    if not records then
        return nil
    end
    local npc = records[1].npc
    for _, record in ipairs(records) do
        if record.npc ~= npc then
            return nil
        end
    end
    return origin, npc, records
end

local function receive(text, sender)
    local origin, npc, records = decodeAnswer(text)
    if not origin then
        return
    end
    local question = asked[npc]
    if not question or GetTime() - question.at > ANSWER_WINDOW then
        return
    end
    -- After the call-off only the rest of answers already under way are taken.
    if question.calledOff and not question.origins[origin] then
        return
    end
    if not knownOrigins[origin] and not allowNewOrigin(sender) then
        session.refused = session.refused + 1
        return
    end
    store(origin, npc, records)
    session.received = session.received + 1
    if not question.origins[origin] then
        question.origins[origin] = true
        question.count = question.count + 1
    end
    if not question.calledOff and (sampleOf(npc) >= SAMPLE_TARGET or question.count >= MAX_ORIGINS_PER_QUESTION) then
        question.calledOff = true
        callOff(npc)
    end
    ns.Fire("DT_DATA_CHANGED", npc)
end

-- The sender of a group message is checked against the group: only members' counts are taken this way.
-- Senders come as "Name" or "Name-Realm".
local function inGroup(sender)
    local short = sender:match("^[^-]+")
    local raid = IsInRaid()
    for i = 1, GetNumGroupMembers() do
        local name, realm = UnitName(raid and ("raid" .. i) or ("party" .. i))
        if name and (name == sender or name == short or (realm and realm ~= "" and name .. "-" .. realm == sender)) then
            return true
        end
    end
    return false
end

-- Group members are taken without a question and without the limit on new installs: the server vouches that the
-- sender is in the group, and one group brings only a handful of installs.
local function receiveGroup(text, sender)
    local origin, npc, records = decodeAnswer(text)
    if not origin or not inGroup(sender) then
        return
    end
    store(origin, npc, records)
    session.groupReceived = session.groupReceived + 1
    ns.Fire("DT_DATA_CHANGED", npc)
end

local function groupChatType()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    end
    return IsInRaid() and "RAID" or "PARTY"
end

-- Queues the player's own counts of the mobs that changed since the last group send, up to GROUP_FLUSH_CAP
-- messages. Only the player's own install goes out this way; counts kept from others stay home.
local function flushGroup()
    local chatType, used = groupChatType(), 0
    for npc in pairs(groupDirty) do
        local source = ns.OwnSource(npc)
        local texts = source and pack("D|" .. ns.db.installId .. "|", Wire.SourceRecords(npc, source, ns.db.names[npc]))
            or {}
        -- A mob too big for one send still goes out when it comes first.
        if used > 0 and used + #texts > GROUP_FLUSH_CAP then
            break
        end
        for _, text in ipairs(texts) do
            enqueue(text, chatType)
        end
        used = used + #texts
        groupDirty[npc] = nil
    end
    session.groupSent = session.groupSent + used
end

local BUDGET_KEY = { CHANNEL = "CHANNEL", WHISPER = "WHISPER", PARTY = "GROUP", RAID = "GROUP", INSTANCE_CHAT = "GROUP" }

-- Sends up to one channel message, one group message and a few whispers per tick; whispers outside instances have
-- no addon throttle.
local function tick()
    local now = GetTime()
    sendDueAnswers(now)
    if messagingBlocked() then
        return
    end
    if now - lastGroupSend >= GROUP_INTERVAL then
        lastGroupSend = now
        if ns.settings.shareData and IsInGroup() and next(groupDirty) then
            flushGroup()
        end
    end
    local budget = { CHANNEL = CHANNEL_PER_TICK, WHISPER = WHISPERS_PER_TICK, GROUP = GROUP_PER_TICK }
    local i = 1
    while queue[i] do
        local message = queue[i]
        local key = BUDGET_KEY[message.chatType]
        if now - message.at > QUEUE_TTL then
            table.remove(queue, i)
        elseif budget[key] > 0 and (message.chatType ~= "CHANNEL" or channelId) then
            if C_ChatInfo.SendAddonMessage(PREFIX, message.text, message.chatType, message.target) == SUCCESS then
                table.remove(queue, i)
                budget[key] = budget[key] - 1
            else
                session.failed = session.failed + 1
                budget[key] = 0
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

ns.On("DT_COUNTS_CHANGED", function(npc)
    groupDirty[npc] = true
end)

ns.On("CHAT_MSG_ADDON", function(prefix, text, chatType, sender)
    if prefix ~= PREFIX or ns.IsSecret(text) or ns.IsSecret(sender) then
        return
    end
    local kind = text:sub(1, 2)
    if chatType == "CHANNEL" and kind == "Q|" then
        local asker, npc, held = text:match("^Q|(%x+)|([0-9a-z]+)|([0-9a-z,]*)$")
        npc = npc and Wire.ReadNumber(npc)
        if npc and #asker == 16 then
            planAnswer(asker, npc, held, sender)
        end
    elseif chatType == "CHANNEL" and kind == "C|" then
        local asker, npc = text:match("^C|(%x+)|([0-9a-z]+)$")
        npc = npc and Wire.ReadNumber(npc)
        if npc then
            planned[asker .. ":" .. npc] = nil
        end
    elseif chatType == "WHISPER" and kind == "D|" then
        receive(text, sender)
    elseif (chatType == "PARTY" or chatType == "RAID" or chatType == "INSTANCE_CHAT") and kind == "D|" then
        receiveGroup(text, sender)
    end
end)

ns.On("PLAYER_TARGET_CHANGED", function()
    local npc = ns.UnitNpc("target")
    if npc then
        ask(npc)
    end
end)

local function joinChannel()
    JoinTemporaryChannel(CHANNEL)
    C_Timer.After(2, function()
        local id = GetChannelName(CHANNEL)
        channelId = id and id > 0 and id or nil
    end)
end

-- Data of the 0.1.0 bridge mode: counts in db.relay (by install) move to db.peers (by mob), the rest goes.
local function migrateRelay(db)
    for origin, entry in pairs(db.relay or {}) do
        for npc, buckets in pairs(entry.mobs or {}) do
            local info = entry.info and entry.info[npc] or {}
            local source = { buckets = {}, maps = {}, minLevel = info.minLevel, maxLevel = info.maxLevel }
            for bucket, data in pairs(buckets) do
                if data.kills and data.money then
                    source.buckets[bucket] = data
                end
            end
            for mapId, place in pairs(info.maps or {}) do
                source.maps[mapId] = place.kills
            end
            local records = Wire.SourceRecords(npc, source)
            local decoded = #records > 0 and Wire.DecodeRecords(table.concat(records, ";"))
            if decoded then
                store(origin, npc, decoded)
            end
        end
    end
    db.relay = nil
    db.share = nil
    db.settings.bridgeMode = nil
end

ns.On("DT_READY", function()
    knownOrigins = {}
    for _, peers in pairs(ns.db.peers) do
        for origin in pairs(peers) do
            knownOrigins[origin] = true
        end
    end
    migrateRelay(ns.db)
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.After(JOIN_DELAY, joinChannel)
    C_Timer.NewTicker(TICK, tick)
end)

function ns.ShareStatus()
    local mobs, installs = 0, {}
    for _, peers in pairs(ns.db.peers) do
        mobs = mobs + 1
        for origin in pairs(peers) do
            installs[origin] = true
        end
    end
    local count = 0
    for _ in pairs(installs) do
        count = count + 1
    end
    local text = ("Sharing %s. Other players' counts for %d mobs from %d installs. This session: %d questions asked, %d answers whispered, %d received."):format(
        ns.settings.shareData and "on" or "off", mobs, count, session.queries, session.answers, session.received)
    if session.groupSent + session.groupReceived > 0 then
        text = text .. (" Group: %d messages sent, %d received."):format(session.groupSent, session.groupReceived)
    end
    if session.refused > 0 then
        text = text .. (" %d answers refused (too many unknown installs from one player)."):format(session.refused)
    end
    if session.failed > 0 then
        text = text .. (" %d messages could not be sent."):format(session.failed)
    end
    return text
end
