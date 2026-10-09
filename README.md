# AltBot

A World of Warcraft **3.3.5a (WotLK)** addon for running a raid of [mod-playerbots](https://github.com/liyunfan1223/mod-playerbots)
bots on an AzerothCore server from one master character. Everything goes through plain whispers and group chat - no server
changes, no bridge addon.

The text of the in-game UI is English; names of quests are shown with their Russian titles next to them (ruRU client).

## What it does

- **Roster**: type the bot names (and class tokens such as `warlock`, `dk` for wild bots) into one textarea; the addon groups
  them, converts to a raid and keeps it in sync.
- **Modes**: *Solo* (roster put away), *Quest* (bots follow the master), *Farm* (bots grind on their own, with automatic
  bag unload / revive / parking of single bots). The mode, follow/stay and aggressive/defensive/passive are account-wide.
- **Stats board**: one draggable frame per raid group (the master is a column too) with hourly XP gain, class icon, name,
  bags, gold, XP % and level. Drag a column by its class icon to move a member between groups.
- **Per-bot windows**: bags (trade / sell / drag to reorder), armory (native-style paperdoll, GearScore), strategies
  (CleanBot-style co/nc form, also for the whole group from the master's column), quest log (grouped by zone, with the
  number of raid members that have each quest) and spellbook (grouped by talent tree, click to cast, right click to make a
  macro).
- **Chat control**: one checkbox per area (init, stats, farm, inventory, armory, strategies, questlog, spellbook); nothing but
  alarms and the mode line reaches the chat unless its checkbox is on.
- Buying at a vendor with a bot targeted (Quest mode) buys the item for the bot.

## Install

Copy this folder to `Interface/AddOns/AltBot`. The quest and spell tables are embedded in `AltBot.lua`, there are no
dependencies.

## Development

`AltBot.lua` is one big file; the main chunk is close to Lua 5.1's limit of 200 locals, so new helpers hang on the `NS`
table. Checks used: `luac -p AltBot.lua` and the Lua language server (`.luarc.json`, stubs for the WoW API in
`wow-stubs/wow-api.lua`). The addon cannot be run outside the game client.

The embedded data tables are generated offline from the sources listed below (the generator scripts are not part of this
repository).

## Data credits

- Spell/talent-tree tables: Wowhead (WotLK Classic).
- Quest titles and quest zones: generated from the data of the author's own QuestChromeCraft addon.
- Zone names and their Russian translations: the Questie addon's tables.
- `playerbot.txt` is a Russian translation of the mod-playerbots configuration file, kept for reference.

## License

[MIT](LICENSE). The embedded data tables come from the sources above and keep their own terms.
