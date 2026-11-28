"""The shared database: exports sent as GitHub issues, merged by tools/build_data.py, loaded back as Data.lua.

Requires: pip install lupa
Run: python tests/test_data.py
"""
import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import ALL_FILES, UI_STUBS, Client, expect, report  # noqa: E402
from test_share import Net, loot_mob  # noqa: E402
import build_data  # noqa: E402
import ingest_issue  # noqa: E402

DAY = "2026-11-18T10:00:00Z"

# The world map, enough for ns.ShowOnMap: the map it shows and the waypoint it gets.
MAP_STUBS = """
WorldMapFrame = widget("WorldMapFrame")
WorldMapFrame.shown = false
WorldMapFrame.SetMapID = function(_, id) shownMap = id end
WorldMapFrame.GetMapID = function() return shownMap end
local canvas = widget()
canvas.GetSize = function() return 1000, 600 end
WorldMapFrame.GetCanvas = function() return canvas end
function ToggleWorldMap() WorldMapFrame.shown = not WorldMapFrame.shown end
function InCombatLockdown() return false end
function hooksecurefunc() end
C_Map.CanSetUserWaypointOnMap = function() return true end
C_Map.SetUserWaypoint = function(point) waypoint = point end
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
"""


def issue(number, body, login="alice-gh", labels=(), created=DAY):
    return {"number": number, "body": body, "user": {"login": login}, "labels": [{"name": n} for n in labels],
            "created_at": created}


def form_body(*strings):
    return "### Export text\n\n```text\n%s\n```\n" % "\n".join(strings)


def export_string(client):
    strings = client.ns.BuildExport().strings
    return strings[1]


def shared_lua(root):
    return build_data.lua_file(build_data.build(build_data.load_submissions(root)))


def bucket(kills, lootable, opened, items=None, money=0):
    return {"kills": kills, "lootable": lootable, "opened": opened,
            "money": {"drops": money, "copper": money * 10, "min": 10 if money else None, "max": 10 if money else None},
            "items": {str(i): {"drops": d, "qty": d, "min": 1, "max": 1} for i, d in (items or {}).items()}}


def mob(buckets, name="Wolf", levels=(5, 6), maps=None):
    return {"buckets": {str(b): data for b, data in buckets.items()}, "levels": list(levels), "maps": maps or {"12": 1},
            "cells": {}, "name": name}


def submission(number, exporter, sources, submitter=None):
    """sources: origin -> {npc: mob}."""
    return {"issue": number, "index": 1, "submitter": submitter or "user-" + exporter, "received": 1000 + number,
            "sha256": "%064d" % number, "string": "",
            "result": {"exporter": exporter, "version": "0.3.0", "time": 1, "part": 1, "parts": 1,
                       "sources": {o: {"mobs": {str(npc): m for npc, m in mobs.items()}} for o, mobs in sources.items()}}}


def origin(n):
    return "%016x" % (0xa000000000000000 + n)


def merge_rules():
    a, b, c, d = origin(1), origin(2), origin(3), origin(4)
    own = submission(1, a, {a: {7: mob({1: bucket(50, 50, 50, {100: 10})})}})
    relayed_b = submission(2, b, {a: {7: mob({1: bucket(80, 80, 80, {100: 16})})}})
    db = build_data.build([own, relayed_b])
    expect("the install's own export beats one bigger relayed copy", db["mobs"]["7"]["from"], {a: 50})
    relayed_c = submission(3, c, {a: {7: mob({1: bucket(90, 90, 90, {100: 18})})}})
    db = build_data.build([own, relayed_b, relayed_c])
    expect("two exporters with more kills win, at the smaller of the two", db["mobs"]["7"]["from"], {a: 80})
    db = build_data.build([relayed_b])
    expect("a relayed copy counts when the install never exported", db["mobs"]["7"]["from"], {a: 80})
    newer = submission(4, a, {a: {7: mob({1: bucket(60, 60, 60, {100: 12})})}})
    db = build_data.build([own, newer])
    expect("the latest own export (most kills) wins", db["mobs"]["7"]["buckets"]["1"]["kills"], 60)
    opened_later = submission(5, a, {a: {7: mob({1: bucket(60, 60, 50, {100: 12})})}})
    for order in ([newer, opened_later], [opened_later, newer]):
        db = build_data.build([own] + order)
        expect("same kills: the one with more corpses opened", db["mobs"]["7"]["buckets"]["1"]["opened"], 60)
    same = submission(6, a, {a: {7: mob({1: bucket(60, 60, 60, {100: 13})})}})
    for order in ([newer, same], [same, newer]):
        db = build_data.build(order)
        expect("a full tie: the latest issue", db["mobs"]["7"]["buckets"]["1"]["items"]["100"]["drops"], 13)

    # Three honest installs and one claiming hundreds of empty corpses.
    honest = [submission(10 + i, origin(10 + i), {origin(10 + i): {8: mob({1: bucket(100, 90, 90, {100: 45})})}})
              for i in range(3)]
    liar = submission(20, d, {d: {8: mob({1: bucket(1000, 10, 10, {100: 5})})}})
    db = build_data.build(honest + [liar])
    expect("the empty-kill liar is left out", sorted(db["mobs"]["8"]["from"]), sorted(origin(10 + i) for i in range(3)))
    expect("kills of the honest three", db["mobs"]["8"]["buckets"]["1"]["kills"], 300)
    item_liar = submission(21, d, {d: {8: mob({1: bucket(100, 90, 90, {100: 0, 101: 1})})}})
    item_liar["result"]["sources"][d]["mobs"]["8"]["buckets"]["1"]["items"].pop("100")
    db = build_data.build(honest + [item_liar])
    expect("an install that never sees a 50% drop is left out", d in db["mobs"]["8"]["from"], False)
    big = [submission(30, origin(30), {origin(30): {9: mob({1: bucket(3000, 3000, 3000, {100: 300})})}})]
    db = build_data.build(big)
    expect("one install counts at most 300 kills", db["mobs"]["9"]["buckets"]["1"]["kills"], 300)
    expect("its drops scale with it", db["mobs"]["9"]["buckets"]["1"]["items"]["100"]["drops"], 30)

    # One submitter relays 60 install ids nobody else ever sent, and only 50 of them count.
    fakes = {origin(100 + i): {10 + i: mob({1: bucket(5, 5, 5)})} for i in range(60)}
    db = build_data.build([submission(40, origin(99), fakes, submitter="spammer")])
    expect("unconfirmed installs per submitter are capped", len(db["mobs"]), build_data.UNCONFIRMED_CAP)

    # Same input, same output.
    subs = honest + [liar, own, relayed_b]
    first = build_data.lua_file(build_data.build(subs))
    expect("the build is the same every time", build_data.lua_file(build_data.build(list(reversed(subs)))), first)

    # An install id made only of digits stays text in Lua.
    digits = "1234567890123456"
    lua = build_data.lua_file(build_data.build([submission(50, digits, {digits: {11: mob({1: bucket(3, 3, 3)})}})]))
    client = Client("Digits", data=lua)
    expect("digit install id is a string key", client.ns.shared[11]["from"][digits], 3)

    # Many mobs are written in chunks and all load.
    many = {origin(500): {20000 + i: mob({1: bucket(4, 4, 3, {100 + i % 50: 1})}, name="Mob %d" % i) for i in range(3000)}}
    lua = build_data.lua_file(build_data.build([submission(60, origin(500), many)]))
    expect("chunks of 500 mobs", lua.count("ns.AddSharedData(function()"), 6)
    client = Client("Many", data=lua)
    expect("all mobs loaded", sum(1 for _ in client.ns.shared.keys()), 3000)


def partial_import(origin_id, mobs):
    sub = submission(0, origin_id, {origin_id: mobs}, submitter="import:" + origin_id)
    sub["partial"] = True
    sub["source"] = {"name": "Test harvest", "url": "https://example.org/harvest", "license": "MIT",
                     "copyright": "Copyright (c) 2026 Test",
                     "notice": "MIT License\n\nCopyright (c) 2026 Test\n\nPermission is hereby granted, free of charge"}
    return sub


def imports(root):
    """A partial import brings looted corpses and items, and takes kills, money and stack sizes from the players."""
    corpses = {npc: mob({1: bucket(40, 40, 40, {100: 20})}) for npc in (31, 32)}
    for record in corpses.values():
        record["buckets"]["1"]["items"]["100"].pop("min")
        record["buckets"]["1"]["items"]["100"].pop("max")
        record["buckets"]["1"]["items"]["100"]["qty"] = 20
        del record["name"]
    harvest = partial_import("harvest", corpses)

    db = build_data.build([], [harvest])
    alone = db["mobs"]["31"]["buckets"]["1"]
    expect("alone: every corpse a kill with loot", (alone["kills"], alone["lootable"], alone["opened"]), (40, 40, 40))
    expect("alone: no money", alone["money"]["drops"], 0)
    expect("alone: no name", "name" in db["mobs"]["31"], False)
    expect("the import is credited", db["imports"][0]["id"], "harvest")

    player = submission(1, origin(70), {origin(70): {31: mob({1: bucket(100, 80, 40, {100: 10}, money=30)})}})
    player["result"]["sources"][origin(70)]["mobs"]["31"]["buckets"]["1"]["items"]["100"]["qty"] = 30
    db = build_data.build([player], [harvest])
    both = db["mobs"]["31"]["buckets"]["1"]
    expect("kills follow the player's share of opened corpses", (both["kills"], both["lootable"], both["opened"]),
           (200, 160, 80))
    expect("money keeps the player's rate", (both["money"]["drops"], both["money"]["copper"]), (60, 600))
    expect("items add up, stacks keep the player's average", (both["items"]["100"]["drops"],
                                                               both["items"]["100"]["qty"]), (30, 90))
    expect("both are in from", db["mobs"]["31"]["from"], {origin(70): 100, "harvest": 40})
    expect("the player's name stays", db["mobs"]["31"]["name"], "Wolf")

    # Three players with plenty of empty corpses and money, and a big import with neither, are all kept.
    honest = [submission(10 + i, origin(80 + i), {origin(80 + i): {32: mob({1: bucket(100, 70, 70, {100: 35},
                                                                                      money=60)})}})
              for i in range(3)]
    db = build_data.build(honest, [harvest])
    expect("an import is never an empty-kill or money outlier", "harvest" in db["mobs"]["32"]["from"], True)
    odd = partial_import("odd", {32: mob({1: bucket(40, 40, 40, {101: 20})})})
    db = build_data.build(honest, [odd])
    expect("an import that never sees a 50% drop is left out", "odd" in db["mobs"]["32"]["from"], False)

    lua = build_data.lua_file(build_data.build([], [harvest]))
    expect("Data.lua names the imported source and its license", "Copyright (c) 2026 Test, under the MIT license" in lua,
           True)
    expect("Data.lua carries the import's whole notice, as a comment",
           "\n-- Permission is hereby granted, free of charge\n" in lua, True)
    client = Client("Imported", data=lua)
    entry = next(e for e in client.ns.GetStats(31, "all").list.values() if e.itemId == 100)
    expect("the addon shows the imported chance", round(entry.rate, 2), 0.5)

    # Kill spots: the import's cells become the mob's spots, the busiest MAX_SPOTS per map, and exports bring none.
    spotted = partial_import("spotted", {33: mob({1: bucket(60, 60, 60, {100: 30})}, maps={"12": 60})})
    spotted["result"]["sources"]["spotted"]["mobs"]["33"]["cells"] = {
        "12": {str(cell): 1 + cell % 3 for cell in range(build_data.MAX_SPOTS + 5)}}
    player = submission(2, origin(71), {origin(71): {33: mob({1: bucket(10, 10, 10, {100: 5})})}})
    db = build_data.build([player], [spotted])
    spots = db["mobs"]["33"]["spots"]["12"]
    expect("spots per map are capped at the busiest", (len(spots), min(spots.values())), (build_data.MAX_SPOTS, 1))
    expect("the busiest spots stay", all(spots.get(str(c)) == 3 for c in range(2, build_data.MAX_SPOTS + 5, 3)), True)
    expect("an export without spots brings none", "spots" in build_data.build([player])["mobs"]["33"], False)
    # One install's spots weigh at most PEER_CAP kills, like its counts.
    loud = submission(3, origin(72), {origin(72): {34: mob({1: bucket(3000, 3000, 3000)}, maps={"12": 3000})}})
    loud["result"]["sources"][origin(72)]["mobs"]["34"]["cells"] = {"12": {"7": 3000}}
    quiet = submission(4, origin(73), {origin(73): {34: mob({1: bucket(200, 200, 200)}, maps={"12": 200})}})
    quiet["result"]["sources"][origin(73)]["mobs"]["34"]["cells"] = {"12": {"8": 200}}
    expect("a big install's spots are scaled down like its kills",
           build_data.build([loud, quiet])["mobs"]["34"]["spots"]["12"], {"7": 300, "8": 200})

    lua = build_data.lua_file(build_data.build([], [spotted]))
    hunter = Client("Hunter", data=lua)
    hunter.lua.execute("DropTablesDB.info[33] = { maps = { [12] = { kills = 2, cells = { [5] = 2 } } } }")
    info = hunter.ns.MobInfo(33)
    expect("shared spots join the player's own", (info.maps[12].cells[5], info.maps[12].cells[2]), (5, 3))
    expect("the player's saved spots don't change", hunter.ns.db.info[33].maps[12].cells[5], 2)
    dropper = hunter.ns.FindDroppers(100)[1]
    expect("a mob with shared spots offers the map", dropper.spots, True)
    hunter.ns.settings.onlyMine = True
    expect("Only mine leaves the shared spots out", hunter.ns.MobInfo(33).maps[12].cells[2], None)
    plain = Client("Plain", data=build_data.lua_file(build_data.build([player])))
    expect("a mob without spots offers no map", plain.ns.FindDroppers(100)[1].spots, False)

    mapper = Client("Mapper", files=ALL_FILES + ("Style.lua", "Map.lua"), saved=UI_STUBS + MAP_STUBS, data=lua)
    # Alone the player's busiest spot is 46, added to the shared ones it is 5.
    mapper.lua.execute("DropTablesDB.info[33] = { maps = { [12] = { kills = 3, cells = { [46] = 2, [5] = 1 } } } }")
    mapper.ns.ShowOnMap(33, 12)
    waypoint = mapper.g.waypoint
    expect("the waypoint goes to the busiest spot, own and shared added up",
           (waypoint.m, round(waypoint.x, 2), round(waypoint.y, 2)), (12, 0.01, 0.11))

    (root / "data" / "submissions").mkdir(parents=True)
    (root / "data" / "imports").mkdir(parents=True)
    (root / "data" / "imports" / "harvest.json").write_text(json.dumps(harvest), encoding="utf-8")
    build_data.main(["--root", str(root)])
    shared = json.loads((root / "data" / "shared.json").read_text(encoding="utf-8"))
    expect("main reads data/imports", sorted(shared["mobs"]), ["31", "32"])
    expect("imports aren't counted as submissions", shared["submissions"], 0)
    expect("the import file stays", (root / "data" / "imports" / "harvest.json").exists(), True)


def issues_and_game(root):
    alice = Client("Alice")
    alice.stand(12, 0.3, 0.3)
    for i in range(10):
        loot_mob(alice, 1, "A%d" % i, [(100, 1)] if i % 2 == 0 else [(101, 2)])
    alice.see(1, "A0", 5)
    alice_id = alice.ns.db.installId
    string = export_string(alice)

    outcome, reply = ingest_issue.ingest(issue(1, form_body(string)), root)
    expect("an export is accepted", outcome, "accepted")
    expect("the reply counts what came in", "1 install, 1 mob, 10 kills" in reply, True)
    expect("the same text again adds nothing", ingest_issue.ingest(issue(2, form_body(string)), root)[0], "duplicate")
    text, key = string.rsplit(".", 1)  # the install's export key comes after the dot
    broken = text[:-12] + "AAAAAAAAAAAA." + key
    outcome, reply = ingest_issue.ingest(issue(3, form_body(broken)), root)
    hashed = "Install key: `%s`\n\n" % ("c" * 64)
    fresh, other = Client("Fresh"), Client("Other")
    loot_mob(fresh, 2, "F1", [(100, 1)])
    loot_mob(other, 2, "O1", [(100, 1)])
    keys = root / "keys"
    ingest_issue.ingest(issue(20, form_body(export_string(fresh)) + hashed, labels=("share", "relay")), keys)
    ingest_issue.ingest(issue(21, form_body(export_string(other)) + hashed), keys)
    subs = {s["issue"]: s for s in build_data.load_submissions(keys)}
    expect("the share page's key hash goes with the submission", subs[20].get("key"), "c" * 64)
    expect("in an issue anyone could open it counts for nothing", (21 in subs, subs[21].get("key")), (True, None))
    expect("a damaged text is refused with the checker's reason", (outcome, "damaged" in reply or "cut" in reply),
           ("rejected", True))
    expect("an issue without a text is refused", ingest_issue.ingest(issue(4, "hello"), root)[0], "rejected")
    expect("only valid texts were saved", sorted(p.name for p in (root / "data" / "submissions").glob("*.json")),
           ["1-1.json"])
    erin = Client("Erin")
    loot_mob(erin, 3, "E1", [(100, 1)])
    outcome, _ = ingest_issue.ingest(issue(5, form_body(export_string(erin)), login="share[bot]",
                                           labels=("share", "relay")), root)
    saved = build_data.load_submissions(root)[-1]
    expect("a page issue is filed under its install", (outcome, saved["submitter"]),
           ("accepted", "relay:" + erin.ns.db.installId))

    lua = shared_lua(root)
    carol = Client("Carol", data=lua)
    stats = carol.ns.GetStats(1, "all")
    expect("a mob carol never met has chances", (stats.kills, stats.sharedKills, stats.ownKills), (10, 10, 0))
    rates = {e.itemId: round(e.rate, 2) for e in stats.list.values() if e.itemId}
    expect("shared chances", rates, {100: 0.5, 101: 0.5})
    expect("the shared mob is known", carol.ns.KnownNpcs()[1], True)
    expect("its name and level come along", (carol.ns.MobName(1), carol.ns.MobInfo(1).minLevel), ("Test Mob", 5))
    expect("the loot finder lists it", sorted(d.npc for d in carol.ns.FindDroppers(100).values()), [1, 3])
    alice_cells = {c: k for c, k in alice.ns.db.info[1].maps[12].cells.items()}
    expect("alice's kill spots reach carol's map", ({c: k for c, k in carol.ns.MobInfo(1).maps[12].cells.items()},
                                                    len(alice_cells) > 0), (alice_cells, True))
    carol.ns.settings.onlyMine = True
    carol.fire("DT_SETTINGS_CHANGED")
    expect("only mine hides the shared data", carol.ns.GetStats(1, "all"), None)
    carol.ns.settings.onlyMine = False
    carol.fire("DT_SETTINGS_CHANGED")

    # Alice's own kills are in the database already, so they count once and her new kills count on top.
    alice2 = Client("Alice", saved=_saved_db(alice), data=lua)
    expect("same install", alice2.ns.db.installId, alice_id)
    stats = alice2.ns.GetStats(1, "all")
    expect("own kills in the database count once", (stats.kills, stats.ownKills, stats.ownCounted), (10, 10, 0))
    for i in range(10, 14):
        loot_mob(alice2, 1, "A%d" % i, [(100, 1)])
    stats = alice2.ns.GetStats(1, "all")
    expect("new kills after the export count", (stats.kills, stats.ownKills, stats.ownCounted), (14, 14, 4))
    rates = {e.itemId: round(e.rate, 4) for e in stats.list.values() if e.itemId}
    # The new part is Alice's counts times 4/14, because we know how much changed since the export but not what.
    expect("the new part moves the chance", rates[100], round((5 + 9 * 4 / 14) / 14, 4))

    # Counts of alice that bob got over the channel are in the database too.
    bob = Client("Bob", data=lua)
    bob.lua.execute("""
        local alice = "%s"
        DropTablesDB.peers[1] = { [alice] = { t = 1, maps = {}, buckets = { [1] = { kills = 10, lootable = 10,
            opened = 10, items = { [100] = { drops = 5, qty = 5 }, [101] = { drops = 5, qty = 10 } },
            money = { drops = 0, copper = 0 } } } } }
    """ % alice_id)
    bob.fire("DT_DATA_CHANGED", 1)
    stats = bob.ns.GetStats(1, "all")
    expect("another player's counts already in the database count once", (stats.kills, stats.peerKills), (10, 0))
    export = bob.ns.BuildExport()
    expect("neither the database nor counts it holds are exported", len(list(export.strings.values())), 0)

    # A mob the database knows well is asked about once a day, like one the player holds 100 corpses of.
    many = {origin(700): {2: mob({1: bucket(150, 150, 150, {100: 30})})}}
    lua = build_data.lua_file(build_data.build([submission(70, origin(700), many)]))
    dave = Client("Dave", data=lua)
    net = Net(dave)
    net.run(10)
    start = len(net.log)
    dave.see(2, "D1", 5)
    net.run(10)
    expect("one daily question about a mob the database knows well", len(net.sent("Dave", "Q|", start)), 1)
    start = len(net.log)
    net.run(600)
    dave.see(2, "D2", 5)
    net.run(10)
    expect("not again the same day", net.sent("Dave", "Q|", start), [])


def pruning(root):
    """A player who sends everything each time leaves only the latest submission; the database stays the same."""
    a, b = origin(900), origin(901)
    first = submission(1, a, {a: {7: mob({1: bucket(50, 50, 40, {100: 10})})}, b: {8: mob({1: bucket(5, 5, 5)})}})
    second = submission(2, a, {a: {7: mob({1: bucket(60, 60, 40, {100: 12})}), 9: mob({1: bucket(3, 3, 3)})},
                               b: {8: mob({1: bucket(5, 5, 5)})}})
    fewer_opened = submission(3, a, {a: {7: mob({1: bucket(70, 70, 30, {100: 12})})}, b: {8: mob({1: bucket(5, 5, 5)})}})
    partial = submission(4, a, {a: {7: mob({1: bucket(80, 80, 80, {100: 16})})}})
    other = submission(5, b, {a: {7: mob({1: bucket(90, 90, 90, {100: 18})})}, b: {8: mob({1: bucket(6, 6, 6)})}})
    old = [x["issue"] for x in build_data.superseded([first, second, fewer_opened, partial, other])]
    expect("only the fully covered submission goes", old, [1])
    expect("more kills but fewer opened corpses covers nothing", build_data.superseded([first, fewer_opened]), [])
    folder = root / "data" / "submissions"
    folder.mkdir(parents=True)
    for sub in (first, second, fewer_opened, partial, other):
        (folder / ("%d-1.json" % sub["issue"])).write_text(json.dumps(sub), encoding="utf-8")
    before = build_data.lua_file(build_data.build(build_data.load_submissions(root)))
    build_data.main(["--root", str(root)])
    expect("its file is deleted", sorted(p.name for p in folder.glob("*.json")),
           ["2-1.json", "3-1.json", "4-1.json", "5-1.json"])
    after = (root / "DropTables" / "Data.lua").read_text(encoding="utf-8")
    expect("the database does not change", after, before)


def shrink_guard(root):
    """A build that takes away much of the database stops before it writes or deletes anything."""
    a, b = origin(910), origin(911)
    first = submission(1, a, {a: {7: mob({1: bucket(50, 50, 40, {100: 10, 101: 2})})}})
    other = submission(2, b, {b: {8: mob({1: bucket(50, 50, 50, {102: 5})})}})
    folder = root / "data" / "submissions"
    folder.mkdir(parents=True)
    for sub in (first, other):
        (folder / ("%d-1.json" % sub["issue"])).write_text(json.dumps(sub), encoding="utf-8")
    expect("the first build goes through", build_data.main(["--root", str(root)]), 0)
    shared = root / "data" / "shared.json"
    expect("all four measures are counted", build_data.measures(json.loads(shared.read_text(encoding="utf-8"))),
           {"mobs": 2, "kills": 100, "skinned corpses": 0, "mob and item pairs": 3})
    before = shared.read_text(encoding="utf-8")

    # The other player's counts go missing, and a new export of the first player's makes the old one superseded.
    (folder / "2-1.json").unlink()
    newer = submission(3, a, {a: {7: mob({1: bucket(60, 60, 45, {100: 12, 101: 2})})}})
    (folder / "3-1.json").write_text(json.dumps(newer), encoding="utf-8")
    expect("the build stops", build_data.main(["--root", str(root)]), 1)
    expect("shared.json stays as it was", shared.read_text(encoding="utf-8"), before)
    expect("the superseded export is still there", (folder / "1-1.json").exists(), True)
    expect("--allow-shrink lets it through", build_data.main(["--root", str(root), "--allow-shrink"]), 0)
    after = build_data.measures(json.loads(shared.read_text(encoding="utf-8")))
    expect("the database shrank", (after["mobs"], after["kills"]), (1, 60))
    expect("and then the superseded export is deleted", (folder / "1-1.json").exists(), False)
    expect("a small drop goes through", build_data.shrunk({"mobs": {"7": mob({1: bucket(100, 100, 100)})}},
                                                          {"mobs": {"7": mob({1: bucket(98, 98, 98)})}}), [])
    expect("a drop below 98% does not", build_data.shrunk({"mobs": {"7": mob({1: bucket(100, 100, 100)})}},
                                                          {"mobs": {"7": mob({1: bucket(97, 97, 97)})}}),
           [("kills", 100, 97)])


def shared_is_trusted():
    """Another install claiming hundreds of empty corpses is left out, never the shared database."""
    lua = build_data.lua_file(build_data.build([submission(80, origin(800), {origin(800): {4: mob({1: bucket(
        100, 100, 100, {100: 50})})}})]))
    frank = Client("Frank", data=lua)
    frank.lua.execute("""
        DropTablesDB.peers[4] = { liar = { t = 1, maps = {}, buckets = { [1] = { kills = 300, lootable = 0,
            opened = 0, items = {}, money = { drops = 0, copper = 0 } } } } }
    """)
    frank.fire("DT_DATA_CHANGED", 4)
    stats = frank.ns.GetStats(4, "all")
    expect("the liar goes, the database stays", (stats.kills, stats.sharedKills), (100, 100))


def hotfix_resets():
    """A mob in data/loot-resets.json counts only what was recorded from its day on."""
    a, since = origin(90), "2026-11-07"
    start = build_data.since_time(since)
    resets = {"9": since}

    def at(sub, received):
        sub["received"] = received
        return sub

    def skinned(record, count, drops):
        record["skins"] = {"skinned": count, "items": {"2318": {"drops": drops, "qty": drops}}}
        return record

    before = at(submission(90, a, {a: {9: skinned(mob({1: bucket(10, 5, 5, {100: 1})}), 4, 4)}}), start - 100)
    after = at(submission(91, a, {a: {9: skinned(mob({1: bucket(16, 11, 11, {100: 6})}, maps={"12": 16}), 10, 9)}}),
               start + 100)
    later = at(submission(92, a, {a: {9: mob({1: bucket(20, 15, 15, {100: 9})})}}), start + 200)

    expect("without a reset the latest export counts whole",
           build_data.build([before, after])["mobs"]["9"]["buckets"]["1"]["kills"], 16)
    db = build_data.build([before, after], resets=resets)
    b = db["mobs"]["9"]["buckets"]["1"]
    expect("an export after the day counts only what it has beyond the last one before",
           (b["kills"], b["lootable"], b["opened"], b["items"]["100"]["drops"]), (6, 6, 6, 5))
    expect("and its kill spots too", db["mobs"]["9"]["maps"], {"12": 15})
    expect("the database lists all of the install's kills, so the addon adds none of them back",
           db["mobs"]["9"]["from"], {a: 16})
    expect("skinning the same way", (db["mobs"]["9"]["skins"]["skinned"], db["mobs"]["9"]["skins"]["items"]["2318"],
                                     db["mobs"]["9"]["skins"]["from"]), (6, {"drops": 5, "qty": 5}, {a: 10}))

    db = build_data.build([after, later], resets=resets)
    b = db["mobs"]["9"]["buckets"]["1"]
    expect("with nothing from before, the first export after the day is the base",
           (b["kills"], b["items"]["100"]["drops"], db["mobs"]["9"]["from"]), (4, 3, {a: 20}))
    expect("a single export after the day may hold older kills, so it counts nothing",
           "9" in build_data.build([after], resets=resets)["mobs"], False)
    expect("other mobs of the same export are left alone",
           build_data.build([after], resets={"8": since})["mobs"]["9"]["buckets"]["1"]["kills"], 16)

    old = partial_import("beta", {9: mob({1: bucket(30, 30, 30, {100: 30})})})
    old["source"]["collectedUntil"] = "2026-10-21"
    fresh = partial_import("dated", {9: skinned(mob({1: bucket(8, 8, 8, {100: 2})}), 3, 2)})
    db = build_data.build([before], [old, fresh], resets=resets)
    expect("an import that stopped before the day goes, one that leaves old records out itself stays",
           sorted(db["mobs"]["9"]["from"]), [a, "dated"])
    expect("the kills left out of a player's install still count as known", db["mobs"]["9"]["from"][a], 10)
    expect("and so do its skinned corpses", db["mobs"]["9"]["skins"]["from"], {a: 4, "dated": 3})
    expect("an import that stopped before the day stays for other mobs",
           "beta" in build_data.build([], [old], resets={"8": since})["mobs"]["9"]["from"], True)

    expect("the last export before the day is kept as the base",
           (build_data.superseded([before, after]) == [before], build_data.superseded([before, after], resets)),
           (True, []))

    # In game, another player's counts of the mob only add what came after the shared database's count of them.
    pal = Client("Pal", data=build_data.lua_file(build_data.build([before, after], resets=resets)))
    pal.lua.execute("""
        DropTablesDB.peers[9] = { ["%s"] = { t = 1, maps = {}, buckets = { [1] = { kills = 16, lootable = 11,
            opened = 11, items = { [100] = { drops = 6, qty = 6 } }, money = { drops = 0, copper = 0 } } } } }
    """ % a)
    pal.fire("DT_DATA_CHANGED", 9)
    expect("the addon doesn't add the install's old kills back", pal.ns.GetStats(9, "all").kills, 6)


def _saved_db(client):
    """Lua code that gives a new client the same saved variables."""
    dump = client.lua.execute("""
        local function dump(v)
            if type(v) == "table" then
                local parts = {}
                for k, x in pairs(v) do
                    local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
                    table.insert(parts, key .. "=" .. dump(x))
                end
                return "{" .. table.concat(parts, ",") .. "}"
            elseif type(v) == "string" then
                return string.format("%q", v)
            end
            return tostring(v)
        end
        return dump
    """)
    return "DropTablesDB = " + dump(client.ns.db)


def issue_list(root):
    """The workflow hands over every open share issue at once, as gh issue list gives them."""
    gina = Client("Gina")
    loot_mob(gina, 6, "G1", [(100, 1)])
    issues = [
        {"number": 9, "body": "no text", "author": {"login": "x"}, "labels": [], "createdAt": DAY},
        {"number": 8, "body": form_body(export_string(gina)), "author": {"login": "gina-gh"},
         "labels": [{"name": "share"}], "createdAt": DAY},
    ]
    listing = root / "issues.json"
    listing.write_text(json.dumps(issues), encoding="utf-8")
    replies = root / "replies"
    ingest_issue.main([str(listing), "--replies", str(replies), "--root", str(root)])
    expect("one outcome per issue, in order", (replies / "outcomes.txt").read_text().splitlines(),
           ["8 accepted", "9 rejected"])
    expect("a reply file per issue", sorted(p.name for p in replies.glob("*.md")), ["8.md", "9.md"])
    expect("commit message names the merged issue", (replies / "message.txt").read_text().strip(),
           "Add shared drop counts from issue #8")


def daily_limit(root):
    noon = 1795089600  # 2026-11-19 12:00 UTC
    outcomes = []
    for i in range(ingest_issue.DAILY_LIMIT + 1):
        sub = Client("Spam%d" % i)
        loot_mob(sub, 5, "S", [(100, 1)])
        late = issue(100 + i, form_body(export_string(sub)), login="busy")
        outcomes.append(ingest_issue.ingest(late, root, now=noon)[0])
    expect("accepted up to the daily limit, then waiting", outcomes,
           ["accepted"] * ingest_issue.DAILY_LIMIT + ["waiting"])
    expect("nothing saved for the waiting one", (root / "data" / "submissions" / "120-1.json").exists(), False)
    # The hourly runs see it again with the waiting label and leave it alone until the day is over.
    late["labels"] = [{"name": "waiting"}]
    expect("answered once while it waits", ingest_issue.ingest(late, root, now=noon + 3600),
           ("still-waiting", ""))
    expect("taken in on the next day", ingest_issue.ingest(late, root, now=noon + 13 * 3600)[0], "accepted")


def names(root):
    """Names in other scripts stay out, from any source, and a mob nobody names keeps its name from before."""
    def named(n, name):
        return submission(80 + n, origin(800 + n), {origin(800 + n): {5: mob({1: bucket(10, 10, 10)}, name=name)}})

    english, korean = named(1, "Wolf"), [named(2, "늑대"), named(3, "늑대")]
    expect("an English name beats two Korean ones", build_data.build([english] + korean)["mobs"]["5"]["name"], "Wolf")
    expect("a mob only named in Korean has no name", "name" in build_data.build(korean)["mobs"]["5"], False)
    nameless = [named(4, None)]
    expect("a mob nobody names keeps its name from before",
           build_data.build(nameless, previous_names={"5": "Old Wolf"})["mobs"]["5"].get("name"), "Old Wolf")
    expect("but not a Korean one", "name" in build_data.build(nameless, previous_names={"5": "늑대"})["mobs"]["5"], False)
    expect("a name given now beats the one from before",
           build_data.build([english], previous_names={"5": "Old Wolf"})["mobs"]["5"]["name"], "Wolf")
    expect("the names left out are listed", build_data.foreign_names([english] + korean), [("5", "늑대")])

    def naming(names):
        return dict(named(9, None), names=names, source={"name": "creature names"})

    gryphon = naming({"5": "Razorbeak Gryphon"})
    expect("a mob no source names takes an import's name",
           build_data.build(nameless, [gryphon])["mobs"]["5"].get("name"), "Razorbeak Gryphon")
    expect("before the name it had", build_data.build(nameless, [gryphon], previous_names={"5": "Old Wolf"})
           ["mobs"]["5"].get("name"), "Razorbeak Gryphon")
    expect("a source's name beats it", build_data.build([english], [gryphon])["mobs"]["5"]["name"], "Wolf")
    expect("a Korean one in the list is left out",
           build_data.build(nameless, [naming({"5": "늑대"})], previous_names={"5": "Old Wolf"})["mobs"]["5"]
           .get("name"), "Old Wolf")

    (root / "data" / "submissions").mkdir(parents=True)
    (root / "data" / "shared.json").write_text(json.dumps({"mobs": {"5": {"name": "Old Wolf"}}}), encoding="utf-8")
    (root / "data" / "submissions" / "84-1.json").write_text(json.dumps(nameless[0]), encoding="utf-8")
    build_data.main(["--root", str(root)])
    shared = json.loads((root / "data" / "shared.json").read_text(encoding="utf-8"))
    expect("main keeps the name data/shared.json had", shared["mobs"]["5"].get("name"), "Old Wolf")


def other_languages():
    """Every name of an exporter whose names mostly differ from the others' stays out: a client in German, French,
    Spanish, Italian or Portuguese writes in Latin letters too."""
    def exporting(n, names, extra=None):
        mobs = {npc: mob({1: bucket(10, 10, 10)}, name=name) for npc, name in names.items()}
        sources = {origin(900 + n): mobs}
        if extra:
            sources[origin(950 + n)] = {npc: mob({1: bucket(10, 10, 10)}, name=name) for npc, name in extra.items()}
        return submission(90 + n, origin(900 + n), sources)

    english = [exporting(1, {5: "Wolf", 6: "Bear", 7: "Boar"}), exporting(5, {6: "Bear", 7: "Boar"})]
    # The German for wolf is Wolf, so one of its names agrees. It also passes on another player's spider.
    german = exporting(2, {5: "Wolf", 6: "Bär", 7: "Eber"}, extra={8: "Spinne"})
    expect("an exporter whose names mostly differ is found", build_data.other_language(english + [german]),
           {origin(902): (2, 3)})
    mobs = build_data.build(english + [german])["mobs"]
    expect("its names stay out", (mobs["6"].get("name"), mobs["7"].get("name")), ("Bear", "Boar"))
    expect("the ones it passed on too", "name" in mobs["8"], False)
    expect("with nobody else to settle it, two that disagree both keep their names",
           build_data.other_language(english[:1] + [german]), {})
    renamed = exporting(3, {5: "Wolf", 6: "Old Bear", 7: "Boar"})
    expect("a mob renamed since doesn't make a client foreign", build_data.other_language(english + [renamed]), {})
    alone = exporting(4, {6: "Bär"})
    expect("one name compared isn't enough to tell", build_data.other_language(english + [alone]), {})


def forged_exports():
    """The first export of an install that carries a key hash pins it. Another export with that install's id and a
    different hash, or none, isn't its own: it can't replace the install's counts or make its real export look old."""
    a, mine, theirs = origin(90), "a" * 64, "b" * 64

    def keyed(number, kills, key):
        sub = submission(number, a, {a: {7: mob({1: bucket(kills, kills, kills, {100: kills // 5})})}})
        return dict(sub, key=key) if key else sub

    own = keyed(91, 50, mine)
    for label, forged in (("with another key", keyed(92, 500, theirs)), ("without a key", keyed(92, 500, None))):
        expect("a forged export %s doesn't make the real one look old" % label,
               build_data.superseded([own, forged]), [])
        expect("and doesn't replace the install's counts (%s)" % label,
               build_data.build([own, forged])["mobs"]["7"]["from"], {a: 50})
    newer = keyed(93, 60, mine)
    expect("the install's next export with its key replaces the old one",
           (build_data.superseded([own, newer]), build_data.build([own, newer])["mobs"]["7"]["from"]), ([own], {a: 60}))
    old_style = [keyed(94, 50, None), keyed(95, 60, None)]
    expect("an install that never sent a key counts as before", build_data.superseded(old_style), [old_style[0]])
    expect("and its later exports still count once it sends one",
           build_data.build(old_style + [keyed(96, 70, mine)])["mobs"]["7"]["from"], {a: 70})


def own_counts(me, solo, group):
    """SavedVariables of an install with solo and group kills of mob 12, item 100 in every corpse."""
    def lua_bucket(kills):
        return ("{ kills = %d, lootable = %d, opened = %d, items = { [100] = { drops = %d, qty = %d } },"
                " money = { drops = 0, copper = 0 } }" % ((kills,) * 5))
    return 'DropTablesDB = { installId = "%s", mobs = { [12] = { [1] = %s, [2] = %s } } }' % (
        me, lua_bucket(solo), lua_bucket(group))


def group_kills():
    """The shared database lists an install's kills per group size once it has group kills, so new group kills count
    only themselves: Solo doesn't count the old solo kills again and Group shows all of the new ones."""
    me = origin(80)
    solo_only = build_data.build([submission(81, me, {me: {12: mob({1: bucket(100, 100, 100, {100: 100})})}})])
    expect("an install with only solo kills is listed with a number", solo_only["mobs"]["12"]["from"][me], 100)
    grouped = Client("Grouped", data=build_data.lua_file(solo_only), saved=own_counts(me, 100, 20))
    expect("then 20 group kills: Solo doesn't count the old solo kills again",
           round(grouped.ns.GetStats(12, "solo").kills), 100)
    expect("and Group shows all 20", round(grouped.ns.GetStats(12, "group").kills), 20)
    expect("All has both", round(grouped.ns.GetStats(12, "all").kills), 120)
    both = build_data.build([submission(82, me, {me: {12: mob({1: bucket(100, 100, 100, {100: 100}),
                                                               2: bucket(20, 20, 20, {100: 20})})}})])
    expect("once it has group kills, they're listed per group size", both["mobs"]["12"]["from"][me], {"1": 100, "2": 20})
    same = Client("Same", data=build_data.lua_file(both), saved=own_counts(me, 100, 20))
    expect("the addon reads them: nothing of it counts twice", round(same.ns.GetStats(12, "all").kills), 120)
    expect("and nothing is left to export", same.ns.NewCount(), 0)
    more = Client("More", data=build_data.lua_file(both), saved=own_counts(me, 100, 21))
    expect("until one more kill", (round(more.ns.GetStats(12, "group").kills), more.ns.NewCount()), (21, 1))
    # The kills a hotfix reset left out are kept per group size too.
    old = dict(submission(83, me, {me: {12: mob({1: bucket(30, 30, 30, {100: 30}), 2: bucket(5, 5, 5, {100: 5})})}}),
               received=build_data.since_time("2026-11-01") - 10)
    new = dict(submission(84, me, {me: {12: mob({1: bucket(40, 40, 40, {100: 40}), 2: bucket(9, 9, 9, {100: 9})})}}),
               received=build_data.since_time("2026-11-01") + 10)
    reset = build_data.build([old, new], resets={"12": "2026-11-01"})
    expect("a reset keeps what it left out per group size", reset["mobs"]["12"]["from"][me], {"1": 40, "2": 9})


def main():
    merge_rules()
    other_languages()
    with tempfile.TemporaryDirectory() as folder:
        names(pathlib.Path(folder))
    shared_is_trusted()
    hotfix_resets()
    group_kills()
    forged_exports()
    with tempfile.TemporaryDirectory() as folder:
        imports(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        issues_and_game(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        daily_limit(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        issue_list(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        pruning(pathlib.Path(folder))
    with tempfile.TemporaryDirectory() as folder:
        shrink_guard(pathlib.Path(folder))
    # A control character in a name can't break Data.lua: it goes in as an escape and reads back the same.
    literal = build_data.lua_string('Line\none "two"\\')
    expect("control characters escaped", "\n" in literal, False)
    reader = Client("Reader")
    expect("the escaped name reads back", reader.lua.eval(literal), 'Line\none "two"\\')
    report("shared data")


if __name__ == "__main__":
    main()
