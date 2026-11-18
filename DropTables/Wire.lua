local _, ns = ...

-- Text form of drop counts, used by peer sharing and by the export string. Records are joined with ";" and each
-- one replaces the previous record with the same key, so sending the same counts twice is harmless:
--   M<npc>.<bucket>.<kills>.<lootable>.<opened>.<money drops>.<copper>.<money min>.<money max>
--   I<npc>.<bucket>.<item>.<drops>.<qty>.<min>.<max>
--   L<npc>.<min level>.<max level>
--   Z<npc>.<map>.<kills>
--   P<npc>.<map>.<cell>.<kills>
--   N<npc>.<mob name>
-- Numbers are base 36; an empty field is a missing value (min/max, unknown level).
local Wire = {}
ns.Wire = Wire

Wire.MAX_MESSAGE = 255

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function encodeNumber(n)
    if n == nil then
        return ""
    end
    n = math.floor(n)
    if n == 0 then
        return "0"
    end
    local out = {}
    while n > 0 do
        local digit = n % 36
        table.insert(out, 1, DIGITS:sub(digit + 1, digit + 1))
        n = math.floor(n / 36)
    end
    return table.concat(out)
end
Wire.EncodeNumber = encodeNumber

-- Six digits stay below 2^32, where tonumber(s, 36) stops.
local MAX_DIGITS = 6

-- A number from a message field, or nil when it is empty, too long or not base 36.
function Wire.ReadNumber(s)
    if #s > MAX_DIGITS or not s:match("^[0-9a-z]+$") then
        return nil
    end
    return tonumber(s, 36)
end

local function decodeNumber(s)
    if s == "" then
        return nil
    end
    return Wire.ReadNumber(s) or error("bad number")
end

function Wire.MobRecord(npc, bucket, data)
    local money = data.money
    return "M" .. table.concat({
        encodeNumber(npc), encodeNumber(bucket), encodeNumber(data.kills), encodeNumber(data.lootable),
        encodeNumber(data.opened), encodeNumber(money.drops), encodeNumber(money.copper),
        encodeNumber(money.min), encodeNumber(money.max),
    }, ".")
end

function Wire.ItemRecord(npc, bucket, itemId, item)
    return "I" .. table.concat({
        encodeNumber(npc), encodeNumber(bucket), encodeNumber(itemId), encodeNumber(item.drops),
        encodeNumber(item.qty), encodeNumber(item.min), encodeNumber(item.max),
    }, ".")
end

function Wire.LevelRecord(npc, minLevel, maxLevel)
    return "L" .. encodeNumber(npc) .. "." .. encodeNumber(minLevel) .. "." .. encodeNumber(maxLevel)
end

function Wire.MapRecord(npc, mapId, kills)
    return "Z" .. encodeNumber(npc) .. "." .. encodeNumber(mapId) .. "." .. encodeNumber(kills)
end

-- Mob names are client text; "|", ";" and control characters never occur in them and are refused.
local function validName(name)
    return type(name) == "string" and #name > 0 and #name <= 64 and not name:find("[%c|;]")
end

function Wire.NameRecord(npc, name)
    return validName(name) and ("N" .. encodeNumber(npc) .. "." .. name) or nil
end

-- A bucket put together from other players' messages can be half there: items without the counts message, or an
-- older counts message than the items. Such a bucket is not passed on.
function Wire.Complete(data)
    if data.kills == 0 then
        return false
    end
    for _, item in pairs(data.items) do
        if item.drops > data.opened then
            return false
        end
    end
    return true
end

-- One install's records of a mob: counts per bucket, level range, kills per map and the name, then the items, the
-- most frequent first, so a message list cut short loses the rarest drops (mostly one-off world drops) and keeps the
-- counts and the items that matter. Nothing at all when no bucket is complete.
-- source is { buckets, minLevel, maxLevel, maps = { [mapId] = kills } }.
function Wire.SourceRecords(npc, source, name)
    local records, items = {}, {}
    for bucket, data in pairs(source.buckets) do
        if Wire.Complete(data) then
            table.insert(records, Wire.MobRecord(npc, bucket, data))
            for itemId, item in pairs(data.items) do
                table.insert(items, { drops = item.drops, record = Wire.ItemRecord(npc, bucket, itemId, item) })
            end
        end
    end
    if #records == 0 then
        return records
    end
    if source.minLevel then
        table.insert(records, Wire.LevelRecord(npc, source.minLevel, source.maxLevel))
    end
    for mapId, kills in pairs(source.maps) do
        table.insert(records, Wire.MapRecord(npc, mapId, kills))
    end
    local nameRecord = Wire.NameRecord(npc, name)
    if nameRecord then
        table.insert(records, nameRecord)
    end
    table.sort(items, function(a, b)
        if a.drops ~= b.drops then
            return a.drops > b.drops
        end
        return a.record < b.record
    end)
    for _, item in ipairs(items) do
        table.insert(records, item.record)
    end
    return records
end

local function split(text, sep)
    local parts = {}
    for part in (text .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
        table.insert(parts, part)
    end
    return parts
end

local FIELDS = {
    M = { "npc", "bucket", "kills", "lootable", "opened", "moneyDrops", "copper", "moneyMin", "moneyMax" },
    I = { "npc", "bucket", "item", "drops", "qty", "min", "max" },
    L = { "npc", "minLevel", "maxLevel" },
    Z = { "npc", "map", "kills" },
    P = { "npc", "map", "cell", "kills" },
}
local REQUIRED = { npc = true, bucket = true, kills = true, lootable = true, opened = true, moneyDrops = true,
    copper = true, item = true, drops = true, qty = true, map = true, cell = true }

-- A stack range is either missing or 1 <= min <= max.
local function range(min, max)
    if min == nil or max == nil then
        return min == max
    end
    return min >= 1 and min <= max
end

-- Counts that cannot come from the collector: an opened corpse is a lootable kill, an item or coin drops at most
-- once per opened corpse.
local function consistent(r)
    if r.kind == "M" then
        return r.lootable <= r.kills and r.opened <= r.lootable and r.moneyDrops <= r.opened
            and (r.moneyDrops > 0 or r.copper == 0) and range(r.moneyMin, r.moneyMax)
    elseif r.kind == "I" then
        return r.drops >= 1 and r.qty >= r.drops and range(r.min, r.max)
    elseif r.kind == "L" then
        return (r.minLevel == nil) == (r.maxLevel == nil) and (r.minLevel or 0) <= (r.maxLevel or 0)
    end
    return true
end

local function decodeRecord(text)
    local kind = text:sub(1, 1)
    if kind == "N" then
        local npc, name = text:match("^N([0-9a-z]+)%.(.+)$")
        if not npc or not validName(name) then
            error("bad name record")
        end
        return { kind = kind, npc = decodeNumber(npc), name = name }
    end
    local names = FIELDS[kind]
    if not names then
        error("bad record kind")
    end
    local values = split(text:sub(2), ".")
    if #values ~= #names then
        error("bad field count")
    end
    local record = { kind = kind }
    for i, name in ipairs(names) do
        record[name] = decodeNumber(values[i])
        if REQUIRED[name] and record[name] == nil then
            error("missing " .. name)
        end
    end
    if record.bucket and (record.bucket < 1 or record.bucket > 6) then
        error("bad bucket")
    end
    if not consistent(record) then
        error("inconsistent " .. kind .. " record")
    end
    return record
end

-- Records of a ";"-joined text, or nil and the reason when any of them is malformed.
function Wire.DecodeRecords(body)
    local records = {}
    local ok, err = pcall(function()
        for _, text in ipairs(split(body, ";")) do
            table.insert(records, decodeRecord(text))
        end
    end)
    if not ok then
        return nil, tostring(err)
    end
    return records
end
