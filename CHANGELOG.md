# Changelog

## [Unreleased]

### Changed

- The addon is called Forever Drop Tables now, in the addon list and on its windows, so it's clear which game it's for. The folder is still DropTables, so your recorded drops stay where they are, and /dt works as before.

### Fixed

- A game client in another language sent its mob names along with its counts, so an export from a German client carried German names. Only an English client sends names now. A name another player's addon sent is still shown, but it no longer goes out with your counts.

## [0.6.3] - 2026-11-25

### Added

- Drop Tables now records loot in dungeons and raids. The game hides which mob you killed there, but a loot window still says whose corpse it belongs to, so every corpse you loot counts as a kill that left loot. Corpses that leave nothing can't be seen at all, so the chances of dungeon mobs come out a little high, and their drop table says "Dungeon: per looted corpse". Since the target doesn't work in dungeons, the drop table window with Follow target on switches to each corpse you loot instead.

### Changed

- Two more shares and the daily refresh of the EG Link and Everloot counts went into the shared database, which now knows 2,176 mobs, with 41,034 kills and 7,867 skinned corpses.

### Fixed

- With the Loot Finder open, the game hitched every second. The game's item cache lets go of items while the Finder reads through two thousand of them, and the Finder kept asking for the ones it had let go. Drop Tables now keeps what it has read about an item until you log out.
- The bar under Kills in the drop table window, which splits the kills between you, other players and the shared database, was drawn in a single colour.
- After a settings change, the Loot Finder's back button went to All items instead of the category you came from, Skinning for example.
- Restore defaults moved the windows around while it put the settings back.
- Mobs you had only skinned lost their names at login.
- A mob someone else finished off, a guard for example, counted as your kill but didn't show up on the map.
- Gold per hour stayed the same when Drop Tables learned a mob's level.

## [0.6.2] - 2026-11-24

### Changed

- The latest EG Link and Everloot counts went into the shared database, which now knows 2,128 mobs, with 39,295 kills and 7,575 skinned corpses.

### Fixed

- The shared database kept the Ridgeshade Lurker corpses from before the hotfix of November 6 that fixed their loot, which threw off their chances. For a mob whose loot a hotfix changed, it now counts only what was recorded from the day after the hotfix, starting with Ridgeshade Lurker.

## [0.6.1] - 2026-11-24

### Fixed

- Minor fixes.

## [0.6.0] - 2026-11-24

### Added

- A seventh colour theme, Classic, takes the colours of the game's own windows: gold titles on near black, with red lines. It's the first square in the Loot Finder's title bar and the default for new installs and after Restore defaults. If you already use Drop Tables, your theme stays as it is until you click the Classic square.
- The mob tooltip shows the mob's gold per hour at the right end of its level line, worked out the same way as the g/ph column of the Loot Finder, and each item's price before its chance. Amounts of a gold or more drop the copper there and get a ~, so 1g 35s 55c reads ~1g 36s.
- The drop table window shows the mob's gold per hour to the right of the All, Solo and Group tabs.

### Changed

- Waylaid Crates count as world drops on every mob, like random gear and recipes, so they go into the world drops section of the drop table instead of the icons under the target.
- One more player's share and the daily refresh of the EG Link and Everloot counts went into the shared database, which now knows 2,115 mobs, with 38,969 kills and 7,546 skinned corpses.

### Fixed

- Quest items no longer show up in drop tables or in the Loot Finder. Drop Tables never recorded them, but the shared database had some that the imported data didn't mark as quest items, Arnak's Hoof among them.
- The share card under the Loot Finder's item list cut its second line short. It now wraps to two lines.

## [0.5.4] - 2026-11-22

### Fixed

- An open Loot Finder or drop table window could make the game stutter about once a second. A few items in the shared database can't be loaded by the game, and each failed try made the window redraw and ask for them again. Those were 23 items that EG Link recorded on Mottled Boars in an early build and that the server doesn't show, and they're out of the shared database now. The Loot Finder also worked every chance and price out again whenever the game loaded any item, the gear of players around you included, and now it does that only for the items it was waiting for.

## [0.5.3] - 2026-11-22

### Added

- The addon's version is shown in game: /dt status starts with it, and the options panel has it next to the name, so a bug report can say which version it was.
- The Loot Finder's search finds mobs too, by name or id. They show up in a Mobs category under the items, with their level, zone, g/ph and kills, and clicking one opens its drop table. When only mobs match, the Finder goes straight to them, so `/dt find kobold` works as well.

### Changed

- One more player's share went into the shared database, which now knows 1,845 mobs, with 34,609 kills and 7,108 skinned corpses.

## [0.5.2] - 2026-11-21

### Added

- g/ph also reads auction prices from FojjiCore's own scan of the auction house. Auctionator still comes first, so FojjiCore's price counts when Auctionator hasn't seen the item in the last 21 days, and a FojjiCore scan older than that is left out too. TradeSkillMaster comes after both.

### Changed

- The drop table window's item tooltip no longer adds a g/ph price line of its own, and the Loot Finder's mob tooltip doesn't repeat what a kill and an hour bring either, since the Price and g/ph columns already show that. The item tooltip now has only the prices Auctionator or FojjiCore put there.

## [0.5.1] - 2026-11-20

### Added

- A "Share with other players" option, on by default. With it off, Drop Tables leaves its hidden channel and stops swapping counts in game, with your group too, so nothing goes out and nothing comes in. Counts you already got from others stay, and /dt export and the shared database work as before. Turning it back on joins the channel again right away, without a /reload.

## [0.5.0] - 2026-11-20

### Added

- The shared database now also holds counts from EG Link, an addon whose players' records Efficient Games publishes as open data under CC BY 4.0. They were counted on the live servers, and the part that fits Drop Tables is 8,591 corpses of 837 mobs, looted solo. With them the database knows 914 mobs instead of 342. Corpses looted in a group are left out, since EG Link doesn't say how big the group was, and so are quest items. The kill spots come along, so the map button in the Loot Finder shows for most of these mobs.
- The shared database now also holds the loot that Everloot's players recorded on the live servers, which Everloot publishes under CC BY-SA 4.0: 12,982 opened corpses of 1,274 mobs from 27 installs. 660 of those mobs weren't in the database yet. Everloot doesn't count kills or corpses that left nothing, so those follow the other counts of the mob, but the money and stack sizes are Everloot's own. Names, levels and places come from the mobs its players saw. Everloot doesn't record that in dungeons, so dungeon mobs have their names but no zone yet.
- Quest items are now left out of every imported source by their item class, the same way the addon leaves them out of your own counts. EG Link and Blackthornes Farmer had let some through, Sunscale Feather and Blood Shard among them.
- Skinning is counted. When you skin a corpse, Drop Tables records what it gave, whoever killed the mob, and works out the chances per skinned corpse. They have a place of their own everywhere, apart from the loot: a second row of icons under the target, a Skinning section in the drop table window, a Skinning line in the tooltip, and a Skinning category at the bottom of the Loot Finder. Pick a leather there and it lists the mobs that give it, with their level, the Skinning skill they need and the chance. The mob it shows for each item is the lowest level one with at least 3 skinned corpses, since that's where you can get it soonest. Pristine Leather, Hide and Scale are marked, because the Bountiful Harvest perk gives more of them.
- Skinning is shared like the loot: with players who ask about the mob, with your group and in the export. It goes out in messages of its own, so older versions of the addon skip it and still read the loot.
- The shared database holds skinning from EG Link and Everloot: 6,105 skinned corpses of 352 mobs. Corpses EG Link's players skinned with Bountiful Harvest are left out. 29 of those mobs had no loot counts at all, and the database now knows 1,602 mobs.
- The Loot Finder has a g/ph column, roughly what farming a mob is worth in an hour, with g, s and c in the coins' colours. The list of mobs that drop an item shows it for each mob, and the item lists show it for the best mob. In Skinning it counts what skinning alone brings, with every kill skinned. The drop table window has a Price column with the price g/ph uses for each item, faded for items that don't count, and its tooltip says where the price comes from. It adds up the mob's money and items at what they sell for, the auction price from Auctionator or TradeSkillMaster when one of them is installed and knows the item, and the vendor price otherwise. Items bound on pickup count at their vendor price, and rare and epic drops are left out, so one lucky drop doesn't decide it. Random world drops are left out too, unless you tick "World drops in g/ph" above the list; then they count at their vendor price. The kills an hour come from a new setting, 70 on mobs of your level by default, more on mobs below you and fewer on mobs above. The prices stay in your game and are never shared.
- Engineers' target dummies are left out of the shared database. Looting your own dummy gives back what it was made of, which made Target Dummy look like a mob that drops Linen Cloth and Bronze Bars.

### Fixed

- When a player asks about a mob and logs off before your answer goes out, the server's "No player named ... is currently playing" no longer shows up in your chat, and the rest of the answers to that player are dropped.
- Dragging the corner of the Loot Finder or the drop table window to resize it no longer makes it jump to its largest size, and a window never grows past the edge of the screen. One saved larger than the screen shrinks to fit when it opens.

### Changed

- The best mob the Loot Finder shows for an item is now the one that brings the most gold an hour, among the mobs with at least 3 kills, so one lucky kill no longer puts a mob on top. Without any prices the best chance decides, and a mob with fewer kills only shows there when no other mob drops the item.

## [0.4.0] - 2026-11-19

### Added

- The shared database now also holds 4,052 looted corpses of 305 mobs that Blackthornes Farmer counted on the Forever beta, from the version of its data that was under the MIT license. 259 of those mobs had no counts at all before. Quest items and leather from skinning are left out, and where players already sent counts of a mob, the money and stack sizes still come from the players alone.

### Changed

- The shared database can say where a mob was killed. The map button in the Loot Finder now shows for every mob with known kill spots, not only for the ones you killed yourself, and the map marks your spots and the shared ones together. Most of the mobs above come with their spots.
- `/dt export` sends your kill spots again, so the spots of the mobs you kill reach the shared database too. An export gets about a quarter bigger, and it still fits in one part for nearly everyone.

## [0.3.1] - 2026-11-19

### Changed

- The shared drop data is under CC BY-SA 4.0 now, so other addons can use it as long as they credit Drop Tables and keep it open. The addon's code stays all rights reserved.
- The share page now links to the GitHub issue it opened, so you can read the bot's answer without an account. If sending fails, your text stays in the box for the next try.
- An export over the daily limit of 20 used to be turned down. Now it waits and goes in the next day.
- The share window now shows the share page address first and the text under it, because the page has to be open before you can paste the text. The address starts selected, so Ctrl+C right after opening the window copies it.

### Fixed

- If you did a /reload while a corpse still had loot in it, reopening that corpse counted it as a second kill. The addon now remembers the corpses it has counted across a reload, for up to 15 minutes after the kill.
- When the game hid a value in a loot window, like an item link or a stack size, the whole window went unrecorded. Now only that slot is left out.

## [0.3.0] - 2026-11-18

### Added

- A shared database comes with the addon. It holds the counts from every `/dt export` players send, so mobs you've never killed have chances too, and they show in the Loot Finder. Your own kills that are already in it don't count twice. The drop table window says how many kills come from it, and Only mine hides it.
- A share page for exports. Paste the text from `/dt export` there and press Send, and you don't need an account for it. A bot checks the text and adds it to the shared database.
- The Loot Finder and the drop table window end in a share card, a square button with the number of your mobs the community doesn't have yet. It glows softly while there's something to share and calms down once you've copied your export. The small SHARE link in the title bar is gone.
- Six colour themes for the windows, called Ledger (the old gold), Frost, Fel, Blood, Arcane and Stone. You pick one with the squares next to OPACITY in the Loot Finder's title bar, and every window changes at once.
- The Loot Finder item list has a Kills column with the number of kills behind the best mob's chance. When two mobs give the same chance, the one with more kills is shown, and chances from fewer than 10 looted corpses are grey like in the mob list.

### Changed

- The drop table window has a new top. Kills, looted corpses and the share of empty corpses show as large numbers next to a bar of where the kills come from, whether that's you, other players or the shared database. The subtitle gives the level and the zone, and the window can be made as narrow as 300 pixels. The Icons and Tooltip switches moved to the options, and `/dt icons` and `/dt tooltip` still work.
- `/dt export` always holds everything of yours that the shared database doesn't have yet, plus what other players sent you. Copying the text and never sending it no longer leaves those counts out of later exports, and the Everything checkbox is gone.
- Exports leave out kill spots, which the shared database doesn't use, so more mobs fit in one part.
- A mob the shared database already knows well is asked about once a day, the same as one you've looted 100 times yourself.
- The Loot Finder stays quick with a big table. It works out each mob's chances once and keeps them until that mob's counts change, and the search waits for you to stop typing.
- The drop table window redraws once after several changes in a row, and only for item info it actually shows.
- Names and levels of creatures you never killed, and that nobody sent counts of, stay in memory for the session and are not saved. Those saved by earlier versions are dropped at login.

### Fixed

- Two open windows could show through each other in parts. Now the window you open or click comes to the front as a whole, and its frame lights up.
- Targeting a flight master or another friendly NPC no longer asks other players about its drops or puts a question mark under the target frame, and the drop table window no longer jumps to it.
- One player can no longer drag all chances of a mob down to zero with made-up empty kills. Another player's counts weigh at most 300 kills, and counts that claim far more empty corpses than everyone else are left out of the chances.
- A group member's counts are taken only for their own install, and one member can bring at most 30 mobs a day that you have no counts of.
- Each player gets one answer at a time however many questions they send, and only the player who asked can call off the answers to them.
- An empty loot window is no longer put down to the wrong corpse when the interact key and the mouse are on two different ones. In that case neither one counts.
- Loot you take right after casting at the next mob counts. Only skinning a corpse that showed no loot is left out.
- A mob that a guard or another player finished counts when you open its corpse.
- A corpse that had no loot at first and opens with loot later gives its loot.
- Restore defaults moves open windows back to the middle.
- Copying the export text counts when you let go of Ctrl before C, and Cmd+C works on a Mac.
- /dt on a friendly NPC opens the table without it, and /dt find keeps your capital letters.
- In the Loot Finder the map button shows only for mobs you killed yourself, and a new list starts at the top. The zone list also picks up zones from new kills.
- A long mob name no longer runs under the buttons in the title bar.

### Removed

- The GitHub form for exports. The share page takes its place.

## [0.2.7] - 2026-11-18

### Fixed

- The addon no longer answers its own questions. The hidden channel hands each question back to the player who asked it, and the addon used to answer it by whispering you counts you already had.

## [0.2.6] - 2026-11-18

### Fixed

- A corpse that sparkles but opens with nothing in it now counts as one that left nothing.

## [0.2.5] - 2026-11-18

### Changed

- Other players' counts go into the chances right away, added to yours, instead of waiting for 30 looted corpses of a mob. Chances from fewer than 10 looted corpses show in grey.
- When the addon answers about a mob with many different drops, it sends the most frequent ones first and leaves out the rarest.
- The addon asks about the same mob again after 2 minutes if someone answered last time, and waits longer each time nobody did.
- Mobs you target one after another wait in line and get asked about in turn.
- Mobs with 100 or more looted corpses are asked about once a day, so their chances keep up with what other players collect.

## [0.2.4] - 2026-11-17

### Added

- Restore defaults in the options puts every setting and window position back the way they were on first install. Your recorded drops stay.

## [0.2.3] - 2026-11-17

### Fixed

- In a group, counts from the other players never arrived, because the game gives their names in a different form than the addon expected.
- If an answer whispered to a two-part name doesn't go through, the addon tries the name once more with a dash between the parts.
- In a group, a corpse your partner looted counted as an empty kill on your side, which halved the chances.
- Skinning a corpse right after the kill no longer counts the leather as a drop.
- An empty loot window no longer gets put on your target when it belongs to another corpse.
- If the addon can't join its channel at login, it keeps trying instead of giving up until the next reload.
- A message that can't be delivered, for example to a player who just logged off, no longer holds up the others for a minute.
- Counts from other players that can't be right (more drops than corpses, a stack of 0) are left out instead of breaking the drop table window.
- New kills show up in the table right away instead of after looting.
- The text in the export window wraps instead of being cut off.
- The Loot Finder updates when you switch Only mine and when item names load.

### Removed

- The Share drop counts option. Drop Tables always swaps counts with other players.

## [0.2.2] - 2026-11-17

### Changed

- No changes you would notice in game.

## [0.2.1] - 2026-11-17

### Fixed

- Exports from game clients in languages other than English are no longer turned down because of the mob names in them.

## [0.2.0] - 2026-11-17

### Added

- Players who run the addon fill in each other's tables. When you target a mob you have little data on, the addon asks other players over a hidden channel and they whisper their counts back. Their kills show in the drop table window next to yours, and once they add up to 30 looted corpses of a mob they count toward the chances.
- In a party or raid, everyone with the addon sends their new counts to the group once a minute.
- `/dt export` opens a window with your counts packed into one piece of text, to paste into a form on GitHub for the shared database. Select marks the text, Ctrl+C copies it, and the link opens the form with a title already filled in.
- An Only mine switch in the drop table window hides other players' counts.
- Once a session, a chat line reminds you when you have a lot of new counts to share. You can turn it off in the options.
- A Share button in the drop table window and Share my tables in the minimap button menu.

### Changed

- The "?" under the target frame says why nothing is shown: only world drops, everything below your minimum quality, or too few looted corpses.
- The tooltip says how many drops your minimum quality hides.
- Chances from other players use the median across players, so one player's numbers can't outweigh everyone else's.

### Removed

- Bridge mode and `/dt bridge`. Counts no longer go to volunteer bridge players.

## [0.1.0] - 2026-11-17

First test build. It records your own kills and loot and shows drop chances under the target frame, in the tooltip and in the drop table window, with the Loot Finder and kill spots on the map.

[Unreleased]: https://github.com/valcheffnet/DropTables/compare/v0.6.2...HEAD
[0.6.2]: https://github.com/valcheffnet/DropTables/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/valcheffnet/DropTables/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/valcheffnet/DropTables/compare/v0.5.4...v0.6.0
[0.5.4]: https://github.com/valcheffnet/DropTables/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/valcheffnet/DropTables/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/valcheffnet/DropTables/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/valcheffnet/DropTables/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/valcheffnet/DropTables/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/valcheffnet/DropTables/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/valcheffnet/DropTables/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/valcheffnet/DropTables/compare/v0.2.7...v0.3.0
[0.2.7]: https://github.com/valcheffnet/DropTables/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/valcheffnet/DropTables/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/valcheffnet/DropTables/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/valcheffnet/DropTables/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/valcheffnet/DropTables/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/valcheffnet/DropTables/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/valcheffnet/DropTables/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/valcheffnet/DropTables/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/valcheffnet/DropTables/releases/tag/v0.1.0
