local _, ns = ...

-- What farming a mob is worth: its drops at the prices the player's own addons know, times an estimate of how many it
-- dies an hour. Prices never leave the player's game: they aren't shared, exported or put in the shared database.
local CALLER = "DropTables"
local AUCTION_CUT = 0.95      -- the auction house keeps 5% of a sale
local MAX_AUCTION_AGE = 21    -- days; an older auction price is left for the vendor price
local RARE = 3                -- items of this quality and up are lucky drops, left out of the value
local BIND_ON_PICKUP = 1

-- Lower mobs die faster: kills an hour on a mob of the player's level, times this for a mob that many levels below
-- (a negative difference is a mob above the player).
local LEVEL_FACTORS = { { 10, 1.5 }, { 5, 1.25 }, { 0, 1 }, { -2, 0.8 } }
local ABOVE_FACTOR = 0.6

local function call(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok and type(value) == "number" and not ns.IsSecret(value) then
        return value
    end
end

-- Auctionator's price when it saw the item in the last MAX_AUCTION_AGE days, else TradeSkillMaster's market value,
-- and which of the two it was.
local function auctionPrice(itemId)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local age = api.GetAuctionAgeByItemID and call(api.GetAuctionAgeByItemID, CALLER, itemId)
        local price = call(api.GetAuctionPriceByItemID, CALLER, itemId)
        if price and (age == nil or age <= MAX_AUCTION_AGE) then
            return price, "Auctionator"
        end
    end
    if TSM_API and TSM_API.GetCustomPriceValue and TSM_API.ToItemString then
        local ok, itemString = pcall(TSM_API.ToItemString, "i:" .. itemId)
        local price = ok and itemString and call(TSM_API.GetCustomPriceValue, "DBMarket", itemString)
        if price then
            return price, "TradeSkillMaster"
        end
    end
end

-- What one of the item fetches, and where that price comes from: the vendor price, or what it sells for on the
-- auction house after the cut when that is more. Items bound on pickup and random world drops only go to a vendor.
-- nil while the client doesn't know the item yet.
function ns.PriceInfo(itemId, vendorOnly)
    local name, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = C_Item.GetItemInfo(itemId)
    if not name then
        return nil
    end
    local vendor = sellPrice or 0
    if vendorOnly or bindType == BIND_ON_PICKUP then
        return vendor, "vendor"
    end
    local auction, source = auctionPrice(itemId)
    auction = auction and math.floor(auction * AUCTION_CUT)
    if auction and auction > vendor then
        return auction, source
    end
    return vendor, "vendor"
end

function ns.UnitPrice(itemId, vendorOnly)
    return (ns.PriceInfo(itemId, vendorOnly))
end

-- True when the entry counts in g/ph: not rare, and a world drop only when the player asks for those. Skinning has no
-- world drops.
function ns.CountsInValue(entry)
    return (entry.quality or 0) < RARE and (not entry.world or ns.settings.gphWorldDrops)
end

-- Copper one kill of the mob brings on average: money plus every item that isn't rare, each at its chance per kill and
-- its average stack. Random world drops only count when the player asks for them in the Loot Finder, since any mob
-- of the level can drop them and one lucky drop in a few kills would decide the whole value.
function ns.ValuePerKill(npc)
    local stats = ns.GetStats(npc, "all")
    if not stats then
        return 0
    end
    local value = 0
    for _, entry in ipairs(stats.list) do
        if entry.money then
            value = value + entry.rate * entry.avg
        elseif ns.CountsInValue(entry) then
            local price = ns.UnitPrice(entry.itemId, entry.world)
            if price then
                value = value + entry.rate * entry.avgQty * price
            end
        end
    end
    return value
end

-- The kills an hour from the setting, more for a mob below the player's level and fewer for one above it.
function ns.KillsPerHour(npc)
    local base = ns.settings.killsPerHour
    local info = ns.MobInfo(npc)
    local level = UnitLevel("player")
    if not info or not info.minLevel or type(level) ~= "number" or ns.IsSecret(level) then
        return base
    end
    local difference = level - info.minLevel
    for _, step in ipairs(LEVEL_FACTORS) do
        if difference >= step[1] then
            return base * step[2]
        end
    end
    return base * ABOVE_FACTOR
end

-- Copper skinning one corpse of the mob brings on average: every item it gives that isn't rare, at its chance per
-- skinned corpse and its average stack.
function ns.SkinValue(npc)
    local skin = ns.GetSkinStats(npc)
    local value = 0
    for _, entry in ipairs(skin and skin.list or {}) do
        if ns.CountsInValue(entry) then
            local price = ns.UnitPrice(entry.itemId)
            if price then
                value = value + entry.rate * entry.avgQty * price
            end
        end
    end
    return value
end

-- Worked out once per mob until its counts, the prices, the setting or the player's level change, because the Loot
-- Finder sorts long lists by it. Loot and skinning are kept apart.
local cache, skinCache = {}, {}

local function forget(npc)
    if npc then
        cache[npc], skinCache[npc] = nil, nil
    else
        cache, skinCache = {}, {}
    end
end

function ns.GoldPerHour(npc)
    local value = cache[npc]
    if not value then
        value = math.floor(ns.ValuePerKill(npc) * ns.KillsPerHour(npc))
        cache[npc] = value
    end
    return value
end

-- What skinning alone brings in an hour, with every kill skinned.
function ns.SkinGoldPerHour(npc)
    local value = skinCache[npc]
    if not value then
        value = math.floor(ns.SkinValue(npc) * ns.KillsPerHour(npc))
        skinCache[npc] = value
    end
    return value
end

-- The coins' own colours for the letters.
local COINS = { { 10000, "|cffffd700g|r" }, { 100, "|cffc7c7cfs|r" }, { 1, "|cffeda55fc|r" } }

-- "1g 5s 3c" with g, s and c in their coin colours, leaving out the parts that are 0, and "" for nothing.
function ns.FormatGold(copper)
    copper = math.floor(copper or 0)
    local parts = {}
    for _, coin in ipairs(COINS) do
        local amount = math.floor(copper / coin[1])
        copper = copper - amount * coin[1]
        if amount > 0 then
            table.insert(parts, amount .. coin[2])
        end
    end
    return table.concat(parts, " ")
end

local function pricesChanged()
    forget()
    ns.Fire("DT_PRICES_CHANGED")
end

-- The windows redraw on these themselves, so the values only have to be worked out again.
local function forgetAll()
    forget()
end
ns.On("DT_DATA_CHANGED", forget)
ns.On("DT_COUNTS_CHANGED", forget)
ns.On("DT_SETTINGS_CHANGED", forgetAll)
ns.On("GET_ITEM_INFO_RECEIVED", forgetAll)
ns.On("PLAYER_LEVEL_UP", pricesChanged)

-- Auctionator says when a scan brought new prices.
local function watchAuctionator()
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.RegisterForDBUpdate then
        pcall(api.RegisterForDBUpdate, CALLER, pricesChanged)
        return true
    end
end

ns.On("DT_READY", function()
    if not watchAuctionator() then
        ns.On("ADDON_LOADED", function(name)
            if name == "Auctionator" then
                watchAuctionator()
            end
        end)
    end
end)
