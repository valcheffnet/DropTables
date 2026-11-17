local _, ns = ...

-- The export string: the player's counts, and the counts other players shared with them, as one line of text to
-- copy into the form for the shared database.
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

local function changedCount()
    local count = 0
    for npc in pairs(ns.db.export.dirty) do
        if ns.db.mobs[npc] then
            count = count + 1
        end
    end
    return count
end

local function remind()
    if reminded or not ns.settings.exportReminder then
        return
    end
    local count = changedCount()
    if count >= REMIND_AFTER then
        reminded = true
        ns.Print(("You have new drop counts for %d mobs. Type /dt export to share them, so they help other players' tables too."):format(count))
    end
end

local function markDirty(npc)
    local export = ns.db.export
    export.change = export.change + 1
    export.dirty[npc] = export.change
end

ns.On("DT_COUNTS_CHANGED", function(npc)
    markDirty(npc)
end)

ns.On("DT_INFO_CHANGED", function(npc)
    if ns.db.mobs[npc] then
        markDirty(npc)
    end
end)

ns.On("DT_DATA_CHANGED", remind)

ns.On("DT_READY", function()
    local db = ns.db
    if not db.export then
        -- First run with export: everything collected so far is new.
        db.export = { dirty = {}, change = 0, last = 0 }
        for npc in pairs(db.mobs) do
            markDirty(npc)
        end
    end
    C_Timer.After(REMIND_DELAY, remind)
end)

function ns.CanExport()
    return C_EncodingUtil ~= nil and C_EncodingUtil.CompressString ~= nil and Enum.CompressionMethod ~= nil
end

-- One line per mob, or nil when nothing complete is left to send.
local function ownLine(npc)
    local records = Wire.SourceRecords(npc, ns.OwnSource(npc), ns.db.names[npc])
    if #records == 0 then
        return nil
    end
    local info = ns.db.info[npc]
    if info then
        for _, record in ipairs(Wire.CellRecords(npc, info)) do
            table.insert(records, record)
        end
    end
    return table.concat(records, ";")
end

local function peerLine(npc, peer)
    local records = Wire.SourceRecords(npc, peer, ns.db.names[npc])
    return #records > 0 and table.concat(records, ";") or nil
end

-- Sections { origin, lines } of what goes out: by default only own mobs changed since the last export and other
-- players' counts received since then (a repeat is harmless, counts replace counts); with everything, all of it.
local function collect(everything)
    local db = ns.db
    local export = db.export
    local result = { sections = {}, versions = {}, mobs = 0, kills = 0, sources = 0 }
    local own = { origin = db.installId, lines = {} }
    for npc, buckets in pairs(db.mobs) do
        local line = (everything or export.dirty[npc]) and ownLine(npc)
        if line then
            result.versions[npc] = export.dirty[npc]
            table.insert(own.lines, line)
            result.mobs = result.mobs + 1
            for _, data in pairs(buckets) do
                result.kills = result.kills + data.kills
            end
        end
    end
    if #own.lines > 0 then
        table.insert(result.sections, own)
    end
    local byOrigin = {}
    for npc, peers in pairs(db.peers) do
        for origin, peer in pairs(peers) do
            local line = (everything or peer.t >= export.last) and peerLine(npc, peer)
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

-- Builds the export. Returns { strings, mobs, kills, sources, versions, builtAt }; strings is empty when there is
-- nothing to share.
function ns.BuildExport(everything)
    local result = collect(everything)
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

-- Called once every part has been copied: the exported counts stop counting as new.
function ns.MarkExported(result)
    local export = ns.db.export
    for npc, change in pairs(result.versions) do
        if export.dirty[npc] == change then
            export.dirty[npc] = nil
        end
    end
    export.last = math.max(export.last, result.builtAt)
end

-- Own mobs whose counts changed since the last export.
ns.ChangedCount = changedCount
