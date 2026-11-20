"""Skinning: recording what skinned corpses give, its chances, sharing it, the export and the shared database, and the
Loot Finder, tooltip and details window that show it.

Requires: pip install lupa
Run: python tests/test_skinning.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import ALL_FILES, UI_STUBS, Client, expect, report  # noqa: E402
from test_share import Net, form_party, plain  # noqa: E402
import build_data  # noqa: E402
import check_export  # noqa: E402

LIGHT, SCRAPS, HIDE, PRISTINE = 2318, 2934, 783, 249427
QUEST_ITEM = 102  # item class 12 in the simulator
SKINNING, MINING = 8613, 2575

SPELLS = """
C_Spell = { GetSpellName = function(id) return (id == 8613 or id == 99999) and "Skinning" or "Mining" end }
"""

UI = UI_STUBS + SPELLS + """
UISpecialFrames = {}
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) tooltipHook = fn end }
Enum.TooltipDataType = { Unit = 1 }
function tContains(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
GameTooltip_Hide = function() end
"""


def cast(client, spell):
    client.fire("UNIT_SPELLCAST_START", "player")
    client.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", spell)


def skin(client, guid, items, spell=SKINNING):
    """Casts the spell at the corpse and opens what it gives."""
    cast(client, spell)
    client.loot([{"type": 1, "item": item, "name": "Item %d" % item, "qty": qty, "sources": [guid, qty]}
                 for item, qty in items])


def kill_loot_skin(client, npc, spawn, items, loot=((100, 1),)):
    guid = client.kill(npc, spawn, True)
    client.advance(5)
    client.loot([{"type": 1, "item": item, "name": "Item %d" % item, "qty": qty, "sources": [guid, qty]}
                 for item, qty in loot])
    client.advance(1)
    skin(client, guid, items)
    client.advance(1)
    return guid


def skins_of(client, npc):
    data = plain(client.ns.db.skins[npc])
    if not data:
        return None
    return data["skinned"], {k: (v["drops"], v["qty"]) for k, v in data["items"].items()}


def recording():
    c = Client("Skinner", saved=SPELLS)
    ns = c.ns
    guid = kill_loot_skin(c, 20, "A", [(LIGHT, 2), (QUEST_ITEM, 1)])
    expect("a skinned corpse is counted with what it gave", skins_of(c, 20), (1, {LIGHT: (1, 2)}))
    expect("its loot stays loot", (ns.db.mobs[20][1].opened, ns.db.mobs[20][1]["items"][LIGHT]), (1, None))

    # The window opens again when the bags were full; the corpse still counts once.
    skin(c, guid, [(LIGHT, 2)])
    expect("a corpse skinned again counts once", skins_of(c, 20)[0], 1)

    # Someone else's kill skins the same, and the group plays no part.
    other = "Creature-0-1-0-1-20-B"
    skin(c, other, [(SCRAPS, 1)])
    expect("another player's kill counts when skinned", skins_of(c, 20), (2, {LIGHT: (1, 2), SCRAPS: (1, 1)}))
    expect("skinning someone else's kill adds no kill", ns.db.mobs[20][1].kills, 1)

    # Another spell at a corpse is neither loot nor skinning.
    c.advance(5)
    skin(c, "Creature-0-1-0-1-21-M", [(2770, 1)], spell=MINING)
    expect("mining a corpse is left out", (ns.db.skins[21], ns.db.mobs[21]), (None, None))

    # A spell called Skinning with another id counts too.
    c.advance(5)
    skin(c, "Creature-0-1-0-1-22-X", [(SCRAPS, 1)], spell=99999)
    expect("a Skinning spell of another id counts", skins_of(c, 22), (1, {SCRAPS: (1, 1)}))

    # Plain loot right after a cast at another mob is still plain loot.
    c.advance(5)
    fresh = c.kill(23, "F", True)
    c.advance(5)
    cast(c, SKINNING)
    c.loot([{"type": 1, "item": 100, "name": "Wolf Fang", "qty": 1, "sources": [fresh, 1]}])
    expect("loot of a corpse known to hold loot isn't skinning", (ns.db.skins[23], ns.db.mobs[23][1].opened), (None, 1))

    expect("a mob only skinned is a known mob", ns.KnownNpcs()[22], True)
    expect("its name of an item seen in skinning is kept", ns.db["items"][SCRAPS].name, "Item %d" % SCRAPS)
    return c


def chances():
    c = Client("Chances")
    ns = c.ns
    c.g.DropTablesNs = ns
    c.lua.execute("""
        local ns = DropTablesNs
        ns.db.skins[30] = { skinned = 4, items = { [2318] = { drops = 3, qty = 3 }, [2934] = { drops = 1, qty = 1 } } }
        local function peer(light, pristine)
            return { buckets = {}, maps = {}, t = 1, skins = { skinned = 40, items = {
                [2318] = { drops = light, qty = light }, [249427] = { drops = pristine, qty = pristine } } } }
        end
        ns.db.peers[30] = { a = peer(20, 2), b = peer(20, 2), c = peer(20, 2), d = peer(40, 30) }
    """)
    c.fire("DT_DATA_CHANGED", 30)
    stats = ns.GetSkinStats(30)
    rates = {e.itemId: round(e.rate, 4) for e in stats.list.values()}
    # Light Leather: d saw it on every corpse, far from the 50% of the other three, so d is left out of it.
    expect("a big install far off the rest is left out of an item", rates[LIGHT], round((3 + 60) / (4 + 120), 4))
    # Pristine Leather: the perk changes it from player to player, so d still counts.
    expect("scarce materials keep every install", rates[PRISTINE], round((2 + 2 + 2 + 30) / (4 + 160), 4))
    expect("scarce materials are marked", [e.scarce for e in stats.list.values() if e.itemId == PRISTINE], [True])
    expect("chances per skinned corpse, no empty share", rates[SCRAPS], round(1 / 164, 4))
    expect("skinned corpses in total", stats.skinned, 164)

    # Big installs count as at most 300 skinned corpses.
    c.lua.execute("""
        local ns = DropTablesNs
        ns.db.peers[30] = { e = { buckets = {}, maps = {}, t = 1, skins = { skinned = 600,
            items = { [2318] = { drops = 600, qty = 600 } } } } }
    """)
    c.fire("DT_DATA_CHANGED", 30)
    expect("an install counts as at most 300 skinned corpses", ns.GetSkinStats(30).skinned, 304)

    # The shared database already holds the player's first 4, so only what came after counts again.
    c.lua.execute("""
        local ns = DropTablesNs
        ns.db.peers[30] = nil
        ns.shared[30] = { buckets = {}, from = {}, maps = {}, skins = { skinned = 10,
            items = { [2318] = { drops = 5, qty = 5 } }, from = { [ns.db.installId] = 4 } } }
    """)
    c.fire("DT_DATA_CHANGED", 30)
    stats = ns.GetSkinStats(30)
    expect("the player's skinning in the shared database isn't counted twice",
           (stats.skinned, round(next(e.rate for e in stats.list.values() if e.itemId == LIGHT), 4)), (10, 0.5))
    ns.settings.onlyMine = True
    c.fire("DT_SETTINGS_CHANGED")
    expect("only mine leaves the shared skinning out", ns.GetSkinStats(30).skinned, 4)
    ns.settings.onlyMine = False
    c.fire("DT_SETTINGS_CHANGED")

    for level, skill in ((5, 1), (10, 1), (11, 10), (15, 50), (20, 100), (21, 105), (40, 200), (60, 300)):
        expect("skill for level %d" % level, ns.SkinningSkill(level), skill)
    expect("no level, no skill", ns.SkinningSkill(None), None)


def wire():
    c = Client("Wire")
    Wire = c.ns.Wire
    skins = c.lua.eval("{ skinned = 12, items = { [2318] = { drops = 7, qty = 9, min = 1, max = 2 }, "
                       "[783] = { drops = 1, qty = 1, min = 1, max = 1 } } }")
    records = Wire.SkinRecords(40, skins)
    texts = [records[i] for i in range(1, len(records) + 1)]
    expect("the count first, the most frequent item next", [t[0] for t in texts], ["K", "U", "U"])
    decoded = Wire.DecodeRecords(";".join(texts))
    first = decoded[2]
    expect("skinning records read back", (decoded[1].skinned, first.item, first.drops, first.qty, first.min, first.max),
           (12, LIGHT, 7, 9, 1, 2))
    bad = c.lua.eval("{ skinned = 1, items = { [2318] = { drops = 2, qty = 2 } } }")
    expect("more drops than skinned corpses isn't passed on", len(list(Wire.SkinRecords(40, bad).values())), 0)
    expect("a skinned count of 0 is refused", Wire.DecodeRecords("K14.0")[0], None)


def sharing():
    ann, bob = Client("Ann"), Client("Bob", saved=SPELLS)
    net = Net(ann, bob)
    net.run(10)  # both join the channel
    for spawn in ("1", "2", "3"):
        kill_loot_skin(bob, 30, spawn, [(LIGHT, 1)])
    start = len(net.log)
    ann.see(30, "X", 12)
    net.run(15)
    loot = [m[1] for m in net.sent("Bob", "D|", start)]
    skinning = [m[1] for m in net.sent("Bob", "S|", start)]
    expect("the answer carries the loot and the skinning", (len(loot), len(skinning)), (1, 1))
    expect("the loot message holds no skinning record, so older versions still read it",
           any(r[0] in "KU" for text in loot for r in text.split("|", 2)[2].split(";")), False)
    expect("the skinning came after the loot", net.log.index(next(m for m in net.log if m[1] == skinning[0]))
           > net.log.index(next(m for m in net.log if m[1] == loot[0])), True)
    peer = ann.ns.db.peers[30][bob.ns.db.installId]
    expect("the asker stores the skinning", (peer.skins.skinned, peer.skins["items"][LIGHT].drops), (3, 3))
    expect("and shows its chance", round(next(e.rate for e in ann.ns.GetSkinStats(30).list.values()), 2), 1.0)

    # Skinning nobody asked about is ignored.
    origin = bob.ns.db.installId
    ann.fire("CHAT_MSG_ADDON", "DropTables", "S|%s|K%s.3;U%s.%s.3.3.1.1" % (origin, "v", "v", "1rq"), "WHISPER", "Bob")
    expect("unasked skinning is ignored", ann.ns.db.peers[31], None)
    # A loot message with skinning records in it is refused as a whole.
    ann.fire("CHAT_MSG_ADDON", "DropTables", "D|%s|K%s.9" % (origin, "u"), "WHISPER", "Bob")
    expect("skinning inside a loot message is refused", ann.ns.db.peers[30][origin].skins.skinned, 3)

    # In a group a mob the player only skinned goes out with the next group send.
    form_party(ann, bob)
    skin(bob, "Creature-0-1-0-1-32-G", [(SCRAPS, 1)])
    start = len(net.log)
    net.run(70)
    sent = {(m[1][:2], m[1].split("|")[2][1:].split(".")[0]) for m in net.sent("Bob", start=start) if m[2] == "PARTY"}
    expect("a mob only skinned goes to the group as skinning alone", (("S|", "w") in sent, ("D|", "w") in sent),
           (True, False))
    expect("the group member stores it", ann.ns.db.peers[32][origin].skins.skinned, 1)


def export_and_database():
    bob = Client("Bob", saved=SPELLS)
    for spawn in ("1", "2", "3", "4"):
        kill_loot_skin(bob, 30, spawn, [(LIGHT, 1)] if spawn != "4" else [(SCRAPS, 2)])
    skin(bob, "Creature-0-1-0-1-32-G", [(SCRAPS, 1)])
    result = bob.ns.BuildExport()
    string = result.strings[1]
    checked = check_export.check(string)
    mobs = checked["sources"][bob.ns.db.installId]["mobs"]
    expect("the export carries skinning",
           mobs["30"]["skins"], {"skinned": 4, "items": {str(LIGHT): {"drops": 3, "qty": 3, "min": 1, "max": 1},
                                                         str(SCRAPS): {"drops": 1, "qty": 2, "min": 2, "max": 2}}})
    expect("a mob only skinned goes out without loot", (mobs["32"]["buckets"], mobs["32"]["skins"]["skinned"]), ({}, 1))
    expect("the summary counts skinned corpses", check_export.summary(checked).endswith("5 skinned"), True)

    head = "DTX|1|%s|0.5.0|1700000000|1/1\n@%s\n" % ("a" * 16, "a" * 16)
    for label, line in (("more items than skinned corpses", "Ku.2;Uu.1rq.3.3.1.1"),
                        ("items without a skinned count", "Uu.1rq.1.1.1.1")):
        try:
            check_export.parse(head + line)
            expect("refused: " + label, "accepted", "refused")
        except check_export.Invalid:
            pass

    sub = {"issue": 7, "index": 1, "submitter": "bob", "received": 1700000000, "result": checked}
    db = build_data.build([sub])
    expect("the database holds the skinning", db["mobs"]["30"]["skins"]["skinned"], 4)
    expect("and lists the install with its skinned corpses", db["mobs"]["30"]["skins"]["from"],
           {bob.ns.db.installId: 4})
    expect("a mob only skinned gets a record", (db["mobs"]["32"]["buckets"], db["mobs"]["32"]["skins"]["skinned"]),
           ({}, 1))

    # A newer export with fewer skinned corpses doesn't make the older one redundant.
    newer = {"issue": 8, "index": 1, "submitter": "bob", "received": 1700000100,
             "result": dict(checked, sources={o: {"mobs": {n: dict(m, skins=None) for n, m in s["mobs"].items()}}
                                              for o, s in checked["sources"].items()})}
    expect("skinning keeps an older export", build_data.superseded([sub, newer]), [])
    expect("an export covering it all replaces it", build_data.superseded([sub, dict(sub, issue=9)]), [sub])

    # In the addon, from Data.lua, after a new install starts.
    lua = build_data.lua_file(db)
    fresh = Client("Fresh", data=lua)
    stats = fresh.ns.GetSkinStats(30)
    expect("the shared skinning loads", (stats.skinned, round(stats.list[1].rate, 2)), (4, 0.75))
    expect("the item comes up for skinning", [s.npc for s in fresh.ns.FindSkinners(LIGHT).values()], [30])
    return db


def merging():
    def skin_sub(origin, skinned, light, pristine, issue):
        items = {str(LIGHT): {"drops": light, "qty": light}, str(PRISTINE): {"drops": pristine, "qty": pristine}}
        return {"issue": issue, "index": 1, "submitter": origin, "received": 0, "result": {
            "exporter": origin, "part": 1, "parts": 1, "sources": {origin: {"mobs": {"50": {
                "buckets": {}, "maps": {}, "name": "Cat", "levels": [12, 13],
                "skins": {"skinned": skinned, "items": items}}}}}}}
    subs = [skin_sub("%016x" % i, 40, 20, 2, i) for i in range(1, 4)] + [skin_sub("%016x" % 9, 40, 40, 30, 9)]
    record = build_data.build(subs)["mobs"]["50"]
    expect("an install far off the rest is left out of the skinning", sorted(record["skins"]["from"]),
           ["%016x" % i for i in range(1, 4)])
    expect("a mob only skinned keeps its name and levels", (record["name"], record["minLevel"], record["maxLevel"]),
           ("Cat", 12, 13))
    subs[-1] = skin_sub("%016x" % 9, 40, 20, 30, 9)
    record = build_data.build(subs)["mobs"]["50"]
    expect("scarce materials don't make an install an outlier", len(record["skins"]["from"]), 4)
    big = skin_sub("%016x" % 10, 900, 450, 0, 10)
    record = build_data.build([big])["mobs"]["50"]
    expect("an install counts as at most 300 skinned corpses", record["skins"]["skinned"], 300)
    quest = skin_sub("%016x" % 11, 4, 2, 0, 11)
    quest["result"]["sources"]["%016x" % 11]["mobs"]["50"]["skins"]["items"]["500"] = {"drops": 1, "qty": 1}
    record = build_data.build([quest], quest_items=frozenset({500}))["mobs"]["50"]
    expect("quest items stay out of skinning", "500" in record["skins"]["items"], False)


def finder(db):
    db = dict(db, mobs=dict(db["mobs"], **{"30": dict(db["mobs"]["30"], minLevel=14, maxLevel=15)}))
    c = Client("Finder", saved=SPELLS, data=build_data.lua_file(db))
    ns = c.ns
    kill_loot_skin(c, 40, "A", [(HIDE, 1)], loot=((100, 1),))
    expect("an item only skinned isn't among the looted items",
           sorted(i.itemId for i in ns.SearchItems("").values()), [100])
    expect("but is among the skinning items", sorted(i.itemId for i in ns.SkinItems("").values()), [HIDE, LIGHT, SCRAPS])
    expect("search works on skinning items", [i.itemId for i in ns.SkinItems(str(HIDE)).values()], [HIDE])

    pick = c.lua.eval("function(ns, list) local t = {} for i, d in ipairs(list) do t[i] = d end "
                      "local best = ns.LowestSkinner(t) return best and best.npc end")

    def lowest(*droppers):
        return pick(ns, c.lua.table_from([c.lua.table_from(d) for d in droppers]))

    expect("the lowest mob with 3 skins or more", lowest(
        {"npc": 1, "minLevel": 10, "kills": 2, "rate": 0.9}, {"npc": 2, "minLevel": 12, "kills": 5, "rate": 0.3},
        {"npc": 3, "minLevel": 11, "kills": 5, "rate": 0.5}), 3)
    expect("on the same level the better chance", lowest(
        {"npc": 2, "minLevel": 11, "kills": 5, "rate": 0.3}, {"npc": 3, "minLevel": 11, "kills": 5, "rate": 0.5}), 3)
    expect("with only mobs under 3 skins, the lowest of them", lowest(
        {"npc": 1, "minLevel": 14, "kills": 2, "rate": 0.9}, {"npc": 2, "minLevel": 12, "kills": 1, "rate": 0.3}), 2)
    for order in (1, -1):
        expect("a mob of unknown level comes last", lowest(
            *[{"npc": 4, "kills": 50, "rate": 1.0}, {"npc": 5, "minLevel": 30, "kills": 3, "rate": 0.1}][::order]), 5)

    summaries, _maps = ns.SummarizeSkinItems(ns.SkinItems(""))
    light = next(s for s in summaries.values() if s.itemId == LIGHT)
    expect("the skinning item's lowest mob", (light.bestNpc, light.minLevel), (30, 14))
    skinner = ns.FindSkinners(LIGHT)[1]
    expect("a skinner says the skill its lowest level needs", skinner.skill, 40)


def interface(db):
    c = Client("Viewer", files=ALL_FILES + ("Style.lua", "Details.lua", "Tooltip.lua", "Finder.lua"), saved=UI,
               data=build_data.lua_file(db))
    c.lua.execute("""
        tipLines = {}
        GameTooltip = setmetatable({
            AddLine = function(_, text) table.insert(tipLines, text) end,
            AddDoubleLine = function(_, left) table.insert(tipLines, left) end,
        }, getmetatable(GameTooltip))
    """)
    hook = c.g.tooltipHook
    hook(c.g.GameTooltip, c.lua.table_from({"guid": "Creature-0-1-0-1-32-T"}))
    lines = list(c.g.tipLines.values())
    expect("a mob only skinned gets a skinning line", any("Skinning" in str(line) and "100%" in str(line)
                                                         for line in lines), True)
    c.lua.execute("tipLines = {}")
    hook(c.g.GameTooltip, c.lua.table_from({"guid": "Creature-0-1-0-1-30-T"}))
    lines = [str(line) for line in c.g.tipLines.values()]
    expect("a mob with loot and skinning gets the skinning line last", "Skinning" in lines[-1], True)

    # The details window and the Loot Finder draw skinning without errors.
    count_calls = c.lua.eval("""function(ns)
        local get = ns.GetSkinStats
        skinCalls = 0
        ns.GetSkinStats = function(...) skinCalls = skinCalls + 1 return get(...) end
    end""")
    count_calls(c.ns)
    c.ns.ShowDetails(32)
    c.ns.ShowDetails(30)
    expect("the details window asks for the skinning", c.g.skinCalls >= 2, True)
    c.ns.OpenFinder(LIGHT, "skin")
    c.ns.OpenFinder(LIGHT)
    c.ns.OpenFinder("Item")
    c.advance(1)

    # Under the target the skinning icons get a row of their own, below the loot icons.
    strip = Client("Strip", files=ALL_FILES + ("Strip.lua",), saved=UI + """
        frames = {}
        local create = CreateFrame
        function CreateFrame(...)
            local w = create(...)
            w.SetPoint = function(self, point, x, y) self.point = { point, x, y } end
            table.insert(frames, w)
            return w
        end
    """, data=build_data.lua_file(db))

    skin_row_icons = strip.lua.eval("""function()
        local n = 0
        for _, f in ipairs(frames) do
            local point = rawget(f, "point")
            if point and point[3] == -46 and rawget(f, "shown") then n = n + 1 end
        end
        return n
    end""")

    strip.see(30, "S", 14)
    expect("a mob with skinning gets a row of skinning icons", skin_row_icons(), 2)
    strip.see(7, "N", 5)
    expect("a mob nobody skinned has none", skin_row_icons(), 0)


def main():
    recording()
    chances()
    wire()
    sharing()
    db = export_and_database()
    merging()
    finder(db)
    interface(db)
    report("skinning")


if __name__ == "__main__":
    main()
