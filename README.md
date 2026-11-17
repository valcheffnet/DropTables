# Drop Tables

Drop Tables is a World of Warcraft: Forever addon that records what drops from the mobs you kill and shows the drop chances in game.

This is an early test build, so expect bugs. For now every table comes from your own kills and loot: the addon starts empty, and the numbers get more reliable the more you play. There is also an experimental feature that sends drop counts between players who run the addon. That's the part I'm testing right now, and what it collects doesn't show up in anyone's tables yet.

## Download

The latest version is here: https://github.com/valcheffnet/DropTables/releases/latest

Under Assets, download `DropTables-x.y.z.zip`. The Source code archives are not the addon.

## Install

1. Close the game.
2. Unzip the file into `World of Warcraft\_forever_\Interface\AddOns\`. You should end up with `Interface\AddOns\DropTables\DropTables.toc`. If you get `DropTables\DropTables\DropTables.toc`, move the inner folder up one level.
3. Start the game and check that Drop Tables is enabled in the AddOns list on the character screen.

To update, delete the old `DropTables` folder and unzip the new one. Your recorded drops live in the WTF folder, so updating doesn't touch them.

## Using it

The addon starts with an empty table and fills it as you kill and loot. Target or mouse over a mob and its most likely drops show up under the target frame and in its tooltip. The minimap button opens the loot finder on left click and a menu on right click.

Commands (`/droptables` works too):

- `/dt` opens or closes the drop table window, on your target if you have one
- `/dt find` opens the loot finder, and `/dt find linen` searches for linen straight away
- `/dt options` (or `/dt config`) opens the settings
- `/dt unlock` lets you drag the icons under the target frame somewhere else, `/dt lock` fixes them in place again. Blizzard's Edit Mode does the same.
- `/dt reset` puts the icons back under the target frame
- `/dt icons`, `/dt tooltip` and `/dt minimap` turn the icons, the tooltip lines or the minimap button on and off
- `/dt status` shows how many mobs and kills you have recorded and how sharing is going
- `/dt bridge on` and `/dt bridge off` switch bridge mode, which collects other players' drop counts

## What it sends

Share my data is on by default and you can turn it off in the options. While it's on, the addon sends your drop counts to players who run it in bridge mode, over addon whispers: mob and item ids, kill counts, and the zones and spots where the kills happened. Character names and account details are never part of it.

## Bugs

Open an issue here. To see Lua errors in game, type `/console scriptErrors 1` once.

## License

All rights reserved, see LICENSE. You can use the addon in game and read the code, but not republish it or reuse the code without asking first.
