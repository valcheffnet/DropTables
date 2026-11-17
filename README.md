# Drop Tables

Drop Tables is a World of Warcraft: Forever addon that records what drops from the mobs you kill and shows the drop chances in game. This is an early test build, so expect bugs.

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

Commands:

- `/dt` drop table of your target
- `/dt find` loot finder
- `/dt options` settings

## What it sends

Share my data is on by default and you can turn it off in the options. While it's on, the addon sends your drop counts to players who run it in bridge mode, over addon whispers: mob and item ids, kill counts, and the zones and spots where the kills happened. Character names and account details are never part of it.

## Bugs

Open an issue here. To see Lua errors in game, type `/console scriptErrors 1` once.
