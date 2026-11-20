# Drop Tables

Drop Tables is a World of Warcraft: Forever addon that records what drops from the mobs you kill and shows the drop chances in game.

This is an early test build, so expect bugs. At first the tables only know your own kills. If other players run the addon too, they can fill the gaps: when you target a mob you know little about, the addon asks them, and their counts show up in your tables next to yours. You can also copy an export out of the game and send it from a web page. Everything sent there goes into a shared database that comes with the addon, so a new install already has chances for mobs you've never killed.

## Screenshots

Target a mob and its likely drops show up as icons under the target frame, each with its chance.

![Drop icons under the target frame of a Greater Plainstrider](screenshots/TargetedMob.png)

Mouse over a mob and its tooltip lists what it drops and how often.

![The tooltip of a Fleeting Plainstrider with its drop chances](screenshots/tooltip.png)

The drop table window follows your target and shows where the kills behind each chance came from.

![The drop table window for a Greater Plainstrider](screenshots/lootTable.png)

The Loot Finder works the other way round. Pick an item and it shows which mobs drop it, where, and how often.

![The Loot Finder showing the mobs that drop Strider Meat](screenshots/LootFinder.png)

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

Skinning is counted apart from the loot, per skinned corpse, since every skin gives something. The drop table window shows it in a section of its own, the tooltip on a line of its own, and the Loot Finder in its own category, where each leather lists the mobs that give it with the Skinning skill they need.

The g/ph column in the Loot Finder says roughly what farming a mob is worth in an hour. It takes the auction prices from Auctionator or TradeSkillMaster if you have one of them, the vendor price otherwise, and the kills per hour from the options.

Commands (`/droptables` works too):

- `/dt` opens or closes the drop table window, on your target if you have one
- `/dt find` opens the loot finder, and `/dt find linen` searches for linen straight away
- `/dt options` (or `/dt config`) opens the settings. Restore defaults at the bottom puts every setting and window back the way it was on first install.
- `/dt unlock` lets you drag the icons under the target frame somewhere else, `/dt lock` fixes them in place again. Blizzard's Edit Mode does the same.
- `/dt reset` puts the icons back under the target frame
- `/dt icons`, `/dt tooltip` and `/dt minimap` turn the icons, the tooltip lines or the minimap button on and off
- `/dt export` opens the window with the text to share (see below)
- `/dt status` shows how many mobs and kills you have recorded, what other players have sent you and how many of your mobs have new counts to share
- `/dt debug` puts a line in chat for every sharing message the addon sends or gets and for every loot window, and says why it ignored one, which helps when you test sharing with a friend or a count looks wrong. It opens a chat tab called DT Debug for these lines and stays on until you type `/dt debug` again, which closes the tab too.

## Sharing your tables

The shared database only grows when players send their tables in. Type `/dt export`, or click the share card at the bottom of the Loot Finder or the drop table window, then press Select and Ctrl+C in the window. Open the share page under the text, paste it there and press Send. You don't need an account for it. The export holds everything of yours that the shared database doesn't have yet, plus what other players sent you, so if you copy it and forget to send it, it's still there the next time. A big table can come out in several parts, and you send each part by itself. The page files it on GitHub, where a bot checks it and adds it to the shared database, usually within a few minutes. Players get the new counts with the next release of the addon.

## Data from other players

Drop Tables relies on drop counts from the players who run it. The addons swap them in the background as addon messages, so nothing shows up in your chat. Anything you send on the share page is public, and so is the shared database built from it (`data/shared.json` here, `Data.lua` in the addon). Both are published under CC BY-SA 4.0. In the drop table window, Only mine hides the counts of other players and the shared database alike.

## Bugs

Open an issue here. To see Lua errors in game, type `/console scriptErrors 1` once.

## License

The code is all rights reserved, see LICENSE. You can use the addon in game and read the code, but not republish it or reuse the code without asking first.

The drop data is different. Everything players send and the shared database built from it are under CC BY-SA 4.0 (see LICENSE-DATA), so other addons and sites can use them as long as they credit Drop Tables and keep what they make from them under the same license. The database also holds counts from Blackthornes Farmer that were published under the MIT license, counts from EG Link that Efficient Games published under CC BY 4.0, and loot that Everloot's players published under CC BY-SA 4.0. LICENSE-DATA says where each comes from and how to credit it.
