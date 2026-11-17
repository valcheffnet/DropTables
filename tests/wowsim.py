"""Loads Drop Tables files into a Lua 5.1 state with stubbed WoW APIs.

Requires: pip install lupa
"""
import pathlib
import sys
import zlib

from lupa import lua51

ADDON_DIR = pathlib.Path(__file__).resolve().parent.parent / "DropTables"

STUBS = r"""
timers = {}
tickers = {}
now = 0
lootable = {}      -- guid -> true/false, what CanLootUnit answers
lootSlots = {}     -- current loot window
units = {}         -- unit token -> guid
outbox = {}        -- addon messages sent: { prefix, text, chatType, target }
sendResult = 0

function CreateFrame()
    return { RegisterEvent = function() end, SetScript = function() end }
end
function strsplit(sep, s)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%-", "%%-")) do table.insert(out, part) end
    return unpack(out)
end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function print() end
date = os.date
-- Errors that ns.Fire hands to the error handler; the Client raises them in Python.
luaErrors = {}
function geterrorhandler() return function(err) table.insert(luaErrors, tostring(err)) end end
-- Chat windows: chatWindowNames[i] is the tab name of ChatFrame<i>; each frame keeps what it was given.
chatWindowNames = { "General", "Combat Log" }
NUM_CHAT_WINDOWS = 10
for i = 1, NUM_CHAT_WINDOWS do
    _G["ChatFrame" .. i] = { lines = {}, AddMessage = function(self, text) table.insert(self.lines, text) end }
end
DEFAULT_CHAT_FRAME = ChatFrame1
function GetChatWindowInfo(i) return chatWindowNames[i] end
SlashCmdList = {}
Enum = {}
function issecretvalue() return false end
function GetTime() return now end
function time() return math.floor(now) end
groupMembers = {}  -- names of the other party members, party1 first
function GetNumGroupMembers() return #groupMembers > 0 and #groupMembers + 1 or 0 end
function IsInGroup(category) return category == nil and #groupMembers > 0 end
function IsInRaid() return false end
LE_PARTY_CATEGORY_INSTANCE = 2
function IsEncounterInProgress() return false end
function CanLootUnit(guid) return lootable[guid] end
function UnitGUID(unit) return units[unit] end
function UnitIsDead(unit) return units[unit] ~= nil end
function UnitName(unit)
    local index = tonumber(unit:match("^party(%d+)$") or "")
    if index then return groupMembers[index] end
    return "Test Mob"
end
unitLevels = {}    -- unit token -> level
playerMap = 1429   -- map the player stands on; nil = no map
playerX, playerY = 0.5, 0.5  -- nil = no position (instances)
function UnitLevel(unit) return unitLevels[unit] end
C_Map = {
    GetBestMapForUnit = function() return playerMap end,
    GetPlayerMapPosition = function()
        if not playerX then return nil end
        return { GetXY = function() return playerX, playerY end }
    end,
    GetMapInfo = function(id) return { name = "Zone " .. id } end,
}
function JoinTemporaryChannel() end
function GetChannelName() return 7, "DropTablesShare" end
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() end,
    InChatMessagingLockdown = function() return false end,
    SendAddonMessage = function(prefix, text, chatType, target)
        table.insert(outbox, { prefix, text, chatType, target })
        return sendResult
    end,
}
C_Timer = {
    After = function(delay, fn) table.insert(timers, { at = now + delay, fn = fn }) end,
    NewTicker = function(interval, fn) table.insert(tickers, { interval = interval, nextAt = now + interval, fn = fn }) end,
}
itemClasses = { [100] = { 15, 0 }, [101] = { 7, 8 }, [102] = { 12, 0 } }  -- item id -> { class, subclass }
C_Item = {
    GetItemInfoInstant = function(id)
        local class = itemClasses[id] or { 15, 0 }
        return id, nil, nil, nil, 134400, class[1], class[2]
    end,
    GetItemClassInfo = function(classId) return "Class " .. classId end,
    GetItemSubClassInfo = function(classId, subclassId) return "Sub " .. classId .. "." .. subclassId end,
    GetItemQualityByID = function() return 1 end,
    GetItemInfo = function() return nil end,
}
-- Base64 in Lua: compressed bytes cannot cross into Python as text.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function encodeBase64(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
        for j = 1, 4 do
            if j <= chars then
                local index = math.floor(n / 64 ^ (4 - j)) % 64
                table.insert(out, B64:sub(index + 1, index + 1))
            else
                table.insert(out, "=")
            end
        end
    end
    return table.concat(out)
end
Enum.CompressionMethod = { Deflate = 0, Zlib = 1, Gzip = 2 }
C_EncodingUtil = {
    CompressString = function(text, method) return pyCompress(text, method) end,
    EncodeBase64 = encodeBase64,
}
function GetNumLootItems() return #lootSlots end
function GetLootSlotType(i) return lootSlots[i].type end
function GetLootSlotInfo(i)
    local s = lootSlots[i]
    return 134400, s.name, s.qty, nil, s.quality or 1, false, s.quest or false
end
function GetLootSlotLink(i)
    local s = lootSlots[i]
    return s.item and ("|cnIQ1:|Hitem:" .. s.item .. "::::|h[x]|h|r") or nil
end
function GetLootSourceInfo(i) return unpack(lootSlots[i].sources) end

-- Moves the clock forward one second at a time, running due timers and tickers.
function advance(seconds)
    local target = now + seconds
    while now < target do
        now = math.min(target, now + 1)
        local due = {}
        for i = #timers, 1, -1 do
            if timers[i].at <= now then table.insert(due, 1, table.remove(timers, i)) end
        end
        for _, t in ipairs(due) do t.fn() end
        for _, t in ipairs(tickers) do
            while t.nextAt <= now do
                t.nextAt = t.nextAt + t.interval
                t.fn()
            end
        end
    end
end
"""

ALL_FILES = ("Core.lua", "Wire.lua", "Collector.lua", "Places.lua", "Share.lua", "Export.lua", "Stats.lua",
             "Search.lua")


def py_compress(text, method):
    """Zlib as C_EncodingUtil.CompressString(text, Enum.CompressionMethod.Zlib) gives it."""
    assert method == 1, "export must use zlib"
    return zlib.compress(text.encode("utf-8"))


class Client:
    """One game client with the addon loaded."""

    def __init__(self, name, files=ALL_FILES, saved=None):
        """saved: Lua code run before the addon loads, e.g. to set DropTablesDB as the game would."""
        self.name = name
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.g = self.lua.globals()
        self.g.pyCompress = py_compress
        self.lua.execute(STUBS)
        if saved:
            self.lua.execute(saved)
        self.ns = self.lua.table()
        loader = self.lua.execute("return function(src, name) return assert(loadstring(src, name)) end")
        for file_name in files:
            loader((ADDON_DIR / file_name).read_text(encoding="utf-8"), file_name)("DropTables", self.ns)
        self.fire("ADDON_LOADED", "DropTables")

    def raise_errors(self):
        errors = self.g.luaErrors
        if len(errors):
            raise RuntimeError("%s: Lua error in a listener: %s" % (self.name, errors[1]))

    def fire(self, event, *args):
        self.ns.Fire(event, *args)
        self.raise_errors()

    def advance(self, seconds):
        self.g.advance(seconds)
        self.raise_errors()

    def kill(self, npc, spawn, has_loot):
        guid = "Creature-0-1-0-1-%d-%s" % (npc, spawn)
        self.g.lootable[guid] = has_loot
        self.fire("PARTY_KILL", "Player-1-ABC", guid)
        return guid

    def loot(self, slots, from_item=False):
        table = self.lua.table()
        for i, slot in enumerate(slots, 1):
            entry = self.lua.table()
            for key, value in slot.items():
                entry[key] = self.lua.table(*value) if key == "sources" else value
            table[i] = entry
        self.g.lootSlots = table
        self.fire("LOOT_OPENED", True, from_item)

    def see(self, npc, spawn, level, unit="target"):
        """The player targets (or mouses over) a mob of the given level."""
        self.g.units[unit] = "Creature-0-1-0-1-%d-%s" % (npc, spawn)
        self.g.unitLevels[unit] = level
        self.fire("PLAYER_TARGET_CHANGED" if unit == "target" else "UPDATE_MOUSEOVER_UNIT")

    def stand(self, map_id, x=None, y=None):
        self.g.playerMap = map_id
        self.g.playerX, self.g.playerY = x, y

    def take_outbox(self):
        sent = [tuple(m.values()) for m in self.g.outbox.values()]
        self.g.outbox = self.lua.table()
        return sent


failures = []


def expect(label, actual, wanted):
    """Records a failed check; report() lists them at the end."""
    if actual != wanted:
        failures.append("%s: got %r, want %r" % (label, actual, wanted))


def report(name):
    """Prints the result of a test file and exits with 1 when a check failed."""
    if failures:
        print("FAILED")
        for line in failures:
            print("  " + line)
        sys.exit(1)
    print("all %s checks passed" % name)
