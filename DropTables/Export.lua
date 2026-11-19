local _, ns = ...

-- The export string carries the player's counts and the counts other players shared with them as one line of text.
-- The player pastes it on the share page, which files it for the shared database.
--   DT1:<base64 of the zlib-compressed text below>
-- The text is a header line, then for each install a line with its id followed by one line per mob:
--   DTX|1|<own install id>|<addon version>|<unix time>|<part>/<parts>
--   @<install id>
--   <Wire records of one mob, joined by ;>
-- Zlib carries a checksum, so a string that was cut short or changed fails to unpack.
local Wire = ns.Wire
local PREFIX = "DT1:"
local FORMAT = "1"
local MAX_STRING = 60000  -- characters per part, below the size limit of a GitHub issue
local FIRST_BUDGET = 150000 -- uncompressed characters per part on the first try
local MIN_BUDGET = 2000     -- below this a part is taken as it is, even if it is over MAX_STRING
local REMIND_AFTER = 25
local REMIND_DELAY = 30     -- seconds after login

local reminded = false

-- True when the shared database lacks this install's counts, either because it never got them or because it got
-- fewer kills. Counts only grow, so more kills than the database lists means there's something new.
local function missing(npc, origin, buckets)
    local shared = ns.shared[npc]
    local known = shared and shared.from[origin]
    return not known or ns.SumBuckets(buckets, "kills") > known
end

-- Own mobs to ask the player to share, meaning the shared database lacks them and they gained kills since the player
-- last copied an export. Copied counts still go out again in the next export, and we only stop asking, because the
-- database won't know about them until the next release.
local function newCount()
    local count = 0
    for npc, buckets in pairs(ns.db.mobs) do
        if missing(npc, ns.db.installId, buckets) and ns.SumBuckets(buckets, "kills") > (ns.db.copied[npc] or 0) then
            count = count + 1
        end
    end
    return count
end

local function remind()
    if reminded or not ns.settings.exportReminder then
        return
    end
    local count = newCount()
    if count >= REMIND_AFTER then
        reminded = true
        ns.Print(("You have drop counts for %d mobs that the shared database does not have yet. Type /dt export to share them, so they help other players' tables too."):format(count))
    end
end

ns.On("DT_DATA_CHANGED", remind)

ns.On("DT_READY", function()
    -- db.export of earlier versions is not used any more.
    ns.db.export = nil
    ns.db.copied = ns.db.copied or {}
    C_Timer.After(REMIND_DELAY, remind)
end)

function ns.CanExport()
    return C_EncodingUtil ~= nil and C_EncodingUtil.CompressString ~= nil and Enum.CompressionMethod ~= nil
end

-- One line per mob, or nil when nothing complete is left to send. The player's own kill spots go along, so the shared
-- database can show where the mob is; other players never send theirs, so their lines have none.
local function ownLine(npc)
    local records = Wire.SourceRecords(npc, ns.OwnSource(npc), ns.db.names[npc])
    if #records == 0 then
        return nil
    end
    local info = ns.db.info[npc]
    local spots = {}
    for mapId, place in pairs(info and info.maps or {}) do
        for cell, kills in pairs(place.cells) do
            table.insert(spots, { mapId = mapId, cell = cell, record = Wire.SpotRecord(npc, mapId, cell, kills) })
        end
    end
    table.sort(spots, function(a, b)
        if a.mapId ~= b.mapId then
            return a.mapId < b.mapId
        end
        return a.cell < b.cell
    end)
    for _, spot in ipairs(spots) do
        table.insert(records, spot.record)
    end
    return table.concat(records, ";")
end

local function peerLine(npc, peer)
    local records = Wire.SourceRecords(npc, peer, ns.db.names[npc])
    return #records > 0 and table.concat(records, ";") or nil
end

-- Sections { origin, lines } of what goes out, which is the player's own counts and the counts other players sent for
-- every mob where the shared database lacks them. Anything copied but never sent goes out again next time, and the
-- repeat does no harm since the database keeps one version per install and mob.
local function collect()
    local db = ns.db
    local result = { sections = {}, copied = {}, mobs = 0, kills = 0, sources = 0 }
    local own = { origin = db.installId, lines = {} }
    for npc, buckets in pairs(db.mobs) do
        local line = missing(npc, db.installId, buckets) and ownLine(npc)
        if line then
            table.insert(own.lines, line)
            result.copied[npc] = ns.SumBuckets(buckets, "kills")
            result.mobs = result.mobs + 1
            result.kills = result.kills + ns.SumBuckets(buckets, "kills")
        end
    end
    if #own.lines > 0 then
        table.insert(result.sections, own)
    end
    local byOrigin = {}
    for npc, peers in pairs(db.peers) do
        for origin, peer in pairs(peers) do
            local line = missing(npc, origin, peer.buckets) and peerLine(npc, peer)
            if line then
                local section = byOrigin[origin]
                if not section then
                    section = { origin = origin, lines = {} }
                    byOrigin[origin] = section
                    table.insert(result.sections, section)
                    result.sources = result.sources + 1
                end
                table.insert(section.lines, line)
            end
        end
    end
    return result
end

-- Splits the sections into parts of at most budget characters, repeating an install's line in every part it spans.
local function split(sections, budget)
    local parts, part, size = {}, nil, 0
    for _, section in ipairs(sections) do
        local opened = false
        for _, line in ipairs(section.lines) do
            if part and size + #line > budget then
                part, size, opened = nil, 0, false
            end
            if not part then
                part = {}
                table.insert(parts, part)
            end
            if not opened then
                table.insert(part, "@" .. section.origin)
                size = size + #section.origin + 2
                opened = true
            end
            table.insert(part, line)
            size = size + #line + 1
        end
    end
    return parts
end

local function encode(text)
    local packed = C_EncodingUtil.CompressString(text, Enum.CompressionMethod.Zlib)
    return PREFIX .. C_EncodingUtil.EncodeBase64(packed)
end

local function version()
    local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    return get and get("DropTables", "Version") or "?"
end

-- Builds the export and returns { strings, copied, mobs, kills, sources, builtAt }. strings is empty when there's
-- nothing to share.
function ns.BuildExport()
    local result = collect()
    result.builtAt = time()
    result.strings = {}
    if #result.sections == 0 then
        return result
    end
    local budget = FIRST_BUDGET
    while true do
        local parts = split(result.sections, budget)
        local strings, fits = {}, true
        for i, lines in ipairs(parts) do
            local header = table.concat({ "DTX", FORMAT, ns.db.installId, version(), result.builtAt, i .. "/" .. #parts }, "|")
            strings[i] = encode(header .. "\n" .. table.concat(lines, "\n"))
            fits = fits and #strings[i] <= MAX_STRING
        end
        if fits or budget < MIN_BUDGET then
            result.strings = strings
            return result
        end
        budget = math.floor(budget / 2)
    end
end

ns.NewCount = newCount

-- Called once every part has been copied, so the share cards stop asking for these counts.
function ns.MarkCopied(result)
    for npc, kills in pairs(result.copied) do
        ns.db.copied[npc] = kills
    end
    ns.Fire("DT_SHARE_COPIED")
end
