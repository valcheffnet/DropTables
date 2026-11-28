# Drop Tables shared data

This folder holds the drop counts that Drop Tables players send in. A bot rebuilds it a few minutes after every
accepted share, and the same data ships as the Forever Drop Tables Data addon (`DropTables_Data/`), which goes to
CurseForge every day it changes.

- `shared.json` is the merged database: https://raw.githubusercontent.com/valcheffnet/DropTables/main/data/shared.json
- `submissions/` keeps every accepted export as it came in, so the database can be rebuilt when the merge rules
  change. Its format is internal and can change at any time.
- `imports/` holds counts that didn't come from a Drop Tables export, already turned into the submission format.
  There are three so far, see "Imported counts" below. The EG Link and Everloot ones are refreshed every morning
  at 04:00 UTC by the "Refresh imported counts" workflow, which rebuilds the database afterwards.
- `quest-items.json` lists the quest items of the game client, which the merge leaves out of every source.

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
| `from` | the installs that went into this mob, keyed by a random install id, with how many kills each had: a number when they were all solo kills, otherwise the kills of each group size, keyed like `buckets`, so the addon can tell an install's new group kills from its old solo ones. An import is listed under its `id` from `imports`, with its looted corpses, except Everloot, whose installs are listed one by one as `everloot-` and the start of their install id |
| `buckets` | the counts, split by group size: `"1"` solo, `"2"` to `"5"` a party of that size, `"6"` a raid. Empty for a mob only skinned |
| `skins` | what skinning its corpses gave, missing when nobody skinned it: `skinned` (skinned corpses), `items` like a bucket's, and `from` with the skinned corpses of each install. The group plays no part in skinning, so it has no buckets |

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

Skinning gives something every time, so its chance is just the share of skinned corpses:

    chance = skins.items[item].drops / skins.skinned

## What the merge does to the counts

The numbers are not plain sums of everything sent in:

- When an install has more than 300 kills of a mob, its counts are scaled down to 300, so one player can't outweigh
  everyone else. That's why the kills in `from` can add up to more than the kills in the buckets.
- Installs whose counts don't fit the rest (far too many empty corpses, or an item rate far from what the bigger
  installs saw) are left out of that mob.
- Each install's counts for a mob go in once, from the most complete version sent.
- Counts are rounded to whole numbers.
- Quest items and character names are never in it.
- A mob's `name` is the one most sources gave. Names in other scripts, like the Korean ones a player with a Korean
  client sends, are left out one by one. When most of a player's names differ from what everyone else calls the same
  mobs, the player's client is in another language (German, say), and all of their names are left out. A mob no
  source names takes the name from an import's `names` list (EG Link's), or else keeps the name it had before.
- An install's kill spots weigh like its counts, at most 300 kills' worth, and only the player's own spots come
  in. Counts that other players passed on in the game carry none.
- Skinning follows the same rules with skinned corpses in place of kills: at most 300 per install, and an install
  far off the rest is left out of the mob's skinning. Pristine Leather, Pristine Hide and Pristine Scale are never
  held against an install, because the Bountiful Harvest perk gives up to twice as many of them to some players.

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
EG Link doesn't say the group size and counts too many empty corpses there. Quest items, pick pocket, nodes, chests,
fishing and containers stay out as well. Names and kill spots come from `creatures.json`, where EG Link keeps one
spot per 5 yards, so each spot counts once. The newest build's name is taken, unless it isn't in Latin letters: some
builds carry the names of a player with a Korean client. The import also lists the name of every creature there under
`names`, the ones it has no loot of too, so the merge can name a mob only Everloot knows.

Skinning comes from the keys with one of the four Skinning ranks (`npc:<id>|spell:8613` and so on), solo and group
alike, since the group plays no part in what a skinned corpse gives. EG Link marks the corpses skinned with the
Bountiful Harvest perk (`|bountifulHarvest:<rank>`), and those stay out, so the Pristine materials come out at the
chance a player without the perk sees.

EG Link counts loot windows, and a corpse the game said nothing about can still be opened, so some mobs have more
windows than corpses with loot. EG Link works out its chances as the share of corpses with loot times drops per
window, the same way Drop Tables does. The windows become opened corpses, and where there are more of them than
corpses with loot, the kills and the corpses with loot are scaled up together until they match. The share of empty
corpses and the drop rates stay as EG Link has them, give or take the rounding to whole kills.

Unlike the Blackthornes import, this one has kills, empty corpses, money and stack sizes of its own, so it counts
like a player who sent an export: at most 300 kills of a mob, and left out of a mob when its counts don't fit the
rest.

`imports/everloot.json` comes from Everloot's public corpus (https://everloot.app/database), which Everloot publishes
under CC BY-SA 4.0 from what the players running its addon record on WoW Forever. Copying it in bulk takes a free API
key from an Everloot account:

    EVERLOOT_API_KEY=... python tools/import_everloot.py fetch everloot-corpus
    python tools/import_everloot.py everloot-corpus --names data/shared.json
    python tools/build_data.py

The daily workflow reads the key from the repository secret `EVERLOOT_API_KEY`.

The corpus has a record for every loot window. The import takes the windows of killed creatures from the day the
live servers opened, and each Everloot install becomes a source of its own, so the 300 kill cap and the checks for
counts that don't fit work per install, as they do for players who send exports. The skinning windows go in as
each install's skinning. Gathering, fishing, disenchanting and containers stay out, and so do quest items. The corpus
doesn't say who had the Bountiful Harvest perk, so its Pristine materials count as they came.

A loot window is an opened corpse, but the corpus doesn't count kills, corpses that left nothing, or group sizes. So
the import is partial like the Blackthornes one: its corpses go into the solo bucket and get kills and empty corpses
in the same proportion as the full sources of the mob, or count as kills with loot where there's no full source.
Money and stack sizes are its own, since Everloot records the copper and the stacks of every window.

Names, levels and kill spots come from the NPC sightings in the same corpus. A sighting carries the name in the
language of the player's client, so names only come from installs whose names match the English ones most installs
agree on. Its place is where the player stood, and an install's corpses of a mob are spread over the cells where the
mob was seen. Everloot records no sightings in dungeons, so the first import gave the mobs nobody saw the English
name QuestieDB has for their npc id, as the Blackthornes import does, and they have no level or place. Each refresh
keeps the names `shared.json` already has, and a new mob nobody saw stays nameless until a player's export or a
sighting names it.

`quest-items.json` lists the item ids of class 12, the quest items, from Everloot's item list of the current game
client. `import_everloot.py` writes it, and `build_data.py` leaves those items out of every source, because the
addon never records them and an import can't always tell them apart.

## Shrinking and backups

A build stops before it writes or deletes anything when the new database would have less than 98% of the mobs,
kills, skinned corpses or mob and item pairs that `shared.json` has now. No share or refresh takes that much away, so
a drop like that means a bug or a source that lost its data. To shrink it on purpose, for example when a source is
taken out, run `python tools/build_data.py --allow-shrink`, or start the workflow by hand with "allow_shrink" ticked.

Before the bot commits a build that changed something, it uploads this folder as it was before the build to a
Cloudflare R2 bucket (`tools/backup_data.py`). It keeps the newest 10 backups and the newest one of each day for 30
days.

## Changes to the format

New fields can appear. Existing ones won't be renamed or removed without a note in CHANGELOG.md first.
