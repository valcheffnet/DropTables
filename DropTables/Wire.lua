local _, ns = ...

-- Text format of shared counts. A data message is
--   "1|<install id>|<seq>|<record>;<record>;..."
-- and each record replaces the previous one with the same key, so resending is harmless:
--   M<npc>.<bucket>.<kills>.<lootable>.<opened>.<money drops>.<copper>.<money min>.<money max>
--   I<npc>.<bucket>.<item>.<drops>.<qty>.<min>.<max>
--   L<npc>.<min level>.<max level>
--   Z<npc>.<map>.<kills>
--   P<npc>.<map>.<cell>.<kills>
-- Numbers are base 36; an empty field is a missing value (min/max, unknown level).
local Wire = {}
ns.Wire = Wire

Wire.VERSION = "1"
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

local function decodeNumber(s)
    if s == "" then
        return nil
    end
    if not s:match("^[0-9a-z]+$") then
        error("bad number")
    end
    return tonumber(s, 36)
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

-- All records of one mob bucket: its counts first, then one record per item.
function Wire.BucketRecords(npc, bucket, data)
    local records = { Wire.MobRecord(npc, bucket, data) }
    for itemId, item in pairs(data.items) do
        table.insert(records, Wire.ItemRecord(npc, bucket, itemId, item))
    end
    return records
end

-- Level range, kills per map and kill spots of one mob.
function Wire.InfoRecords(npc, info)
    local id = encodeNumber(npc)
    local records = { "L" .. id .. "." .. encodeNumber(info.minLevel) .. "." .. encodeNumber(info.maxLevel) }
    for mapId, place in pairs(info.maps) do
        local map = encodeNumber(mapId)
        table.insert(records, "Z" .. id .. "." .. map .. "." .. encodeNumber(place.kills))
        for cell, kills in pairs(place.cells) do
            table.insert(records, "P" .. id .. "." .. map .. "." .. encodeNumber(cell) .. "." .. encodeNumber(kills))
        end
    end
    return records
end

function Wire.Header(installId, seq)
    return Wire.VERSION .. "|" .. installId .. "|" .. encodeNumber(seq) .. "|"
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

local function decodeRecord(text)
    local kind = text:sub(1, 1)
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
    return record
end

-- Returns install id, sequence number and records, or nil and a reason for a malformed message.
function Wire.Decode(message)
    local version, installId, seq, body = message:match("^(%w+)|(%x+)|([0-9a-z]+)|(.*)$")
    if version ~= Wire.VERSION or #installId ~= 16 then
        return nil, "bad header"
    end
    local records = {}
    local ok, err = pcall(function()
        for _, text in ipairs(split(body, ";")) do
            table.insert(records, decodeRecord(text))
        end
    end)
    if not ok then
        return nil, tostring(err)
    end
    return installId, tonumber(seq, 36), records
end
