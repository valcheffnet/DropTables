"""Checks kill and loot recording and drop rates with stubbed WoW APIs.

Requires: pip install lupa
Run: python tests/test_collector.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wowsim import Client, expect, report  # noqa: E402


def guid(npc, spawn):
    return "Creature-0-1-0-1-%d-%s" % (npc, spawn)


def main():
    client = Client("Tester")
    lua, g, ns = client.lua, client.g, client.ns

    def kill(spawn, has_loot, npc=1):
        return client.kill(npc, spawn, has_loot)

    loot = client.loot

    a = kill("A", True)
    kill("B", False)  # empty corpse
    kill("C", True)  # has loot, never opened
    d = kill("D", True)
    # D is looted before the loot check runs (fast autoloot).
    loot([{"type": 1, "item": 101, "name": "Meat", "qty": 1, "sources": [d, 1]},
          {"type": 2, "name": "5 Copper", "qty": 0, "sources": [d, 5]}])
    g.advance(5)
    loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 2, "sources": [a, 2]},
          {"type": 1, "item": 102, "name": "Quest Paw", "qty": 1, "quest": True, "sources": [a, 1]},
          {"type": 2, "name": "10 Copper", "qty": 0, "sources": [a, 10]}])
    # Skinning D reopens the same corpse: must be ignored.
    loot([{"type": 1, "item": 101, "name": "Meat", "qty": 1, "sources": [d, 1]}])
    # Pickpocket: a living mob that was never killed.
    loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [guid(2, "P"), 1]}])
    # A sparkling corpse that opens empty is found through the mouseover.
    e = kill("E", True)
    g.advance(5)
    g.units["mouseover"] = e
    loot([])
    g.units["mouseover"] = None
    # Area loot: one slot holding the same item from two corpses.
    f = kill("F", True)
    gg = kill("G", True)
    g.advance(5)
    loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 4, "sources": [f, 1, gg, 3]}])
    # Loot from a container item is not mob loot.
    loot([{"type": 1, "item": 101, "name": "Meat", "qty": 1, "sources": [f, 1]}], from_item=True)
    # One corpse with the same item split over two slots: one drop of a stack of 3.
    h = kill("H", True)
    g.advance(5)
    loot([{"type": 1, "item": 101, "name": "Meat", "qty": 1, "sources": [h, 1]},
          {"type": 1, "item": 101, "name": "Meat", "qty": 2, "sources": [h, 2]}])

    solo = ns.db.mobs[1][1]
    expect("kills", solo.kills, 8)
    expect("lootable", solo.lootable, 7)
    expect("opened", solo.opened, 6)
    fang_data = solo["items"][100]
    expect("fang drops", fang_data.drops, 3)
    expect("fang qty", fang_data.qty, 6)
    expect("fang range", (fang_data.min, fang_data.max), (1, 3))
    meat_data = solo["items"][101]
    expect("meat drops", meat_data.drops, 2)
    expect("meat qty", meat_data.qty, 4)
    expect("meat range", (meat_data.min, meat_data.max), (1, 3))
    expect("quest item skipped", solo["items"][102], None)
    expect("money drops", solo.money.drops, 2)
    expect("money copper", solo.money.copper, 15)
    expect("money range", (solo.money.min, solo.money.max), (5, 10))
    expect("pickpocket npc ignored", ns.db.mobs[2], None)

    stats = ns.GetStats(1, "all")
    fang = next(e for e in stats.list.values() if e.itemId == 100)
    expect("fang rate", round(fang.rate, 6), round(7 / 8 * 3 / 6, 6))
    expect("fang stack text", ns.FormatStack(fang), "1-3")
    expect("money rate", round(stats.money.rate, 6), round(7 / 8 * 2 / 6, 6))
    expect("money stats range", (stats.money.min, stats.money.max), (5, 10))
    expect("empty kills", stats.empty, 1)

    # Money is an entry of the list, sorted by chance with the items.
    entries = list(stats.list.values())
    rates = [e.rate for e in entries]
    expect("list sorted by chance", rates, sorted(rates, reverse=True))
    expect("money in the list", [e.money for e in entries].count(True), 1)
    ns.settings.minQuality = 2
    visible, world_count, low_count = ns.VisibleEntries(stats)
    expect("quality filter keeps only money", [bool(e.money) for e in visible.values()], [True])
    expect("filtered items counted as low quality, not world", (world_count, low_count), (0, len(entries) - 1))
    ns.settings.minQuality = 0

    # Gear of any quality is a world drop unless a well-sampled mob drops it often.
    lua.execute("""
        local base = C_Item.GetItemInfoInstant
        C_Item.GetItemInfoInstant = function(id)
            if id == 200 then return id, nil, nil, nil, 134400, 4 end
            return base(id)
        end
    """)
    gear_mob = ns.db.mobs
    gear_mob[3] = lua.eval("{ [1] = { kills = 20, lootable = 20, opened = 20, items = { [200] = { drops = 1, qty = 1 } }, money = { drops = 0, copper = 0 } } }")
    gear = next(e for e in ns.GetStats(3, "all").list.values() if e.itemId == 200)
    expect("grey gear at 5% is a world drop", gear.world, True)
    gear_mob[3][1]["items"][200].drops = 8
    gear = next(e for e in ns.GetStats(3, "all").list.values() if e.itemId == 200)
    expect("gear at 40% of 20 corpses is the mob's own", gear.world, False)
    ns.settings.collapseWorldDrops = True
    visible, world_count, _ = ns.VisibleEntries(ns.GetStats(3, "all"))
    expect("own gear stays visible", (len(list(visible.values())), world_count), (1, 0))
    gear_mob[3][1]["items"][200].drops = 1
    visible, world_count, _ = ns.VisibleEntries(ns.GetStats(3, "all"))
    expect("world drop left out of icons", (len(list(visible.values())), world_count), (0, 1))
    expect("group mode empty", ns.GetStats(1, "group"), None)
    expect("rate format", ns.FormatRate(0.514), "51%")
    expect("rate format small", ns.FormatRate(0.0123), "1.2%")

    # Skinning an empty corpse right after the kill is profession loot, not the mob's drop.
    skinner = Client("Skinner")
    s = skinner.kill(4, "S", False)
    skinner.advance(2)
    skinner.fire("UNIT_SPELLCAST_START", "player")
    skinner.fire("UNIT_SPELLCAST_SUCCEEDED", "player")
    skinner.loot([{"type": 1, "item": 300, "name": "Light Leather", "qty": 1, "sources": [s, 1]}])
    skinner.advance(3)
    skinned = skinner.ns.db.mobs[4][1]
    expect("skinned corpse counted as an empty kill", (skinned.kills, skinned.lootable, skinned.opened), (1, 0, 0))
    expect("leather not a drop", skinned["items"][300], None)
    # An instant spell just before looting does not hide the loot.
    t = skinner.kill(4, "T", True)
    skinner.advance(5)
    skinner.fire("UNIT_SPELLCAST_SUCCEEDED", "player")
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [t, 1]}])
    expect("loot after an instant spell counted", skinned["items"][100].drops, 1)
    # Opening a recorded corpse again does not mark the mob as changed.
    skinner.lua.execute("changes = 0")
    skinner.ns.On("DT_COUNTS_CHANGED", skinner.lua.eval("function() changes = changes + 1 end"))
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [t, 1]}])
    expect("reopened corpse is no change", skinner.g.changes, 0)

    # An empty window belongs to the corpse under the interact key or the mouse, not to the target.
    x = skinner.kill(5, "X", True)
    y = skinner.kill(5, "Y", True)
    skinner.advance(5)
    skinner.g.units["target"] = y
    skinner.g.units["softinteract"] = x
    skinner.loot([])
    skinner.g.units["softinteract"] = None
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [y, 1]}])
    expect("both corpses opened once", skinner.ns.db.mobs[5][1].opened, 2)
    expect("the target's own loot counted", skinner.ns.db.mobs[5][1]["items"][100].drops, 1)

    # In a party, a corpse the player may not loot is someone else's, not an empty kill.
    party = Client("Partner")
    party.g.groupMembers = party.lua.table("Looter")
    party.kill(6, "R", False)
    party.advance(5)
    expect("partner's corpse not counted", party.ns.db.mobs[6], None)

    # /dt debug is a saved setting and opens its own chat tab with no other messages in it.
    tester = Client("Debugger")
    tester.lua.execute("""
        groupsRemoved = 0
        FCF_OpenNewWindow = function(name) chatWindowNames[4] = name; return ChatFrame4 end
        FCF_Close = function(frame) if frame == ChatFrame4 then chatWindowNames[4] = nil end end
        ChatFrame_RemoveAllMessageGroups = function(frame) if frame == ChatFrame4 then groupsRemoved = 1 end end
    """)
    tester.g.SlashCmdList.DROPTABLES("debug")
    expect("debug saved", tester.ns.settings.debug, True)
    expect("debug tab opened", (tester.g.chatWindowNames[4], tester.g.groupsRemoved), ("DT Debug", 1))
    expect("debug lines in the tab", len(tester.g.ChatFrame4.lines) > 0, True)
    tester.g.SlashCmdList.DROPTABLES("debug")
    expect("debug off closes the tab", (tester.ns.settings.debug, tester.g.chatWindowNames[4]), (False, None))
    tester.g.SlashCmdList.DROPTABLES("debug")
    expect("debug on opens it again", tester.g.chatWindowNames[4], "DT Debug")
    reloaded = Client("Reloaded", saved="DropTablesDB = { settings = { debug = true } }")
    reloaded.ns.Debug("after a reload")
    expect("debug still on after a reload", len(reloaded.g.ChatFrame1.lines), 1)

    # Restore defaults puts the settings back and forgets window places, and keeps the recorded drops.
    ns.settings.minQuality = 3
    ns.settings.debug = True
    ns.settings.stripPos = lua.table(10, 20)
    ns.settings.finderCategory = "7:0"
    ns.RestoreDefaults()
    expect("settings back to defaults", (ns.settings.minQuality, ns.settings.debug, ns.settings.stripPos,
                                         ns.settings.finderCategory), (0, False, None, None))
    expect("recorded drops kept", ns.db.mobs[1][1].kills, 8)

    report("collector")


if __name__ == "__main__":
    main()
