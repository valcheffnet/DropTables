local _, ns = ...

-- The export string: the player's counts, and the counts other players shared with them, as one line of text to
-- paste on the share page, which files it for the shared database.
--   DT1:<base64 of the zlib-compressed text below>
-- The text is a header line, then a line with an install id and one line per mob of that install:
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

-- True when the shared database lacks the counts of this install: it never got them, or got fewer kills. Counts
-- only grow, so more kills than the database lists means something new.
local function missing(npc, origin, buckets)
    local shared = ns.shared[npc]
    local known = shared and shared.from[origin]
    return not known or ns.SumBuckets(buckets, "kills") > known
end

-- Own mobs whose counts the shared database does not have yet.
local function newCount()
    local count = 0
    for npc, buckets in pairs(ns.db.mobs) do
        if missing(npc, ns.db.installId, buckets) then
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
    -- Earlier versions kept track of what was copied; the shared database tells that now.
    ns.db.export = nil
    C_Timer.After(REMIND_DELAY, remind)
end)

function ns.CanExport()
    return C_EncodingUtil ~= nil and C_EncodingUtil.CompressString ~= nil and Enum.CompressionMethod ~= nil
end

-- One line per mob, or nil when nothing complete is left to send. Kill spots stay out: the shared database has no use
-- for them.
local function ownLine(npc)
    local records = Wire.SourceRecords(npc, ns.OwnSource(npc), ns.db.names[npc])
    return #records > 0 and table.concat(records, ";") or nil
end

local function peerLine(npc, peer)
    local records = Wire.SourceRecords(npc, peer, ns.db.names[npc])
    return #records > 0 and table.concat(records, ";") or nil
end

-- Sections { origin, lines } of what goes out: the player's own counts and the counts other players sent, of every
-- mob where the shared database lacks them. Whatever was copied but never sent goes out again next time; a repeat is
-- harmless, the database keeps one version per install and mob.
local function collect()
    local db = ns.db
    local result = { sections = {}, mobs = 0, kills = 0, sources = 0 }
    local own = { origin = db.installId, lines = {} }
    for npc, buckets in pairs(db.mobs) do
        local line = missing(npc, db.installId, buckets) and ownLine(npc)
        if line then
            table.insert(own.lines, line)
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

-- Splits the sections into parts of at most budget characters, an install line repeated in every part it spans.
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

-- Builds the export. Returns { strings, mobs, kills, sources, builtAt }; strings is empty when there is nothing to
-- share.
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

-- Own mobs whose counts the shared database does not have yet.
ns.NewCount = newCount
