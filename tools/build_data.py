"""Merges the accepted submissions (data/submissions/*.json) and the imports (data/imports/*.json) into the shared
database.

Writes data/shared.json and DropTables/Data.lua, which the addon loads as one more source of counts.
The same input always gives the same output, so a rebuild without new submissions changes nothing.

An import marked partial counts looted corpses and the items in them, but not kills or empty corpses, and unless its
"own" list names them, not money or stack sizes either. Its corpses get what's missing in the same proportion as the
full sources of the mob, so it moves the item chances and nothing else.

Items in data/quest-items.json (item class 12 of the game client, which the addon never records) are left out of
every source, since an import can't always tell them apart.

Mobs in data/loot-resets.json had their loot changed by a hotfix, so what was recorded of them before the day named
there is left out (see after_reset). The EG Link and Everloot imports leave those records out themselves, by their
dates.

Usage:
    python tools/build_data.py [--root DIR]
"""
import calendar
import json
import math
import pathlib
import sys
import time

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
# Creatures that aren't mobs: engineers' Target Dummy, Advanced Target Dummy and Masterwork Target Dummy. Looting
# one's own dummy gives back what it was made of.
NOT_MOBS = frozenset({"2673", "2674", "12426"})
# Pristine Leather, Pristine Hide and Pristine Scale, as SCARCE_SKINS in DropTables/Stats.lua.
SCARCE_SKINS = frozenset({"249427", "249428", "249429"})


def mob_kills(mob):
    return sum(b["kills"] for b in mob["buckets"].values())


def complete_buckets(mob):
    """Buckets with kills. A bucket made only of item records (no counts record) is left out, as the addon does."""
    return {b: data for b, data in mob["buckets"].items() if data["kills"] > 0}


def without(buckets, quest_items):
    if not quest_items:
        return buckets
    return {b: dict(data, items={i: e for i, e in data["items"].items() if int(i) not in quest_items})
            for b, data in buckets.items()}


def versions(submissions, quest_items=frozenset()):
    """(origin, npc) -> list of versions, each {kills, exporter, submitter, issue, mob}."""
    found = {}
    for sub in submissions:
        result = sub["result"]
        for origin, source in result["sources"].items():
            for npc, mob in source["mobs"].items():
                if npc in NOT_MOBS:
                    continue
                buckets = without(complete_buckets(mob), quest_items)
                if not buckets:
                    continue
                mob = dict(mob, buckets=buckets)
                found.setdefault((origin, npc), []).append(dict(
                    dated(sub), kills=mob_kills(mob), exporter=result["exporter"], submitter=sub["submitter"],
                    issue=sub["issue"], mob=mob, partial=bool(sub.get("partial")), own=frozenset(sub.get("own") or ()),
                ))
    return found


def dated(sub):
    """When a version was received, and the last day its source recorded anything, when the source says so."""
    return {"received": sub["received"], "until": (sub.get("source") or {}).get("collectedUntil"),
            "imported": sub["submitter"].startswith("import:")}


def since_time(day):
    return calendar.timegm(time.strptime(day, "%Y-%m-%d"))


def minus_mob(mob, base):
    """What an install recorded of a mob after base, an earlier version of the same install: the counts of every
    bucket less the earlier ones, kept in order (drops <= opened <= lootable <= kills). None when nothing is left."""
    buckets = {}
    for b, data in mob["buckets"].items():
        old = base["buckets"].get(b)
        if old is None:
            buckets[b] = data
            continue
        kills = data["kills"] - old["kills"]
        if kills <= 0:
            continue
        lootable = max(0, min(kills, data["lootable"] - old["lootable"]))
        opened = max(0, min(lootable, data["opened"] - old["opened"]))
        money = dict(data["money"])
        money["drops"] = max(0, min(opened, data["money"]["drops"] - old["money"]["drops"]))
        money["copper"] = max(0, data["money"]["copper"] - old["money"]["copper"]) if money["drops"] else 0
        items = {}
        for item, entry in data["items"].items():
            before = old["items"].get(item, {"drops": 0, "qty": 0})
            drops = max(0, min(opened, entry["drops"] - before["drops"]))
            if drops:
                items[item] = dict(entry, drops=drops, qty=max(drops, entry["qty"] - before["qty"]))
        buckets[b] = {"kills": kills, "lootable": lootable, "opened": opened, "money": money, "items": items}
    if not buckets:
        return None
    maps = {m: k - (base.get("maps") or {}).get(m, 0) for m, k in (mob.get("maps") or {}).items()}
    cells = {}
    for m, spots in (mob.get("cells") or {}).items():
        older = (base.get("cells") or {}).get(m, {})
        left = {c: k - older.get(c, 0) for c, k in spots.items() if k - older.get(c, 0) > 0}
        if left:
            cells[m] = left
    return dict(mob, buckets=buckets, maps={m: k for m, k in maps.items() if k > 0}, cells=cells)


def minus_loot(v, base):
    mob = minus_mob(v["mob"], base["mob"])
    return mob and dict(v, mob=mob, kills=mob_kills(mob), total=v["kills"])


def minus_skins(v, base):
    skinned = v["skins"]["skinned"] - base["skins"]["skinned"]
    if skinned <= 0:
        return None
    items = {}
    for item, entry in v["skins"]["items"].items():
        before = base["skins"]["items"].get(item, {"drops": 0, "qty": 0})
        drops = max(0, min(skinned, entry["drops"] - before["drops"]))
        if drops:
            items[item] = dict(entry, drops=drops, qty=max(drops, entry["qty"] - before["qty"]))
    return dict(v, kills=skinned, skins=dict(v["skins"], skinned=skinned, items=items), total=v["kills"])


def after_reset(candidates, since, minus):
    """The versions of one install's mob with only what was recorded on or after since, the day a hotfix changed the
    mob's loot, and how many of the install's kills were left out.

    An import that says it stopped recording before that day goes. The other imports stay as they are, since they
    leave the older records out themselves. A player's export has no time for each kill, only the time it was
    received, so the install's last version from before that day becomes the base and later versions count only what
    they have beyond it. With no version from before, the first one after it is the base, as it may hold kills from
    before the hotfix too."""
    imports = [v for v in candidates if v["imported"] and (v["until"] is None or v["until"] >= since)]
    players = [v for v in candidates if not v["imported"]]
    start = since_time(since)
    before = [v for v in players if v["received"] < start]
    after = sorted((v for v in players if v["received"] >= start), key=lambda v: (v["received"], v["issue"]))
    if before:
        base, rest = latest_best(before), after
    elif after:
        base, rest = after[0], after[1:]
    else:
        return imports, 0
    later = [d for d in (minus(v, base) for v in rest) if d]
    return imports + later, base["kills"]


def apply_resets(found, resets, minus):
    """found with after_reset applied to the mobs in resets, and npc -> {origin: kills left out}."""
    if not resets:
        return found, {}
    out, left_out = {}, {}
    for (origin, npc), candidates in found.items():
        if npc not in resets:
            out[(origin, npc)] = candidates
            continue
        kept, kills = after_reset(candidates, resets[npc], minus)
        if kills:
            left_out.setdefault(npc, {})[origin] = kills
        if kept:
            out[(origin, npc)] = kept
    return out, left_out


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
        # The installs of an import come from a source checked by hand, not from a player's export.
        if origin in confirmed or submitter.startswith("import:"):
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


def item_outliers(sums, moneyless=frozenset(), unchecked=frozenset()):
    """usedFor in the addon. With enough big installs, one whose share of an item is far off their median doesn't fit,
    and when none of them fits for an item, nobody gets blamed for it. Partial sources without money of their own are
    left out of the money comparison, and the items in unchecked aren't compared at all."""
    keys = set()
    for s in sums.values():
        keys.update(s["entries"])
    out = set()
    for key in sorted(keys - unchecked):
        big = {o: s for o, s in sums.items() if s["opened"] >= BIG_SOURCE and not (key == "money" and o in moneyless)}
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


def completed(data, full, own=frozenset()):
    """A partial bucket with kills, empty corpses, money and stack sizes in the same proportion as the full sources,
    except for the money and stack sizes that own says the source counted itself. Without any full source to follow,
    every corpse counts as a kill with loot, and nothing as money."""
    opened = data["opened"]
    out = {"opened": opened, "kills": opened, "lootable": opened, "money": {"drops": 0.0, "copper": 0.0}, "items": {}}
    if full["opened"] > 0:
        out["kills"] = opened * full["kills"] / full["opened"]
        out["lootable"] = opened * full["lootable"] / full["opened"]
        money = opened * full["money"] / full["opened"]
        out["money"] = {"drops": money, "copper": money * full["copper"] / full["money"] if full["money"] else 0.0}
    if "money" in own:
        out["money"] = data["money"]
    for item, entry in data["items"].items():
        drops = entry["drops"]
        if "qty" in own:
            out["items"][item] = entry
            continue
        known = full["drops"].get(item, 0)
        out["items"][item] = {"drops": drops, "qty": drops * full["qty"][item] / known if known else drops}
    return out


def shared_mob(chosen):
    """chosen: origin -> version. Returns the shared record of the mob, or None when no install is left."""
    sums = {origin: scaled_sum(v["mob"]) for origin, v in chosen.items()}
    partial = frozenset(o for o, v in chosen.items() if v["partial"])
    moneyless = frozenset(o for o in partial if "money" not in chosen[o]["own"])
    out = empty_kill_outliers({o: s for o, s in sums.items() if o not in partial})
    out |= item_outliers({o: s for o, s in sums.items() if o not in out}, moneyless)
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
                data = completed(data, full, v["own"])
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
    record = {"buckets": buckets, "from": {o: v.get("total", v["kills"]) for o, v in kept.items()}, "maps": {}}
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


def covered(older, newer, resets=None):
    """True when the newer submission comes from the same exporter and has every install and mob of the older one
    with at least as many kills and opened corpses, so the older one can't change the database any more. One that
    holds a mob of resets from before its day stays, as the base later versions are counted from."""
    if older["result"]["exporter"] != newer["result"]["exporter"]:
        return False
    for origin, source in older["result"]["sources"].items():
        later = newer["result"]["sources"].get(origin)
        for npc, mob in source["mobs"].items():
            if npc in (resets or {}) and older["received"] < since_time(resets[npc]):
                return False
            other = later and later["mobs"].get(npc)
            if not other:
                return False
            for bucket, data in mob["buckets"].items():
                again = other["buckets"].get(bucket)
                if not again or again["kills"] < data["kills"] or again["opened"] < data["opened"]:
                    return False
            skinned = (mob.get("skins") or {}).get("skinned", 0)
            if skinned and (other.get("skins") or {}).get("skinned", 0) < skinned:
                return False
    return True


def superseded(submissions, resets=None):
    """Submissions a later one covers. A player who sends everything each time ends up leaving only the last."""
    ordered = sorted(submissions, key=lambda s: (s["issue"], s["index"]))
    return [old for i, old in enumerate(ordered) if any(covered(old, new, resets) for new in ordered[i + 1:])]


def skin_versions(submissions, quest_items=frozenset()):
    """(origin, npc) -> list of versions of an install's skinning, shaped like versions() with the skinned corpses as
    its kills, so choose() picks between them the same way."""
    found = {}
    for sub in submissions:
        result = sub["result"]
        for origin, source in result["sources"].items():
            for npc, mob in source["mobs"].items():
                skins = mob.get("skins")
                if npc in NOT_MOBS or not skins or not skins.get("skinned"):
                    continue
                items = {i: e for i, e in skins["items"].items() if int(i) not in quest_items}
                found.setdefault((origin, npc), []).append(dict(
                    dated(sub), kills=skins["skinned"], exporter=result["exporter"], submitter=sub["submitter"],
                    issue=sub["issue"], mob=mob, skins=dict(skins, items=items),
                ))
    return found


def shared_skins(chosen):
    """What skinning a mob gives, merged from chosen (origin -> skin version) like loot: each install at most PEER_CAP
    skinned corpses, and a big one whose share of an item doesn't fit the others left out, except for the scarce
    materials, which the Bountiful Harvest perk changes from one player to the next. None when nothing is left."""
    sums = {}
    for origin, v in chosen.items():
        skinned = v["skins"]["skinned"]
        factor = PEER_CAP / skinned if skinned > PEER_CAP else 1
        sums[origin] = {"opened": skinned * factor,
                        "entries": {i: e["drops"] * factor for i, e in v["skins"]["items"].items()}}
    out = item_outliers(sums, unchecked=SCARCE_SKINS)
    kept = {o: v for o, v in chosen.items() if o not in out}
    skinned, items = 0.0, {}
    for origin, v in kept.items():
        factor = sums[origin]["opened"] / v["skins"]["skinned"]
        skinned += sums[origin]["opened"]
        for item, entry in v["skins"]["items"].items():
            into = items.setdefault(item, {"drops": 0.0, "qty": 0.0})
            into["drops"] += entry["drops"] * factor
            into["qty"] += entry["qty"] * factor
            merge_range(into, entry.get("min"), entry.get("max"))
    result = {"skinned": round_half_up(skinned), "items": {},
              "from": {o: v.get("total", v["skins"]["skinned"]) for o, v in kept.items()}}
    if result["skinned"] == 0:
        return None
    for item, entry in items.items():
        drops = round_half_up(entry["drops"])
        if drops > 0:
            out_item = {"drops": drops, "qty": max(drops, round_half_up(entry["qty"]))}
            if "min" in entry:
                out_item["min"], out_item["max"] = entry["min"], entry["max"]
            result["items"][item] = out_item
    return result


def skin_only_record(chosen):
    """The record of a mob nobody sent loot of, only skinning: its name, levels and maps from the same versions."""
    record = {"buckets": {}, "from": {}, "maps": {}}
    levels = [v["mob"]["levels"] for v in chosen.values() if v["mob"].get("levels") and v["mob"]["levels"][0]]
    if levels:
        record["minLevel"] = min(low for low, _ in levels)
        record["maxLevel"] = max(high for _, high in levels)
    names = {}
    for v in chosen.values():
        for map_id, kills in (v["mob"].get("maps") or {}).items():
            record["maps"][map_id] = record["maps"].get(map_id, 0) + kills
        if v["mob"].get("name"):
            names[v["mob"]["name"]] = names.get(v["mob"]["name"], 0) + 1
    if names:
        record["name"] = sorted(names.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
    return record


def build(submissions, imports=(), quest_items=frozenset(), resets=None):
    """The shared database: {"built": time, "submissions": n, "mobs": {npc: record}}, plus "imports" with the source
    and license of each import that went in. resets: npc -> the day a hotfix changed its loot."""
    everything = list(submissions) + list(imports)
    found = versions(everything, quest_items)
    skin_found = skin_versions(everything, quest_items)
    either = {key: list(candidates) for key, candidates in found.items()}
    for key, candidates in skin_found.items():
        either.setdefault(key, []).extend(candidates)
    cut = unconfirmed_cut(either)
    found, left_out = apply_resets(found, resets, minus_loot)
    skin_found, skins_left_out = apply_resets(skin_found, resets, minus_skins)
    by_npc, skins_by_npc = {}, {}
    for into, versions_found in ((by_npc, found), (skins_by_npc, skin_found)):
        for (origin, npc), candidates in versions_found.items():
            if origin not in cut:
                into.setdefault(npc, {})[origin] = choose(origin, candidates)
    mobs = {}
    for npc in set(by_npc) | set(skins_by_npc):
        record = shared_mob(by_npc[npc]) if npc in by_npc else None
        skins = shared_skins(skins_by_npc[npc]) if npc in skins_by_npc else None
        if skins:
            record = record or skin_only_record(skins_by_npc[npc])
            record["skins"] = skins
        if record:
            # The kills left out still count as known, so the addon doesn't add them back from the same install
            # (newShare in DropTables/Stats.lua) and /dt export doesn't send them again.
            for origin, kills in left_out.get(npc, {}).items():
                if origin not in cut and record["buckets"]:
                    record["from"][origin] = max(record["from"].get(origin, 0), kills)
            for origin, kills in skins_left_out.get(npc, {}).items():
                if origin not in cut and record.get("skins"):
                    record["skins"]["from"][origin] = max(record["skins"]["from"].get(origin, 0), kills)
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


def load_quest_items(root):
    path = root / "data" / "quest-items.json"
    return frozenset(json.loads(path.read_text(encoding="utf-8"))["items"]) if path.exists() else frozenset()


def load_resets(root):
    """npc -> the day from which its loot counts, from data/loot-resets.json."""
    path = root / "data" / "loot-resets.json"
    if not path.exists():
        return {}
    return {npc: entry["since"] for npc, entry in json.loads(path.read_text(encoding="utf-8"))["mobs"].items()}


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
    resets = load_resets(root)
    for old in superseded(submissions, resets):
        (root / "data" / "submissions" / ("%d-%d.json" % (old["issue"], old["index"]))).unlink()
        submissions.remove(old)
    imports = load_imports(root)
    database = build(submissions, imports, load_quest_items(root), resets)
    changed = write_outputs(root, database)
    print("%d submissions, %d imports, %d mobs%s" % (database["submissions"], len(imports), len(database["mobs"]),
                                                     "" if changed else ", nothing changed"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
