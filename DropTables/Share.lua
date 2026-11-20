local _, ns = ...

-- Sharing between players. When a player targets a mob the addon knows little about, it asks on a hidden channel and
-- says whose counts it already holds, and players with other or bigger counts whisper theirs back:
--   Q|<asking install id>|<npc>|<held>   held: "<first 6 hex of an install id><its kills>" joined by ","
--   D|<origin install id>|<records of one mob>   (whisper to the asker)
--   C|<asking install id>|<npc>                  (channel: the asker has enough, pending answers are dropped)
-- The asker keeps collecting until it holds SAMPLE_TARGET looted corpses of the mob or MAX_ORIGINS_PER_QUESTION
-- installs have answered. Bigger sources answer sooner, so one or two big ones often settle a question before the small
-- ones get to send. Group members also send each other their own counts once a minute, over the group's addon channel:
--   D|<own install id>|<records of one mob>      (PARTY, RAID or INSTANCE_CHAT)
-- Counts are kept per origin install and replaced rather than added, so the same counts arriving twice change nothing.
-- One thing we live with: two members who see the same kill both count it, which leaves each one's rates right but
-- makes the kill totals of party kills ("312 by 7 players") too high. Telling the copies apart would need corpse GUIDs
-- that match across clients, and that isn't confirmed for Forever.
local Wire = ns.Wire
local PREFIX = "DropTables"
local CHANNEL = "DropTablesShare"
local TICK = 1.1
local JOIN_DELAY = 6
local JOIN_RETRY = 15       -- seconds between tries while the player is not in the channel
local MAX_SOURCES = 12      -- other installs kept per mob
local SAMPLE_TARGET = 100   -- looted corpses of a mob (own plus other installs') worth asking for
local MAX_ORIGINS_PER_QUESTION = 10
-- Seconds before the same mob is asked about again. After a question someone answered it's the first step, and every
-- question nobody answered moves one step further.
local PAUSES = { 120, 300, 600, 1800 }
local REFRESH = 86400       -- a mob with SAMPLE_TARGET corpses or more is asked about once a day
local QUERY_GAP = 5         -- seconds between any two questions
local WAITING_QUESTIONS = 3 -- mobs targeted during the gap wait for their turn; only the newest are kept
local ANSWER_WINDOW = 120   -- whispered counts are taken only this long after asking about that mob
local ANSWER_ORIGINS = 3    -- installs one player whispers back per question, the biggest first
-- How long an answer waits. A source with SAMPLE_TARGET corpses or more waits BIG_DELAY, one with almost none up to
-- BIG_DELAY + SIZE_DELAY, and up to JITTER is added on top so sources of the same size don't all send at once.
local BIG_DELAY, SIZE_DELAY, JITTER = 0.3, 3, 0.7
local NEW_ORIGINS_PER_SENDER = 3 -- installs the player has never seen that one sender may bring per day
local GROUP_NEW_MOBS = 30   -- mobs the player knows nothing of that one group member may bring per day
local HELD_PREFIX = 6
local QUEUE_TTL = 60
local MAX_WAITING_WHISPERS = 40 -- no new answers are planned while this many whispers wait
local CHANNEL_PER_TICK, WHISPERS_PER_TICK, GROUP_PER_TICK = 1, 4, 1
local GROUP_INTERVAL = 60   -- seconds between two sends of the player's changed counts to the group
local GROUP_FLUSH_CAP = 10  -- messages per group send; mobs that do not fit wait for the next one
local MOB_MESSAGES = 4      -- messages one install's mob may take; the rarest items are left out past that
local RESULT = Enum.SendAddonMessageResult or {}
local SUCCESS = RESULT.Success or 0
-- Send results worth trying again later. Any other failure (target offline, not in a group, ...) drops the message.
local RETRY = {
    [RESULT.AddonMessageThrottle or 3] = true,
    [RESULT.ChannelThrottle or 8] = true,
    [RESULT.AddOnMessageLockdown or 11] = true,
}

local channelId
local queue = {}     -- { text, at, chatType, target } waiting to go out
local planned = {}   -- asking player -> { npc, target, due = { [origin] = time } }, the answer waiting to go out
-- npc -> { at, origins = { [origin] = true }, count, step, refresh, calledOff } of the player's last question
local asked = {}
local lastQuery = -QUERY_GAP
local waiting = {}   -- npcs targeted while another question had just gone out, oldest first
local knownOrigins   -- set of every install id the player holds counts of
-- sender -> { day, count } of what that sender brought, kept for this session only and never saved
local newBySender = {}      -- installs the player had never seen
local newMobsBySender = {}  -- mobs the player knew nothing of, from group members
local groupOrigins = {}     -- group member -> the one install they send; this session only
local groupDirty = {}  -- npc -> true: the player's own counts changed since the last group send
local lastGroupSend = 0
local whispered = {}  -- player key (see playerKey) -> GetTime() of the last whisper sent to them
local playerKey
local session = { queries = 0, answers = 0, received = 0, refused = 0, failed = 0, groupSent = 0, groupReceived = 0 }

-- The option that turns all of it off, both ways.
local function sharing()
    return ns.settings.sharePlayers
end

-- The player's own counts of a mob in the same shape as another install's, with buckets, levels and kills per map.
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
        minLevel = info and info.minLevel, maxLevel = info and info.maxLevel, skins = ns.db.skins[npc],
    }
end

-- Every install's counts the player holds for a mob, own included, the most kills first.
local function sources(npc)
    local list = { ns.OwnSource(npc) }
    for origin, peer in pairs(ns.db.peers[npc] or {}) do
        table.insert(list, {
            origin = origin, buckets = peer.buckets, maps = peer.maps,
            minLevel = peer.minLevel, maxLevel = peer.maxLevel, skins = peer.skins,
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

local pack

-- The messages of one install's mob: its loot (D|) and, when it skinned the mob, its skinning (S|) after it. Older
-- versions skip S| messages, which they don't know, and still read the loot.
local function sourceTexts(npc, source, name)
    local texts = pack("D|" .. source.origin .. "|", Wire.SourceRecords(npc, source, name))
    local skinRecords = Wire.SkinRecords(npc, source.skins)
    if #skinRecords > 0 then
        for _, text in ipairs(pack("S|" .. source.origin .. "|", skinRecords)) do
            table.insert(texts, text)
        end
    end
    return texts
end

function pack(header, records)
    local texts, text = {}, nil
    for _, record in ipairs(records) do
        if text and #text + 1 + #record > Wire.MAX_MESSAGE then
            table.insert(texts, text)
            text = nil
            if #texts == MOB_MESSAGES then
                return texts
            end
        end
        text = text and (text .. ";" .. record) or (header .. record)
    end
    if text then
        table.insert(texts, text)
    end
    return texts
end

-- A message the way it can be shown in chat, with pipes doubled so the chat frame doesn't read them as codes.
local function shown(text)
    local short = #text > 48 and text:sub(1, 48) .. "..." or text
    return short:gsub("|", "||") .. (" (%d bytes)"):format(#text)
end

local function enqueue(text, chatType, target)
    table.insert(queue, { text = text, at = GetTime(), chatType = chatType, target = target })
end

-- Looted corpses of a mob the player holds: their own, every other install's and the shared database's.
local function sampleOf(npc)
    local own = ns.db.mobs[npc]
    local shared = ns.shared[npc]
    local opened = (own and ns.SumBuckets(own, "opened") or 0) + (shared and ns.SumBuckets(shared.buckets, "opened") or 0)
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

-- The pause after the last question about a mob, short when someone answered it and longer each time nobody did.
local function pauseAfter(question)
    return question.count > 0 and PAUSES[1] or PAUSES[question.step]
end

-- Why a question about the mob can't go out yet, or nil when it can. The gap between questions isn't a reason here,
-- because it only makes the mob wait in line.
local function notYet(npc, now)
    local last = asked[npc]
    if not channelId then
        return "not in the channel"
    elseif last and now - last.at < pauseAfter(last) then
        return ("asked %d s ago, next in %d s"):format(math.floor(now - last.at), math.ceil(pauseAfter(last) - (now - last.at)))
    elseif not wantsData(npc) and (ns.db.refreshed[npc] or 0) > time() - REFRESH then
        return "already holds enough corpses, asked again tomorrow"
    end
end

local function sendQuestion(npc, now)
    local last = asked[npc]
    local step = not last and 1 or last.count > 0 and 1 or math.min(last.step + 1, #PAUSES)
    local refresh = not wantsData(npc)
    if refresh then
        ns.db.refreshed[npc] = time()
    end
    ns.Debug("asking about mob %d, %d looted corpses held%s", npc, sampleOf(npc), refresh and " (daily refresh)" or "")
    asked[npc] = { at = now, origins = {}, count = 0, step = step, refresh = refresh }
    lastQuery = now
    enqueue(question(npc), "CHANNEL", channelId)
    session.queries = session.queries + 1
end

local function ask(npc)
    local now = GetTime()
    local reason = notYet(npc, now)
    if reason then
        ns.Debug("not asking about mob %d: %s", npc, reason)
    elseif now - lastQuery >= QUERY_GAP and #waiting == 0 then
        sendQuestion(npc, now)
    else
        for _, queued in ipairs(waiting) do
            if queued == npc then
                return
            end
        end
        table.insert(waiting, npc)
        if #waiting > WAITING_QUESTIONS then
            table.remove(waiting, 1)
        end
        ns.Debug("mob %d waits its turn to be asked about", npc)
    end
end

-- Sends the oldest waiting question once the gap has passed. Mobs that stopped being worth asking about in the
-- meantime drop out of the line.
local function askWaiting(now)
    while waiting[1] and now - lastQuery >= QUERY_GAP do
        local npc = table.remove(waiting, 1)
        if not notYet(npc, now) then
            sendQuestion(npc, now)
        end
    end
end

-- Answers in the queue plus installs planned to be sent, counting at least one whisper for each planned install.
local function waitingWhispers()
    local count = 0
    for _, message in ipairs(queue) do
        if message.chatType == "WHISPER" then
            count = count + 1
        end
    end
    for _, plan in pairs(planned) do
        for _ in pairs(plan.due) do
            count = count + 1
        end
    end
    return count
end

-- Picks up to ANSWER_ORIGINS installs the asker lacks or holds with fewer kills. Each player gets one planned answer
-- at a time, for their latest question, and nothing gets planned while many whispers are waiting, so one player
-- flooding questions can't hold up the answers to everyone else.
local function planAnswer(asker, npc, heldText, sender)
    local waiting = waitingWhispers()
    if waiting >= MAX_WAITING_WHISPERS then
        ns.Debug("%s asks about mob %d: not answering, %d whispers still waiting", sender, npc, waiting)
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
        if source.origin ~= asker and (not theirs or theirs < source.kills)
            and #Wire.SourceRecords(npc, source) > 0 then
            local size = math.min(ns.SumBuckets(source.buckets, "opened"), SAMPLE_TARGET) / SAMPLE_TARGET
            due[source.origin] = GetTime() + BIG_DELAY + SIZE_DELAY * (1 - size) + math.random() * JITTER
            count = count + 1
            if count == ANSWER_ORIGINS then
                break
            end
        end
    end
    if count > 0 then
        planned[sender] = { npc = npc, target = sender, due = due }
    end
    ns.Debug("%s asks about mob %d: answering with %d installs", sender, npc, count)
end

local function sendDueAnswers(now)
    for key, plan in pairs(planned) do
        for _, source in ipairs(sources(plan.npc)) do
            local due = plan.due[source.origin]
            if due and now >= due then
                plan.due[source.origin] = nil
                for _, text in ipairs(sourceTexts(plan.npc, source, ns.db.names[plan.npc])) do
                    enqueue(text, "WHISPER", plan.target)
                end
                session.answers = session.answers + 1
            end
        end
        -- Installs dropped from the store since the question have nothing left to send.
        for origin, due in pairs(plan.due) do
            if now >= due then
                plan.due[origin] = nil
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

-- Keeps the MAX_SOURCES installs that were updated most recently. Size plays no part, so big made-up counts can't push
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
        elseif r.kind == "K" or r.kind == "U" then
            peer.skins = peer.skins or { skinned = 0, items = {} }
            if r.kind == "K" then
                peer.skins.skinned = r.skinned
            else
                peer.skins.items[r.item] = { drops = r.drops, qty = r.qty, min = r.min, max = r.max }
                rememberItem(r.item)
            end
        end
    end
    trim(peers)
end

-- Counts one more of something a sender brought today (the sender is a name the server vouches for), and returns false
-- once the limit is reached.
local function withinDailyLimit(counts, sender, limit)
    local day = math.floor(time() / 86400)
    local entry = counts[sender]
    if not entry or entry.day ~= day then
        entry = { day = day, count = 0 }
        counts[sender] = entry
    end
    if entry.count >= limit then
        return false
    end
    entry.count = entry.count + 1
    return true
end

-- A sender may bring only a few installs a day that the player has never seen, so nobody can fill the tables with
-- made-up installs. Updates of installs we already know are taken from anyone.
local function allowNewOrigin(sender)
    return withinDailyLimit(newBySender, sender, NEW_ORIGINS_PER_SENDER)
end

local function messagingBlocked()
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return true
    end
    return IsEncounterInProgress and IsEncounterInProgress()
end

-- The call-off skips the queue, because every moment it waits another player may start whispering.
local function callOff(npc)
    local text = "C|" .. ns.db.installId .. "|" .. Wire.EncodeNumber(npc)
    if not channelId or messagingBlocked()
        or C_ChatInfo.SendAddonMessage(PREFIX, text, "CHANNEL", channelId) ~= SUCCESS then
        enqueue(text, "CHANNEL", channelId)
    else
        ns.Debug("sent CHANNEL %s", shown(text))
    end
end

local SKIN_KINDS = { K = true, U = true }

-- Origin, npc and records of a well-formed message about one mob of another install, or nil. A D| message holds loot
-- and an S| message skinning, nothing else.
local function decodeAnswer(text)
    local kind, origin, body = text:match("^([DS])|(%x+)|(.+)$")
    if not origin or #origin ~= 16 or origin == ns.db.installId then
        return nil
    end
    local records = Wire.DecodeRecords(body)
    if not records then
        return nil
    end
    local npc = records[1].npc
    for _, record in ipairs(records) do
        if record.npc ~= npc or (SKIN_KINDS[record.kind] == true) ~= (kind == "S") then
            return nil
        end
    end
    return origin, npc, records, kind == "S"
end

local function receive(text, sender)
    local origin, npc, records, skinning = decodeAnswer(text)
    if not origin then
        ns.Debug("  ignored: malformed, impossible counts or your own install")
        return
    end
    local question = asked[npc]
    if not question or GetTime() - question.at > ANSWER_WINDOW then
        ns.Debug("  ignored: no open question about mob %d", npc)
        return
    end
    -- After the call-off only the rest of answers already under way are taken.
    if question.calledOff and not question.origins[origin] then
        ns.Debug("  ignored: the question is already answered")
        return
    end
    if not knownOrigins[origin] and not allowNewOrigin(sender) then
        session.refused = session.refused + 1
        ns.Debug("  refused: %s brought too many new installs today", sender)
        return
    end
    ns.Debug("  stored: mob %d from install %s", npc, origin)
    store(origin, npc, records)
    session.received = session.received + 1
    -- Skinning comes along with an install's loot and doesn't make it one more answer.
    if skinning then
        ns.Fire("DT_DATA_CHANGED", npc)
        return
    end
    if not question.origins[origin] then
        question.origins[origin] = true
        question.count = question.count + 1
    end
    -- A daily refresh of a well-known mob runs until enough installs answered, not until the corpses add up.
    local enough = not question.refresh and sampleOf(npc) >= SAMPLE_TARGET
    if not question.calledOff and (enough or question.count >= MAX_ORIGINS_PER_QUESTION) then
        question.calledOff = true
        callOff(npc)
    end
    ns.Fire("DT_DATA_CHANGED", npc)
end

-- Counts from group members come in without a question, since the server only delivers group messages from members.
-- A member only ever sends their own install, so the first install a member sends is the only one we take from them.
-- Mobs the player has no counts of at all are capped per member and day, because a group mostly kills the same mobs
-- anyway. Forever names the sender "First Last", which doesn't match UnitName, so the sender isn't checked against
-- the group.
local function receiveGroup(text, sender)
    if text:sub(3, 2 + #ns.db.installId) == ns.db.installId then
        ns.Debug("  your own message, back from the group")
        return
    end
    local origin, npc, records = decodeAnswer(text)
    if not origin then
        ns.Debug("  ignored: malformed or impossible counts")
        return
    end
    groupOrigins[sender] = groupOrigins[sender] or origin
    if groupOrigins[sender] ~= origin then
        ns.Debug("  refused: %s already sent counts of another install", sender)
        session.refused = session.refused + 1
        return
    end
    local known = ns.db.mobs[npc] or ns.db.skins[npc] or ns.db.peers[npc] or asked[npc]
    if not known and not withinDailyLimit(newMobsBySender, sender, GROUP_NEW_MOBS) then
        ns.Debug("  refused: %s brought too many mobs you have no counts of today", sender)
        session.refused = session.refused + 1
        return
    end
    ns.Debug("  stored: mob %d from group member %s", npc, sender)
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

-- Queues the player's own counts of the mobs that changed since the last group send, up to GROUP_FLUSH_CAP messages.
-- Only the player's own install goes out this way, and counts kept from others stay home.
local function flushGroup()
    local chatType, used = groupChatType(), 0
    for npc in pairs(groupDirty) do
        -- A mob the player only skinned has no loot of theirs, just the skinning.
        local source = ns.OwnSource(npc) or { origin = ns.db.installId, buckets = {}, maps = {}, skins = ns.db.skins[npc] }
        local texts = sourceTexts(npc, source, ns.db.names[npc])
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

local function refreshChannel()
    local id = GetChannelName(CHANNEL)
    channelId = id and id > 0 and id or nil
    return channelId
end

-- A player who asked and logged off before the answer went out makes the server say "No player named ... is currently
-- playing" in the chat for every whisper the addon sends them. The player never wrote to anyone, so that line is
-- hidden for the names the addon whispered a moment ago, and whatever else waits for that player is dropped.
local WHISPER_ERROR_WINDOW = 10

-- Forever names players "First Last" and the server may give them back as "First-Last", so both are the same key.
function playerKey(name)
    return (name:gsub("-", " "):lower())
end

local function stopWhispers(name)
    local key, dropped = playerKey(name), 0
    for i = #queue, 1, -1 do
        if queue[i].chatType == "WHISPER" and playerKey(queue[i].target) == key then
            table.remove(queue, i)
            dropped = dropped + 1
        end
    end
    for sender, plan in pairs(planned) do
        if playerKey(plan.target) == key then
            planned[sender] = nil
        end
    end
    return dropped
end

-- The game's own "No player named '%s' is currently playing." turned into a pattern that captures the name.
local function notFoundPattern()
    local text = ERR_CHAT_PLAYER_NOT_FOUND_S
    if type(text) ~= "string" or not text:find("%%s") then
        return nil
    end
    local before, after = text:match("^(.-)%%s(.*)$")
    local function escape(s)
        return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
    end
    return "^" .. escape(before) .. "(.+)" .. escape(after) .. "$"
end

local notFound -- notFoundPattern(), set once the game's strings are there

-- The chat filter: true hides the line.
function ns.HideWhisperError(_, _, text)
    if type(text) ~= "string" or ns.IsSecret(text) then
        return false
    end
    local name = notFound and text:match(notFound)
    local at = name and whispered[playerKey(name)]
    if not at or GetTime() - at > WHISPER_ERROR_WINDOW then
        return false
    end
    local dropped = stopWhispers(name)
    ns.Debug("%s is offline: the error was hidden and %d waiting whispers to them dropped", name, dropped)
    return true
end

ns.On("DT_READY", function()
    notFound = notFoundPattern()
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if addFilter and notFound then
        addFilter("CHAT_MSG_SYSTEM", ns.HideWhisperError)
    end
end)

-- Sends up to one channel message, one group message and a few whispers per tick. Whispers outside instances have no
-- addon throttle, so a few at once are fine.
local function tick()
    if not sharing() then
        return
    end
    local now = GetTime()
    for key, at in pairs(whispered) do
        if now - at > WHISPER_ERROR_WINDOW then
            whispered[key] = nil
        end
    end
    refreshChannel()
    askWaiting(now)
    sendDueAnswers(now)
    if messagingBlocked() then
        return
    end
    if now - lastGroupSend >= GROUP_INTERVAL then
        lastGroupSend = now
        if IsInGroup() and next(groupDirty) then
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
            -- The channel number can change while a message waits, so this takes the current one.
            local target = message.chatType == "CHANNEL" and channelId or message.target
            local result = C_ChatInfo.SendAddonMessage(PREFIX, message.text, message.chatType, target)
            if result == SUCCESS then
                ns.Debug("sent %s%s %s", message.chatType,
                    message.chatType == "WHISPER" and " to " .. message.target or "", shown(message.text))
                if message.chatType == "WHISPER" then
                    whispered[playerKey(message.target)] = now
                end
                table.remove(queue, i)
                budget[key] = budget[key] - 1
            elseif RETRY[result] or result == false then
                ns.Debug("could not send %s yet, result %s", message.chatType, tostring(result))
                budget[key] = 0
                i = i + 1
            elseif message.chatType == "WHISPER" and message.target:find(" ") then
                -- Forever names players "First Last". If a whisper to that form fails, "First-Last" is tried once.
                ns.Debug("could not whisper %s, result %s, trying %s", message.target, tostring(result),
                    (message.target:gsub(" ", "-")))
                message.target = message.target:gsub(" ", "-")
                budget[key] = 0
                i = i + 1
            else
                ns.Debug("could not send %s%s, result %s, dropped", message.chatType,
                    message.target and " to " .. tostring(message.target) or "", tostring(result))
                session.failed = session.failed + 1
                table.remove(queue, i)
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
    if prefix ~= PREFIX or not sharing() or ns.IsSecret(text) or ns.IsSecret(sender) then
        return
    end
    ns.Debug("got %s from %s: %s", chatType, sender, shown(text))
    local kind = text:sub(1, 2)
    if chatType == "CHANNEL" and kind == "Q|" then
        local asker, npc, held = text:match("^Q|(%x+)|([0-9a-z]+)|([0-9a-z,]*)$")
        npc = npc and Wire.ReadNumber(npc)
        if asker == ns.db.installId then
            ns.Debug("own question about mob %s came back over the channel, ignored", npc or "?")
        elseif npc and #asker == 16 then
            planAnswer(asker, npc, held, sender)
        end
    elseif chatType == "CHANNEL" and kind == "C|" then
        -- Only the asker can call off the answers to them. The plan is looked up by the sender rather than by the
        -- install id in the message, because anyone could copy that id.
        local npc = text:match("^C|%x+|([0-9a-z]+)$")
        npc = npc and Wire.ReadNumber(npc)
        if npc and planned[sender] and planned[sender].npc == npc then
            planned[sender] = nil
        end
    elseif chatType == "WHISPER" and (kind == "D|" or kind == "S|") then
        receive(text, sender)
    elseif (chatType == "PARTY" or chatType == "RAID" or chatType == "INSTANCE_CHAT") and (kind == "D|" or kind == "S|") then
        receiveGroup(text, sender)
    end
end)

ns.On("PLAYER_TARGET_CHANGED", function()
    local npc = ns.UnitMob("target")
    if npc then
        ask(npc)
    end
end)

-- Joins the hidden channel and tries again every JOIN_RETRY seconds while the player isn't in it, which happens after
-- loading screens, a /leave or hitting the channel limit.
local function joinChannel()
    if not sharing() or refreshChannel() then
        return
    end
    JoinTemporaryChannel(CHANNEL)
    C_Timer.After(2, function()
        ns.Debug(refreshChannel() and "joined the sharing channel" or "could not join the sharing channel, trying again")
    end)
end

-- With the option on, joins the channel (at once when it was just turned on). With it off, leaves the channel, which
-- a /reload doesn't do, and drops whatever waited to go out.
local function applySharing()
    if sharing() then
        joinChannel()
        return
    end
    if refreshChannel() then
        LeaveChannelByName(CHANNEL)
        channelId = nil
    end
    wipe(queue)
    wipe(planned)
    wipe(waiting)
end
ns.On("DT_SETTINGS_CHANGED", applySharing)

-- Data from the 0.1.0 bridge mode. Counts in db.relay (by install) move to db.peers (by mob) and the rest is dropped.
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
    db.settings.shareData = nil
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
    C_Timer.After(JOIN_DELAY, function()
        applySharing()
        C_Timer.NewTicker(JOIN_RETRY, joinChannel)
    end)
    C_Timer.NewTicker(TICK, tick)
end)

function ns.ShareDebugState()
    return ("channel %s, %s, %d messages waiting"):format(channelId and "joined" or "not joined",
        IsInGroup() and groupChatType() .. " group" or "no group", #queue)
end

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
    if not sharing() then
        return ("Sharing with other players is off in the options, so nothing is sent or taken in. Their counts "
            .. "for %d mobs from %d installs stay."):format(mobs, count)
    end
    local text = ("Other players' counts for %d mobs from %d installs. This session: %d questions asked, %d answers whispered, %d received."):format(
        mobs, count, session.queries, session.answers, session.received)
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
