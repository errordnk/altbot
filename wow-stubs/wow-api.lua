---@meta
-- LuaCATS/EmmyLua annotations for the WoW 3.3.5 (WotLK) client Lua API.
--
-- This file is never loaded by the game - it exists purely so lua-language-
-- server (LuaLS, used by Zed/VSCode's Lua extension) can resolve globals and
-- offer autocomplete/hover docs while editing AltBot.lua. Point LuaLS at
-- this folder via `workspace.library` in .luarc.json.
--
-- Scope: this only covers the *global* API functions AltBot.lua actually
-- calls (verified by grepping the addon source and cross-checking against
-- locally-defined functions). It intentionally does NOT try to be a full
-- WoW API library - there's no maintained, ready-made LuaCATS package for
-- 3.3.5 specifically (the well-known community one, Ketho/vscode-wow-api,
-- only targets Retail/MoP Classic/Vanilla Classic). Add more stubs here as
-- AltBot grows and LuaLS starts flagging new undefined globals.

---@class UnitId

---Returns the name (and, for players, realm) of a unit.
---@param unit UnitId|string
---@return string name
---@return string? realm
function UnitName(unit) end

---Returns the localized and non-localized class name plus class filename token.
---@param unit UnitId|string
---@return string className
---@return string classFilename
---@return number classId
function UnitClass(unit) end

---@param unit UnitId|string
---@return number level -- -1 for a unit whose level is unknown/greyed out
function UnitLevel(unit) end

---@param unit1 UnitId|string
---@param unit2 UnitId|string
---@return boolean
function UnitIsUnit(unit1, unit2) end

---@param unit UnitId|string
---@return boolean
function UnitIsPlayer(unit) end

---@param unitA UnitId|string
---@param unitB UnitId|string
---@return boolean
function UnitIsFriend(unitA, unitB) end

---@param unit UnitId|string
---@return boolean
function UnitIsDeadOrGhost(unit) end

---@param unit UnitId|string
---@return boolean
function UnitExists(unit) end

---False for a group member whose slot is still shown (e.g. "left the
---game" in the party frame) but who's actually offline/disconnected.
---@param unit UnitId|string
---@return boolean
function UnitIsConnected(unit) end

---Removes a unit from the player's party/raid. Leader/assist only.
---@param unit UnitId|string
function UninviteUnit(unit) end

---@return number
function GetNumRaidMembers() end

---@return number
function GetNumPartyMembers() end

---Converts the player's current party into a raid group.
function ConvertToRaid() end

---Leaves the player's current party or raid.
function LeaveParty() end

---@param msg string
---@param chatType string
---@param language string?
---@param channel string?
function SendChatMessage(msg, chatType, language, channel) end

---@param frameType string?
---@param name string?
---@param parent table?
---@param template string?
---@return table frame
function CreateFrame(frameType, name, parent, template) end

---Seconds since the client started (not wall-clock time).
---@return number
function GetTime() end

---@param name string
---@return string value
---@return string defaultValue
function GetCVar(name) end

---@param name string
---@param value string|number
function SetCVar(name, value) end

---Cancels an in-progress player trade.
function CancelTrade() end

---@param item number|string|nil -- itemId or item link; returns nil for an invalid/unknown item
---@return any texturePath -- string path, or nil/false depending on caller usage
function GetItemIcon(item) end

---Registers a filter run against every chat message of the given event
---before it's added to a chat frame; return true to suppress the line.
---@param event string
---@param filterFunc fun(chatFrame: table, event: string, ...: any): boolean
function ChatFrame_AddMessageEventFilter(event, filterFunc) end

---@param dropdown table
---@param width number
function UIDropDownMenu_SetWidth(dropdown, width) end

---@param dropdown table
---@param text string
function UIDropDownMenu_SetText(dropdown, text) end

---@param dropdown table
---@param initFunc fun(self: table, level: number, menuList: table?)
---@param displayMode "MENU"|nil -- "MENU" makes a context menu instead of a dropdown button
---@param level number?
---@param menuList table?
function UIDropDownMenu_Initialize(dropdown, initFunc, displayMode, level, menuList) end

---Fields of the info table passed to UIDropDownMenu_AddButton.
---@class UIDropDownMenuInfo
---@field text string?
---@field value any?
---@field func function?
---@field arg1 any?
---@field arg2 any?
---@field checked boolean|function?
---@field notCheckable boolean?
---@field isTitle boolean?
---@field disabled boolean?
---@field hasArrow boolean?
---@field keepShownOnClick boolean?
---@field icon string?
---@field notClickable boolean?
---@field tooltipTitle string?
---@field tooltipText string?
---@field tooltipOnButton boolean?

---@return UIDropDownMenuInfo info
function UIDropDownMenu_CreateInfo() end

---@param info UIDropDownMenuInfo
---@param level number?
function UIDropDownMenu_AddButton(info, level) end

function CloseDropDownMenus() end

---Cursor position in UI (screen pixel) coordinates.
---@return number x
---@return number y
function GetCursorPosition() end

-- ---------------------------------------------------------------------
-- Global string-library aliases. The client exposes most of Lua's
-- `string.*` functions as bare globals for legacy (pre-5.1-namespacing)
-- addon compatibility; AltBot.lua uses these instead of `string.lower`
-- etc. `wipe` and `time` are separate Blizzard-added globals.
-- ---------------------------------------------------------------------

---@param s string
---@return string
function strlower(s) end

---@param s string
---@param pattern string
---@param init number?
---@param plain boolean?
---@return number? start
---@return number? finish
function strfind(s, pattern, init, plain) end

---@param s string
---@param i number
---@param j number?
---@return string
function strsub(s, i, j) end

---WoW's global alias of string.match.
---@param s string
---@param pattern string
---@param init number?
---@return string ...
function strmatch(s, pattern, init) end

---Clears every key from a table in place and returns it.
---@generic T: table
---@param t T
---@return T
function wipe(t) end

---@param format string?
---@return number
function time(format) end

-- ---------------------------------------------------------------------
-- Group / unit state, items, cursor, trade, chat edit box, dropdown menus.
-- ---------------------------------------------------------------------

---Whether `unit` is close enough for an interaction. Only works for units
---the client currently has (e.g. group members).
---  1 = inspect (~28 yd), 2 = trade (~11 yd), 3 = duel (~10 yd), 4 = follow (~28 yd).
---@param unit UnitId|string
---@param distIndex 1|2|3|4
---@return boolean? inRange  -- 1/true in range, nil/false otherwise
function CheckInteractDistance(unit, distIndex) end

---@return boolean? -- true/1 if you are the party leader
function IsPartyLeader() end

---@return boolean? -- true/1 if you are the raid leader
function IsRaidLeader() end

---Sets the loot method. Requires group leader.
---@param method "freeforall"|"roundrobin"|"master"|"group"|"needbeforegreed"
---@param masterPlayer string? -- required for "master"
---@param threshold number? -- item quality threshold for "group"/"master"
function SetLootMethod(method, masterPlayer, threshold) end

---Opens a trade window with `unit` (must be within trade range).
---@param unit UnitId|string
function InitiateTrade(unit) end

---@return boolean
function IsShiftKeyDown() end

---Returns the frame currently under the mouse cursor.
---@return table? frame
function GetMouseFocus() end

---@return boolean -- true if the mouse cursor is carrying an item
function CursorHasItem() end

---Sets the mouse cursor to a built-in cursor name (e.g. "BUY_CURSOR", "ITEM_CURSOR").
---@param cursor string
function SetCursor(cursor) end

---Restores the default mouse cursor.
function ResetCursor() end

---Returns information about an item (by id, name or item link). Nil fields
---if the item isn't in the client's cache yet.
---@param item number|string
---@return string? name
---@return string? link
---@return number? quality -- 0 poor .. 6 artifact
---@return number? itemLevel
---@return number? requiredLevel
---@return string? itemType
---@return string? itemSubType
---@return number? stackCount
---@return string? equipLoc
---@return string? texture
---@return number? vendorPrice
function GetItemInfo(item) end

---Returns the color of an item quality.
---@param quality number
---@return number r
---@return number g
---@return number b
---@return string hex -- "ffrrggbb" without the |c prefix
function GetItemQualityColor(quality) end

---Returns the localized auction-house item class names, in a fixed order
---(the 12th is the quest class AltBot compares against).
---@return string ...
function GetAuctionItemClasses() end

---Inserts an item link into the active chat edit box; true if one took it.
---@param text string
---@return boolean
function ChatEdit_InsertLink(text) end

---Icon texture path of the item in an inventory slot of `unit` (nil if empty).
---Slot ids: 0 ammo, 1 head ... 16 main hand, 17 off hand, 18 ranged, 19 tabard.
---@param unit UnitId|string
---@param slotId number
---@return string? texture
function GetInventoryItemTexture(unit, slotId) end

---Localized race name (gendered for the unit) and the race token.
---@param unit UnitId|string
---@return string race
---@return string raceToken
function UnitRace(unit) end

---Upper-cases a string (WoW alias of string.upper).
---@param s string
---@return string
function strupper(s) end

---Whether the client has `unit` in view (close enough to be drawn / inspected).
---@param unit UnitId|string
---@return boolean
function UnitIsVisible(unit) end

---Item link of the item in an inventory slot of `unit` (nil if empty).
---@param unit UnitId|string
---@param slotId number
---@return string? link
function GetInventoryItemLink(unit, slotId) end

---Hides a standard UI panel window and releases its UI-panel slot (use this, not frame:Hide(), for Blizzard panels).
---@param frame table
---@param skipSetPoint boolean?
function HideUIPanel(frame, skipSetPoint) end

---Opens/closes a dropdown menu.
---@param level number?
---@param value any?
---@param dropDownFrame table?
---@param anchorName string|table?
---@param xOffset number?
---@param yOffset number?
---@param menuList table?
---@param button table?
---@param autoHideDelay number?
function ToggleDropDownMenu(level, value, dropDownFrame, anchorName, xOffset, yOffset, menuList, button, autoHideDelay) end

-- ---------------------------------------------------------------------
-- Global UI objects/frames/tables referenced directly by name rather than
-- returned from a function call.
-- ---------------------------------------------------------------------

---Standard 12pt Blizzard UI font object, commonly passed to
---FontString:SetFontObject(...).
---@type table
GameFontNormal = nil

---@type table
GameFontHighlightLarge = nil

---Font object matching the default chat window's font.
---@type table
ChatFontNormal = nil

---The root frame nearly everything in the default UI is parented to.
---@type table
UIParent = nil

---The minimap frame.
---@type table
Minimap = nil

---The default (leftmost) chat frame - has an `AddMessage(text)` method.
---@type table
DEFAULT_CHAT_FRAME = nil

---The shared tooltip frame shown on mouseover.
---@type table
GameTooltip = nil

---The player trade window frame.
---@type table
TradeFrame = nil

---FontString in the trade window showing the other party's name
---(`:GetText()`).
---@type table
TradeFrameRecipientNameText = nil

---The full-screen world frame everything else sits over.
---@type table
WorldFrame = nil

---Localized "Soulbound" tooltip text (also matches the item tooltip line).
---@type string
ITEM_SOULBOUND = nil

---Maps class filename tokens (e.g. "MAGE") to {r,g,b} color tables.
---@type table<string, {r: number, g: number, b: number}>
RAID_CLASS_COLORS = nil

---Maps class filename tokens (e.g. "MAGE") to the localized (male) class names.
---@type table<string, string>
LOCALIZED_CLASS_NAMES_MALE = nil

---The red/yellow error-text frame in the middle of the screen (`:AddMessage(text, r, g, b, alpha)`).
---@type table
UIErrorsFrame = nil

---Localized "Trade cancelled." system string.
---@type string
ERR_TRADE_CANCELLED = nil

---Maps class tokens to localized female class names.
---@type table<string, string>
LOCALIZED_CLASS_NAMES_FEMALE = nil

---@param unit UnitId|string
---@return number
function UnitXP(unit) end

---@param unit UnitId|string
---@return number
function UnitXPMax(unit) end

---@return number copper
function GetMoney() end

---@param bag number
---@return number
function GetContainerNumSlots(bag) end

---@param bag number
---@return number
function GetContainerNumFreeSlots(bag) end

---@param index number
---@return string? name
---@return number? rank
---@return number? subgroup
function GetRaidRosterInfo(index) end

---@param tab string
function ToggleCharacter(tab) end

---Toggles all bag windows (closes them if open).
function OpenAllBags() end

function ToggleQuestLog() end

---Moves a raid member to a subgroup (leader/assist only; fails if that group is full).
---@param index number
---@param subgroup number
function SetRaidSubgroup(index, subgroup) end

---Swaps two raid members between their subgroups (leader/assist only).
---@param index1 number
---@param index2 number
function SwapRaidSubgroup(index1, index2) end

---@return boolean? -- true/1 if you are a raid assistant
function IsRaidOfficer() end

---Plays a UI sound by name (3.3.5 uses string names such as "igCharacterInfoOpen").
---@param sound string|number
function PlaySound(sound, ...) end

---@param dropdown table
function UIDropDownMenu_DisableDropDown(dropdown) end

---@param spell number|string
---@return string? name
---@return string? rank
---@return string? icon
function GetSpellInfo(spell) end

---@param name string
---@return number index -- 0 if there is no such macro
function GetMacroIndexByName(name) end

---@param index number
---@param name string
---@param icon string|number
---@param body string
function EditMacro(index, name, icon, body) end

---@param name string
---@param icon string|number
---@param body string
---@param perCharacter boolean?
---@return number index
function CreateMacro(name, icon, body, perCharacter) end

---Puts a macro on the cursor.
---@param index number
function PickupMacro(index) end

---@return number
function GetNumMacroIcons() end

---@param index number
---@return string? texture
function GetMacroIconInfo(index) end

---Refreshes the memory figures of all addons (the cost is paid here, not in GetAddOnMemoryUsage).
function UpdateAddOnMemoryUsage() end

---@param addon string|number
---@return number kilobytes
function GetAddOnMemoryUsage(addon) end

---Opens the chat edit box with `text` in it.
---@param text string
---@param chatFrame table?
function ChatFrame_OpenChat(text, chatFrame) end

---@return number numEntries
---@return number numQuests
function GetNumQuestLogEntries() end

---@param index number
---@return string? title
---@return number? level
---@return string? tag
---@return number? suggestedGroup
---@return boolean? isHeader
function GetQuestLogTitle(index) end

---@param index number
---@return string? link
function GetQuestLink(index) end

---Hooks a global function: `hook` runs after the original every time it is called.
---@param name string
---@param hook function
function hooksecurefunc(name, hook) end

---The native quest log frame and its list redraw.
---@type table
QuestLogFrame = nil
function QuestLog_Update() end

---@type table<string, function>
SlashCmdList = nil

---@param s string
---@return string
function strtrim(s) end

---Buys an item from the open vendor window.
---@param index number
---@param quantity number
function BuyMerchantItem(index, quantity) end

---@param index number
---@return string? link
function GetMerchantItemLink(index) end

---@param index number
---@return string? name
---@return string? texture
---@return number? price -- copper, for one stack of `quantity` items
---@return number? quantity
function GetMerchantItemInfo(index) end

---Plays a sound file from the game's data.
---@param path string
function PlaySoundFile(path) end
