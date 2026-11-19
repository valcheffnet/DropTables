# Drop Tables shared data

This folder holds the drop counts that Drop Tables players send in. A bot rebuilds it a few minutes after every
accepted share, and the same data ships inside the addon as `DropTables/Data.lua`.

- `shared.json` is the merged database: https://raw.githubusercontent.com/valcheffnet/DropTables/main/data/shared.json
- `submissions/` keeps every accepted export as it came in, so the database can be rebuilt when the merge rules
  change. Its format is internal and can change at any time.

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

One mob:

| Field | Meaning |
|---|---|
| `name` | the name most installs saw |
| `minLevel`, `maxLevel` | lowest and highest level seen, missing when no level was read |
| `maps` | kills per map, keyed by uiMapID. Kills recorded without a map aren't in it, so it can add up to less than the kills |
| `from` | the installs that went into this mob, keyed by a random install id, with how many kills each had |
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
- Quest items, kill spots and character names are never in it.

## Changes to the format

New fields can appear. Existing ones won't be renamed or removed without a note in CHANGELOG.md first.
