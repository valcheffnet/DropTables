"""Checks kill and loot recording and drop rates with stubbed WoW APIs.

Requires: pip install lupa
Run: python tests/test_collector.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wowsim import ALL_FILES, UI_STUBS, Client, expect, report  # noqa: E402


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
    # Skinning D reopens the same corpse, which has to be ignored.
    loot([{"type": 1, "item": 101, "name": "Meat", "qty": 1, "sources": [d, 1]}])
    # Pickpocketing a living mob that was never killed.
    loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [guid(2, "P"), 1]}])
    # A sparkling corpse that opens empty is found through the mouseover and counts as one that left nothing.
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
    expect("lootable", solo.lootable, 6)
    expect("opened", solo.opened, 5)
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
    expect("fang rate", round(fang.rate, 6), round(6 / 8 * 3 / 5, 6))
    expect("fang stack text", ns.FormatStack(fang), "1-3")
    expect("money rate", round(stats.money.rate, 6), round(6 / 8 * 2 / 5, 6))
    expect("money stats range", (stats.money.min, stats.money.max), (5, 10))
    expect("empty kills", stats.empty, 2)

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
    client.fire("DT_DATA_CHANGED", 3)
    gear = next(e for e in ns.GetStats(3, "all").list.values() if e.itemId == 200)
    expect("gear at 40% of 20 corpses is the mob's own", gear.world, False)
    ns.settings.collapseWorldDrops = True
    visible, world_count, _ = ns.VisibleEntries(ns.GetStats(3, "all"))
    expect("own gear stays visible", (len(list(visible.values())), world_count), (1, 0))
    gear_mob[3][1]["items"][200].drops = 1
    client.fire("DT_DATA_CHANGED", 3)
    visible, world_count, _ = ns.VisibleEntries(ns.GetStats(3, "all"))
    expect("world drop left out of icons", (len(list(visible.values())), world_count), (0, 1))
    expect("group mode empty", ns.GetStats(1, "group"), None)

    # Stats are kept between calls until the mob's counts change or item info arrives.
    same = lua.eval("function(a, b) return rawequal(a, b) end")
    first = ns.GetStats(1, "all")
    expect("stats kept between calls", same(first, ns.GetStats(1, "all")), True)
    ns.db["items"][100].quality = 3
    client.fire("GET_ITEM_INFO_RECEIVED", 100)
    fang = next(e for e in ns.GetStats(1, "all").list.values() if e.itemId == 100)
    expect("item info arriving updates the stats", fang.quality, 3)
    second = ns.GetStats(3, "all")
    kill("Z", False, npc=3)
    g.advance(5)
    expect("a new kill updates the stats", (same(second, ns.GetStats(3, "all")), ns.GetStats(3, "all").kills),
           (False, 21))
    expect("rate format", ns.FormatRate(0.514), "51%")
    expect("rate format small", ns.FormatRate(0.0123), "1.2%")

    # Spell casts are registered for the player only, not for every nameplate and raid member.
    cast_events = ("UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED",
                   "UNIT_SPELLCAST_FAILED")
    expect("casts of the player only", [g.registeredEvents[e] for e in cast_events], ["player"] * 4)
    expect("other events for everyone", g.registeredEvents["LOOT_OPENED"], True)

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
    lurker = skinner.ns.db.mobs[5][1]
    expect("empty window is a corpse that left nothing", (lurker.kills, lurker.lootable, lurker.opened), (2, 1, 1))
    expect("the target's own loot counted", skinner.ns.db.mobs[5][1]["items"][100].drops, 1)
    skinner.g.units["target"] = None

    def counts_of(client, npc):
        data = client.ns.db.mobs[npc][1]
        return data.kills, data.lootable, data.opened, data["items"][100] and data["items"][100].drops

    # With the interact key and the mouse on two different corpses there's no telling which one opened empty.
    p1, p2 = skinner.kill(7, "P1", True), skinner.kill(7, "P2", True)
    skinner.advance(5)
    skinner.g.units["softinteract"], skinner.g.units["mouseover"] = p1, p2
    skinner.loot([])
    skinner.g.units["softinteract"], skinner.g.units["mouseover"] = None, None
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [p2, 1]}])
    expect("two corpses under the cursor, neither counted empty", counts_of(skinner, 7), (2, 2, 1, 1))

    # A corpse with no loot at the last check that opens with loot later still gives its loot.
    late = skinner.kill(9, "L1", False)
    skinner.advance(5)
    skinner.g.lootable[late] = True
    skinner.advance(30)
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [late, 1]}])
    expect("late loot counted once", counts_of(skinner, 9), (1, 1, 1, 1))

    # A cast at the next mob just before looting a corpse known to hold loot does not hide the loot.
    caster = skinner.kill(10, "F1", True)
    skinner.advance(5)
    skinner.fire("UNIT_SPELLCAST_START", "player")
    skinner.fire("UNIT_SPELLCAST_SUCCEEDED", "player")
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [caster, 1]}])
    expect("loot right after a cast at another mob counted", counts_of(skinner, 10), (1, 1, 1, 1))

    # A mob finished by someone outside the group (a guard) counts when its corpse is opened under the mouse.
    skinner.advance(2)
    guarded = "Creature-0-1-0-1-11-G1"
    skinner.g.lootable[guarded] = True
    skinner.g.units["mouseover"] = guarded
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [guarded, 1]}])
    skinner.g.units["mouseover"] = None
    expect("kill finished by someone else counted from the corpse", counts_of(skinner, 11), (1, 1, 1, 1))
    # Pickpocketing the living target is not a kill.
    living = "Creature-0-1-0-1-12-A1"
    skinner.g.units["target"], skinner.g.alive["target"] = living, True
    skinner.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [living, 1]}])
    skinner.g.units["target"], skinner.g.alive["target"] = None, None
    expect("pickpocketed living target not counted", skinner.ns.db.mobs[12], None)

    # In a party, a corpse the player may not loot is someone else's, not an empty kill.
    party = Client("Partner")
    party.g.groupMembers = party.lua.table("Looter")
    party.kill(6, "R", False)
    party.advance(5)
    expect("partner's corpse not counted", party.ns.db.mobs[6], None)

    # A /reload keeps the corpses already counted, so reopening one under the mouse doesn't count it again.
    before = Client("Reloader")
    opened = before.kill(13, "O1", True)
    waiting = before.kill(13, "O2", True)
    before.advance(5)
    before.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [opened, 1]}])
    fresh = before.kill(13, "O3", False)  # its loot check hasn't run yet at the reload
    after = before.reload()
    for corpse in (opened, waiting, fresh):
        after.g.lootable[corpse] = True
    after.advance(5)
    expect("the reload's cut-off loot check runs again", counts_of(after, 13)[:3], (3, 3, 1))
    for corpse in (opened, waiting):
        after.g.units["mouseover"] = corpse
        after.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [corpse, 1]}])
    after.g.units["mouseover"] = None
    expect("corpses counted before a reload counted once", counts_of(after, 13), (3, 3, 2, 2))
    expect("nothing about corpses stays saved", after.ns.db.corpses, None)
    # Corpses older than the time a kill waits for its loot are not kept.
    late = Client("Late")
    late.kill(14, "X1", True)
    late.advance(1000)
    late.fire("PLAYER_LOGOUT")
    expect("an old corpse is not saved", late.ns.db.corpses, None)
    # Nor one from a session that ended long before the next login.
    gone = late.kill(14, "X2", True)
    late.advance(5)
    next_day = late.reload(later=1000)
    next_day.g.lootable[gone] = True
    next_day.g.units["mouseover"] = gone
    next_day.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [gone, 1]}])
    expect("a corpse from long before the login counts as new", next_day.ns.db.mobs[14][1].kills, 3)

    # A value the client hides in one slot leaves that slot out and keeps the rest of the window.
    hider = Client("Hider")
    hider.lua.execute("""
        -- A hidden string is still a string in the game, so the stub marks the link text as secret.
        secrets = {}
        issecretvalue = function(value)
            return (type(value) == "table" and value.secret == true) or (value ~= nil and secrets[value] == true)
        end
        local link = GetLootSlotLink
        GetLootSlotLink = function(i)
            local text = link(i)
            if lootSlots[i].hidden then secrets[text] = true end
            return text
        end
        local sources = GetLootSourceInfo
        GetLootSourceInfo = function(i)
            if lootSlots[i].hiddenQty then return lootSlots[i].sources[1], { secret = true } end
            return sources(i)
        end
    """)
    hidden = hider.kill(15, "H1", True)
    hider.advance(5)
    hider.loot([{"type": 1, "item": 101, "name": "Meat", "qty": 1, "hidden": True, "sources": [hidden, 1]},
                {"type": 1, "item": 100, "name": "Wolf Fang", "qty": 3, "hiddenQty": True, "sources": [hidden, 3]}])
    data = hider.ns.db.mobs[15][1]
    expect("hidden values leave only their slots out", (data.kills, data.opened, data["items"][101],
                                                         data["items"][100]), (1, 1, None, None))
    coins = hider.kill(15, "H3", True)
    hider.advance(5)
    hider.loot([{"type": 2, "name": "7 Copper", "qty": 0, "hiddenQty": True, "sources": [coins, 7]}])
    expect("hidden money not counted", (data.money.drops, data.money.copper), (0, 0))
    # Read as no slots, the window would count the corpse under the mouse as one that left nothing.
    hider.lua.execute("GetNumLootItems = function() return { secret = true } end")
    unread = hider.kill(15, "H2", True)
    hider.advance(5)
    hider.g.units["mouseover"] = unread
    hider.loot([])
    hider.g.units["mouseover"] = None
    expect("a hidden slot count skips the window", (data.kills, data.lootable, data.opened), (3, 3, 1))

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
    # The options checkbox and Restore defaults open and close the tab too.
    tester.ns.RestoreDefaults()
    expect("restore defaults closes the tab", tester.g.chatWindowNames[4], None)
    tester.ns.settings.debug = True
    tester.fire("DT_SETTINGS_CHANGED")
    expect("the options checkbox opens it", tester.g.chatWindowNames[4], "DT Debug")

    # /dt find keeps the case of the text, and /dt on a friendly NPC opens the table without it.
    tester.lua.eval("""function(ns)
        ns.ToggleFinder = function(text) finderText = text end
        ns.ToggleDetails = function(npc) detailsNpc = npc or "none" end
    end""")(tester.ns)
    tester.g.SlashCmdList.DROPTABLES("FIND Linen Cloth")
    expect("search text keeps its case", tester.g.finderText, "Linen Cloth")
    tester.see(90, "C90", 30, friendly=True)
    tester.g.SlashCmdList.DROPTABLES("")
    expect("no table for a friendly NPC", tester.g.detailsNpc, "none")
    tester.see(91, "M91", 30)
    tester.g.SlashCmdList.DROPTABLES("")
    expect("the table of a hostile target", tester.g.detailsNpc, 91)
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

    # Under the target, a mob without data gets the question mark and a friendly NPC gets nothing.
    viewer = Client("Viewer", files=ALL_FILES + ("Strip.lua",), saved=UI_STUBS)
    viewer.see(7, "M7", 10)
    expect("icons for a mob without data", viewer.g.DropTablesStrip.shown, True)
    viewer.see(90, "C90", 30, friendly=True)
    expect("no icons for a friendly NPC", viewer.g.DropTablesStrip.shown, False)

    # The details window redraws once for several changes in a row, and not for items it does not list.
    reader = Client("Reader", files=ALL_FILES + ("Style.lua", "Details.lua"), saved=UI_STUBS)
    wolf = reader.kill(8, "W1", True)
    reader.advance(5)
    reader.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [wolf, 1]}])
    reader.ns.ShowDetails(8)
    reader.advance(1)
    reader.lua.eval("""function(ns)
        local getStats = ns.GetStats
        renders = 0
        -- One render asks for the loot and, through GetSkinStats, for the skinning; the loot counts it once.
        ns.GetStats = function(npc, mode)
            if mode ~= "skin" then renders = renders + 1 end
            return getStats(npc, mode)
        end
    end""")(reader.ns)
    for _ in range(3):
        reader.fire("DT_DATA_CHANGED", 8)
    reader.advance(1)
    expect("one redraw for three changes", reader.g.renders, 1)
    reader.fire("GET_ITEM_INFO_RECEIVED", 555)
    reader.advance(1)
    expect("no redraw for an item it does not list", reader.g.renders, 1)
    reader.fire("GET_ITEM_INFO_RECEIVED", 100)
    reader.advance(1)
    expect("a redraw for an item it lists", reader.g.renders, 2)

    # A theme rewrites the shared colours in place and runs every painter again, and Restore defaults goes back.
    ns = reader.ns
    colors = ns.Style.colors
    ledger_gold = tuple(colors.gold[i] for i in (1, 2, 3))
    reader.lua.execute("paints = 0")
    reader.lua.eval("function(Style) Style.Paint(function() paints = paints + 1 end) end")(ns.Style)
    ns.settings.theme = "frost"
    reader.fire("DT_SETTINGS_CHANGED")
    frost = next(t for t in ns.Style.THEMES.values() if t.key == "frost")
    expect("the theme's accent is in use", tuple(colors.gold[i] for i in (1, 2, 3)),
           tuple(frost.gold[i] for i in (1, 2, 3)))
    expect("painters ran again", (reader.g.paints, ns.Style.CurrentTheme()), (2, "frost"))
    reader.fire("DT_SETTINGS_CHANGED")
    expect("the same theme paints nothing", reader.g.paints, 2)
    ns.settings.theme = "no such theme"
    reader.fire("DT_SETTINGS_CHANGED")
    expect("an unknown theme falls back to the first", ns.Style.CurrentTheme(), "ledger")
    ns.settings.theme = "frost"
    reader.fire("DT_SETTINGS_CHANGED")
    ns.RestoreDefaults()
    expect("restore defaults brings the first theme back", (ns.Style.CurrentTheme(),
           tuple(colors.gold[i] for i in (1, 2, 3))), ("ledger", ledger_gold))

    # Forever hides the server and spawn ids in GUIDs since 1.60.1, and a hotfix hides the realm id too. Only the npc
    # id, the sixth field, is ever read; the rest only has to stay the same for one corpse within the session.
    npc_of = reader.ns.NpcFromGuid
    for label, guid_text, npc in (
            ("a plain creature GUID", "Creature-0-4447-0-12-448-000043F59F", 448),
            ("hidden realm, server and spawn ids", "Creature-7f3a-9c21e-0-1b2c-448-a1b2c3d4e5", 448),
            ("a vehicle", "Vehicle-5e1d-3a3a-0-1b2c-3000-ffee11", 3000),
            ("a player", "Player-4447-0A1B2C3D", None),
            ("an object", "GameObject-0-4447-0-12-19021-000043F59F", None)):
        expect("npc id of " + label, npc_of(guid_text), npc)

    report("collector")


if __name__ == "__main__":
    main()
