# Drop Tables

Drop Tables is a World of Warcraft: Forever addon that records what drops from the mobs you kill and shows the drop chances in game.

This is an early test build, so expect bugs. At first the tables only know your own kills. If other players run the addon too, they can fill the gaps: when you target a mob you know little about, the addon asks them, and their counts show up in your tables next to yours. You can also copy an export out of the game and send it on GitHub. Everything sent there goes into a shared database that comes with the addon, so a new install already has chances for mobs you've never killed. That part is new and still being tested.

## Download

The latest version is here: https://github.com/valcheffnet/DropTables/releases/latest

Under Assets, download `DropTables-x.y.z.zip`. The Source code archives are not the addon.

## Install

1. Close the game.
2. Unzip the file into `World of Warcraft\_forever_\Interface\AddOns\`. You should end up with `Interface\AddOns\DropTables\DropTables.toc`. If you get `DropTables\DropTables\DropTables.toc`, move the inner folder up one level.
3. Start the game and check that Drop Tables is enabled in the AddOns list on the character screen.

To update, delete the old `DropTables` folder and unzip the new one. Your recorded drops live in the WTF folder, so updating doesn't touch them.

## Using it

The addon starts with an empty table and fills it as you kill and loot. Target or mouse over a mob and its most likely drops show up under the target frame and in its tooltip. The minimap button opens the loot finder on left click and a menu on right click. The table window shows how many kills are yours and how many came from other players, and Only mine hides theirs. Their counts go straight into the chances together with yours, and a chance from fewer than 10 looted corpses shows in grey.

Commands (`/droptables` works too):

- `/dt` opens or closes the drop table window, on your target if you have one
- `/dt find` opens the loot finder, and `/dt find linen` searches for linen straight away
- `/dt options` (or `/dt config`) opens the settings. Restore defaults at the bottom puts every setting and window back the way it was on first install.
- `/dt unlock` lets you drag the icons under the target frame somewhere else, `/dt lock` fixes them in place again. Blizzard's Edit Mode does the same.
- `/dt reset` puts the icons back under the target frame
- `/dt icons`, `/dt tooltip` and `/dt minimap` turn the icons, the tooltip lines or the minimap button on and off
- `/dt export` opens the window with the text to share (see below)
- `/dt status` shows how many mobs and kills you have recorded, what other players have sent you and how many of your mobs are new since your last export
- `/dt debug` puts a line in chat for every sharing message the addon sends or gets and for every loot window, and says why it ignored one, which helps when you test sharing with a friend or a count looks wrong. It opens a chat tab called DT Debug for these lines and stays on until you type `/dt debug` again, which closes the tab too.

## Sharing your tables

Every table someone shares makes the numbers better for everybody. Type `/dt export` (or pick Share my tables in the minimap button menu), press Select and then Ctrl+C in the window, open the form link under the text and paste it there. For now you need a GitHub account for that. An export only carries what changed since your last one, so doing it now and then is enough. A big table can come out in several parts, and each part goes into its own form. A bot on GitHub checks the text and adds it to the shared database, and it answers in the issue, usually within a few minutes. Players get the new counts with the next release of the addon.

## Data from other players

Drop Tables relies on drop counts from the players who run it. The addons swap them in the background as addon messages, so nothing shows up in your chat. Anything you paste into the export form is public, and so is the shared database built from it (`data/shared.json` here, `Data.lua` in the addon). In the drop table window, Only mine hides the counts of other players and the shared database alike.

## Bugs

Open an issue here. To see Lua errors in game, type `/console scriptErrors 1` once.

## License

All rights reserved, see LICENSE. You can use the addon in game and read the code, but not republish it or reuse the code without asking first.
