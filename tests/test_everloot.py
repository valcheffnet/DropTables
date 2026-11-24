"""The Everloot import: tools/import_everloot.py turns downloaded pages of Everloot's public corpus into
data/imports/everloot.json, and tools/build_data.py merges it as a partial source with its own money and stacks.

Requires: pip install lupa
Run: python tests/test_everloot.py
"""
import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import Client, expect, report  # noqa: E402
import build_data  # noqa: E402
import import_everloot  # noqa: E402

DAY = "2026-11-10T12:00:00Z"
QUEST_ITEM = 900


def loot(install, npc, items=(), copper=0, loot_type="kill", at=DAY, n=[0]):
    n[0] += 1
    rec = {"installId": install, "eventId": "e:%d" % n[0], "capturedAt": at, "kind": "loot", "lootType": loot_type,
           "sourceNpcId": npc, "sourceEvidence": "loot-api",
           "items": [{"itemId": item, "count": count} for item, count in items]}
    if copper:
        rec["copper"] = copper
    return rec


def sighting(install, npc, name, level=5, ui_map=1429, x=10.1, y=20.5):
    return {"installId": install, "eventId": "s", "capturedAt": DAY, "kind": "npc_sighting", "npcId": npc,
            "name": name, "level": level, "mapId": ui_map, "x": x, "y": y}


def save(folder, name, field, rows, extra=None):
    page = dict({field: rows, "next": None, "dataAsOf": "2026-11-20T09:10:13Z"}, **(extra or {}))
    (folder / ("%s-00.json" % name)).write_text(json.dumps(page), encoding="utf-8")


def fake_corpus(folder):
    a, b, es = "pub-aaaaaaaa11", "pub-bbbbbbbb22", "pub-cccccccc33"
    records = [
        # npc 10: install a opens 4 corpses, install b 2.
        loot(a, 10, [(100, 2), (QUEST_ITEM, 1)], copper=30),
        loot(a, 10, [(100, 1), (100, 2)], copper=50),
        loot(a, 10, [(QUEST_ITEM, 1)]),
        loot(a, 10, []),
        loot(b, 10, [(101, 1)], copper=10),
        loot(b, 10, [(100, 3)]),
        # Not kills, and a kill from the beta.
        loot(a, 10, [(2318, 1)], loot_type="skinning"),
        loot(a, 10, [(500, 1)], at="2026-10-20T10:00:00Z"),
        {"installId": a, "eventId": "x", "capturedAt": DAY, "kind": "loot", "sourceNpcId": 10, "items": []},
        # npc 11: only install b, never seen.
        loot(b, 11, [(300, 1)]),
        # Skinning: two corpses of npc 10 for a, and npc 15 that b only skinned.
        loot(a, 10, [(2318, 2)], loot_type="skinning"),
        loot(b, 15, [(2934, 1), (QUEST_ITEM, 1)], loot_type="skinning"),
    ]
    save(folder, "loot", "records", records)
    sightings = []
    for install in (a, b):
        for npc, name in ((10, "Forest Thing"), (20, "Tree"), (21, "Rock"), (22, "Bush"), (23, "Pond"), (24, "Hill")):
            sightings.append(sighting(install, npc, name, level=5 if install == a else 7))
    for npc, name in ((10, "Cosa del bosque"), (20, "Arbol"), (21, "Roca"), (22, "Arbusto"), (23, "Estanque"),
                      (24, "Colina")):
        sightings.append(sighting(es, npc, name, level=9, ui_map=1430))
    sightings.append(sighting(a, 10, "Forest Thing", ui_map=1430, x=20.2, y=20.2))
    # More sightings of npc 10 in Spanish than in English, without a place.
    sightings += [sighting(es, 10, "Cosa del bosque", ui_map=None) for _ in range(4)]
    save(folder, "sightings", "records", sightings)
    items = [{"itemId": QUEST_ITEM, "class": {"id": 12}}, {"itemId": 100, "class": {"id": 7}}]
    save(folder, "items", "items", items, {"gameData": {"build": "1.60.1.70959"}})


def write_names(folder, data):
    path = folder / "names.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def conversion(folder):
    imp = import_everloot.make_import(folder)
    sources = imp["result"]["sources"]
    expect("one source per install, with a short id", sorted(sources), ["everloot-aaaaaaaa", "everloot-bbbbbbbb"])
    a = sources["everloot-aaaaaaaa"]["mobs"]
    expect("only the kill and skinning windows of the live servers", sorted(a), ["10"])
    expect("skinning windows count per install", a["10"]["skins"],
           {"skinned": 2, "items": {"2318": {"drops": 2, "qty": 3, "min": 1, "max": 2}}})
    only = sources["everloot-bbbbbbbb"]["mobs"]["15"]
    expect("a mob only skinned has no loot, and no quest items", (only["buckets"], only["skins"]["items"]),
           ({}, {"2934": {"drops": 1, "qty": 1, "min": 1, "max": 1}}))
    b = a["10"]["buckets"]["1"]
    expect("every kill window is an opened corpse, empty or with only a quest item too", b["opened"], 4)
    expect("a partial source counts each corpse as a kill with loot", (b["kills"], b["lootable"]), (4, 4))
    expect("quest items stay out", sorted(b["items"]), ["100"])
    expect("an item twice in one window is one drop of both stacks",
           b["items"]["100"], {"drops": 2, "qty": 5, "min": 2, "max": 3})
    expect("money with its range", b["money"], {"drops": 2, "copper": 80, "min": 30, "max": 50})
    expect("names come from English installs only", a["10"]["name"], "Forest Thing")
    expect("levels span the sightings", a["10"]["levels"], [5, 9])
    # npc 10 was seen twice on 1429, in cell 260, and twice on 1430, in cells 260 and 510; a has 4 corpses of it.
    expect("corpses spread over the maps the mob was seen on", a["10"]["maps"], {"1429": 2, "1430": 2})
    expect("cells weigh like the corpses", a["10"]["cells"], {"1429": {"260": 2}, "1430": {"260": 1, "510": 1}})
    expect("an install with fewer corpses gets a smaller share of the spots",
           sources["everloot-bbbbbbbb"]["mobs"]["10"]["cells"], {"1429": {"260": 1}, "1430": {"260": 0.5, "510": 0.5}})
    unseen = sources["everloot-bbbbbbbb"]["mobs"]["11"]
    expect("a mob nobody saw has no name, place or level", (unseen["name"], unseen["maps"], unseen["levels"]),
           (None, {}, None))
    names = {"10": "Name From The File", "11": "Dungeon Thing"}
    named = import_everloot.make_import(folder, names)["result"]["sources"]
    expect("the names file names a mob nobody saw", named["everloot-bbbbbbbb"]["mobs"]["11"]["name"], "Dungeon Thing")
    expect("but a name from the sightings comes first", named["everloot-aaaaaaaa"]["mobs"]["10"]["name"],
           "Forest Thing")
    expect("QuestieDB's npc rows work as a names file",
           import_everloot.read_names(write_names(folder, {"npcs": {"11": {"name": "Dungeon Thing", "lo": 1}}})),
           {"11": "Dungeon Thing"})
    expect("so does shared.json, which keeps the names given before",
           import_everloot.read_names(write_names(folder, {"mobs": {"11": {"name": "Dungeon Thing"}, "12": {}}})),
           {"11": "Dungeon Thing"})
    expect("the import is partial with its own money and stacks", (imp["partial"], imp["own"]),
           (True, ["money", "qty"]))
    expect("the quest list comes from the item list", import_everloot.quest_list(folder)["items"], [QUEST_ITEM])
    return imp


def resets(folder):
    """A mob whose loot a hotfix changed keeps only the windows from the day in data/loot-resets.json on."""
    a = "pub-aaaaaaaa11"
    records = [loot(a, 10, [(100, 1)], at="2026-11-10T12:00:00Z"), loot(a, 10, [(100, 1)], at="2026-11-12T08:00:00Z"),
               loot(a, 10, [(2318, 1)], loot_type="skinning", at="2026-11-10T12:00:00Z"),
               loot(a, 10, [(2318, 1)], loot_type="skinning", at="2026-11-12T08:00:00Z")]
    reset = {"10": "2026-11-12"}
    expect("kill windows from before the day stay out",
           (import_everloot.tally(records, set())[(a, 10)]["opened"],
            import_everloot.tally(records, set(), reset)[(a, 10)]["opened"]), (2, 1))
    expect("so do skinning windows", import_everloot.tally_skins(records, set(), reset)[(a, 10)]["skinned"], 1)
    expect("other mobs keep theirs", import_everloot.tally(records, set(), {"11": "2026-11-12"})[(a, 10)]["opened"], 2)
    sources = import_everloot.make_import(folder, resets={"10": "2026-11-11"})["result"]["sources"]
    npcs = {npc for source in sources.values() for npc in source["mobs"]}
    expect("the import passes the resets on", ("10" in npcs, "11" in npcs), (False, True))


def full_source(npc, kills, lootable, opened, items, money=(0, 0)):
    mob = {"buckets": {"1": {"kills": kills, "lootable": lootable, "opened": opened, "items": items,
                             "money": {"drops": money[0], "copper": money[1]}}}, "maps": {}, "name": "Forest Thing"}
    return {"index": 1, "issue": 0, "partial": False, "received": 0, "submitter": "import:full",
            "result": {"exporter": "full", "part": 1, "parts": 1, "sources": {"full": {"mobs": {npc: mob}}}},
            "source": {"name": "full", "copyright": "x", "license": "x", "url": "x"}}


def merged(imp):
    full = full_source("10", 40, 20, 20, {"100": {"drops": 10, "qty": 10}, str(QUEST_ITEM): {"drops": 5, "qty": 5}},
                       money=(20, 2000))
    db = build_data.build([], [full, imp], frozenset([QUEST_ITEM]))
    b = db["mobs"]["10"]["buckets"]["1"]
    # Everloot brings 6 corpses: with the full source's half of kills empty, they stand for 12 kills.
    expect("kills follow the full source", (b["kills"], b["lootable"], b["opened"]), (52, 26, 26))
    expect("money is Everloot's own, not the full source's share", b["money"]["drops"], 20 + 3)
    expect("so is copper", b["money"]["copper"], 2000 + 90)
    expect("stack sizes are Everloot's own", b["items"]["100"]["qty"], 10 + 5 + 3)
    expect("the quest list clears quest items of every source", str(QUEST_ITEM) in b["items"], False)
    dummy = full_source("2673", 3, 3, 3, {"2841": {"drops": 3, "qty": 3}})
    expect("a Target Dummy isn't a mob", "2673" in build_data.build([], [dummy])["mobs"], False)
    expect("both installs are listed", sorted(db["mobs"]["10"]["from"]),
           ["everloot-aaaaaaaa", "everloot-bbbbbbbb", "full"])

    many = dict(imp, result=dict(imp["result"], sources={
        "everloot-%04d" % i: imp["result"]["sources"]["everloot-bbbbbbbb"] for i in range(60)}))
    db = build_data.build([], [many])
    expect("an import's installs aren't cut as unconfirmed", len(db["mobs"]["11"]["from"]), 60)
    return build_data.build([], [imp], frozenset([QUEST_ITEM]))


def in_the_addon(database):
    lua = build_data.lua_file(database)
    expect("Data.lua carries the CC BY-SA credit",
           "-- Data from Everloot (https://everloot.app), CC BY-SA 4.0. Drop Tables changed it" in lua, True)
    client = Client("Everloot", data=lua)
    stats = client.ns.GetStats(11, "all")
    entry = next(e for e in stats.list.values() if e.itemId == 300)
    expect("a mob only Everloot knows shows its drop per corpse", round(entry.rate, 2), 1.0)
    expect("and its name falls back to the npc id", client.ns.MobName(11), "NPC 11")


def main():
    with tempfile.TemporaryDirectory() as folder:
        folder = pathlib.Path(folder)
        fake_corpus(folder)
        imp = conversion(folder)
        in_the_addon(merged(imp))
        resets(folder)
    report("Everloot import")


if __name__ == "__main__":
    main()
