"""Mob levels, kill places and the loot finder queries.

Requires: pip install lupa
Run: python tests/test_finder.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wowsim import ALL_FILES, FINDER_STUBS, Client, expect, report  # noqa: E402

def count(table):
    return len(list(table.keys()))


def lua_list(table):
    return [table[i] for i in range(1, len(table) + 1)]


def kill_and_loot(client, npc, spawn, items):
    guid = client.kill(npc, spawn, True)
    client.advance(5)
    client.loot([{"type": 1, "item": item, "name": name, "qty": 1, "sources": [guid, 1]} for item, name in items])


def main():
    c = Client("Tester")
    ns = c.ns
    cloth = (2589, "Linen Cloth")
    fang = (100, "Wolf Fang")

    # Levels come from targeting and mouseover, and unknown (-1 / skull) levels are ignored.
    c.see(1, "a", 5)
    c.see(1, "b", 7, unit="mouseover")
    c.see(1, "c", -1)
    expect("level range", (ns.MobInfo(1).minLevel, ns.MobInfo(1).maxLevel), (5, 7))
    expect("name known", ns.MobName(1), "Test Mob")
    expect("not saved before the first counts", (ns.db.info[1], ns.db.names[1]), (None, None))

    # Mob 1 (levels 5-7) in zone 12: three kills, two at one spot.
    c.stand(12, 0.411, 0.302)
    kill_and_loot(c, 1, "k1", [cloth, fang])
    kill_and_loot(c, 1, "k2", [cloth])
    c.stand(12, 0.8, 0.8)
    kill_and_loot(c, 1, "k3", [fang])
    expect("saved with the first kill", (ns.db.info[1].minLevel, ns.db.info[1].maxLevel, ns.db.names[1]),
           (5, 7, "Test Mob"))
    place = ns.db.info[1].maps[12]
    expect("zone kills", place.kills, 3)
    cell = 20 * 50 + 15
    expect("kill spot cell", place.cells[cell], 2)
    x, y = ns.CellCenter(cell)
    expect("cell center", (round(x, 3), round(y, 3)), (0.41, 0.31))

    # Mob 2 (level 12) in zone 40 drops cloth once in four kills, and one kill inside an instance has no spot.
    c.see(2, "a", 12)
    c.stand(40, 0.2, 0.2)
    kill_and_loot(c, 2, "k1", [cloth])
    for spawn in ("k2", "k3"):
        c.kill(2, spawn, False)
    c.stand(40)
    c.kill(2, "k4", False)
    c.advance(5)
    expect("instance kill counted without spot", ns.db.info[2].maps[40].kills, 4)
    expect("instance kill adds no cell", count(ns.db.info[2].maps[40].cells), 1)

    # Mob 3 has no level and no map.
    c.stand(None)
    kill_and_loot(c, 3, "k1", [cloth])
    expect("no map, no place", ns.db.info[3], None)

    # Cells per map are capped.
    c.stand(55, 0.01, 0.01)
    for i in range(60):
        c.stand(55, 0.01 + i * 0.016, 0.5)
        c.kill(4, "spot%d" % i, False)
    expect("cell cap", count(ns.db.info[4].maps[55].cells), 40)
    expect("capped map still counts kills", ns.db.info[4].maps[55].kills, 60)

    # Item search by part of the name and by id.
    expect("search by name", [r.itemId for r in lua_list(ns.SearchItems("LINEN"))], [2589])
    expect("search by id", [r.itemId for r in lua_list(ns.SearchItems("100"))], [100])
    expect("empty search lists everything", sorted(r.itemId for r in lua_list(ns.SearchItems("  "))), [100, 2589])

    # Grouping like the auction house, from the client's item classes only.
    c.lua.execute("""
        itemClasses[2589] = { 7, 5 }
        itemClasses[200] = { 2, 7 }
        itemClasses[201] = { 2, 1 }
        itemClasses[300] = { 4, 1 }
    """)
    items = ns.db["items"]
    items[200] = c.lua.table_from({"name": "Rusty Sword", "quality": 0})
    items[201] = c.lua.table_from({"name": "Bent Axe", "quality": 2})
    items[300] = c.lua.table_from({"name": "Cloth Hat", "quality": 1})
    tree = lua_list(ns.BuildItemTree(ns.SearchItems("")))
    expect("class order", [g.classId for g in tree], [2, 4, 7, 15])
    expect("class counts", [g.count for g in tree], [2, 1, 1, 1])
    weapons = tree[0]
    expect("weapon subclasses by name", [s.name for s in lua_list(weapons.subs)], ["Sub 2.1", "Sub 2.7"])
    expect("single subclass has no sub level", tree[2].subs, None)
    expect("items on a single-subclass class", [i.itemId for i in lua_list(tree[2]["items"])], [2589])
    greens = ns.SearchItems("", c.lua.table_from({2: True}))
    expect("quality filter", [i.itemId for i in lua_list(greens)], [201])
    for item_id in (200, 201, 300):
        items[item_id] = None

    droppers = ns.FindDroppers(2589)
    by_npc = {d.npc: d for d in lua_list(droppers)}
    expect("cloth droppers", sorted(by_npc), [1, 2, 3])
    expect("mob 1 cloth rate", round(by_npc[1].rate, 4), round(2 / 3, 4))
    expect("mob 2 cloth rate", round(by_npc[2].rate, 4), 0.25)
    expect("mob 1 zone", by_npc[1].zone, "Zone 12")
    expect("mob 2 levels", (by_npc[2].minLevel, by_npc[2].maxLevel), (12, 12))
    expect("zone list", lua_list(ns.DropperMaps(droppers)), [12, 40])

    def names(filters, sort_key="rate", descending=True):
        table = c.lua.table_from(filters)
        return [d.npc for d in lua_list(ns.FilterDroppers(droppers, table, sort_key, descending))]

    expect("sorted by chance", names({}), [3, 1, 2])
    expect("filter by zone", names({"mapId": 40}), [2])
    expect("filter by level from", names({"minLevel": 10}), [2])
    expect("filter by level to", names({"maxLevel": 6}), [1])
    expect("level filter drops unknown levels", 3 in names({"minLevel": 1}), False)
    expect("sorted by level", names({}, "level", False), [3, 1, 2])
    expect("sorted by drops", names({}, "drops", True), [1, 2, 3])

    # Category view: one line per item with the number of mobs and the best one.
    summary_list, summary_maps = ns.SummarizeItems(ns.SearchItems(""))
    summaries = {s.itemId: s for s in lua_list(summary_list)}
    expect("zones offered for the category", lua_list(summary_maps), [12, 40])
    expect("cloth mobs", summaries[2589].mobs, 3)
    # Mob 3 has the best cloth chance, 1 in 1, but under 3 kills it loses to mob 1's 2 in 3.
    expect("cloth best mob has 3 kills or more", (summaries[2589].bestNpc, round(summaries[2589].rate, 4)),
           (1, round(2 / 3, 4)))
    expect("kills behind the best chance", summaries[2589].kills, 3)
    expect("kills behind the fang chance", summaries[100].kills, 3)
    expect("fang mobs", summaries[100].mobs, 1)
    expect("fang best chance", round(summaries[100].rate, 4), round(2 / 3, 4))
    zone40, zone40_maps = ns.SummarizeItems(ns.SearchItems(""), c.lua.table_from({"mapId": 40}))
    zone40 = {s.itemId: s for s in lua_list(zone40)}
    expect("zone filter keeps only items dropped there", sorted(zone40), [2589])
    expect("zone filter counts only mobs there", (zone40[2589].mobs, zone40[2589].bestNpc), (1, 2))
    expect("zone list ignores the zone filter", lua_list(zone40_maps), [12, 40])
    level_low, _ = ns.SummarizeItems(ns.SearchItems(""), c.lua.table_from({"maxLevel": 6}))
    expect("level filter on categories", sorted(s.itemId for s in lua_list(level_low)), [100, 2589])
    mob3 = c.lua.table_from([by_npc[3]])
    expect("with only mobs under 3 kills, the best of them still shows", ns.BestDropper(mob3).npc, 3)
    ordered, _ = ns.SummarizeItems(ns.SearchItems(""))
    expect("sorted by mobs", [s.itemId for s in lua_list(ns.SortSummaries(ordered, "mobs", True))], [2589, 100])
    expect("sorted by chance ascending", [s.itemId for s in lua_list(ns.SortSummaries(ordered, "rate", False))],
           [100, 2589])

    # The droppers are kept between calls and follow new loot, new mobs and new levels.
    kill_and_loot(c, 2, "k5", [cloth])
    after = {d.npc: d for d in lua_list(ns.FindDroppers(2589))}
    expect("new loot moves the chance", round(after[2].rate, 4), 0.4)
    kill_and_loot(c, 5, "k1", [fang])
    expect("a new mob shows up", sorted(d.npc for d in lua_list(ns.FindDroppers(100))), [1, 5])
    c.see(5, "a", 20)
    expect("a new level shows up", [d.minLevel for d in lua_list(ns.FindDroppers(100)) if d.npc == 5], [20])
    # Counts from other players come with DT_DATA_CHANGED alone.
    c.lua.execute("""
        DropTablesDB.peers[6] = { other = { t = 1, maps = {}, buckets = { [1] = { kills = 4, lootable = 4, opened = 4,
            items = { [100] = { drops = 2, qty = 2 } }, money = { drops = 0, copper = 0 } } } } }
    """)
    c.fire("DT_DATA_CHANGED", 6)
    expect("a mob from other players shows up", sorted(d.npc for d in lua_list(ns.FindDroppers(100))), [1, 5, 6])
    ns.settings.onlyMine = True
    c.fire("DT_SETTINGS_CHANGED")
    expect("a settings change rebuilds them", sorted(d.npc for d in lua_list(ns.FindDroppers(100))), [1, 5])
    ns.settings.onlyMine = False
    c.fire("DT_SETTINGS_CHANGED")

    # When two mobs give the same best chance, the one with more kills behind it is shown.
    for spawn in ("t1", "t2", "t3"):
        kill_and_loot(c, 7, spawn, [cloth])
    for spawn in ("t1", "t2", "t3", "t4"):
        kill_and_loot(c, 8, spawn, [cloth])
    tie_list = ns.SummarizeItems(ns.SearchItems(""))[0]
    tie = {s.itemId: s for s in lua_list(tie_list)}
    expect("a tie goes to more kills", (tie[2589].bestNpc, tie[2589].kills), (8, 4))
    tie_order = c.lua.table_from([d for d in lua_list(ns.FindDroppers(2589)) if d.npc in (7, 8)][::-1])
    expect("whichever comes first", ns.BestDropper(tie_order).npc, 8)
    expect("sorted by kills", [s.itemId for s in lua_list(ns.SortSummaries(tie_list, "kills", True))], [2589, 100])

    # The mob search finds mobs by part of the name or by id, with their kills and places, and follows new names.
    ns.db.names[7] = "Kobold Miner"
    c.fire("DT_INFO_CHANGED", 7)
    expect("mob search by name", [m.npc for m in lua_list(ns.SearchMobs("KOBOLD"))], [7])
    expect("mob search by id", [(m.npc, m.kills) for m in lua_list(ns.SearchMobs("7"))], [(7, 3)])
    everyone = [m.npc for m in lua_list(ns.SearchMobs(""))]
    expect("an empty mob search lists every mob, by name", (everyone[0], sorted(everyone)), (7, [1, 2, 3, 4, 5, 6, 7, 8]))
    mob_table = c.lua.table_from
    in_zone = ns.FilterDroppers(ns.SearchMobs(""), mob_table({"mapId": 40}), "kills", True)
    expect("the zone filter on mobs", [m.npc for m in lua_list(in_zone)], [2])
    by_kills = ns.FilterDroppers(ns.SearchMobs(""), mob_table({}), "kills", True)
    expect("mobs sorted by kills", [m.npc for m in lua_list(by_kills)][:2], [4, 2])
    # A mob only ever skinned is found too, with its skinned corpses as kills.
    c.lua.execute("""
        DropTablesDB.skins[50] = { skinned = 4, items = { [100] = { drops = 2, qty = 4, min = 2, max = 2 } } }
    """)
    c.fire("DT_DATA_CHANGED", 50)
    expect("a skinned mob in the mob search", [(m.npc, m.kills) for m in lua_list(ns.SearchMobs("50"))], [(50, 4)])

    # The Loot Finder goes straight to the mobs when only mobs match the search, and stays with the items otherwise.
    viewer = Client("Viewer", files=ALL_FILES + ("Style.lua", "Finder.lua"), saved=FINDER_STUBS)
    kill_and_loot(viewer, 7, "v1", [cloth])
    viewer.ns.db.names[7] = "Kobold Miner"
    viewer.fire("DT_INFO_CHANGED", 7)
    viewer.lua.execute("texts = {}")
    viewer.ns.OpenFinder("kobold")
    shown = set(viewer.g.texts.values())
    expect("a mob's name opens the mobs", ("Mobs matching your search" in shown, "Kobold Miner" in shown), (True, True))
    viewer.lua.execute("texts = {}")
    viewer.ns.OpenFinder("linen")
    shown = set(viewer.g.texts.values())
    expect("an item's name stays with the items", ("Search results" in shown, "Mobs matching your search" in shown),
           (True, False))
    # The open Finder redraws when the client brings the info of an item it shows, and not for every item the client
    # loads for others, which happens all the time near other players and made the game stutter.
    viewer.lua.execute("""
        C_Item.GetItemInfo = function(id) if id == 2589 then return "Linen Cloth, loaded" end end
        texts = {}
    """)
    viewer.fire("GET_ITEM_INFO_RECEIVED", 9999, True)
    viewer.advance(1)
    expect("an unrelated item doesn't redraw the Finder", len(viewer.g.texts), 0)
    # An item the server can't load comes back as a failure, and a redraw would only ask for it again.
    viewer.fire("GET_ITEM_INFO_RECEIVED", 2589, False)
    viewer.advance(1)
    expect("an item that failed to load doesn't redraw the Finder", len(viewer.g.texts), 0)
    viewer.fire("GET_ITEM_INFO_RECEIVED", 2589, True)
    viewer.advance(1)
    expect("a shown item's info redraws it",
           any("Linen Cloth, loaded" in str(text) for text in viewer.g.texts.values()), True)

    # Names and levels saved by earlier versions for creatures without any counts are dropped on login.
    old = Client("Old", saved="""DropTablesDB = {
        mobs = { [1] = { [1] = { kills = 1, lootable = 0, opened = 0, items = {}, money = { drops = 0, copper = 0 } } } },
        names = { [1] = "Wolf", [2] = "Rabbit" },
        info = { [1] = { minLevel = 5, maxLevel = 5, maps = {} }, [2] = { minLevel = 1, maxLevel = 1, maps = {} } },
    }""")
    expect("sightings without counts dropped", (old.ns.db.names[2], old.ns.db.info[2]), (None, None))
    expect("mobs with counts kept", (old.ns.db.names[1], old.ns.db.info[1].minLevel), ("Wolf", 5))

    # Quest items stay out even when the shared database carries them (the imports don't know every one).
    quester = Client("Quester")
    qns = quester.ns
    qns.shared[900] = quester.lua.eval("""{ from = {}, maps = {}, buckets = { [1] = { kills = 3, lootable = 3, opened = 3,
        money = { copper = 0, drops = 0 },
        items = { [102] = { drops = 2, qty = 2, min = 1, max = 1 }, [100] = { drops = 1, qty = 1, min = 1, max = 1 } } } } }""")
    qns.db["items"][102] = quester.lua.table_from({"quality": 1})
    expect("quest item left out of the table", [e.itemId for e in lua_list(qns.GetStats(900, "all").list)], [100])
    expect("quest item left out of the search", 102 in [r.itemId for r in lua_list(qns.SearchItems(""))], False)

    report("finder")


if __name__ == "__main__":
    main()
