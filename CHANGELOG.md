# Changelog

## [Unreleased]

### Added

- A shared database comes with the addon. It holds the counts from every `/dt export` players send, so mobs you've never killed have chances too, and they show in the Loot Finder. Your own kills that are already in it don't count twice. The drop table window says how many kills come from it, and Only mine hides it.
- A share page for exports: paste the text from `/dt export` there and press Send, no account needed. A bot checks it and adds it to the shared database.
- The Loot Finder has a SHARE link in its title bar, like the drop table window.
- The Loot Finder item list has a Kills column: how many kills of the best mob its chance comes from. When two mobs give the same chance, the one with more kills is shown, and chances from fewer than 10 looted corpses are grey like in the mob list.

### Changed

- `/dt export` always holds everything of yours that the shared database doesn't have yet, plus what other players sent you. Copying the text and never sending it no longer leaves those counts out of later exports, and the Everything checkbox is gone.
- Exports leave out kill spots, which the shared database doesn't use, so more mobs fit in one part.
- A mob the shared database already knows well is asked about once a day, the same as one you've looted 100 times yourself.
- The Loot Finder stays quick with a big table. It works out each mob's chances once and keeps them until that mob's counts change, and the search waits for you to stop typing.
- The table window redraws once after several changes in a row, and only for item info it actually shows.
- Names and levels of creatures you never killed, and that nobody sent counts of, stay in memory for the session and are not saved. Those saved by earlier versions are dropped at login.

### Fixed

- Targeting a flight master or another friendly NPC no longer asks other players about its drops or puts a question mark under the target frame, and the details window no longer jumps to it.
- One player can no longer drag all chances of a mob down to zero with made-up empty kills. Another player's counts weigh at most 300 kills, and counts that claim far more empty corpses than everyone else are left out of the chances.
- A group member's counts are taken only for their own install, and one member can bring at most 30 mobs a day that you have no counts of.
- Each player gets one answer at a time however many questions they send, and only the player who asked can call off the answers to them.
- An empty loot window is not put down to the wrong corpse when the interact key and the mouse are on two different ones; then neither counts.
- Loot you take right after casting at the next mob counts. Only skinning a corpse that showed no loot is left out.
- A mob that a guard or another player finished counts when you open its corpse.
- A corpse that had no loot at first and opens with loot later gives its loot.
- Restore defaults moves open windows back to the middle, and the Debug messages checkbox opens and closes the DT Debug tab the way /dt debug does.
- Copying the export text counts when you let go of Ctrl before C, and Cmd+C works on a Mac.
- /dt on a friendly NPC opens the table without it, and /dt find keeps your capital letters.
- In the Loot Finder the map button shows only for mobs you killed yourself, a new list starts at the top, and the zone list picks up zones from new kills.
- A long mob name stops before the SHARE button.

### Removed

- The GitHub form for exports. The share page takes its place.

## [0.2.7] - 2026-11-18

### Fixed

- The addon no longer answers its own questions. The hidden channel hands each question back to the player who asked it, and the addon used to answer it by whispering you counts you already had.

## [0.2.6] - 2026-11-18

### Added

- `/dt debug` also shows what each loot window gave and why the addon skipped one.

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
- Debug messages in the options, the same switch as `/dt debug`.

### Changed

- `/dt debug` stays on after a reload or an update. It opens its own DT Debug chat tab and closes it again when you turn it off.
- `/dt debug` says when a group message is your own coming back, instead of calling it malformed.

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

### Changed

- `/dt debug` lines start with the time.

### Removed

- The Share drop counts option. Drop Tables always swaps counts with other players.

## [0.2.2] - 2026-11-17

### Added

- `/dt debug` lines go to a chat tab called DT Debug if you make one, and stay out of your main chat.

## [0.2.1] - 2026-11-17

### Added

- `/dt debug` puts a chat line for every sharing message the addon sends or gets, and says why it ignored one. It turns itself off when you reload.

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

[Unreleased]: https://github.com/valcheffnet/DropTables/compare/v0.2.6...HEAD
[0.2.6]: https://github.com/valcheffnet/DropTables/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/valcheffnet/DropTables/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/valcheffnet/DropTables/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/valcheffnet/DropTables/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/valcheffnet/DropTables/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/valcheffnet/DropTables/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/valcheffnet/DropTables/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/valcheffnet/DropTables/releases/tag/v0.1.0
