"""The EG Link import: tools/import_eglink.py turns a clone of EG Link output into data/imports/eglink.json.

Requires: pip install lupa, and git on PATH
Run: python tests/test_eglink.py
"""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "tools"))
from wowsim import Client, expect, report  # noqa: E402
import build_data  # noqa: E402
import import_eglink  # noqa: E402


def kills(deaths, empty=0, unknown=0, levels=None):
    return {"deaths": deaths, "empty": empty, "unknown": unknown, "levels": levels or {}, "sources": 1}


def window(windows, items=None, coins=0, copper=0, copper_windows=0):
    return {"windows": windows, "items": items or {}, "coins": coins, "copper": copper,
            "copperWindows": copper_windows, "sources": 1}


def item(drops, quantity=None, quest=None):
    entry = {"drops": drops, "quantity": drops if quantity is None else quantity, "chance": 0}
    if quest:
        entry["quest"] = quest
    return entry


def pos(ui_map, x, y):
    return {"instance": 0, "uiMap": ui_map, "mapX": x, "mapY": y, "worldX": 0, "worldY": 0}


def write(folder, name, data):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_text(json.dumps(data), encoding="utf-8")


def fake_clone(root):
    """Two live builds and one beta build, committed so the import can name the commit."""
    live = root / "data" / "wowf"
    write(live / "1.60.1.70100", "loot.json", {
        "kills": {
            "npc:10": kills(10, empty=2, levels={"5": 6, "6": 4}),
            "npc:10|quest": kills(4, levels={"7": 4}),
            "npc:10|group": kills(50, empty=40),
            "npc:11": kills(4, empty=2),
            "npc:12": kills(3, empty=3),
            "object:99|spell:3365": kills(9),
        },
        "sources": {
            "npc:10": window(8, {"100": item(4, quantity=6), "200": item(2, quest=123), "288842": item(1)},
                             coins=8, copper=400, copper_windows=4),
            "npc:10|quest": window(4, {"100": item(2), "201": item(4, quest=True)}),
            "npc:10|group": window(10, {"100": item(10)}),
            "npc:10|spell:8613": window(6, {"2318": item(6), "288900": item(1)}),
            "npc:10|spell:8617|group": window(2, {"2318": item(1), "783": item(1, quantity=2)}),
            "npc:10|spell:8613|bountifulHarvest:1": window(5, {"249427": item(5)}),
            "npc:10|spell:921": window(3, {"5000": item(3)}),
            "npc:14|spell:8613": window(3, {"2934": item(3)}),
            "npc:11": window(4, {"300": item(2), "289086": item(1)}, coins=3),
            "object:99|spell:3365": window(9, {"400": item(9)}),
        },
    })
    write(live / "1.60.1.70100", "creatures.json", {"creatures": {
        "10": {"name": "Old Name", "positions": [pos(1429, 0.101, 0.205), pos(1429, 0.105, 0.209)]},
        "14": {"name": "Skinned Cat", "positions": [pos(1431, 0.5, 0.5)]},
        "15": {"name": "Lonely Owl"},
    }})
    # Later the server hid 288842 (not public yet) and 288900 (no such item), and showed 289086 after hiding it.
    write(live / "1.60.1.70100", "item_hotfixes.enUS.json", {"items": {
        "288842": {"status": "valid"}, "289086": {"status": "invalid"},
    }})
    write(live / "1.60.1.70200", "item_hotfixes.enUS.json", {"items": {
        "288842": {"status": "invalid"}, "288900": {"status": "removed"}, "289086": {"status": "valid", "name": "Elixir"},
    }})
    write(live / "1.60.1.70200", "loot.json", {
        "meta": {"collectedOn": {"first": "2026-11-12", "last": "2026-11-14"}},
        "kills": {"npc:10": kills(6, empty=2, levels={"8": 6})},
        "sources": {"npc:10": window(4, {"100": item(2)}, coins=2, copper=100, copper_windows=2)},
    })
    write(live / "1.60.1.70200", "creatures.json", {"creatures": {
        "10": {"name": "Forest Thing", "positions": [pos(1429, 0.5, 0.5), pos(1430, 0.2, 0.2), {"uiMap": 0}]},
        # A player with a Korean client recorded these on the later build.
        "11": {"name": "숲 괴물"},
        "14": {"name": "얼룩 고양이"},
        "16": {"name": "부엉이"},
    }})
    write(root / "data" / "wow_classic_beta" / "1.60.1.70009", "loot.json", {
        "kills": {"npc:13": kills(5)}, "sources": {"npc:13": window(5, {"500": item(5)})},
    })
    git = ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@example.org"]
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(git + ["add", "."], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "data"], check=True)


def conversion(clone):
    imp = import_eglink.make_import(clone)
    mobs = imp["result"]["sources"]["eglink"]["mobs"]
    expect("solo mobs and skinned mobs only, beta left out", sorted(mobs), ["10", "11", "12", "14"])
    # Skinning: solo and group corpses alike, but not the ones skinned with Bountiful Harvest or other spells.
    expect("skinning without the perk adds up", mobs["10"]["skins"],
           {"skinned": 8, "items": {"2318": {"drops": 7, "qty": 7}, "783": {"drops": 1, "qty": 2}}})
    expect("a mob only skinned has no loot", (mobs["14"]["buckets"], mobs["14"]["skins"]["skinned"]), ({}, 3))
    expect("and is placed by its skinned corpses", (mobs["14"]["maps"], mobs["14"]["name"]), ({"1431": 3}, "Skinned Cat"))
    b = mobs["10"]["buckets"]["1"]
    expect("solo and quest corpses of both builds add up, group corpses don't", (b["kills"], b["opened"]), (20, 16))
    expect("empty corpses count", b["lootable"], 16)
    expect("quest items, hidden items, skinning and group loot stay out", sorted(b["items"]), ["100"])
    expect("drops and stack sizes add up", b["items"]["100"], {"drops": 8, "qty": 10})
    # 10 windows with coins, copper known for 6 of them with 500 copper: 10 drops of about 83 copper.
    expect("money follows the windows with one corpse", (b["money"]["drops"], b["money"]["copper"]), (10, 833))
    expect("levels span the builds", mobs["10"]["levels"], [5, 8])
    expect("the newest build's name wins", mobs["10"]["name"], "Forest Thing")
    expect("a Korean name doesn't replace the English one", mobs["14"]["name"], "Skinned Cat")
    expect("a mob with only a Korean name has none", mobs["11"]["name"], None)
    expect("every creature with a name is in names, with or without loot", imp["names"],
           {"10": "Forest Thing", "14": "Skinned Cat", "15": "Lonely Owl"})
    expect("kills split over the maps the deaths were seen on", mobs["10"]["maps"], {"1429": 15, "1430": 5})
    expect("spots on the addon's 50x50 grid, one per position",
           mobs["10"]["cells"], {"1429": {"260": 2, "1275": 1}, "1430": {"510": 1}})
    expect("a mob with no positions has no maps", (mobs["11"]["maps"], mobs["11"]["cells"]), ({}, {}))

    # npc 11: 4 kills, 2 empty, but 4 windows. Kills and corpses with loot double, so the share stays a half and
    # the item rate stays 2 drops per 4 windows times that half.
    b = mobs["11"]["buckets"]["1"]
    expect("more windows than corpses with loot scale the kills up", (b["kills"], b["lootable"], b["opened"]),
           (8, 4, 4))
    expect("coins without any known copper give no money", b["money"]["drops"], 0)
    expect("an item the newest hotfixes call valid stays", sorted(b["items"]), ["289086", "300"])
    expect("a mob that only ever left empty corpses still counts", mobs["12"]["buckets"]["1"]["kills"], 3)

    expect("the import is full, not partial", imp["partial"], False)
    expect("the source names the commit", "/tree/" in imp["source"]["url"], True)
    return imp


def resets(clone):
    """A mob whose loot a hotfix changed keeps only the builds that started recording on or after its day."""
    mobs = import_eglink.make_import(clone, {"10": "2026-11-12"})["result"]["sources"]["eglink"]["mobs"]
    b = mobs["10"]["buckets"]["1"]
    expect("only the build that started on the day counts", (b["kills"], b["lootable"], b["opened"]), (6, 4, 4))
    expect("a build that doesn't say when it started counts nothing of it, skinning too", "skins" in mobs["10"], False)
    expect("other mobs keep every build", mobs["11"]["buckets"]["1"]["kills"], 8)
    mobs = import_eglink.make_import(clone, {"10": "2026-11-13"})["result"]["sources"]["eglink"]["mobs"]
    expect("a build that started a day too early counts nothing of it", "10" in mobs, False)


def in_the_addon(imp):
    lua = build_data.lua_file(build_data.build([], [imp]))
    expect("Data.lua carries the CC BY credit",
           "-- Data from Efficient Games (https://efficient.games), licensed under CC BY 4.0" in lua, True)
    expect("Data.lua says what was changed", "Drop Tables changed it" in lua, True)
    client = Client("EgLink", data=lua)
    stats = client.ns.GetStats(11, "all")
    entry = next(e for e in stats.list.values() if e.itemId == 300)
    expect("the addon shows EG Link's own chance (share with loot times drops per window)", round(entry.rate, 2), 0.25)


def main():
    with tempfile.TemporaryDirectory() as folder:
        clone = pathlib.Path(folder)
        fake_clone(clone)
        in_the_addon(conversion(clone))
        resets(clone)
    report("EG Link import")


if __name__ == "__main__":
    main()
