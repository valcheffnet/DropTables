# Drop Tables

Drop Tables is a World of Warcraft: Forever addon that records what drops from the mobs you kill and shows the drop chances in game.

This is an early test build, so expect bugs. At first the tables only know your own kills. If other players run the addon too, they can fill the gaps: when you target a mob you know little about, the addon asks them, and their counts show up in your tables next to yours. You can also copy an export out of the game. I'd like to turn those exports into a shared database that comes with the addon, but that part is new and I'm still testing it.

## Download

The latest version is here: https://github.com/valcheffnet/DropTables/releases/latest

Under Assets, download `DropTables-x.y.z.zip`. The Source code archives are not the addon.

## Install

1. Close the game.
2. Unzip the file into `World of Warcraft\_forever_\Interface\AddOns\`. You should end up with `Interface\AddOns\DropTables\DropTables.toc`. If you get `DropTables\DropTables\DropTables.toc`, move the inner folder up one level.
3. Start the game and check that Drop Tables is enabled in the AddOns list on the character screen.

To update, delete the old `DropTables` folder and unzip the new one. Your recorded drops live in the WTF folder, so updating doesn't touch them.

## Using it

The addon starts with an empty table and fills it as you kill and loot. Target or mouse over a mob and its most likely drops show up under the target frame and in its tooltip. The minimap button opens the loot finder on left click and a menu on right click. The table window shows how many kills are yours and how many came from other players, and Only mine hides theirs. Their counts only feed into the chances once they add up to 30 looted corpses of a mob, so for a while a mob you've never killed can show other players' kills and no chances at all.

Commands (`/droptables` works too):

- `/dt` opens or closes the drop table window, on your target if you have one
- `/dt find` opens the loot finder, and `/dt find linen` searches for linen straight away
- `/dt options` (or `/dt config`) opens the settings
- `/dt unlock` lets you drag the icons under the target frame somewhere else, `/dt lock` fixes them in place again. Blizzard's Edit Mode does the same.
- `/dt reset` puts the icons back under the target frame
- `/dt icons`, `/dt tooltip` and `/dt minimap` turn the icons, the tooltip lines or the minimap button on and off
- `/dt export` opens the window with the text to share (see below)
- `/dt status` shows how many mobs and kills you have recorded, what other players have sent you and how many of your mobs are new since your last export
- `/dt debug` puts a line in chat for every sharing message the addon sends or gets, and says why it ignored one, which helps when you test sharing with a friend. It turns itself off when you reload.

## Sharing your tables

Every table someone shares makes the numbers better for everybody. Type `/dt export` (or pick Share my tables in the minimap button menu), press Select and then Ctrl+C in the window, open the form link under the text and paste it there. For now you need a GitHub account for that. An export only carries what changed since your last one, so doing it now and then is enough. A big table can come out in several parts, and each part goes into its own form.

## What it sends

Share drop counts with other players is on by default, and you can turn it off in the options. While it's on, the addon asks about mobs it has little data on over a hidden addon channel. The question says whose counts you already have, and players with something newer whisper theirs back to you as addon messages, so none of it shows up in your chat. Your addon answers other people's questions the same way. In a group, everyone who runs Drop Tables also sends their own new counts to the rest of the group once a minute. The messages carry mob and item ids, kill and drop counts, levels, the zones where the kills happened, the mob's name and a random id of your install. They never carry character names or account details. So that one player can't fill the tables with made-up numbers, the addon takes only a few new installs from each player per day and leaves out counts that are far off what everyone else reports. With sharing off, your addon stops sending anything, to the channel or to your group, but it still keeps whatever your group sends you.

The export carries the same things plus the spots on the map where you made your kills. Anything you paste into the form is public.

## Bugs

Open an issue here. To see Lua errors in game, type `/console scriptErrors 1` once.

## License

All rights reserved, see LICENSE. You can use the addon in game and read the code, but not republish it or reuse the code without asking first.
