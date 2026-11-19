"""Merges the accepted submissions (data/submissions/*.json) and the imports (data/imports/*.json) into the shared
database.

Writes data/shared.json and DropTables/Data.lua, which the addon loads as one more source of counts.
The same input always gives the same output, so a rebuild without new submissions changes nothing.

An import marked partial counts looted corpses and the items in them, but not kills, empty corpses, money or stack
sizes. Its corpses get those in the same proportion as the players' own counts of the mob, so it moves the item
chances and nothing else.

Usage:
    python tools/build_data.py [--root DIR]
"""
import json
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The same limits as DropTables/Stats.lua.
PEER_CAP = 300
BIG_SOURCE = 30
MIN_BIG_SOURCES = 3
OUTLIER_Z = 3
# How many installs one submitter may bring that only one exporter ever sent and that never exported themselves.
UNCONFIRMED_CAP = 50
CHUNK = 500  # mobs per Lua function, far below the constant limit of one Lua 5.1 function
MAX_SPOTS = 40  # kill spots kept per map of a mob, the busiest, as MAX_CELLS in DropTables/Places.lua


def mob_kills(mob):
    return sum(b["kills"] for b in mob["buckets"].values())


def complete_buckets(mob):
    """Buckets with kills. A bucket made only of item records (no counts record) is left out, as the addon does."""
    return {b: data for b, data in mob["buckets"].items() if data["kills"] > 0}


def versions(submissions):
    """(origin, npc) -> list of versions, each {kills, exporter, submitter, issue, mob}."""
    found = {}
    for sub in submissions:
        result = sub["result"]
        for origin, source in result["sources"].items():
            for npc, mob in source["mobs"].items():
                buckets = complete_buckets(mob)
                if not buckets:
                    continue
                mob = dict(mob, buckets=buckets)
                found.setdefault((origin, npc), []).append({
                    "kills": mob_kills(mob), "exporter": result["exporter"], "submitter": sub["submitter"],
                    "issue": sub["issue"], "mob": mob, "partial": bool(sub.get("partial")),
                })
    return found


def latest_best(candidates):
    """The version with the most kills. On a tie it takes the one with more opened corpses, since a corpse can be
    opened after its kill was counted, and after that the latest issue."""
    return max(candidates, key=lambda v: (v["kills"], sum(b["opened"] for b in v["mob"]["buckets"].values()),
                                          v["issue"]))


def choose(origin, candidates):
    """The install's own export wins. A copy someone else relayed counts when the install never exported itself, and
    a relayed copy with more kills than the install's own export only wins when two exporters report that much."""
    own = [v for v in candidates if v["exporter"] == origin]
    relayed = [v for v in candidates if v["exporter"] != origin]
    if not own:
        return latest_best(relayed)
    best = latest_best(own)
    by_exporter = {}
    for v in relayed:
        if v["exporter"] not in by_exporter or v["kills"] > by_exporter[v["exporter"]]["kills"]:
            by_exporter[v["exporter"]] = v
    tops = sorted(by_exporter.values(), key=lambda v: (-v["kills"], v["issue"]))
    if len(tops) >= 2 and tops[1]["kills"] > best["kills"]:
        return tops[1]
    return best


def unconfirmed_cut(found):
    """As far as anyone can tell, origins that only one exporter reported and that never exported themselves are
    fake install ids. Each submitter can bring at most UNCONFIRMED_CAP of them, the earliest first."""
    # An origin confirmed for one mob is confirmed for all of them.
    confirmed, first_seen = set(), {}
    for (origin, _npc), candidates in found.items():
        exporters = {v["exporter"] for v in candidates}
        if origin in exporters or len(exporters) > 1:
            confirmed.add(origin)
        for v in candidates:
            seen = first_seen.get(origin)
            if seen is None or v["issue"] < seen[0]:
                first_seen[origin] = (v["issue"], v["submitter"])
    per_submitter, cut = {}, set()
    for origin, (_issue, submitter) in sorted(first_seen.items(), key=lambda kv: (kv[1][0], kv[0])):
        if origin in confirmed:
            continue
        count = per_submitter.get(submitter, 0) + 1
        per_submitter[submitter] = count
        if count > UNCONFIRMED_CAP:
            cut.add(origin)
    return cut


def scaled_sum(mob):
    """One install's counts over all buckets, scaled down to PEER_CAP kills."""
    kills = mob_kills(mob)
    factor = PEER_CAP / kills if kills > PEER_CAP else 1
    total = {"kills": 0.0, "lootable": 0.0, "opened": 0.0, "entries": {}}
    for data in mob["buckets"].values():
        total["kills"] += data["kills"] * factor
        total["lootable"] += data["lootable"] * factor
        total["opened"] += data["opened"] * factor
        if data["money"]["drops"] > 0:
            total["entries"]["money"] = total["entries"].get("money", 0) + data["money"]["drops"] * factor
        for item, entry in data["items"].items():
            total["entries"][item] = total["entries"].get(item, 0) + entry["drops"] * factor
    return total


def z_score(seen1, n1, seen2, n2):
    p1, p2 = seen1 / n1, seen2 / n2
    pooled = (seen1 + seen2) / (n1 + n2)
    se = math.sqrt(pooled * (1 - pooled) * (1 / n1 + 1 / n2))
    if se == 0:
        return 0 if p1 == p2 else math.inf
    return abs(p1 - p2) / se


def empty_kill_outliers(sums):
    """lootableSources in the addon. The install whose share of lootable corpses is furthest from the rest goes, one
    at a time."""
    used = dict(sums)
    out = set()
    while True:
        kills = sum(s["kills"] for s in used.values())
        lootable = sum(s["lootable"] for s in used.values())
        worst, worst_z = None, OUTLIER_Z
        for origin, s in sorted(used.items()):
            rest = kills - s["kills"]
            if s["kills"] >= BIG_SOURCE and rest > 0:
                z = z_score(s["lootable"], s["kills"], lootable - s["lootable"], rest)
                if z > worst_z:
                    worst, worst_z = origin, z
        if worst is None:
            return out
        out.add(worst)
        del used[worst]


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def plausible(seen, opened, p):
    z2 = OUTLIER_Z * OUTLIER_Z
    center = (seen + z2 / (2 * opened)) / (1 + z2 / opened)
    half = OUTLIER_Z * math.sqrt(seen * (1 - seen) / opened + z2 / (4 * opened * opened)) / (1 + z2 / opened)
    return abs(p - center) <= half + 1e-9


def item_outliers(sums, partial=frozenset()):
    """usedFor in the addon. With enough big installs, one whose share of an item is far off their median doesn't fit,
    and when none of them fits for an item, nobody gets blamed for it. Partial sources have no money count, so they
    are left out of the money comparison."""
    keys = set()
    for s in sums.values():
        keys.update(s["entries"])
    out = set()
    for key in sorted(keys):
        big = {o: s for o, s in sums.items() if s["opened"] >= BIG_SOURCE and not (key == "money" and o in partial)}
        if len(big) < MIN_BIG_SOURCES:
            continue
        shares = {o: min(1, s["entries"].get(key, 0) / s["opened"]) for o, s in big.items()}
        middle = median(list(shares.values()))
        failing = {o for o, share in shares.items() if not plausible(share, big[o]["opened"], middle)}
        if len(failing) < len(big):
            out |= failing
    return out


def round_half_up(value):
    return int(math.floor(value + 0.5))


def merge_range(into, low, high):
    if low is not None and high is not None:
        into["min"] = low if into.get("min") is None else min(into["min"], low)
        into["max"] = high if into.get("max") is None else max(into["max"], high)


def full_totals(kept):
    """The scaled counts of the full sources over all buckets, which a partial source's missing counts follow."""
    total = {"kills": 0.0, "lootable": 0.0, "opened": 0.0, "money": 0.0, "copper": 0.0, "drops": {}, "qty": {}}
    for v in kept.values():
        if v["partial"]:
            continue
        factor = PEER_CAP / v["kills"] if v["kills"] > PEER_CAP else 1
        for data in v["mob"]["buckets"].values():
            for key in ("kills", "lootable", "opened"):
                total[key] += data[key] * factor
            total["money"] += data["money"]["drops"] * factor
            total["copper"] += data["money"]["copper"] * factor
            for item, entry in data["items"].items():
                total["drops"][item] = total["drops"].get(item, 0) + entry["drops"] * factor
                total["qty"][item] = total["qty"].get(item, 0) + entry["qty"] * factor
    return total


def completed(data, full):
    """A partial bucket with kills, empty corpses, money and stack sizes in the same proportion as the full sources.
    Without any full source to follow, every corpse counts as a kill with loot, and nothing as money."""
    opened = data["opened"]
    out = {"opened": opened, "kills": opened, "lootable": opened, "money": {"drops": 0.0, "copper": 0.0}, "items": {}}
    if full["opened"] > 0:
        out["kills"] = opened * full["kills"] / full["opened"]
        out["lootable"] = opened * full["lootable"] / full["opened"]
        money = opened * full["money"] / full["opened"]
        out["money"] = {"drops": money, "copper": money * full["copper"] / full["money"] if full["money"] else 0.0}
    for item, entry in data["items"].items():
        drops = entry["drops"]
        known = full["drops"].get(item, 0)
        out["items"][item] = {"drops": drops, "qty": drops * full["qty"][item] / known if known else drops}
    return out


def shared_mob(chosen):
    """chosen: origin -> version. Returns the shared record of the mob, or None when no install is left."""
    sums = {origin: scaled_sum(v["mob"]) for origin, v in chosen.items()}
    partial = frozenset(o for o, v in chosen.items() if v["partial"])
    out = empty_kill_outliers({o: s for o, s in sums.items() if o not in partial})
    out |= item_outliers({o: s for o, s in sums.items() if o not in out}, partial)
    kept = {o: v for o, v in chosen.items() if o not in out}
    if not kept:
        return None
    full = full_totals(kept)
    raw = {}
    for origin, v in kept.items():
        mob = v["mob"]
        kills = v["kills"]
        factor = PEER_CAP / kills if kills > PEER_CAP else 1
        for bucket, data in mob["buckets"].items():
            if v["partial"]:
                data = completed(data, full)
            into = raw.setdefault(bucket, {"kills": 0.0, "lootable": 0.0, "opened": 0.0,
                                           "money": {"drops": 0.0, "copper": 0.0}, "items": {}})
            into["kills"] += data["kills"] * factor
            into["lootable"] += data["lootable"] * factor
            into["opened"] += data["opened"] * factor
            money = data["money"]
            into["money"]["drops"] += money["drops"] * factor
            into["money"]["copper"] += money["copper"] * factor
            merge_range(into["money"], money.get("min"), money.get("max"))
            for item, entry in data["items"].items():
                target = into["items"].setdefault(item, {"drops": 0.0, "qty": 0.0})
                target["drops"] += entry["drops"] * factor
                target["qty"] += entry["qty"] * factor
                merge_range(target, entry.get("min"), entry.get("max"))
    buckets = {}
    for bucket, data in raw.items():
        # Rounding keeps the order of the sums, so opened <= lootable <= kills and drops <= opened still hold.
        result = {"kills": round_half_up(data["kills"]), "lootable": round_half_up(data["lootable"]),
                  "opened": round_half_up(data["opened"]), "items": {}}
        if result["kills"] == 0:
            continue
        money = {"drops": round_half_up(data["money"]["drops"]), "copper": round_half_up(data["money"]["copper"])}
        if money["drops"] == 0:
            money["copper"] = 0
        elif "min" in data["money"]:
            money["min"], money["max"] = data["money"]["min"], data["money"]["max"]
        result["money"] = money
        for item, entry in data["items"].items():
            drops = round_half_up(entry["drops"])
            if drops == 0:
                continue
            item_out = {"drops": drops, "qty": max(drops, round_half_up(entry["qty"]))}
            if "min" in entry:
                item_out["min"], item_out["max"] = entry["min"], entry["max"]
            result["items"][item] = item_out
        buckets[bucket] = result
    if not buckets:
        return None
    record = {"buckets": buckets, "from": {o: v["kills"] for o, v in kept.items()}, "maps": {}}
    levels = [v["mob"]["levels"] for v in kept.values() if v["mob"].get("levels") and v["mob"]["levels"][0]]
    if levels:
        record["minLevel"] = min(low for low, _ in levels)
        record["maxLevel"] = max(high for _, high in levels)
    # Spots weigh like counts: one install brings at most PEER_CAP kills' worth, so it can't make its own spots the
    # busiest ones by claiming huge numbers.
    spots = {}
    for v in kept.values():
        factor = PEER_CAP / v["kills"] if v["kills"] > PEER_CAP else 1
        for map_id, kills in v["mob"]["maps"].items():
            record["maps"][map_id] = record["maps"].get(map_id, 0) + kills
        for map_id, cells in (v["mob"].get("cells") or {}).items():
            into = spots.setdefault(map_id, {})
            for cell, kills in cells.items():
                into[cell] = into.get(cell, 0) + kills * factor
    for map_id, cells in sorted(spots.items()):
        rounded = {cell: round_half_up(kills) for cell, kills in cells.items()}
        busiest = sorted(((c, k) for c, k in rounded.items() if k > 0), key=lambda kv: (-kv[1], int(kv[0])))
        if busiest:
            record.setdefault("spots", {})[map_id] = dict(busiest[:MAX_SPOTS])
    names = {}
    for v in kept.values():
        name = v["mob"].get("name")
        if name:
            names[name] = names.get(name, 0) + 1
    if names:
        record["name"] = sorted(names.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
    return record


def covered(older, newer):
    """True when the newer submission comes from the same exporter and has every install and mob of the older one
    with at least as many kills and opened corpses, so the older one can't change the database any more."""
    if older["result"]["exporter"] != newer["result"]["exporter"]:
        return False
    for origin, source in older["result"]["sources"].items():
        later = newer["result"]["sources"].get(origin)
        for npc, mob in source["mobs"].items():
            other = later and later["mobs"].get(npc)
            if not other:
                return False
            for bucket, data in mob["buckets"].items():
                again = other["buckets"].get(bucket)
                if not again or again["kills"] < data["kills"] or again["opened"] < data["opened"]:
                    return False
    return True


def superseded(submissions):
    """Submissions a later one covers. A player who sends everything each time ends up leaving only the last."""
    ordered = sorted(submissions, key=lambda s: (s["issue"], s["index"]))
    return [old for i, old in enumerate(ordered) if any(covered(old, new) for new in ordered[i + 1:])]


def build(submissions, imports=()):
    """The shared database: {"built": time, "submissions": n, "mobs": {npc: record}}, plus "imports" with the source
    and license of each import that went in."""
    found = versions(list(submissions) + list(imports))
    cut = unconfirmed_cut(found)
    by_npc = {}
    for (origin, npc), candidates in found.items():
        if origin not in cut:
            by_npc.setdefault(npc, {})[origin] = choose(origin, candidates)
    mobs = {}
    for npc, chosen in by_npc.items():
        record = shared_mob(chosen)
        if record:
            mobs[npc] = record
    built = max((s["received"] for s in submissions), default=0)
    database = {"built": built, "submissions": len(submissions), "mobs": mobs, "license": "CC-BY-SA-4.0",
                "attribution": "Drop Tables contributors, https://github.com/valcheffnet/DropTables"}
    if imports:
        database["imports"] = sorted((dict(imp["source"], id=imp["result"]["exporter"]) for imp in imports),
                                     key=lambda s: s["id"])
    return database


def lua_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_value(value, string_keys=False):
    """Lua constructor for value. Keys made of digits become numbers (npc, bucket, item and map ids), except with
    string_keys, because install ids are hex text even when they happen to be all digits."""
    if isinstance(value, dict):
        def numeric(k):
            return not string_keys and str(k).isdigit()

        parts = []
        for key in sorted(value, key=lambda k: (0, int(k), "") if numeric(k) else (1, 0, str(k))):
            if numeric(key):
                lua_key = "[%s]" % int(key)
            elif str(key).isidentifier():
                lua_key = str(key)
            else:
                lua_key = "[%s]" % lua_string(str(key))
            parts.append("%s=%s" % (lua_key, lua_value(value[key], key == "from")))
        return "{" + ",".join(parts) + "}"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return lua_string(value)
    raise TypeError("no Lua form for %r" % (value,))


def lua_file(database):
    lines = [
        "local _, ns = ...",
        "",
        "-- The shared database: counts from every /dt export merged on GitHub (tools/build_data.py). Generated, do",
        "-- not edit; the issue workflow rebuilds it after each accepted submission.",
        "-- The data is under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/), credited to the Drop",
        "-- Tables contributors, https://github.com/valcheffnet/DropTables (see LICENSE-DATA there).",
    ]
    # The release ships this folder alone, so each import's own notice has to travel inside this file.
    for imp in database.get("imports", []):
        lines.append("--")
        lines.append("-- It includes %s, %s, under the %s license: %s." % (
            imp["name"], imp["copyright"], imp["license"], imp["url"]))
        if imp.get("notice"):
            lines.append("--")
            lines.extend(("-- " + line).rstrip() for line in imp["notice"].splitlines())
    lines.append("ns.SharedBuilt = %d" % database["built"])
    npcs = sorted(database["mobs"], key=int)
    for start in range(0, len(npcs), CHUNK):
        lines.append("ns.AddSharedData(function() return {")
        for npc in npcs[start:start + CHUNK]:
            lines.append("[%d]=%s," % (int(npc), lua_value(database["mobs"][npc])))
        lines.append("} end)")
    return "\n".join(lines) + "\n"


def load_submissions(root, folder="submissions"):
    folder = root / "data" / folder
    subs = [json.loads(path.read_text(encoding="utf-8")) for path in folder.glob("*.json")]
    return sorted(subs, key=lambda s: (s["issue"], s["index"]))


def load_imports(root):
    return load_submissions(root, "imports")


def write_outputs(root, database):
    """Writes both files and returns True when either one changed."""
    targets = {
        root / "data" / "shared.json": json.dumps(database, sort_keys=True, indent=1, ensure_ascii=False) + "\n",
        root / "DropTables" / "Data.lua": lua_file(database),
    }
    changed = False
    for path, text in targets.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        old = path.read_text(encoding="utf-8") if path.exists() else None
        if old != text:
            path.write_text(text, encoding="utf-8", newline="\n")
            changed = True
    return changed


def main(argv):
    root = pathlib.Path(argv[argv.index("--root") + 1]) if "--root" in argv else ROOT
    submissions = load_submissions(root)
    for old in superseded(submissions):
        (root / "data" / "submissions" / ("%d-%d.json" % (old["issue"], old["index"]))).unlink()
        submissions.remove(old)
    imports = load_imports(root)
    database = build(submissions, imports)
    changed = write_outputs(root, database)
    print("%d submissions, %d imports, %d mobs%s" % (database["submissions"], len(imports), len(database["mobs"]),
                                                     "" if changed else ", nothing changed"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
