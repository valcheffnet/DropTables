# Drop Tables shared data

This folder holds the drop counts that Drop Tables players send in. A bot rebuilds it a few minutes after every
accepted share, and the same data ships inside the addon as `DropTables/Data.lua`.

- `shared.json` is the merged database: https://raw.githubusercontent.com/valcheffnet/DropTables/main/data/shared.json
- `submissions/` keeps every accepted export as it came in, so the database can be rebuilt when the merge rules
  change. Its format is internal and can change at any time.
- `imports/` holds counts that didn't come from a Drop Tables export, already turned into the submission format.
  There is one so far, see "Imported counts" below.

## License

CC BY-SA 4.0 (see [LICENSE-DATA](../LICENSE-DATA)). Credit it as "Drop Tables contributors,
https://github.com/valcheffnet/DropTables" and share what you build from it under the same license.

## shared.json

Top level:

| Field | Meaning |
|---|---|
| `mobs` | the mobs, keyed by npc id (as a string) |
| `built` | unix time of the newest submission in it |
| `submissions` | how many submissions it was built from |
| `license`, `attribution` | the license and the credit line above |
| `imports` | where each import came from: `id` (its key in `from`), `name`, `url`, `license`, `copyright` and `notice`, the license text that has to stay with the data |

One mob:

| Field | Meaning |
|---|---|
| `name` | the name most installs saw |
| `minLevel`, `maxLevel` | lowest and highest level seen, missing when no level was read |
| `maps` | kills per map, keyed by uiMapID. Kills recorded without a map aren't in it, so it can add up to less than the kills |
| `spots` | where on each map the mob was killed: per uiMapID, kills per grid cell, at most the 40 busiest cells. The map is cut into a 50 x 50 grid, and cell `c` is column `floor(c / 50)` and row `c % 50` from the top left, so its centre is at `x = (floor(c / 50) + 0.5) / 50`, `y = (c % 50 + 0.5) / 50`. Missing when nothing tells where |
| `from` | the installs that went into this mob, keyed by a random install id, with how many kills each had. An import is listed under its `id` from `imports`, with its looted corpses |
| `buckets` | the counts, split by group size: `"1"` solo, `"2"` to `"5"` a party of that size, `"6"` a raid |

One bucket:

| Field | Meaning |
|---|---|
| `kills` | kills |
| `lootable` | kills whose corpse had loot for the player |
| `opened` | corpses the player opened |
| `items` | per item id: `drops` (corpses it dropped from), `qty` (total quantity), `min` and `max` (smallest and largest stack). Counts recorded before stack sizes were kept have no `min` and `max` |
| `money` | the same for money, with `copper` instead of `qty` |

## Getting a drop chance

The addon's chance is the share of kills that left loot times the share of opened corpses that had the item:

    chance = lootable / kills * drops / opened

Bleeding Horror (npc 1529) solo, for example, has 39 kills, 37 lootable and 36 opened, and Linen Cloth (2589) dropped
from 9 of them, so 37 / 39 * 9 / 36 comes to about 24%. To merge group sizes, add up the buckets first and then
divide.

## What the merge does to the counts

The numbers are not plain sums of everything sent in:

- When an install has more than 300 kills of a mob, its counts are scaled down to 300, so one player can't outweigh
  everyone else. That's why the kills in `from` can add up to more than the kills in the buckets.
- Installs whose counts don't fit the rest (far too many empty corpses, or an item rate far from what the bigger
  installs saw) are left out of that mob.
- Each install's counts for a mob go in once, from the most complete version sent.
- Counts are rounded to whole numbers.
- Quest items and character names are never in it.
- An install's kill spots weigh like its counts, at most 300 kills' worth, and only the player's own spots come
  in. Counts that other players passed on in the game carry none.

## Imported counts

`imports/blackthornes-mit.json` comes from Blackthornes Farmer, from the last version of its harvest that was under
the MIT license (commit 43bc5ee, 20 October 2026, counted on the WoW Forever beta). It has 4,052 looted corpses of
305 mobs. The copyright and license notice is in [LICENSE-DATA](../LICENSE-DATA).

The source kept mob names, places and drop counts per spot. The import keeps npc ids, item ids, levels, the corpses
per map and, as `spots`, where on the map each spot was. Spots inside dungeons are left out, because the source's
coordinates there aren't on a map the addon knows. Each mob's name is the English one QuestieDB has for its npc id, like the name a Drop Tables export
carries. The import leaves out:

- quest items, which Drop Tables doesn't record;
- leather, hides and Deviate scales, because the source counted what skinning gave as loot;
- fishing, and five mob names that fit two npc ids equally well.

The source counted looted corpses and what was in them, but not kills, empty corpses, money or stack sizes, and not
group sizes. Its corpses go into the solo bucket. Where players sent counts of the same mob, the imported corpses get
kills, empty corpses, money and stack sizes in the same proportion as the players' counts, so the import changes
the item chances and nothing else. Where it's the only source, every corpse counts as a kill with loot, there's no
money, and every drop is a stack of one.

`imports/eglink.json` comes from EG Link output (https://github.com/JIVESCORP/eg-link-output-wowf), which Efficient
Games publishes under CC BY 4.0 from what the players running their EG Link addon record on WoW Forever. Its credit
line and what was changed are in [LICENSE-DATA](../LICENSE-DATA). `tools/import_eglink.py` makes it from a clone of
that repository:

    git clone --depth 1 https://github.com/JIVESCORP/eg-link-output-wowf.git
    python tools/import_eglink.py eg-link-output-wowf
    python tools/build_data.py

EG Link keeps a folder per client build with only what was recorded on that build, so the import adds up the
builds of the live servers (`data/wowf/`) and leaves the beta out. From `loot.json` it takes the corpses looted solo,
including the ones tied to a quest, and puts them in the solo bucket. Corpses looted in a group stay out, because
EG Link doesn't say the group size and counts too many empty corpses there. Quest items, skinning, pick pocket,
nodes, chests, fishing and containers stay out as well. Names and kill spots come from `creatures.json`, where
EG Link keeps one spot per 5 yards, so each spot counts once.

EG Link counts loot windows, and a corpse the game said nothing about can still be opened, so some mobs have more
windows than corpses with loot. EG Link works out its chances as the share of corpses with loot times drops per
window, the same way Drop Tables does. The windows become opened corpses, and where there are more of them than
corpses with loot, the kills and the corpses with loot are scaled up together until they match. The share of empty
corpses and the drop rates stay as EG Link has them, give or take the rounding to whole kills.

Unlike the Blackthornes import, this one has kills, empty corpses, money and stack sizes of its own, so it counts
like a player who sent an export: at most 300 kills of a mob, and left out of a mob when its counts don't fit the
rest.

## Changes to the format

New fields can appear. Existing ones won't be renamed or removed without a note in CHANGELOG.md first.
