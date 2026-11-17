# Changelog

## [Unreleased]

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

[Unreleased]: https://github.com/valcheffnet/DropTables/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/valcheffnet/DropTables/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/valcheffnet/DropTables/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/valcheffnet/DropTables/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/valcheffnet/DropTables/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/valcheffnet/DropTables/releases/tag/v0.1.0
