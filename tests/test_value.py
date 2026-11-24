"""Gold per hour in the Loot Finder: item prices from the vendor, Auctionator or TradeSkillMaster, the value of a kill,
kills per hour by level, and the "1g 5s 3c" format.

Requires: pip install lupa
Run: python tests/test_value.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wowsim import ALL_FILES, FINDER_STUBS, Client, expect, report  # noqa: E402

# Items: 100 sells for 50c and goes for more at auction, 101 is bound on pickup, 103 is rare, 105 is armor (a random
# world drop) and 106 is one the client doesn't know yet.
PRICES = """
itemInfo = {
    [100] = { sell = 50, bind = 0 }, [101] = { sell = 20, bind = 1 }, [103] = { sell = 1000, bind = 0 },
    [105] = { sell = 30, bind = 2 },
}
C_Item.GetItemInfo = function(id)
    local i = itemInfo[id]
    if not i then return nil end
    return "Item " .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, i.sell, nil, nil, i.bind
end
itemClasses[105] = { 4, 1 }
auctionPrices, auctionAges = { [100] = 200, [101] = 1000, [103] = 5000, [105] = 900 }, {}
Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(_, id) return auctionPrices[id] end,
    GetAuctionAgeByItemID = function(_, id) return auctionAges[id] end,
    RegisterForDBUpdate = function(_, fn) auctionatorUpdate = fn end,
} } }
"""


def loot(client, npc, spawn, items, copper):
    guid = client.kill(npc, spawn, True)
    client.advance(5)
    slots = [{"type": 1, "item": item, "name": "Item %d" % item, "qty": 1, "quality": quality, "sources": [guid, 1]}
             for item, quality in items]
    slots.append({"type": 2, "name": "Copper", "qty": 0, "sources": [guid, copper]})
    client.loot(slots)


def main():
    c = Client("Farmer", saved=PRICES)
    ns = c.ns
    gold, silver, copper_ = "|cffffd700g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
    for amount, text in ((0, ""), (5, "5" + copper_), (100, "1" + silver), (10005, "1%s 5%s" % (gold, copper_)),
                         (123456, "12%s 34%s 56%s" % (gold, silver, copper_))):
        expect("format of %d copper, letters in the coin colours" % amount, ns.FormatGold(amount), text)

    # Four kills of mob 1, each with 10 copper: item 100 in two of them, the bound item in all four, the rare one
    # once, the world drop once and the unknown item once.
    loot(c, 1, "A", [(100, 1), (101, 1), (103, 3), (106, 1)], 10)
    loot(c, 1, "B", [(100, 1), (101, 1), (105, 2)], 10)
    loot(c, 1, "C", [(101, 1)], 10)
    loot(c, 1, "D", [(101, 1)], 10)
    # Money 10 + item 100 at 200 x 0.95 = 190 in half of the kills + the bound item at its vendor 20. The rare item,
    # the unknown one and, by default, the world drop add nothing.
    per_kill = 10 + 0.5 * 190 + 20
    expect("value of a kill", ns.ValuePerKill(1), per_kill)
    expect("the price and where it comes from", ns.PriceInfo(100), (190, "Auctionator"))
    expect("a bound item's price is the vendor's", ns.PriceInfo(101), (20, "vendor"))
    expect("a world drop's price is the vendor's", ns.PriceInfo(105, True), (30, "vendor"))
    expect("gold per hour at 70 kills an hour", ns.GoldPerHour(1), int(per_kill * 70))
    # The client brings item 106 later. Info for items Drop Tables never asked about keeps the cached value, and 106's
    # own arrival counts it in.
    c.lua.execute("itemInfo[106] = { sell = 400, bind = 0 }")
    c.fire("GET_ITEM_INFO_RECEIVED", 4242, True)
    expect("an unrelated item keeps the cached g/ph", ns.GoldPerHour(1), int(per_kill * 70))
    c.fire("GET_ITEM_INFO_RECEIVED", 106, True)
    expect("the awaited item's info updates g/ph", ns.GoldPerHour(1) > int(per_kill * 70), True)
    c.lua.execute("itemInfo[106] = nil")
    c.fire("DT_DATA_CHANGED", 1)
    # With world drops on, the armor counts at its vendor 30 in a quarter of the kills, not at its auction price.
    ns.settings.gphWorldDrops = True
    c.fire("DT_SETTINGS_CHANGED")
    expect("world drops count at their vendor price when asked for", ns.GoldPerHour(1), int((per_kill + 0.25 * 30) * 70))
    counts = c.lua.eval("function(ns, quality, world) return ns.CountsInValue({ quality = quality, world = world }) end")
    expect("a world drop counts when asked for", counts(ns, 2, True), True)
    expect("a rare drop never counts, and the drop table says why", counts(ns, 3, True), (False, "rare"))
    ns.settings.gphWorldDrops = False
    c.fire("DT_SETTINGS_CHANGED")
    expect("a world drop left out says why", counts(ns, 2, True), (False, "world"))

    # An auction price older than 21 days doesn't count, and the vendor price takes over.
    c.g.auctionAges[100] = 30
    c.g.auctionatorUpdate()
    expect("an old auction price falls back to the vendor", ns.GoldPerHour(1), int((10 + 0.5 * 50 + 20) * 70))
    # Without Auctionator, TradeSkillMaster's market value is used.
    c.lua.execute("""
        Auctionator = nil
        TSM_API = { ToItemString = function(s) return s end,
                    GetCustomPriceValue = function(source, s) return source == "DBMarket" and s == "i:100" and 400 end }
    """)
    c.fire("DT_SETTINGS_CHANGED")
    expect("TradeSkillMaster's price when Auctionator is missing", ns.ValuePerKill(1), 10 + 0.5 * 380 + 20)
    expect("TradeSkillMaster named as the source", ns.PriceInfo(100), (380, "TradeSkillMaster"))
    # FojjiCore's own scan comes before TradeSkillMaster when it's no older than 21 days. It loads after Drop Tables,
    # and its scan tells the values to be worked out again.
    gph_tsm = ns.GoldPerHour(1)
    c.lua.execute("""
        fojjiSeen, fojjiFrom = time() - 86400, nil
        FojjiCoreNS = { Auctions = {
            Price = function(id) if id == 100 then return 300, 5, fojjiSeen, fojjiFrom end end,
            OnChange = function(fn) fojjiChanged = fn end,
        } }
    """)
    c.fire("ADDON_LOADED", "FojjiCore_Professions")
    expect("FojjiCore's scan before TradeSkillMaster", ns.PriceInfo(100), (285, "FojjiCore"))
    expect("the cached value stays until FojjiCore scans", ns.GoldPerHour(1), gph_tsm)
    c.g.fojjiChanged()
    expect("a FojjiCore scan updates g/ph", ns.GoldPerHour(1), int((10 + 0.5 * 285 + 20) * 70))
    c.lua.execute("fojjiSeen = time() - 30 * 86400")
    expect("an old FojjiCore scan is left out", ns.PriceInfo(100), (380, "TradeSkillMaster"))
    c.lua.execute("fojjiSeen, fojjiFrom = time() - 86400, 'auctionator'")
    expect("Auctionator's price passed on by FojjiCore is left out", ns.PriceInfo(100), (380, "TradeSkillMaster"))
    c.lua.execute("fojjiFrom = nil; FojjiCoreNS.Auctions.Price = function() error('changed') end")
    expect("a FojjiCore that changed only means no price from it", ns.PriceInfo(100), (380, "TradeSkillMaster"))
    c.lua.execute("FojjiCoreNS = nil")
    # A vendor price above the auction price wins.
    c.lua.execute("TSM_API = nil")
    c.g.itemInfo[100].sell = 60
    c.fire("DT_SETTINGS_CHANGED")
    expect("the vendor price without any auction addon", ns.ValuePerKill(1), 10 + 0.5 * 60 + 20)
    expect("the vendor named as the source", ns.PriceInfo(100), (60, "vendor"))

    # Kills an hour follow the setting and the level difference.
    ns.settings.killsPerHour = 100
    c.fire("DT_SETTINGS_CHANGED")
    expect("the setting sets the kills an hour", ns.KillsPerHour(1), 100)
    c.see(1, "A", 8)
    for player, kills in ((8, 100), (13, 125), (18, 150), (6, 80), (5, 60)):
        c.g.unitLevels["player"] = player
        c.fire("PLAYER_LEVEL_UP")
        expect("kills an hour at player level %d on a level 8 mob" % player, ns.KillsPerHour(1), kills)
    c.g.unitLevels["player"] = 18
    c.fire("PLAYER_LEVEL_UP")
    expect("a mob far below counts half as many kills again", ns.GoldPerHour(1), int((10 + 0.5 * 60 + 20) * 150))

    # The Loot Finder can sort the mobs that drop an item by it. Mob 2 drops item 100 as often as mob 1 does, but its
    # money makes it worth more.
    loot(c, 2, "E", [(100, 1)], 500)
    loot(c, 2, "F", [], 500)
    order = c.lua.eval("""function(ns)
        local list = ns.FilterDroppers(ns.FindDroppers(100), {}, "gph", true)
        local out = {}
        for i, d in ipairs(list) do out[i] = d.npc end
        return out
    end""")(ns)
    expect("sorted by gold per hour", [order[i] for i in range(1, len(order) + 1)], [2, 1])
    # Mob 1 has the better chance of item 101, but mob 3 brings more gold an hour, so it's the best mob, and with no
    # gold either way the chance decides.
    for spawn in ("G", "H", "I"):
        loot(c, 3, spawn, [(101, 1)] if spawn == "G" else [], 900)
    best = c.lua.eval("function(ns, item) return ns.BestDropper(ns.FindDroppers(item)).npc end")
    expect("the best mob is the one with the most gold an hour", best(ns, 101), 3)
    summaries = ns.SummarizeItems(ns.SearchItems(""))[0]
    row = next(s for s in summaries.values() if s.itemId == 101)
    expect("the item list shows the best mob's gold an hour", (row.bestNpc, row.gph), (3, ns.GoldPerHour(3)))

    # Skinning has its own gold an hour: mob 50 gives item 100 (60c at the vendor by now) in half of its 4 skins, two
    # at a time, and the rare item 103 once, which doesn't count. Kills an hour are the 100 of the setting.
    c.lua.execute("""
        DropTablesDB.skins[50] = { skinned = 4, items = {
            [100] = { drops = 2, qty = 4, min = 2, max = 2 }, [103] = { drops = 1, qty = 1, min = 1, max = 1 } } }
    """)
    c.fire("DT_DATA_CHANGED", 50)
    expect("skinning is worth its items at their price", ns.SkinValue(50), 0.5 * 2 * 60)
    expect("skinning gold an hour", ns.SkinGoldPerHour(50), int(0.5 * 2 * 60 * 100))
    expect("the loot gold an hour of a mob only skinned", ns.GoldPerHour(50), 0)
    skinners = ns.FindSkinners(100)
    expect("a skinner's g/ph is its skinning", ns.MobGoldPerHour(skinners[1]), ns.SkinGoldPerHour(50))
    skin_rows = ns.SummarizeSkinItems(ns.SkinItems(""))[0]
    expect("the skinning list shows the lowest mob's skinning g/ph",
           next(s.gph for s in skin_rows.values() if s.itemId == 100), ns.SkinGoldPerHour(50))

    # The Loot Finder writes the g/ph of every mob that drops the item into its row.
    viewer = Client("Viewer", files=ALL_FILES + ("Style.lua", "Finder.lua"), saved=FINDER_STUBS + PRICES)
    loot(viewer, 1, "A", [(100, 1)], 10)
    viewer.lua.execute("texts = {}")
    viewer.ns.OpenFinder(100)
    shown = set(viewer.g.texts.values())
    expect("the Loot Finder shows the mob's g/ph", viewer.ns.FormatGold(viewer.ns.GoldPerHour(1)) in shown, True)

    # The mob tooltip shows the g/ph at the right end of the level line, which sits lower when the mob has a title.
    tipper = Client("Tipper", files=ALL_FILES + ("Tooltip.lua",), saved=FINDER_STUBS + PRICES + """
        GetCoinTextureString = function(copper) return copper .. "c" end
        TOOLTIP_UNIT_LEVEL = "Level %s"
        TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) tooltipHook = fn end }
        Enum.TooltipDataType = { Unit = 1 }
        local function line(text)
            return { text = text, GetText = function(self) return self.text end,
                SetText = function(self, t) self.text = t end, SetTextColor = function() end, Show = function() end }
        end
        tipPairs = {}
        tipLeft = { line("Deepmoss Venomspitter"), line("Spider Title"), line("Level 18"), line("Corpse") }
        tipRight = { line(nil), line(nil), line(nil), line(nil) }
        for i = 1, 4 do _G["GameTooltipTextLeft" .. i], _G["GameTooltipTextRight" .. i] = tipLeft[i], tipRight[i] end
        GameTooltip = setmetatable({
            GetName = function() return "GameTooltip" end,
            NumLines = function() return #tipLeft end,
            AddLine = function() end,
            AddDoubleLine = function(_, left, right) table.insert(tipPairs, { left, right }) end,
        }, getmetatable(GameTooltip))
    """)
    loot(tipper, 1, "A", [(100, 1)], 10)
    tipper.g.tooltipHook(tipper.g.GameTooltip, tipper.lua.table_from({"guid": "Creature-0-1-0-1-1-T"}))
    right = [tipper.g.tipRight[i].text for i in range(1, 5)]
    expect("g/ph on the level line only", right,
           [None, None, tipper.ns.FormatGoldShort(tipper.ns.GoldPerHour(1)) + " |cff999999g/ph|r", None])
    pairs_ = [(str(p[1]), str(p[2])) for p in tipper.g.tipPairs.values()]
    item_right = next(r for l, r in pairs_ if "Item 100" in l)
    expect("the item line has its price before the chance", item_right,
           tipper.ns.FormatGoldShort(tipper.ns.UnitPrice(100)) + "   " + tipper.ns.FormatRate(1))
    money_right = next(r for l, r in pairs_ if "Money" in l)
    expect("the money line has no price", money_right, tipper.ns.FormatRate(1))
    for amount, text in ((13545, "~1%s 35%s" % (gold, silver)), (13555, "~1%s 36%s" % (gold, silver)),
                         (13500, "1%s 35%s" % (gold, silver)), (19960, "~2" + gold), (230, "2%s 30%s" % (silver, copper_))):
        expect("short format of %d copper" % amount, ns.FormatGoldShort(amount), text)

    # The details window shows the mob's g/ph next to the All / Solo / Group tabs.
    shower = Client("Shower", files=ALL_FILES + ("Style.lua", "Details.lua"),
                    saved=FINDER_STUBS + PRICES + "GetCoinTextureString = function(c) return c .. \"c\" end")
    loot(shower, 1, "A", [(100, 1)], 10)
    shower.lua.execute("texts = {}")
    shower.ns.ShowDetails(1)
    expect("the details window shows the mob's g/ph",
           shower.ns.FormatGold(shower.ns.GoldPerHour(1)) + " |cff999999g/ph|r" in set(shower.g.texts.values()), True)
    report("gold per hour")


if __name__ == "__main__":
    main()
