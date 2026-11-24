"""Turns Everloot's public corpus into a Drop Tables import (data/imports/everloot.json).

Everloot (https://everloot.app) publishes what the players running its addon record on WoW Forever, one record per
observation, under CC BY-SA 4.0. Copying the corpus in bulk takes a free API key from an Everloot account.

What goes in:
- the loot windows of killed creatures (lootType "kill"), each install of the corpus as a source of its own;
- the items in them with their stack sizes, and money;
- the skinning windows (lootType "skinning"), each a skinned corpse, with the items and stack sizes skinning gave;
- names, levels and places from the NPC sightings of the same corpus. Mobs nobody saw that way, mostly in dungeons,
  where Everloot records no sightings, can get their English name from a names file (--names, npc id -> name, or
  QuestieDB's npc rows with a "name" field).

What stays out: quest items, gathering, fishing, disenchanting and containers, anything recorded before the live
servers opened, and what was recorded of a mob in data/loot-resets.json before the day a hotfix changed its loot. The corpus doesn't say who had the Bountiful Harvest perk, so its skinning counts the scarce Pristine
materials as they came.

The quest items are item class 12 in Everloot's item list, which it reads from the game client of the current build.
The import also writes them to data/quest-items.json, so tools/build_data.py leaves them out of every source.

A loot window is one opened corpse, but the corpus doesn't count kills or corpses that left nothing, and doesn't say
the group size. So the import is partial, like the Blackthornes one: its corpses go into the solo bucket and get kills
and empty corpses in the same proportion as the full sources of the mob. Money and stack sizes are its own.

Usage:
    python tools/import_everloot.py fetch DIR     downloads the corpus into DIR, with the key in EVERLOOT_API_KEY
    python tools/import_everloot.py DIR [--names FILE] [--root DIR]
"""
import calendar
import json
import math
import os
import pathlib
import sys
import time
import urllib.request

from build_data import load_resets

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORIGIN = "everloot"
API = "https://everloot.app/api"
PAGE = 5000  # rows per page with a key
GRID = 50  # DropTables/Places.lua
QUEST_CLASS = 12  # DropTables/Collector.lua
LAUNCH = "2026-11-04"  # the live servers opened that day; earlier records are from the beta
DATASETS = {"loot": "corpus/public?kinds=loot", "sightings": "corpus/public?kinds=npc_sighting", "items": "items"}
NOTICE = ("Data from Everloot (https://everloot.app), CC BY-SA 4.0. Drop Tables changed it: only the loot and\n"
          "skinning windows of creatures, without quest items, counted per install and turned into Drop Tables\n"
          "counts, with names, levels and places from the NPC sightings.")


def fetch(folder, key):
    """Every page of the three datasets, saved as they came: loot-00.json, sightings-00.json, items-00.json, ..."""
    folder.mkdir(parents=True, exist_ok=True)
    for name, path in DATASETS.items():
        url = "%s/%s%slimit=%d" % (API, path, "&" if "?" in path else "?", PAGE)
        page = 0
        while url:
            request = urllib.request.Request(url, headers={"Authorization": "Bearer " + key,
                                                           "User-Agent": "DropTables-import"})
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read()
            (folder / ("%s-%02d.json" % (name, page))).write_bytes(body)
            data = json.loads(body)
            url = data.get("next")
            page += 1
            time.sleep(1)
        print("%s: %d pages" % (name, page))


def pages(folder, name):
    return [json.loads(path.read_text(encoding="utf-8")) for path in sorted(folder.glob(name + "-*.json"))]


def rows(folder, name, field):
    return [row for page in pages(folder, name) for row in page[field]]


def origin_ids(installs):
    """A short id per install: everloot- and the start of its hash, longer when two would clash."""
    for length in range(8, 64):
        ids = {i: "%s-%s" % (ORIGIN, i.removeprefix("pub-")[:length]) for i in installs}
        if len(set(ids.values())) == len(ids):
            return ids
    raise ValueError("install ids clash")


def add_stack(into, field, amount):
    into["drops"] += 1
    into[field] += amount
    into["min"] = amount if into["min"] is None else min(into["min"], amount)
    into["max"] = amount if into["max"] is None else max(into["max"], amount)


def recorded_early(rec, npc, resets):
    """True for a record from before the live servers opened, or from before the day a hotfix changed the mob's loot."""
    return rec["capturedAt"] < max(LAUNCH, (resets or {}).get(str(npc), LAUNCH))


def tally(loot, quest_items, resets=None):
    """(install, npc) -> {opened, items, money} from the kill windows."""
    counts = {}
    for rec in loot:
        npc = rec.get("sourceNpcId")
        if rec.get("lootType") != "kill" or not isinstance(npc, int) or recorded_early(rec, npc, resets):
            continue
        t = counts.setdefault((rec["installId"], npc), {"opened": 0, "items": {}, "money": None})
        t["opened"] += 1
        stacks = {}
        for item in rec["items"]:
            if item["itemId"] not in quest_items:
                stacks[item["itemId"]] = stacks.get(item["itemId"], 0) + item.get("count", 1)
        for item, amount in stacks.items():
            add_stack(t["items"].setdefault(str(item), {"drops": 0, "qty": 0, "min": None, "max": None}), "qty", amount)
        if rec.get("copper", 0) > 0:
            if t["money"] is None:
                t["money"] = {"drops": 0, "copper": 0, "min": None, "max": None}
            add_stack(t["money"], "copper", rec["copper"])
    return counts


def tally_skins(loot, quest_items, resets=None):
    """(install, npc) -> {skinned, items} from the skinning windows. Every one is a skinned corpse, whoever killed it."""
    counts = {}
    for rec in loot:
        npc = rec.get("sourceNpcId")
        if rec.get("lootType") != "skinning" or not isinstance(npc, int) or recorded_early(rec, npc, resets):
            continue
        t = counts.setdefault((rec["installId"], npc), {"skinned": 0, "items": {}})
        t["skinned"] += 1
        stacks = {}
        for item in rec["items"]:
            if item["itemId"] not in quest_items:
                stacks[item["itemId"]] = stacks.get(item["itemId"], 0) + item.get("count", 1)
        for item, amount in stacks.items():
            add_stack(t["items"].setdefault(str(item), {"drops": 0, "qty": 0, "min": None, "max": None}), "qty", amount)
    return counts


def english_installs(sightings):
    """Installs whose names are English. Sightings carry the names of the player's client language, so an install
    counts as English when at least 90% of its names match the ones most English installs agree on. It starts from
    every install and drops the ones that don't fit until nothing changes."""
    names = {}
    for rec in sightings:
        if rec.get("name"):
            names.setdefault(rec["npcId"], {}).setdefault(rec["name"], set()).add(rec["installId"])
    kept = {i for by_name in names.values() for ids in by_name.values() for i in ids}
    while True:
        agreed = {}
        for npc, by_name in names.items():
            votes = {name: len(ids & kept) for name, ids in by_name.items()}
            name, count = max(votes.items(), key=lambda kv: (kv[1], kv[0]))
            if count >= 2:
                agreed[npc] = name
        rate = {}
        for npc, name in agreed.items():
            for seen_as, ids in names[npc].items():
                for i in ids:
                    total, same = rate.get(i, (0, 0))
                    rate[i] = (total + 1, same + (seen_as == name))
        now = {i for i, (total, same) in rate.items() if total >= 5 and same >= 0.9 * total}
        if now == kept:
            return kept
        kept = now


def about(sightings):
    """npc -> {name, levels, maps, cells}: the most common English name, the level range, and sightings per map and
    cell."""
    english = english_installs(sightings)
    seen = {}
    for rec in sightings:
        if rec["capturedAt"] < LAUNCH:
            continue
        s = seen.setdefault(rec["npcId"], {"names": {}, "levels": [], "maps": {}, "cells": {}})
        if rec.get("name") and rec["installId"] in english:
            s["names"][rec["name"]] = s["names"].get(rec["name"], 0) + 1
        if isinstance(rec.get("level"), int) and rec["level"] > 0:
            s["levels"].append(rec["level"])
        ui_map = rec.get("mapId")
        if not ui_map:
            continue
        key = str(ui_map)
        s["maps"][key] = s["maps"].get(key, 0) + 1
        x, y = rec.get("x"), rec.get("y")
        if x is not None and y is not None and 0 < x < 100 and 0 < y < 100:
            cell = str(math.floor(x / 100 * GRID) * GRID + math.floor(y / 100 * GRID))
            cells = s["cells"].setdefault(key, {})
            cells[cell] = cells.get(cell, 0) + 1
    out = {}
    for npc, s in seen.items():
        name = sorted(s["names"].items(), key=lambda kv: (-kv[1], kv[0]))[0][0] if s["names"] else None
        levels = [min(s["levels"]), max(s["levels"])] if s["levels"] else None
        out[npc] = {"name": name, "levels": levels, "maps": s["maps"], "cells": s["cells"]}
    return out


def places(info, opened):
    """The install's corpses spread over the maps and cells where the mob was seen."""
    if not info or not info["maps"]:
        return {}, {}
    seen = sum(info["maps"].values())
    maps = {m: max(1, round(opened * n / seen)) for m, n in info["maps"].items()}
    spotted = sum(sum(c.values()) for c in info["cells"].values())
    cells = {m: {c: round(opened * n / spotted, 3) for c, n in cs.items()} for m, cs in info["cells"].items()}
    return maps, cells


def convert(counts, sightings, names=None, skins=None):
    skins = skins or {}
    ids = origin_ids({install for install, _npc in set(counts) | set(skins)})
    sources = {}
    for install, npc in sorted(set(counts) | set(skins)):
        info = sightings.get(npc)
        t, s = counts.get((install, npc)), skins.get((install, npc))
        maps, cells = places(info, t["opened"] if t else s["skinned"])
        buckets = {}
        if t:
            money = t["money"] or {"drops": 0, "copper": 0, "min": None, "max": None}
            buckets["1"] = {"kills": t["opened"], "lootable": t["opened"], "opened": t["opened"], "money": money,
                            "items": dict(sorted(t["items"].items(), key=lambda kv: int(kv[0])))}
        mobs = sources.setdefault(ids[install], {"mobs": {}})["mobs"]
        name = (info and info["name"]) or (names or {}).get(str(npc))
        mobs[str(npc)] = {"buckets": buckets, "cells": cells, "levels": info and info["levels"], "maps": maps,
                          "name": name}
        if s:
            mobs[str(npc)]["skins"] = {"skinned": s["skinned"],
                                       "items": dict(sorted(s["items"].items(), key=lambda kv: int(kv[0])))}
    return sources


def unix(stamp):
    return calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))


def read_names(path):
    """npc id -> name from a names file: plain {npc: name}, QuestieDB's npc rows ({"npcs": {npc: {"name": ...}}}), or
    data/shared.json, whose mobs keep the names they were given before."""
    rows = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    rows = rows.get("npcs") or rows.get("mobs") or rows
    names = {}
    for npc, row in rows.items():
        name = row.get("name") if isinstance(row, dict) else row
        if name:
            names[npc] = name
    return names


def make_import(folder, names=None, resets=None):
    loot_pages = pages(folder, "loot")
    loot = [rec for page in loot_pages for rec in page["records"]]
    quest = quest_items(folder)
    sources = convert(tally(loot, quest, resets), about(rows(folder, "sightings", "records")), names,
                      tally_skins(loot, quest, resets))
    as_of = loot_pages[0]["dataAsOf"]
    return {
        "index": 3, "issue": 0, "partial": True, "own": ["money", "qty"], "received": unix(as_of),
        "submitter": "import:" + ORIGIN,
        "result": {"exporter": ORIGIN, "part": 1, "parts": 1, "sources": sources},
        "source": {"name": "Everloot's public corpus, recorded by players on WoW Forever",
                   "copyright": "Everloot contributors, https://everloot.app", "license": "CC BY-SA 4.0",
                   "url": "https://everloot.app/database", "notice": NOTICE, "dataAsOf": as_of},
    }


def quest_list(folder):
    page = pages(folder, "items")[0]
    items = sorted(quest_items(folder))
    return {"build": page["gameData"]["build"], "items": items,
            "about": "Item class 12 (quest items) of the WoW Forever client, from Everloot's item list "
                     "(https://everloot.app/api/items). Game data, Blizzard Entertainment."}


def quest_items(folder):
    return {i["itemId"] for i in rows(folder, "items", "items") if (i.get("class") or {}).get("id") == QUEST_CLASS}


def main(argv):
    if len(argv) >= 3 and argv[1] == "fetch":
        key = os.environ.get("EVERLOOT_API_KEY")
        if not key:
            print("EVERLOOT_API_KEY is not set")
            return 2
        fetch(pathlib.Path(argv[2]), key)
        return 0
    if len(argv) < 2:
        print("\n".join(line.strip() for line in __doc__.strip().splitlines()[-2:]))
        return 2
    root = pathlib.Path(argv[argv.index("--root") + 1]) if "--root" in argv else ROOT
    folder = pathlib.Path(argv[1])
    names = read_names(argv[argv.index("--names") + 1]) if "--names" in argv else None
    imp = make_import(folder, names, load_resets(root))
    quest = root / "data" / "quest-items.json"
    quest.write_text(json.dumps(quest_list(folder), indent=1) + "\n", encoding="utf-8", newline="\n")
    target = root / "data" / "imports" / (ORIGIN + ".json")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(imp, sort_keys=True, indent=1, ensure_ascii=False) + "\n", encoding="utf-8",
                      newline="\n")
    sources = imp["result"]["sources"]
    npcs = {npc for s in sources.values() for npc in s["mobs"]}
    mobs = [m for s in sources.values() for m in s["mobs"].values()]
    opened = sum(m["buckets"]["1"]["opened"] for m in mobs if m["buckets"])
    skinned = sum(m["skins"]["skinned"] for m in mobs if m.get("skins"))
    print("%d installs, %d mobs, %d opened and %d skinned corpses -> %s" % (len(sources), len(npcs), opened, skinned,
                                                                          target))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
