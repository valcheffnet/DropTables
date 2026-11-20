"""Turns the loot counts of EG Link output into a Drop Tables import (data/imports/eglink.json).

EG Link output (https://github.com/JIVESCORP/eg-link-output-wowf) is open data from Efficient Games, recorded on
WoW Forever by the players who run their EG Link addon, under CC BY 4.0. Each live build has a folder,
data/wowf/<build>/, holding only what was recorded on that build, so the builds add up.

What goes in:
- corpses looted solo (npc:<id>, and npc:<id>|quest for creatures tied to one of the player's quests), as bucket 1;
- kills, empty corpses, opened corpses, items with their stack sizes, and money;
- levels, the English name, and the kill spots of creatures.json.

What stays out: corpses looted in a group (EG Link doesn't say the group size, and counts too many empty corpses
there), quest items, skinning and pick pocket (npc:<id>|spell:<id>), nodes, chests, fishing and containers, and the
beta servers.

EG Link counts loot windows rather than opened corpses, and corpses the game said nothing about (unknown) can be
opened too, so a mob can have more windows than corpses with loot. Its own chances treat the windows as a sample:
share of corpses with loot times drops per window. Drop Tables works the chances out the same way, so the windows go
in as opened corpses, and where they outnumber the corpses with loot, kills and corpses with loot are scaled up
together until they match. That keeps the share of empty corpses and every drop rate as EG Link has them.

Usage:
    python tools/import_eglink.py PATH_TO_EG_LINK_CLONE [--root DIR]
"""
import json
import math
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORIGIN = "eglink"
PRODUCT = "wowf"
GRID = 50  # DropTables/Places.lua
REPO_URL = "https://github.com/JIVESCORP/eg-link-output-wowf"
NOTICE = ("Data from Efficient Games (https://efficient.games), licensed under CC BY 4.0\n"
          "(https://creativecommons.org/licenses/by/4.0/). Drop Tables changed it: only corpses looted solo on the\n"
          "live servers, without quest items, summed over the builds and turned into Drop Tables counts.")


def round_half_up(value):
    return int(math.floor(value + 0.5))


def corpse_key(key):
    """The npc id of a solo corpse key, or None for anything else."""
    parts = key.split("|")
    if not parts[0].startswith("npc:") or any(p != "quest" for p in parts[1:]):
        return None
    npc = parts[0][4:]
    return npc if npc.isdigit() else None


def new_tally():
    return {"deaths": 0, "empty": 0, "unknown": 0, "windows": 0, "coins": 0, "copper": 0, "copperWindows": 0,
            "items": {}, "levels": {}}


def add_build(tallies, loot):
    for key, kills in loot.get("kills", {}).items():
        npc = corpse_key(key)
        if npc is None:
            continue
        t = tallies.setdefault(npc, new_tally())
        for field in ("deaths", "empty", "unknown"):
            t[field] += kills.get(field, 0)
        for level, count in kills.get("levels", {}).items():
            t["levels"][level] = t["levels"].get(level, 0) + count
    for key, source in loot.get("sources", {}).items():
        npc = corpse_key(key)
        if npc is None:
            continue
        t = tallies.setdefault(npc, new_tally())
        for field in ("windows", "coins", "copper", "copperWindows"):
            t[field] += source.get(field, 0)
        for item, entry in source.get("items", {}).items():
            if entry.get("quest"):
                continue
            into = t["items"].setdefault(item, {"drops": 0, "qty": 0})
            into["drops"] += entry.get("drops", 0)
            into["qty"] += entry.get("quantity", 0)


def add_creatures(info, creatures):
    """Names and death spots. A later build's name replaces an earlier one."""
    for npc, record in creatures.get("creatures", {}).items():
        into = info.setdefault(npc, {"name": None, "positions": []})
        if record.get("name"):
            into["name"] = record["name"]
        into["positions"].extend(record.get("positions", []))


def bucket(t):
    kills = t["deaths"] - t["unknown"]
    lootable = kills - t["empty"]
    opened = t["windows"]
    if opened > lootable:
        if lootable > 0:
            kills = round_half_up(kills * opened / lootable)
        else:
            kills += opened
        lootable = opened
    items = {}
    for item, entry in sorted(t["items"].items(), key=lambda kv: int(kv[0])):
        drops = min(entry["drops"], opened)
        if drops > 0:
            items[item] = {"drops": drops, "qty": max(drops, entry["qty"])}
    money = {"copper": 0, "drops": 0, "max": None, "min": None}
    # Copper is only known for windows with one corpse in them; the coins count every window with money.
    coins = min(t["coins"], opened)
    if coins > 0 and t["copperWindows"] > 0:
        money["drops"] = coins
        money["copper"] = round_half_up(t["copper"] * coins / t["copperWindows"])
    return {"items": items, "kills": kills, "lootable": lootable, "money": money, "opened": opened}


def places(positions, kills):
    """maps (kills per map, split by where the deaths were seen) and cells (spots per map)."""
    per_map, cells = {}, {}
    for pos in positions:
        ui_map = pos.get("uiMap")
        if not ui_map:
            continue
        key = str(ui_map)
        per_map[key] = per_map.get(key, 0) + 1
        x, y = pos.get("mapX"), pos.get("mapY")
        if x is not None and y is not None and 0 < x < 1 and 0 < y < 1:
            cell = str(math.floor(x * GRID) * GRID + math.floor(y * GRID))
            spots = cells.setdefault(key, {})
            spots[cell] = spots.get(cell, 0) + 1
    seen = sum(per_map.values())
    maps = {m: max(1, round_half_up(kills * n / seen)) for m, n in per_map.items()} if seen else {}
    return maps, cells


def convert(tallies, info):
    mobs = {}
    for npc in sorted(tallies, key=int):
        t = tallies[npc]
        data = bucket(t)
        if data["kills"] <= 0:
            continue
        levels = [int(level) for level, count in t["levels"].items() if count > 0 and level.isdigit()]
        about = info.get(npc, {"name": None, "positions": []})
        maps, cells = places(about["positions"], data["kills"])
        mobs[npc] = {"buckets": {"1": data}, "cells": cells, "levels": [min(levels), max(levels)] if levels else None,
                     "maps": maps, "name": about["name"]}
    return mobs


def read(clone):
    tallies, info, builds = {}, {}, []
    product = clone / "data" / PRODUCT
    for folder in sorted(p for p in product.iterdir() if p.is_dir()):
        loot = folder / "loot.json"
        creatures = folder / "creatures.json"
        if loot.exists():
            add_build(tallies, json.loads(loot.read_text(encoding="utf-8")))
            builds.append(folder.name)
        if creatures.exists():
            add_creatures(info, json.loads(creatures.read_text(encoding="utf-8")))
    return tallies, info, builds


def commit_of(clone):
    out = subprocess.run(["git", "-C", str(clone), "log", "-1", "--format=%H %ct"], capture_output=True, text=True,
                         check=True)
    sha, when = out.stdout.split()
    return sha, int(when)


def make_import(clone):
    tallies, info, builds = read(clone)
    sha, when = commit_of(clone)
    mobs = convert(tallies, info)
    return {
        "index": 2, "issue": 0, "partial": False, "received": when, "submitter": "import:" + ORIGIN,
        "result": {"exporter": ORIGIN, "part": 1, "parts": 1, "sources": {ORIGIN: {"mobs": mobs}}},
        "source": {"name": "EG Link output, recorded by players on WoW Forever",
                   "copyright": "Efficient Games, https://efficient.games", "license": "CC BY 4.0",
                   "url": "%s/tree/%s/data/%s" % (REPO_URL, sha, PRODUCT), "notice": NOTICE,
                   "builds": "%s to %s" % (builds[0], builds[-1]) if builds else ""},
    }


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1].strip())
        return 2
    clone = pathlib.Path(argv[1])
    root = pathlib.Path(argv[argv.index("--root") + 1]) if "--root" in argv else ROOT
    imp = make_import(clone)
    target = root / "data" / "imports" / (ORIGIN + ".json")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(imp, sort_keys=True, indent=1, ensure_ascii=False) + "\n", encoding="utf-8",
                      newline="\n")
    mobs = imp["result"]["sources"][ORIGIN]["mobs"]
    opened = sum(m["buckets"]["1"]["opened"] for m in mobs.values())
    print("%d mobs, %d opened corpses -> %s" % (len(mobs), opened, target))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
